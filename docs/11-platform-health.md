# Worker Failure, Recovery and Platform Health

## Objective

Validate the operational behavior of the Platform Lab when a Kubernetes worker node becomes unavailable.

The validation covers:

1. platform baseline health;
2. worker failure detection;
3. Kubernetes workload recovery;
4. worker recovery;
5. final platform health validation.

The test uses the `test-app/nginx` Deployment as a simple stateless workload.

---

## 1. Platform Health Check

The Platform Lab provides a dedicated health-check script:

```bash
./scripts/platform-health.sh
```

Its purpose is to provide a single operational view of the platform without modifying the infrastructure or Kubernetes configuration.

The script checks:

### Local prerequisites

The following commands must be available:

```text
terraform
kubectl
flux
ssh
git
jq
```

### Git repositories

The script checks:

* `platform-lab` working tree;
* `edge-platform` working tree;
* presence of unexpected uncommitted changes.

The nested `edge-platform` repository is intentionally excluded from the parent repository's untracked-file warning.

### Terraform

The script verifies that the Terraform state is accessible.

It does not perform `plan`, `apply`, `destroy` or any other infrastructure modification.

### SSH connectivity

The script checks SSH access to:

```text
192.168.1.167  k8s-cp
192.168.1.168  k8s-worker-1
192.168.1.169  k8s-worker-2
192.168.1.170  k8s-worker-3
```

It uses the dedicated Platform Lab SSH known-hosts file:

```text
~/.ssh/known_hosts_platform-lab
```

### K3s services

The script verifies:

```text
k3s       → control plane
k3s-agent → workers
```

### Kubernetes

The script verifies:

* kubeconfig availability;
* Kubernetes API connectivity;
* node visibility;
* `Ready` condition of every node.

### Flux

The script verifies:

* Flux health;
* Flux Kustomizations;
* Flux HelmReleases.

A healthy platform therefore means more than simply having all VMs powered on.

---

## 2. Health Check Exit Status

The script returns a useful status for automation:

```text
0 → healthy
1 → one or more failures
```

Warnings do not cause a failure exit code.

The summary has three counters:

```text
OK
WARN
FAIL
```

The final states are:

```text
Platform Lab: HEALTHY
```

or:

```text
Platform Lab: HEALTHY WITH WARNINGS
```

or:

```text
Platform Lab: UNHEALTHY
```

This makes the script suitable for later integration into CI, scheduled monitoring or operational tooling.

---

## 3. Baseline Health

Before starting the failure test, the platform was healthy.

Command:

```bash
./scripts/platform-health.sh
```

Result:

```text
OK   : 27
WARN : 0
FAIL : 0

Platform Lab: HEALTHY
```

The baseline confirmed:

* all four nodes reachable through SSH;
* all K3s services running;
* Kubernetes API reachable;
* all four Kubernetes nodes `Ready`;
* Flux healthy;
* Flux Kustomizations ready;
* Flux HelmReleases ready.

This baseline is important because it provides a known-good state against which the failure scenario can be compared.

---

# 4. Failure Scenario

## 4.1 Initial workload

The `test-app` Deployment contains one nginx replica:

```yaml
spec:
  replicas: 1
```

The workload is stateless and does not use persistent storage.

Initially, the Pod was running on:

```text
k8s-worker-2
```

---

## 4.2 Force the workload onto worker-3

To perform a controlled worker failure test, the other nodes were temporarily cordoned:

```bash
kubectl cordon k8s-cp k8s-worker-1 k8s-worker-2
```

The existing nginx Pod was then deleted:

```bash
kubectl -n test-app delete pod -l app=nginx
```

The Deployment immediately caused a replacement Pod to be created.

Because the other nodes were cordoned, the replacement was scheduled onto:

```text
k8s-worker-3
```

The test condition was therefore:

```text
test-app/nginx
       │
       ▼
k8s-worker-3
```

---

# 5. Simulate Worker Failure

