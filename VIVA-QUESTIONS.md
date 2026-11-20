# Comprehensive Viva Voce Questions & Answers
## Project: Priority-Based Pod Scheduling in Kubernetes

This guide contains **30 carefully structured Viva questions and simple, clear answers** designed for academic evaluations, professor examinations, and technical presentations.

---

### Category 1: Fundamentals of Kubernetes & Containers

#### Q1: What is Kubernetes?
**Answer:**  
Kubernetes (often called K8s) is an open-source container orchestration platform originally developed by Google. It automates the deployment, scaling, management, and networking of containerized applications across clusters of machines.

#### Q2: What is a Pod?
**Answer:**  
A Pod is the smallest and simplest deployable unit in Kubernetes. A Pod encapsulates one or more containers (such as Docker containers), shared storage volumes, and network configurations (IP address and port space).

#### Q3: What is a Node in Kubernetes?
**Answer:**  
A Node is a physical or virtual worker machine in a Kubernetes cluster. Every node is managed by the Kubernetes Control Plane and runs essential services: the **kubelet** (node agent), **kube-proxy** (networking), and a **container runtime** (like Docker or containerd).

#### Q4: What is the difference between a Master/Control Plane Node and a Worker Node?
**Answer:**  
- **Control Plane Node:** Runs components that manage the cluster: `kube-apiserver` (API gateway), `etcd` (database), `kube-scheduler` (assigns pods to nodes), and `kube-controller-manager` (handles controllers).  
- **Worker Node:** Runs the actual application containers inside Pods, managed by `kubelet`.

#### Q5: What is a Kubernetes Namespace?
**Answer:**  
A Namespace provides virtual isolation within a single physical Kubernetes cluster. It partitions resources, allows unique object naming per namespace, and prevents naming collisions. In our project, all experiments run in the `priority-scheduling` namespace.

#### Q6: What is `kubectl`?
**Answer:**  
`kubectl` is the official command-line interface (CLI) for Kubernetes. It communicates with the `kube-apiserver` using REST API requests to create, inspect, update, and delete cluster resources.

#### Q7: What is Minikube?
**Answer:**  
Minikube is an open-source tool that provisions a single-node Kubernetes cluster locally inside a virtual machine or Docker container. It is specifically designed for learning, development, and testing on a developer laptop without incurring cloud hosting costs.

---

### Category 2: Resource Management & Requests vs Limits

#### Q8: What is a CPU Request in Kubernetes?
**Answer:**  
A CPU request is the minimum guaranteed amount of CPU capacity that Kubernetes reserves for a container. The `kube-scheduler` uses the CPU request (not actual live usage) to decide which node has enough space to place the Pod. It is measured in millicores (e.g., `500m` = 0.5 CPU core).

#### Q9: What is a Memory Request in Kubernetes?
**Answer:**  
A memory request is the minimum amount of RAM (e.g., `128Mi` or `1Gi`) reserved for a container. The scheduler ensures that a node has at least this much unreserved allocatable memory before scheduling the Pod.

#### Q10: What is the difference between Resource "Requests" and "Limits"?
**Answer:**  
- **Requests:** Used by the **scheduler** to place the Pod on a node. It represents the *guaranteed minimum* capacity.  
- **Limits:** Enforced by the **container runtime** at execution time. It is the *maximum upper ceiling* of resources a container is allowed to consume before being throttled (CPU) or killed (Out Of Memory / OOMKilled for RAM).

#### Q11: What is "Allocatable" resource capacity on a Node?
**Answer:**  
Allocatable resources represent the actual compute capacity available for user application Pods after subtracting system reservations (such as CPU/RAM reserved for the OS kernel and Kubernetes control agents like kubelet and kube-proxy).

---

### Category 3: Kubernetes Scheduler & Priority Mechanics

#### Q12: What is the Kubernetes Scheduler (`kube-scheduler`)?
**Answer:**  
`kube-scheduler` is the core control plane component that watches for newly created Pods that have no assigned node. For every unscheduled Pod, the scheduler finds the best suitable node according to a 2-phase algorithm: **Filtering** (finding nodes that meet requirements) and **Scoring** (ranking feasible nodes).

#### Q13: What is a PriorityClass in Kubernetes?
**Answer:**  
A `PriorityClass` is a Kubernetes API resource (`scheduling.k8s.io/v1`) that defines a mapping between a human-readable name (like `high-priority`) and an integer value (such as `100000`). Pods reference a PriorityClass via their `spec.priorityClassName` field.

#### Q14: How does priority affect the Kubernetes scheduling queue?
**Answer:**  
The scheduler maintains an internal priority queue called `activeQ`. When multiple Pods are waiting to be scheduled, `kube-scheduler` orders them by their integer priority value from highest to lowest. As a result, higher-priority Pods are popped off the queue and evaluated before lower-priority Pods.

#### Q15: What is the difference between scheduling and execution?
**Answer:**  
- **Scheduling:** The logical control plane decision of assigning a Pod to a specific worker node (`spec.nodeName`).  
- **Execution:** The physical pulling of container images and launching of processes on that node by `kubelet`.  
*Note:* A higher-priority Pod is scheduled first in the queue, but its exact container `Running` start time also depends on container image download speeds.

