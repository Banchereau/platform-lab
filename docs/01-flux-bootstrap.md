# FluxCD Bootstrap

## 1. Overview

This document describes the installation and bootstrap of FluxCD on the Kubernetes cluster created by the Platform Lab project.

The goal is to establish the GitOps foundation for the Edge Platform project:

```text
GitHub repository
Banchereau/edge-platform
        |
        | Git
        v
     FluxCD
        |
        | Kubernetes manifests
        v
   K3s cluster
```

At this stage, FluxCD is responsible for synchronizing Kubernetes configuration from Git.

Terraform remains responsible for the underlying infrastructure:

```text
Terraform
    |
    +-- Proxmox
    +-- Virtual machines
    +-- Network configuration
    +-- Cloud-init
    +-- K3s installation
```

FluxCD is responsible for the Kubernetes layer:

```text
FluxCD
    |
    +-- GitRepository
    +-- Kustomization
    +-- Kubernetes resources
```

This separation is intentional.

---

## 2. Prerequisites

The following components were already operational before installing FluxCD:

* Proxmox VE 9.2.11
* Terraform 1.15.9
* Debian 13 (Trixie)
* K3s v1.36.4+k3s1
* One Kubernetes control-plane node
* Three Kubernetes worker nodes
* SSH access to the nodes
* GitHub account
* GitHub CLI (`gh`)
* Flux CLI v2.9.5

The Kubernetes cluster was healthy before the Flux bootstrap.

Current cluster:

```text
k8s-cp        192.168.1.167
k8s-worker-1  192.168.1.168
k8s-worker-2  192.168.1.169
k8s-worker-3  192.168.1.170
```

---

## 3. Dedicated Kubernetes kubeconfig

The K3s kubeconfig is generated on the control-plane node at:

```text
/etc/rancher/k3s/k3s.yaml
```

The default K3s configuration uses:

```text
https://127.0.0.1:6443
```

which is appropriate on the control-plane node but not from the workstation.

A dedicated local kubeconfig was therefore created:

```bash
mkdir -p ~/.kube

ssh xcode@192.168.1.167 \
  'sudo cat /etc/rancher/k3s/k3s.yaml' \
  > ~/.kube/platform-lab.yaml

chmod 600 ~/.kube/platform-lab.yaml
```

The Kubernetes API endpoint was changed from:

```text
https://127.0.0.1:6443
```

to:

```text
https://192.168.1.167:6443
```

using:

```bash
sed -i \
  's#https://127.0.0.1:6443#https://192.168.1.167:6443#' \
  ~/.kube/platform-lab.yaml
```

The kubeconfig contains the embedded Kubernetes CA data, so certificate verification works from the workstation.

Validation:

```bash
KUBECONFIG=~/.kube/platform-lab.yaml \
kubectl get nodes
```

Expected result:

```text
NAME           STATUS   ROLES           ...
k8s-cp         Ready    control-plane   ...
k8s-worker-1   Ready    <none>          ...
k8s-worker-2   Ready    <none>          ...
k8s-worker-3   Ready    <none>          ...
```

---

## 4. Flux prerequisite check

The Flux CLI was installed with:

```bash
curl -s https://fluxcd.io/install.sh | sudo bash
```

Version:

```text
flux version 2.9.5
```

The prerequisites were checked with:

```bash
KUBECONFIG=~/.kube/platform-lab.yaml \
flux check --pre
```

Result:

```text
► checking prerequisites
✔ Kubernetes 1.36.4+k3s1 >=1.33.0-0
✔ prerequisites checks passed
```

---

## 5. GitHub repository

A dedicated repository was created for the Edge Platform GitOps configuration:

```text
Banchereau/edge-platform
```

It was created with:

```bash
cd ~/projects/platform-lab

gh repo create Banchereau/edge-platform \
  --private \
  --description "Edge platform lab: infrastructure automation, Kubernetes, GitOps and DevSecOps." \
  --clone
```

The local repository is:

```text
~/projects/platform-lab/edge-platform
```

Remote:

```text
https://github.com/Banchereau/edge-platform.git
```

The repository is private.

---

## 6. GitHub authentication for Flux

The GitHub CLI authentication used for administrative operations is separate from the authentication used by Flux.

Flux requires GitHub API access during bootstrap in order to configure the repository integration.

A dedicated fine-grained GitHub personal access token was used for Flux.

The token was restricted to the:

```text
Banchereau/edge-platform
```

repository.

The required repository permissions include:

```text
Administration: Read and write
Contents: Read and write
Metadata: Read-only
```

The token itself is not stored in this repository.

It must never be committed to Git.

---

## 7. Flux bootstrap

Flux was bootstrapped with:

```bash
cd ~/projects/platform-lab/edge-platform

KUBECONFIG=~/.kube/platform-lab.yaml \
flux bootstrap github \
  --owner=Banchereau \
  --repository=edge-platform \
  --branch=main \
  --path=clusters/platform-lab \
  --personal
```

The bootstrap created the Flux components and configured the repository synchronization.

The target GitOps path is:

```text
clusters/platform-lab
```

---

## 8. Bootstrap authentication issue

The first bootstrap attempt reached the repository successfully but failed when Flux attempted to access the repository deploy keys:

