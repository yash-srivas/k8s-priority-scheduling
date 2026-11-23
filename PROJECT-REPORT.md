# Priority-Based Pod Scheduling and Preemption in Kubernetes
**Course:** Cloud Computing Laboratory &bull; **Problem Statement:** 05  
**Department of Computer Science and Engineering**  
**Environment:** Multi-Node Kubernetes (`kind` v0.33.0 / k8s v1.31) on containerd / WSL 2  

---

## 1. Abstract
In distributed multi-tenant container orchestration platforms, compute resources (CPU cores and memory) are finite. When aggregate workload demands exceed physical cluster capacity, the orchestrator requires deterministic policies to govern scheduling precedence. This project investigates and demonstrates priority-based workload scheduling and preemption mechanisms using native Kubernetes architectural primitives. A multi-node cluster comprising one control plane and two worker nodes was established using `kind`. Workloads assigned varying PriorityClass specifications (high, medium, and low) were deployed under controlled resource saturation. The empirical evaluation demonstrates: (i) deterministic priority-queue sorting over First-In-First-Out (FIFO) submission order, (ii) reproducible `Pending` states due to resource constraints, and (iii) automated victim selection and graceful eviction via the native `kube-scheduler` preemption cycle.

---

## 2. Problem Definition & Objectives
Standard First-Come-First-Served (FCFS) pod scheduling is inadequate in mission-critical production environments where transactional workflows (e.g., checkout and payment services) must take precedence over asynchronous batch tasks (e.g., analytics and log processing). The objectives of this project are:
- Configure multiple declarative `PriorityClass` resources in Kubernetes.
- Deploy heterogeneous workloads with defined CPU requests mapped to distinct priority classes.
- Evaluate scheduling behavior under constrained cluster resource capacity.
- Empirically measure and document pod scheduling order, pending pod conditions, and native preemption events.

---

## 3. System Architecture & Methodology
The cluster architecture consists of an isolated multi-node topology running within WSL 2 / containerd:

### 3.1 Cluster Node Configuration
| Node Name | Role | Allocatable CPU | Status |
| :--- | :--- | :--- | :--- |
| `kind-control-plane` | Control Plane (API Server, Scheduler, etcd) | System Reserved | Tainted (`NoSchedule`) |
| `kind-worker` | Compute Worker Node 1 | 16,000m (16 Cores) | Ready / Schedulable |
| `kind-worker2` | Compute Worker Node 2 | 16,000m (16 Cores) | Ready / Schedulable |

### 3.2 Workload Priority Specifications
| Priority Class | Integer Value | Preemption Policy | Target Workload Profile |
| :--- | :---: | :--- | :--- |
| **`high-priority`** | **100,000** | `PreemptLowerPriority` | Revenue-critical, latency-intolerant services (e.g., Payment, Auth) |
| **`medium-priority`** | **50,000** | `PreemptLowerPriority` | Standard business logic, customer-facing portals (e.g., Catalog, Inventory) |
| **`low-priority`** | **10,000** | `PreemptLowerPriority` *(or `Never`)* | Asynchronous, interruptible batch workloads (e.g., ETL, Video Transcoding) |

---

## 4. Theoretical Foundations: Internal Scheduler Mechanics
The Kubernetes scheduling engine (**`kube-scheduler`**) executes placement decisions through two interconnected internal structures and two operational cycles:

```text
Workload Submitted -> API Admission -> Active Queue (activeQ: Binary Max-Heap by Priority Value)
                                              | (Pop Highest Priority Pod)
1. SCHEDULING CYCLE: [Filter Phase] (Check Node Allocatable >= Requests)
                     -> If Node Available: [Score Phase] -> [Reserve & Permit] -> [Bind to Worker Node]
                     -> If Insufficient CPU: [Enter Preemption Cycle]
2. PREEMPTION CYCLE: a. Identify feasible nodes where evicting lower-priority pods frees required CPU
                     b. Select victim set minimizing victim count and priority tier (Preserve medium, evict low)
                     c. Annotate nominatedNodeName -> Issue SIGTERM eviction -> Bind high-priority Pod
```

### PriorityClass vs. Quality of Service (QoS):
- **PriorityClass:** Governs *admission and scheduling precedence* by `kube-scheduler` based on declared resource requests.
- **QoS Class (`Guaranteed`, `Burstable`, `BestEffort`):** Governs *host OS memory eviction* by the Linux kernel Out-Of-Memory (OOM) killer via `oom_score_adj` when node RAM is physically exhausted.

---

