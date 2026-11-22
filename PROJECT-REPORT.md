# Academic Project Report

## Priority-Based Pod Scheduling and Preemption in Kubernetes

**Program** — Fifth-semester Computer Science and Engineering (Artificial Intelligence)  
**Course** — Cloud Computing Lab

## Abstract

This project uses the Kubernetes default scheduler to demonstrate Pod priorities and resource-based preemption. A Windows 11 host runs Docker Desktop with WSL 2 and a kind cluster with one control plane and two workers. A Flask dashboard displays cluster data and calls PowerShell scripts. The normal stage validates three priority tiers across twelve Pods. A guided one-slot test captures Pending state and observed scheduling preference. The preemption experiment compares equal and high priorities under comparable conditions and correlates native scheduler events with Pod state.

## Problem and objective

Critical services may need to start while background workloads already hold scheduler capacity. Kubernetes uses priority when ordering its active scheduling queue. If a higher-priority Pod cannot fit, preemption can free capacity by removing lower-priority Pods on a feasible node. The project checks priority admission, scheduler placement, and preemption using API evidence.

## System architecture

| Component | Role |
| --- | --- |
| Windows 11 and PowerShell | Lab host, setup, orchestration, and evidence collection |
| Docker Desktop and WSL 2 | Linux container and VM environment |
| kind control plane | kube-apiserver, etcd, controller manager, and kube-scheduler |
| Two kind workers | Each worker runs a kubelet and containerd to start bound workloads |
| Flask, JavaScript, Chart.js | Local controls, node information, request and usage display, Pod audit, and scheduler event display |
| kubectl | Reads and writes the intended Kubernetes API using a verified context |

Setup matches the active context's endpoint and certificate authority to Docker's kind kubeconfig, compares Docker node names with the API's nodes, and verifies role and readiness. Application scripts use the verified context explicitly. Project experiment and cleanup scripts serialize their writes per context using a local mutex. Cleanup uses both the ownership and experiment labels inside `priority-scheduling`.

## Priority and resource model

| Class | Priority | Workload example |
| --- | ---: | --- |
| `high-priority` | 100000 | Payment or order surge |
| `medium-priority` | 50000 | Customer portal or inventory |
| `low-priority` | 10000 | Analytics, crawling, or video transcoding |

The classes use `scheduling.k8s.io/v1`, `globalDefault: false`, and `PreemptLowerPriority`. Pod creation references a class by name, and admission records its numeric priority. Requests drive resource fit. CPU limits constrain CPU time and a memory limit can lead to an OOM termination when exceeded. The scheduler accounts for allocatable capacity and requested resources. Real resource use requires measurements, which the dashboard obtains from the Metrics Server API when available. [Kubernetes resource management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) · [Kubernetes Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)

## Experiment 1 — Multi-tier configuration and placement

The script creates 12 BusyBox Pods from `experiments/experiment-1.yaml`. The four high Pods represent core services, the four medium Pods represent normal application services, and the four low Pods represent background tasks. Required node affinity excludes nodes with the control-plane role, leaving both workers eligible. The original workload names and resource requests are preserved.

Evidence includes each Pod's UID, class, priority value, CPU and memory requests, phase, assigned worker, and scheduling timestamps. A successful result verifies all 12 Pods Running with the expected priority and worker assignment and saves evidence. Running order also depends on image pulls and container startup. This experiment measures placement and demonstrates the three classes. A controlled queue-order comparison would need its own setup and evidence.

## Guided scheduling order and Pending demonstration

A demo-only blocker reserves about 75% of the initially free CPU on one worker. The two identical-size contestants individually request about 65% of that worker's initially free CPU. The low-priority Pod is submitted first. Both use a matching worker hostname and non-preempting classes. Once both show real CPU scheduling failures, the presenter can hold this stage to inspect Pending state. Release rechecks the worker budget, Pod UIDs and request equality. It removes the blocker so the worker can fit either contestant individually. Kubernetes then chooses where to bind the eligible Pod. The script reports PASS only for a native high-priority Scheduled event and high Running while low is still Pending. This design isolates queue preference from victim removal. Backoff and concurrent cluster changes can affect repeatability.

## Experiment 3 — Staged two-worker CPU contention