```text
GET https://api.github.com/repos/Banchereau/edge-platform/keys:
403 Resource not accessible by personal access token
```

The Kubernetes components had already been installed successfully.

The issue was caused by insufficient permissions on the fine-grained GitHub token.

The token was updated to allow repository administration operations.

The bootstrap was then rerun successfully.

No cluster rebuild or Terraform changes were required.

---

## 9. Flux components

The following Flux controllers are running in the `flux-system` namespace:

```text
helm-controller
kustomize-controller
notification-controller
source-controller
```

Validation:

```bash
KUBECONFIG=~/.kube/platform-lab.yaml \
kubectl get pods -n flux-system
```

Expected state:

```text
NAME                                       READY   STATUS    RESTARTS
helm-controller-...                        1/1     Running   0
kustomize-controller-...                   1/1     Running   0
notification-controller-...                1/1     Running   0
source-controller-...                      1/1     Running   0
```

All four controllers were running with zero restarts during validation.

---

## 10. GitRepository and Kustomization

Flux created a `GitRepository` resource representing the GitHub repository.

Validation:

```bash
KUBECONFIG=~/.kube/platform-lab.yaml \
flux get all -A
```

The resulting state was:

```text
NAMESPACE       NAME                         REVISION
flux-system     gitrepository/flux-system    main@sha1:c15f3a2c

READY   MESSAGE
True    stored artifact for revision 'main@sha1:c15f3a2c'
```

Flux also created the corresponding Kustomization:

```text
NAMESPACE       NAME                         REVISION
flux-system     kustomization/flux-system    main@sha1:c15f3a2c

READY   MESSAGE
True    Applied revision: main@sha1:c15f3a2c
```

This confirms that:

1. Flux can authenticate to GitHub.
2. Flux can retrieve the Git repository.
3. Flux can create a source artifact.
4. Flux can apply the Kubernetes manifests from Git.
5. The Git repository and Kubernetes cluster are synchronized.

---

## 11. Git history

The bootstrap created two commits in the repository.

```text
c15f3a2 Add Flux sync manifests
d5a3b45 Add Flux v2.9.5 component manifests
```

The repository was then synchronized locally:

```bash
git pull origin main
```

The local branch is now aligned with GitHub:

```text
c15f3a2 (HEAD -> main, origin/main) Add Flux sync manifests
d5a3b45 Add Flux v2.9.5 component manifests
```

---

## 12. Current architecture

The current platform is divided into two layers.

### Infrastructure layer

Managed by Terraform:

```text
Terraform
    |
    v
Proxmox
    |
    +-- k8s-cp
    +-- k8s-worker-1
    +-- k8s-worker-2
    +-- k8s-worker-3
    |
    v
K3s cluster
```

Terraform provisions the infrastructure and performs the initial K3s installation through cloud-init.

### Kubernetes / GitOps layer

Managed by FluxCD:

```text
GitHub
Banchereau/edge-platform
        |
        v
     FluxCD
        |
        v
Kubernetes resources
```

The resulting separation is:

```text
Terraform
    |
    | infrastructure
    v
Proxmox + K3s
    ^
    |
    | Kubernetes configuration
    |
FluxCD
    ^
    |
    | Git
    |
GitHub
```

---

## 13. Responsibilities

### Terraform

Terraform is responsible for:

* Proxmox infrastructure
* Virtual machines
* CPU and memory allocation
* Virtual disks
* Network configuration
* Cloud-init configuration
* K3s installation
* Initial cluster provisioning

Terraform should not become the primary mechanism for managing normal Kubernetes application configuration.

### FluxCD

FluxCD will be responsible for:

* Kubernetes manifests
* Namespaces
* Deployments
* Services
* ConfigMaps
* Secrets references
* Helm releases
* Kustomizations
* GitOps reconciliation

The Git repository becomes the source of truth for the Kubernetes layer.

---

## 14. Current state

The following milestones are complete:

* [x] Proxmox infrastructure
* [x] Terraform infrastructure automation
* [x] Debian cloud-init provisioning
* [x] K3s control-plane provisioning
* [x] K3s worker provisioning
* [x] Kubernetes cluster validation
* [x] Dedicated workstation kubeconfig
* [x] GitHub repository creation
* [x] Flux CLI installation
* [x] Flux prerequisite validation
* [x] Flux bootstrap
* [x] GitHub authentication
* [x] Flux controllers running
* [x] GitRepository reconciliation
* [x] Kustomization reconciliation

---

## 15. Next step

The Flux installation itself is complete.

The next step is to create a small Kubernetes resource in Git and verify the complete GitOps workflow:

```text
Edit YAML
    |
    v
git commit
    |
    v
git push
    |
    v
GitHub
    |
    v
Flux detects the new revision
    |
    v
Flux reconciles the cluster
    |
    v
Kubernetes resource updated
```

A simple namespace or test deployment should be used first.

More complex components such as Helm releases, ingress, observability and application workloads should be introduced only after this basic GitOps cycle has been validated.

---

## 16. Important principle

The Edge Platform project deliberately separates:

```text
Infrastructure as Code
        +
GitOps
```

Terraform answers:

> How do I create the platform?

FluxCD answers:

> What should be running on the platform?

This separation is the foundation for the next stages of the Platform Lab.
