# Kubernetes Priority-Based Scheduling & Preemption: Technical Evaluation Report

**Course**: Cloud Computing Lab (Evaluation 2 / Problem 05)  
**System Architecture**: Multi-Node Kubernetes (kind: 1 Control-Plane, 2 Workers) on containerd / Docker WSL 2  
**Core Mechanism**: Native `kube-scheduler` Priority Sorting, Node Filtering, and Preemption Cycle  

---

## 1. Executive Summary & Clarification for Faculty

This demonstration uses **100% native Kubernetes scheduling primitives**. No custom, simulated, or third-party schedulers are deployed. All decisions are executed by Kubernetes' built-in component: **`kube-scheduler`**.

When an evaluator asks:
> *"Why did you assign these priorities? What does baseline mean? Is your scheduler using a priority queue or did you write custom code?"*

The formal answers are:
1. **Scheduler Used**: We use the official **standard Kubernetes `kube-scheduler`** binary running in the control plane container.
2. **Priority Queue Mechanism**: `kube-scheduler` internally maintains an **active priority scheduling queue (`activeQ`)**, implemented as a **heap / priority queue**. Pods awaiting scheduling are sorted primarily by their numerical `PriorityClass` integer value.
3. **The Baseline**: The baseline represents the steady-state cluster utilization where worker nodes are intentionally populated with lower-priority workloads reserving guaranteed allocatable CPU, leaving insufficient residual capacity for large incoming pods.
4. **Real-World Relevance**: In production (e.g., Netflix, Uber, Google Cloud), non-critical background jobs (ETL, machine learning batch jobs, log transcoders) are given `low-priority` with `preemptionPolicy: PreemptLowerPriority`, while critical user-facing microservices (payment gateways, checkout APIs) run with `high-priority` so that during sudden traffic spikes, Kubernetes evicts disposable batch work to free compute immediately without waiting for cluster autoscaling.

---

## 2. Priority Modeling: Real-World Industry Mapping

Priority in Kubernetes is an admitted, immutable integer resolved by the API admission controller from a `PriorityClass` object (`scheduling.k8s.io/v1`).

| Priority Tier | `value` | `preemptionPolicy` | Real-World Workload Example | Operational Rationale |
| :--- | :---: | :---: | :--- | :--- |
| **`high-priority`** | **`100000`** | `PreemptLowerPriority` | **Payment Gateway, Checkout API, Auth Service** | Revenue-critical. Cannot tolerate pending latency. Must evict background jobs if the node is at capacity. |
| **`medium-priority`** | **`50000`** | `PreemptLowerPriority` | **Search Service, Recommendation Engine, Inventory API** | Customer-facing regular services. Can tolerate queueing behind checkout, but cannot be preempted by batch analytics. |
| **`low-priority`** | **`10000`** | `PreemptLowerPriority` *(or `Never` in order test)* | **Video Transcoding, Nightly ETL, Web Scraping, Log Analytics** | Fault-tolerant, restartable batch jobs. Can be cleanly killed and rescheduled later when nodes free up. |

*Why these numbers?*  
Kubernetes reserve values above `1,000,000,000` for system-critical daemonsets (`system-cluster-critical` = 2000000000, `system-node-critical` = 2000001000). User workload priorities are positive 32-bit integers ($\le 10^9$). We choose $100000$, $50000$, and $10000$ to maintain clear mathematical stratification across tiers.

---

## 3. Deep Dive: Which Scheduler & How the Priority Queue Works

### 3.1 The Kubernetes `kube-scheduler` Architecture
Our kind control-plane runs the standard `kube-scheduler`. Its scheduling algorithm executes across two continuous queues and a two-phase cycle:

```text
                  +-------------------------------------------------+
                  |              kube-scheduler Queue               |
                  |  +--------------------+   +-------------------+ |
 Pod Submitted -> |  | activeQ (Priority) |   |  backoffQ / unsched |
                  |  |  Max-Heap by Value |   |  (Failed Pods)    | |
                  |  +---------+----------+   +-------------------+ |
                  +------------|------------------------------------+
                               | Pop Highest Priority Pod
                               v
                  +-------------------------------------------------+
                  |               1. Scheduling Cycle               |
                  |  [Filter] -> [Score] -> [Reserve/Permit]        |
                  +------------|------------------------------------+
                               |
              Fit Found? ------+------ No Fit (Insufficient CPU)
              |                       |
              v (YES)                 v (NO)
     [Bind to Node]       +-----------------------------------------+
                          |        2. Native Preemption Cycle       |
                          |  - Find nodes where victims can fit pod |
                          |  - Select lowest-priority victims       |
                          |  - Nominate node & send SIGTERM         |
                          |  - Evict victims -> Bind high-priority  |
                          +-----------------------------------------+
```

### 3.2 Does `kube-scheduler` use a Priority Queue?
**Yes.** In the official Kubernetes scheduling framework (`pkg/scheduler/internal/queue/scheduling_queue.go`):
- **`activeQ`**: A **heap-based priority queue**. The heap comparator function sorts waiting pods such that `p1.priority > p2.priority`. When multiple pods are waiting, the scheduler pops the highest-priority pod first.
- **FIFO within equal priority**: If two pods have identical priority values, the scheduler breaks ties using submission timestamp (`creationTimestamp`).
- **`unschedulablePods`**: Pods that fail the filter phase (e.g. `Insufficient cpu`) are moved to the unschedulable pool until cluster events (like pod deletion or node update) move them back into `backoffQ` and `activeQ`.

