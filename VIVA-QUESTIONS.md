# Viva Questions and Short Answers

| Question | Short answer |
| --- | --- |
| What problem does the project address? | It shows how Kubernetes can get important Pods running while lower-priority Pods hold scheduler capacity. |
| What is Kubernetes? | A system that places and manages containerized workloads. |
| What is a Pod? | The smallest deployable unit. It contains one or more containers that share networking and can share volumes. |
| What does kind do? | It creates Kubernetes nodes as containers, giving us a three-node lab on one computer. |
| Why Docker Desktop and WSL 2? | Docker Desktop provides the Linux container engine using the WSL 2 Linux kernel on Windows. |
| What are the three nodes? | One control plane and two worker nodes. |
| What runs on the control plane? | The API server, scheduler, controllers, and the etcd store. |
| What runs on a worker? | A kubelet and a container runtime, along with networking components and workload Pods. |
| Why does the demo target workers? | The control plane normally has a NoSchedule taint. Experiment 1 explicitly excludes it and Experiment 2 selects the two worker hostnames. |
| What does kubectl do? | It reads and changes resources through the Kubernetes API. |
| What is a context? | A kubeconfig entry that identifies a cluster, credentials, and optionally a default namespace. |
| How does the script check cluster identity? | It compares the selected server and CA against Docker kind, then checks matching node names, roles, and readiness. |
| What is the project namespace? | `priority-scheduling`. It groups the demo Pods and their events. |
| What is a PriorityClass? | A cluster-scoped Kubernetes object that maps a class name to an integer priority and a preemption policy. |
| Which values does this project use? | High 100000, medium 50000, and low 10000. |
| What does globalDefault mean? | A class marked as the global default supplies priority to Pods that omit a class. All demo classes set it to false. |
| What does PreemptLowerPriority mean? | A pending Pod can cause removal of strictly lower-priority Pods if that makes a placement feasible. |
| How does priority affect scheduling order? | Among Pods ready in the active queue, higher priority is considered first. Submission, retry, and startup timing can affect observed ordering. |
| What is allocatable? | The CPU, memory, and other resources offered to Pods on a node. |
| What is a request? | The resource amount Kubernetes uses in placement and resource accounting. For CPU, 1000m is one core. |
| What is a limit? | A runtime resource ceiling. CPU can be throttled, and exceeding memory limits may cause OOM termination. |
| Are requests the same as usage? | Requests guide placement. Actual usage comes from resource metrics such as the Metrics Server API. |
| What does Experiment 1 verify? | Twelve Pods, four per tier, with the correct priorities and worker placement, all Running on a successful run. |
| What does Experiment 2 verify? | An equal incoming Pod is genuinely Pending, while a matched high-priority Pod can preempt. Both high Pods must run, each worker needs native victim evidence, and both medium Pods must still be Running. |
| Why a hostname selector? | It gives each high Pod one planned worker and keeps a free second worker from bypassing the intended contention. |
| Is the selector the same as nodeName? | A selector constrains the scheduler's choices. Direct nodeName binding would bypass its normal placement decision. |
| How are resource requests chosen for Experiment 2? | From each worker's allocatable CPU minus bound requests across all namespaces, followed by a fresh calculation after the baseline starts. |
| What is a nominated node? | The scheduler's tentative target when it expects capacity to become available after preemption. |
| How do we prove a victim was preempted? | Match the default-scheduler Preempted event to the victim UID and the high Pod UID, then inspect the recorded victim state. |
| Why save Pod UIDs and events? | A rerun can reuse a Pod name. A deleted victim can disappear from Pod listings before inspection. |
| What does INCONCLUSIVE mean? | Safe contention could not be prepared, or the observed evidence was incomplete. |
| How does Flask run commands? | It uses an argument list and launches fixed scripts or kubectl. Flask returns JSON to the browser. |
| How does cleanup select Pods? | It checks the cluster identity and selects Pods in the project namespace by ownership and experiment labels. |
| What is the main limitation of kind here? | All three nodes share one host, and the per-node reported capacity can overlap. The tests show scheduler behavior for lightweight demo Pods. |