#### Q16: What happens when cluster resources are insufficient for a Pod?
**Answer:**  
Without priority or preemption, a Pod whose resource requests exceed available capacity will stay in the `Pending` state indefinitely until existing Pods terminate and free up resources. With priority and preemption, the scheduler will evict lower-priority Pods to make room.

---

### Category 4: Pod Preemption Internals

#### Q17: What is Priority-Based Preemption?
**Answer:**  
Preemption is the automated process by which `kube-scheduler` evicts (terminates) one or more running lower-priority Pods from a node so that a higher-priority Pod that cannot fit can be successfully scheduled on that node.

#### Q18: What is the Preemption Policy?
**Answer:**  
In `PriorityClass`, `preemptionPolicy` can be set to:
- `PreemptLowerPriority` (default): The Pod can preempt lower-priority Pods if resources are tight.
- `Never`: The Pod gets priority in the scheduling queue (`activeQ`), but will *never* evict any running Pods.

#### Q19: Which Pods are chosen as victims during preemption?
**Answer:**  
The scheduler tries to minimize disruption:
1. It only considers Pods with a lower priority value than the incoming preemptor Pod.
2. It prefers Pods with lower priority over Pods with higher priority.
3. It selects the minimum number of victim Pods whose freed resources will allow the higher-priority Pod to fit.
4. It prefers victim Pods that violate fewer PodDisruptionBudgets (PDBs).

#### Q20: Are preempted Pods abruptly killed or gracefully terminated?
**Answer:**  
Preempted Pods are terminated gracefully. The kubelet sends a `SIGTERM` signal to the victim container and grants it a graceful termination period (`terminationGracePeriodSeconds`, default 30s) to save state and close connections before sending `SIGKILL`.

#### Q21: What is a "Nominated Node"?
**Answer:**  
When the scheduler preempts victim Pods for a higher-priority Pod, it sets the `status.nominatedNodeName` field of the higher-priority Pod to that node. The Pod waits until the victims finish terminating before officially binding to that node.

---

### Category 5: Our Project Implementation & Experiments

#### Q22: What PriorityClasses did we create in our project?
**Answer:**  
We created three distinct PriorityClasses in `configs/priority-classes.yaml`:
1. `high-priority`: value `100000` (used for critical services and the preemptor)
2. `medium-priority`: value `50000` (used for standard API services)
3. `low-priority`: value `10000` (used for batch workers and preemption victims)

#### Q23: What does Experiment 1 demonstrate?
**Answer:**  
Experiment 1 deploys Pods across all three priority tiers into the `priority-scheduling` namespace. It proves that Kubernetes correctly binds the integer priority values to the Pods, orders them in the scheduling queue, and schedules them across available resources while measuring scheduling latencies.

#### Q24: What does Experiment 2 demonstrate?
**Answer:**  
Experiment 2 demonstrates real-world preemption under resource saturation. We deploy two low-priority victim Pods requesting `600m` CPU each (total `1200m`), which fills up the Minikube node. We then deploy a high-priority Pod requesting `900m` CPU. Because the node lacks `900m` free CPU, the Kubernetes scheduler automatically evicts a low-priority victim Pod, frees the CPU, and schedules the high-priority Pod.

#### Q25: How do we verify that genuine preemption took place rather than manual deletion?
**Answer:**  
We verify this through official Kubernetes API events:
1. Running `kubectl get events -n priority-scheduling` displays the event reason `Preempted` with message `by priority-scheduling/preemptor-high-pod on node minikube`.
2. The victim Pod displays a `deletionTimestamp` and transitions to `Terminating`.
3. Our automated scripts and Web Dashboard log these genuine Kubernetes events without any manual delete commands.

#### Q26: Did we write a completely new Kubernetes scheduler?
**Answer:**  
No. We utilize the official, production-grade Kubernetes scheduler (`kube-scheduler`) and configure it using Kubernetes native APIs (`PriorityClass` and `scheduling.k8s.io/v1`). Writing a custom scheduler from scratch would reinvent basic queue logic; our project demonstrates advanced utilization and testing of Kubernetes' built-in scheduling framework.

#### Q27: How does the Web Dashboard work?
**Answer:**  
The dashboard is built with Python Flask on the backend and HTML5/CSS3/JavaScript/Chart.js on the frontend. The backend queries `kubectl` via secure subprocess calls, parses JSON responses, and returns cluster status, Pod metadata, and events. The frontend renders real-time metric cards, priority distribution charts, latency graphs, and an interactive log console.

#### Q28: How does our project respect an 8 GB RAM laptop?
**Answer:**  
We configure Minikube to use a lightweight allocation of 2 CPUs and 3 GB RAM. Workload Pods use ultra-lightweight BusyBox containers that consume negligible idle memory (~2 MB per container) while setting controlled CPU and memory requests to safely trigger scheduling algorithms.

#### Q29: What are the main limitations of our current project setup?
**Answer:**  
1. Tested on a single-node Minikube cluster; does not demonstrate cross-node multi-zone scheduling topologies.
2. Uses sleep containers rather than heavy microservices, which is appropriate for academic demonstration but does not test application-level state recovery.

#### Q30: Why is Priority-Based Scheduling critical in enterprise production clusters?
**Answer:**  
In enterprise production, multi-tenant clusters run revenue-generating web applications alongside non-urgent background batch tasks (data backups, log indexing, machine learning model batch scoring). Priority-based scheduling guarantees that critical customer-facing services never experience downtime or queue starvation during sudden traffic spikes.
