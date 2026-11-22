# Cloud Computing Lab Evaluation 2 — Problem 05

**Opening line:** “Sir, this project shows how the default Kubernetes scheduler uses Pod priority when CPU requests compete for space. I will show normal placement, then a controlled scheduling-order test, and finally equal versus high priority with real preemption.”

Open the local Flask dashboard and a PowerShell terminal. Verify `kind-kind` has three Ready nodes. Keep [the manual guide](MANUAL-DEMONSTRATION.md) and the browser visible. If image pulls are slow, run normal placement once before the evaluation and then clear the demo Pods. The cached image speeds up the live run. A saved run is evidence of its own recorded date.

## Short demonstration · 5–7 minutes

| Time | What to open or click | What to point at and say | Likely question |
| --- | --- | --- | --- |
| 0:00–1:00 | Node and Lab PriorityClasses tables | “The control plane runs the scheduler. Most demo Pods run on the two workers. Each class name maps to 100000, 50000, or 10000.” Show `PreemptLowerPriority`, `globalDefault=false`, and the descriptions. | **Does high get more CPU?** The Pod’s request controls CPU fit. The class controls preference and preemption eligibility. |
| 1:00–2:00 | **Normal Placement** | Show 12 BusyBox Pods Running, four per tier, with CPU, memory and Node columns. “There was room for all these Pods, so this stage verifies admission and placement.” | **Does this show order?** The one-slot competition in the next stage tests that. |
| 2:00–3:30 | **Purge Workloads**, then **Prepare Pending Pods** | Point to the blocker Running, contestants Pending and their native `Insufficient cpu` messages. Compare allocatable, requested, and free CPU in the node table. “Both ask for the same CPU and memory. Low arrived first. The two extra order classes use Never so they cannot preempt.” | **CPU usage looks low; why Pending?** Kubernetes fits requests against allocatable CPU. The containers sleep. |
| 3:30–4:30 | **Release One Slot** | Show the actual winner and saved scheduler timeline. On a PASS say, “Kubernetes placed high into the one slot, and low stayed Pending.” Point to a native Scheduled event and the low Pod’s unbound status. | **Is high always first?** Among eligible queue entries it has preference. Backoff, fit, and concurrency can affect an observed run. |
| 4:30–6:30 | **Purge Workloads**, then **Prepare Workloads** → **Test Equal Priority** → **Trigger Preemption** → **Compare Results** | Pause after Prepare to show the baseline and after Test Equal Priority to show the real Pending probe. Then trigger preemption and open the comparison. Point to the matched requests, high Running, and the UID-matched victim events. Point to before/after free CPU on both workers. | **Why could high succeed?** There were strictly lower-priority Pods whose removal made high fit. The scheduler selected the victim set. |
| 6:30–7:00 | **Export Audit CSV**, or the saved evidence panel | Show the event source, Pod UID and reason, then the surviving medium Pods. “I can open the event CSV after a victim is gone.” | **Is Terminating proof?** The native scheduler event and victim identity supply proof. |

If the order example is INCONCLUSIVE, show the two authentic Pending states, explain the actual result, and use a previous saved PASS as a clearly labeled example if time is short. Use Purge Workloads before switching stages. The backend blocks starting a conflicting stage while owned workloads are active.

## Detailed demonstration · 15–20 minutes

1. **Architecture, 0–3 minutes.** Open `kind-config.yaml` and show `kubectl --context kind-kind get nodes -o wide`. Trace kubectl to API server, etcd, scheduler, and kubelet/container runtime. Point to the control-plane taint in `describe node kind-control-plane`. A toleration can allow suitable control-plane workloads.
2. **YAML and normal placement, 3–6 minutes.** Open `configs/priority-classes.yaml` and the first Pod in `experiments/experiment-1.yaml`. Link `metadata.name` of the class to the Pod’s `spec.priorityClassName`. Show requests, limits, and node affinity. Run stage 1, then show the Pod description and 12 live rows.
3. **Pending and queue preference, 6–10 minutes.** Prepare the order stage. Show the generated manifests, real worker CPU budget, same `nodeSelector`, and equal requests. Read both event messages. While the blocker is Running, the state can be shown for as long as the session remains stable. Release the slot, then compare the saved low and high creation times, the high Scheduled event, and the final PodScheduled conditions. Explain why comparing Running timestamps alone is weak evidence.
4. **Priority comparison and preemption, 10–15 minutes.** Clean up the order Pods. Run the four Experiment 3 buttons separately. Show the calibrated shortages after Prepare. Inspect the probe while it is Pending after Test Equal Priority, then trigger native preemption and open Compare Results. Show matching victim UID, related high UID, and native scheduler source. Check placement, the medium survivors, and before/after free resources. Explain that a nominated node is tentative.
5. **Code and results, 15–20 minutes.** Follow the code walkthrough from the HTML button to `triggerAction()`, the Flask allowlist, the PowerShell manifest, kubectl, the API response and the saved CSV. Open the two output formats. Use saved evidence openly if a live command times out. See the [project explanation](PROJECT-EXPLANATION.md) and [viva questions](VIVA-QUESTIONS.md).

## Quick terminal evidence

```powershell
kubectl --context kind-kind get priorityclasses
kubectl --context kind-kind get pods -n priority-scheduling -o wide
kubectl --context kind-kind get events -n priority-scheduling --sort-by=.metadata.creationTimestamp
kubectl --context kind-kind get events -n priority-scheduling --field-selector reason=Preempted
```

Use the namespace events for inspection and the per-run CSV to isolate the UIDs for the result you are explaining.