---

## 4. Understanding the Baseline & Resource Budget Arithmetic

### 4.1 What is the "Baseline"?
In a production cloud environment, you do not test preemption on empty nodes. Preemption is only triggered when a node experiences **resource saturation**.
- The **Baseline** is our controlled steady-state:
  - We deploy 1 `medium-priority` pod (10% allocatable CPU) and 3 `low-priority` pods (75% allocatable CPU) onto the worker node.
  - The node is now **85% committed** in CPU requests.
  - Residual CPU available: $\approx 15\%$ ($2385\,\text{m}$).

### 4.2 Exact Mathematical Proof from Live Cluster Telemetry
Consider a worker node with **Allocatable CPU = $16000\,\text{m}$** (16 cores):

$$\text{Committed Requests} = 100\,\text{m (system)} + 1590\,\text{m (medium)} + (3 \times 3975\,\text{m (low)}) = 13615\,\text{m}$$
$$\text{Free CPU Available for Requests} = 16000\,\text{m} - 13615\,\text{m} = \mathbf{2385\,\text{m}}$$

Now, look at the two tests executed against this baseline:

#### Test A: The Equal-Priority Probe (`Test Equal`)
- An incoming `low-priority` pod requests **$4373\,\text{m}$**.
- Deficit: $4373\,\text{m} - 2385\,\text{m} = \mathbf{1988\,\text{m}}$ shortfall.
- Can it preempt? **NO.** Because existing pods on the node have priority $\ge 10000$ (`low` and `medium`). Kubernetes rules strictly forbid preempting equal or higher priority pods.
- **Observed Result**: Pod stays **`Pending`** with reason `FailedScheduling: Insufficient cpu`.

#### Test B: The High-Priority Arrival (`Trigger Preemption`)
- A `high-priority` pod ($100000$) arrives requesting the exact same **$4373\,\text{m}$**.
- Deficit: Same $1988\,\text{m}$ shortfall.
- Can it preempt? **YES.** The scheduler scans victims and selects **1 low-priority pod** ($3975\,\text{m}$).
- Preempting one low pod frees: $2385\,\text{m} + 3975\,\text{m} = \mathbf{6360\,\text{m}}$.
- $6360\,\text{m} \ge 4373\,\text{m}$ $\rightarrow$ Sufficient!
- **Observed Result**:
  1. Scheduler generates native event: `Preempted: Preempted pod low-priority-xxx by high-priority-yyy`.
  2. Kubelet terminates the low-priority pod.
  3. The high-priority pod transitions to **`Running`**.
  4. The `medium-priority` pod is **untouched** (medium is higher than low, and evicting low was sufficient).
  5. Remaining free CPU: $6360\,\text{m} - 4373\,\text{m} = \mathbf{1987\,\text{m}}$.

---

## 5. Summary of Experiments & Concrete Evidence

| Demonstration | What is Tested | Key Evidence Captured from Kubernetes API | Evaluator Verification Command |
| :--- | :--- | :--- | :--- |
| **1. Multi-Tier Normal Placement** | 12 pods (4 High, 4 Med, 4 Low) across 2 workers when capacity exists. | All 12 pods `Running`. Proves priority classes do not block pods when resources are sufficient. | `kubectl get pods -n priority-scheduling -o wide` |
| **2. Priority Queue Order (`activeQ`)** | Two identical pods (High & Low) both blocked by a temporary CPU blocker. | Low was created first. Once blocker is deleted, **High runs first**; Low remains `Pending`. Proves priority over FIFO. | `kubectl get events -n priority-scheduling --sort-by=.metadata.creationTimestamp` |
| **3. Matched Preemption vs Equal Probe** | Same CPU deficit tested with Equal vs High priority. | Equal probe $\rightarrow$ `Pending` forever.<br>High priority $\rightarrow$ Evicts low-priority victim and runs. | `kubectl get events -n priority-scheduling --field-selector reason=Preempted` |

---

## 6. Faculty Defense / Viva Cheat-Sheet

1. **"Did you write a custom scheduler in Python/Flask?"**  
   *Answer*: **No.** Flask is only a telemetry dashboard and orchestration trigger. Every single scheduling decision, queuing order, and preemption signal is made natively by the compiled **Go binary `kube-scheduler`** inside the control-plane node.
2. **"Why do your containers just run `sleep`?"**  
   *Answer*: The Kubernetes scheduler makes placement decisions strictly based on **declared Resource Requests (`spec.containers.resources.requests`)**, NOT on runtime CPU spikes. Using lightweight containers allows us to demonstrate massive multi-core enterprise resource scheduling cleanly inside a development laptop without melting the host CPU.
3. **"Why didn't the high pod evict the medium pod?"**  
   *Answer*: Kubernetes' preemption algorithm minimizes the priority and count of preempted victims. Evicting a single low-priority pod was mathematically sufficient to satisfy the $1988\,\text{m}$ deficit. The scheduler leaves higher and unaffected tiers untouched.