## 5. Baseline Resource Budget & Mathematical Proof
In container scheduling, preemption can only be verified when cluster nodes reach resource saturation. A controlled **Baseline** was established on the target worker node (`kind-worker`, Total Allocatable: 16,000m CPU):

- System Overhead = **100m**
- Medium Workload = **1,590m**
- Low Workloads = 3 &times; 3,975m = **11,925m**

$$\text{Total Committed Requests} = 100\text{m} + 1,590\text{m} + 11,925\text{m} = \mathbf{13,615\text{m}}$$
$$\text{Residual Free CPU Available for Scheduling} = 16,000\text{m} - 13,615\text{m} = \mathbf{2,385\text{m}}$$

To evaluate priority-governed placement versus equal-priority rejection, two comparative workloads requiring **4,373m CPU** were evaluated against the **2,385m residual capacity** (Deficit = **1,988m**):

- **Experiment Case A (Equal-Priority Probe, Value: 10,000):**  
  *Deficit:* 1,988m shortfall.  
  *Rule Evaluation:* Existing node pods are Medium (50k) and Low (10k). Kubernetes scheduling specifications prohibit preempting workloads of equal or higher priority.  
  *Observed Telemetry:* Workload remained permanently in `Pending`. Scheduler generated: `FailedScheduling: 0/3 nodes available: 1 node has Insufficient cpu`. No workloads evicted.

- **Experiment Case B (High-Priority Arrival, Value: 100,000):**  
  *Deficit:* 1,988m shortfall.  
  *Rule Evaluation:* High-priority exceeds low-priority pods. Evicting *one* low workload frees 3,975m CPU.  
  *Post-Eviction Capacity:* $2,385\text{m} + 3,975\text{m} = \mathbf{6,360\text{m}} \ge 4,373\text{m}$.  
  *Observed Telemetry:* Native `Preempted` event emitted. Low pod evicted gracefully. High pod transitioned to `Running`. Medium pod preserved. Final Free CPU = **1,987m**.

---

## 6. Summary of Experimental Demonstrations
| Trial / Scenario | Test Configuration | Observed System Telemetry (API & Events) | Outcome |
| :--- | :--- | :--- | :--- |
| **1. Multi-Tier Normal Placement** | 12 pods deployed (4 High, 4 Med, 4 Low) across 2 workers without resource saturation. | All 12 pods transitioned to `Running` status with balanced node affinity (6 pods/worker). Proved PriorityClasses do not impede placement when capacity exists. | Verified (12/12 Running) |
| **2. Queue Priority vs. FIFO Ordering** | Capacity blocker deployed. Low contestant submitted first, High submitted second. Blocker deleted. | Upon capacity release, `kube-scheduler` bypassed FIFO arrival order and placed **High contestant first**. Low contestant remained in `Pending`. | Verified (Priority Ordering) |
| **3. Controlled Native Preemption** | Saturated baseline evaluated against Equal Probe vs. High-Priority arrival. | Equal probe was rejected with `Insufficient cpu`. High-priority workload triggered eviction of `data-crawler-job-1`. Medium workload remained unaffected. | Verified (Native Preemption) |

---

## 7. Discussion & Practical Implications
In production enterprise cloud environments (e.g., streaming platforms, financial transaction systems, and e-commerce platforms), resource priorities are governed by structured Service Level Agreements (SLAs). Critical services (Tier-0) such as payment authorization and identity verification are assigned high-priority classes with preemption enabled. Non-critical asynchronous tasks such as nightly data aggregation, web indexing, and video encoding are allocated low-priority classes. Automated policy controllers (such as OPA Gatekeeper and Kyverno) enforce priority assignments at cluster ingress, ensuring that during high-traffic surges, critical services immediately reclaim compute resources from disposable workloads without waiting for infrastructure autoscaling latency.

---

## 8. Conclusion
The experimental evaluation successfully validates the role of PriorityClass configurations in Kubernetes resource management. The findings confirm that `kube-scheduler` deterministically sorts unscheduled workloads via a priority heap queue, enforces resource isolation under saturation, and executes preemption while minimizing collateral workload disruption. The empirical results demonstrate exact adherence to Kubernetes scheduling specifications and provide a robust foundation for multi-tenant cloud capacity management.

---

## References
1. Kubernetes Documentation: *Pod Priority and Preemption*, Kubernetes v1.31 Concepts Guide.
2. Kubernetes Source Code: `pkg/scheduler/internal/queue/scheduling_queue.go`, Kubernetes Project Repository.
3. Burns, B., Oppenheimer, D. *Design Patterns for Container-Based Distributed Systems*, ACM Queue.