The VM corresponding to `k8s-worker-3` is VMID `513`.

It was shut down through the Proxmox host:

```bash
ssh root@192.168.1.200 'qm shutdown 513'
```

After Kubernetes detected the loss of communication, the node became:

```text
k8s-worker-3   NotReady
```

---

# 6. Platform Health During Failure

The health-check script was then executed:

```bash
./scripts/platform-health.sh
```

The result was:

```text
OK   : 24
WARN : 0
FAIL : 3

Platform Lab: UNHEALTHY
```

The three failures were:

```text
[FAIL] SSH 192.168.1.170
[FAIL] k3s-agent service on 192.168.1.170
[FAIL] Node k8s-worker-3 Ready=Unknown
```

This is the expected behavior.

The health check did not falsely report the platform as healthy while a worker was unavailable.

The failure was therefore detected at three complementary levels:

```text
Infrastructure access
        │
        ├── SSH failure
        │
        ▼
K3s service
        │
        ├── k3s-agent unavailable
        │
        ▼
Kubernetes
        │
        └── worker-3 not Ready
```

---

# 7. Kubernetes Failure Detection

The Kubernetes node eventually received an unreachable taint:

```text
node.kubernetes.io/unreachable:NoSchedule
node.kubernetes.io/unreachable:NoExecute
```

The nginx Pod had the standard five-minute tolerations:

```text
node.kubernetes.io/not-ready:NoExecute
  tolerationSeconds: 300

node.kubernetes.io/unreachable:NoExecute
  tolerationSeconds: 300
```

Consequently, Kubernetes did not immediately evict the Pod.

This delay is intentional: it prevents transient network interruptions from immediately causing workload recreation.

---

# 8. Workload Recovery

The remaining workers were made schedulable again:

```bash
kubectl uncordon k8s-worker-1 k8s-worker-2
```

After the toleration period, Kubernetes evicted the Pod from the failed node.

The event history showed:

```text
TaintManagerEviction
Marking for deletion Pod test-app/nginx-...
```

The old Pod entered:

```text
Terminating
```

The ReplicaSet detected that the Deployment no longer had its desired replica and created a replacement:

```text
SuccessfulCreate
Created pod: nginx-...
```

The new Pod was scheduled onto:

```text
k8s-worker-2
```

The recovery chain was therefore:

```text
worker-3 failure
       │
       ▼
Node NotReady
       │
       ▼
unreachable taint
       │
       ▼
300 s toleration
       │
       ▼
Pod eviction
       │
       ▼
ReplicaSet reconciliation
       │
       ▼
new Pod created
       │
       ▼
Scheduler
       │
       ▼
k8s-worker-2
```

### Important Kubernetes principle

Kubernetes did not move the original container from `worker-3` to `worker-2`.

It:

1. detected that the original Pod could no longer be relied upon;
2. terminated/evicted the old Pod;
3. created a new Pod;
4. scheduled the new Pod onto an available node.

Kubernetes maintains the **desired state**, not the identity of individual Pods.

---

# 9. Restore the Failed Worker

The control-plane node was made schedulable again:

```bash
kubectl uncordon k8s-cp
```

The failed VM was restarted:

```bash
ssh root@192.168.1.200 'qm start 513'
```

The node initially returned as:

```text
k8s-worker-3   NotReady
```

and subsequently recovered to:

```text
k8s-worker-3   Ready
```

The K3s agent reconnected automatically.

No Terraform or Ansible operation was required for this recovery.

---

# 10. Final Platform Health

After the worker had recovered, the health check was executed again:

```bash
./scripts/platform-health.sh
```

Final result:

```text
OK   : 27
WARN : 0
FAIL : 0

Platform Lab: HEALTHY
```

The final Kubernetes state was:

```text
k8s-cp         Ready
k8s-worker-1   Ready
k8s-worker-2   Ready
k8s-worker-3   Ready
```

The nginx workload remained on `k8s-worker-2`.