## Scheduling order and fair comparison

| Question | Short answer |
| --- | --- |
| Why does Experiment 1 not prove order? | There is room for all twelve Pods and they were submitted in manifest order. Running time also depends on pulling and starting the image. |
| How does the order test prove preference? | Low arrives first. Both comparable Pods genuinely wait on one worker. One shared slot opens. If high binds with a native Scheduled event while low stays unbound, the trial supports preference. |
| What makes the candidates comparable? | Same worker, container image, CPU request, memory request, and Never policy. Their priority values differ. |
| What does preemptionPolicy Never do? | The Pod still receives queue priority, and it cannot cause preemption of another Pod. |
| Why remove a blocker in the order test? | It releases exactly one scheduling opportunity for both waiting Pods. This is controlled release, a different scenario from native preemption. |
| Can low schedule before high? | Yes, for example if high does not fit, arrives later, or is in backoff. A single trial demonstrates one observed preference under its conditions. |
| Can a high Pod remain Pending? | Yes. Its constraints may rule out every node or no eligible victim set can make enough room. |
| Why does the equal probe stay Pending? | Its request exceeds free CPU, and the baseline Pods have equal or higher priority. The event records a CPU failure and no suitable victims. |
| Can an equal-priority Pod preempt? | The incoming Pod can preempt only strictly lower-priority Pods. |
| Why is the equal/high comparison fair? | The same worker, CPU, memory, selector, default scheduler and preemption policy are used. Baseline state is rechecked before the high Pod. |
| What if the incoming Pod exceeds all allocatable CPU on its worker? | Removing every eligible victim still cannot create enough CPU. That worker cannot fit it. |
| How does the script handle a low candidate winning the order test? | It reports INCONCLUSIVE for the intended preference and keeps the observed evidence. |
| What output proves genuine Pending? | Pod phase Pending without a binding, an Unschedulable PodScheduled condition, and a native FailedScheduling event describing insufficient CPU. |

## Additional architecture and implementation questions

| Question | Short answer |
| --- | --- |
| What happens after kubectl apply? | The API server validates, admits and stores the resource in etcd. The scheduler notices unbound Pods, and the kubelet starts a container after binding. |
| What is a container? | A packaged process and its dependencies, isolated by the container runtime. |
| What does etcd store? | Kubernetes API objects and cluster state in a key-value database. |
| What are filtering, scoring and binding? | Filtering removes infeasible nodes, scoring ranks feasible ones, and binding records the chosen node. |
| What is scheduler preemption versus node-pressure eviction? | Preemption tries to make a placement for a higher-priority Pod. Kubelet node-pressure eviction responds to resource pressure on a running node. |
| What is a PodDisruptionBudget? | It expresses a minimum availability or maximum disruption target. Default preemption considers it on a best-effort basis. This lab rejects PDBs in its demo namespace for predictable victim selection. |
| What does nominatedNodeName mean? | A tentative worker chosen while preemption is in progress. A final placement has a real node binding. |
| Where are resource calculations? | `Get-LabPodRequest` and `Get-LabNodeBudget` in `scripts/resource-requests.ps1`. They read effective requests and subtract them from each node's allocatable CPU and memory. |
| How is order orchestrated? | `scripts/run-scheduling-order.ps1` creates and verifies both stages. The queue and binding belong to the Kubernetes scheduler. |
| How does Flask trigger controlled stages? | `execute_action` maps fixed action names to scripts; the order handlers pass a fixed Prepare or Release value. A local mutex blocks concurrent modifying scripts. |
| Why CSV and JSON? | CSV is easy to read in a spreadsheet. JSON preserves structured budgets, UIDs, conditions and the verdict. |
| How do I debug a failed run? | Read its outcome and inspect its Pod snapshots or the current Pods and the namespace events. Reset the owned workload before rerunning. |
| Which source files should I know for the viva? | Primary classes YAML, the first Pod in Experiment 1, resource request helpers, order Prepare and Release, and `Get-ConfirmedPreemption`. |