The baseline consists of one medium Pod per worker and three low Pods on the first worker, two on the second. The script reads each worker's CPU, memory, and Pod slot allocatable values. It calculates committed requests from bound nonterminal Pods in every namespace, accounting for regular containers, init containers, restartable sidecars, Pod-level requests, and overhead. In-progress changes may make a snapshot differ from scheduler cache.

Each medium Pod requests approximately 10% of its worker's initial free CPU. Its low Pods together request approximately 75%. The script confirms the baseline is Running, measures free resources again, and requests free CPU plus half the smallest low request for the high Pod. One low victim is enough to close the CPU gap. Memory and Pod slots are checked to isolate CPU contention. A hostname `nodeSelector` gives each high Pod a separate contention scenario on its worker. It preserves native filtering, preemption, and binding.

The dashboard runs four separate actions. Prepare stores worker budgets and actual baseline Pods. Test Equal leaves the probe Pending for live inspection. Trigger Preemption runs only when the live UID set and resource requests still match. Compare Results opens the saved before and after snapshots. Pod placement annotations and admission-time YAML remain available for departed workloads.

The first worker also receives an equal-priority probe under the same CPU deficit. The probe uses the high Pod's CPU and memory requests, worker selector and preemption policy. It ties the lowest baseline priority and therefore has no eligible baseline victim. The script records its real Pending state and CPU failure, clears just the unbound probe, and rechecks comparable baseline conditions. It then submits the two high Pods. The allocation and admitted resource specs are checked again before claiming a matched comparison.

When normal filtering cannot find a feasible placement, the scheduler's default preemption logic can nominate a node, select lower-priority victims, and initiate graceful termination. The nominated node is provisional until binding. Scheduler event proof requires the `Preempted` reason, the scheduler source, the baseline victim UID, and the related high UID. The run also checks the actual victim state, high Pod Running state, continued medium Pod Running state, and native CPU scheduling failure evidence. [Kubernetes preemption behavior](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/#preemption)

## Observed live results

Live validation on **22 November 2026 (IST)** used the existing `kind-kind` cluster on Kubernetes v1.37.0. The controlled order test observed both contestants Pending with 3975m free and 10335m requested per Pod. The low Pod was created first. After the blocker was removed, the high Pod became Running and the low Pod stayed Pending. The matched preemption comparison requested 4373m and 64Mi in both cases on `kind-worker`, with 2385m free. The equal-priority probe remained Pending, while the high-priority Pod reached Running after native preemption. The final free CPU observed on that worker was 1987m. See the [requirement audit and evidence index](REQUIREMENT-TRACEABILITY.md).

The following table refers to the earlier archive, which established normal placement and preemption before the scheduling-order and matched comparison stages were added.

| Experiment | Observed result |
| --- | --- |
| 1 | PASS. All 12 Pods reached Running with their expected priority values, six on each worker. The run saved 12 Pod rows and 60 event rows, including 12 scheduler placements. |
| 2 | PASS. Both high Pods had native `Insufficient cpu` evidence and became Running on their assigned workers. The scheduler preempted `data-crawler-job-1` on `kind-worker` and `video-transcoder-node-2` on `kind-worker2`. Both medium Pods stayed Running. |

The measured free CPU before each high submission was 2385m and 2386m. The high requests were 4373m and 5367m, respectively. These figures are specific to the tested cluster. [Experiment 1 outcome](results/kind/kind-kind/experiment-1/20261121-211303-2967726-77274267/outcome.json) · [Experiment 2 outcome](results/kind/kind-kind/experiment-2/20261121-211414-2914854-0017b532/outcome.json) · [Experiment 2 scheduler events](results/kind/kind-kind/experiment-2/20261121-211414-2914854-0017b532/kubernetes-events.csv)

The top-level CSVs and screenshots record earlier executions and UI previews. Some use older collection rules. The archived results retain their original verdicts. The new evidence index points to the controlled order and matched comparison results.

## Limitations

kind runs all nodes on one Docker Desktop VM. Node-reported allocatable resources can therefore represent overlapping host resources. The workload containers sleep to keep physical load small. The staged preemption demonstration expects a stable, dedicated lab with the normal scheduler and can become inconclusive if allocations change, other workloads are present, or event evidence is incomplete. Scheduler events expire from Kubernetes. Raw API snapshots preserve the captured event objects, and CSVs preserve the summarized record. Metrics Server is optional and was unavailable for the validation cluster.