This is expected: Kubernetes does not automatically move a healthy Pod back to the node on which it originally ran.

---

# 11. What Was Validated

The test validated several independent operational properties.

## Infrastructure failure detection

The Platform Health Check detects the loss of a worker through:

* SSH connectivity;
* K3s agent availability;
* Kubernetes node state.

## Kubernetes failure detection

Kubernetes detects that the worker is unreachable and changes its state to `NotReady`.

## Pod eviction

The `NoExecute` taint and Pod toleration mechanism determine when the workload should be evicted.

## Workload reconciliation

The ReplicaSet maintains the Deployment's desired replica count.

When the original Pod is lost, a replacement is automatically created.

## Workload rescheduling

The Kubernetes scheduler places the replacement Pod on an available worker.

## Worker recovery

When the VM is restarted, the K3s agent reconnects and the node returns to `Ready`.

## Operational validation

`platform-health.sh` provides an independent, repeatable way to determine whether the complete platform is healthy.

---

# 12. Test Results

| Test                      | Expected result              | Observed |
| ------------------------- | ---------------------------- | -------- |
| Baseline health check     | Healthy                      | PASS     |
| Stop worker-3             | Failure detected             | PASS     |
| SSH check                 | Worker unreachable           | PASS     |
| K3s agent check           | Agent unavailable            | PASS     |
| Kubernetes node check     | Worker not Ready             | PASS     |
| Pod eviction              | Pod eventually evicted       | PASS     |
| ReplicaSet reconciliation | Replacement Pod created      | PASS     |
| Pod rescheduling          | Replacement runs on worker-2 | PASS     |
| Restart worker-3          | Node recovers                | PASS     |
| Final health check        | Healthy                      | PASS     |

---

# 13. Limitations

This test uses:

```yaml
replicas: 1
```

Therefore the application experiences a period of unavailability while Kubernetes:

1. detects the failed node;
2. waits for the Pod toleration period;
3. evicts the Pod;
4. creates a replacement;
5. schedules the replacement;
6. starts the new container.

The test therefore validates **automatic recovery**, not zero-downtime high availability.

A highly available application would normally use multiple replicas distributed across independent nodes, together with suitable readiness probes and traffic distribution.

---

# 14. Operational Runbook

The health check can be used as the first diagnostic command:

```bash
cd ~/projects/platform-lab
./scripts/platform-health.sh
```

If the result is:

```text
Platform Lab: HEALTHY
```

the tested platform components are operational.

If the result is:

```text
Platform Lab: HEALTHY WITH WARNINGS
```

the platform is operational but one or more non-fatal conditions require attention.

If the result is:

```text
Platform Lab: UNHEALTHY
```

the `FAIL` entries identify the first areas to investigate.

For a worker failure, the basic diagnostic sequence is:

```bash
./scripts/platform-health.sh

kubectl get nodes -o wide

kubectl get pods -A -o wide

ssh root@192.168.1.200 'qm list'
```

The health check should be run again after remediation:

```bash
./scripts/platform-health.sh
```

The expected recovery condition is:

```text
FAIL : 0
Platform Lab: HEALTHY
```

---

# Conclusion

The Platform Lab has now been tested as an operational platform rather than only as a provisioning exercise.

The complete lifecycle has been validated:

```text
Proxmox VM
    │
    ▼
K3s worker
    │
    ▼
Kubernetes workload
    │
    ▼
Worker failure
    │
    ▼
Platform Health detects failure
    │
    ▼
Kubernetes detects NotReady
    │
    ▼
Pod eviction
    │
    ▼
ReplicaSet reconciliation
    │
    ▼
Pod recreation
    │
    ▼
Rescheduling
    │
    ▼
Worker recovery
    │
    ▼
Platform Health confirms recovery
```

The Platform Lab therefore has a first operational validation loop:

```text
Observe → Detect → Recover → Validate
```

This provides the foundation for the next stages of the platform work: observability, diagnostics, security, CI/CD and more advanced resilience testing.
