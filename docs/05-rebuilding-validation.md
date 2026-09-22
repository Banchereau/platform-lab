# Validation de la reconstruction complète de la plateforme

**Date :** 21 septembre 2026

## Objectif

Valider qu'une reconstruction complète de la plateforme depuis Terraform permet de retrouver un environnement Kubernetes fonctionnel, depuis l'infrastructure Proxmox jusqu'à l'application déployée par GitOps.

Chaîne validée :

```text
Terraform
    ↓
Proxmox
    ↓
VMs Debian
    ↓
cloud-init
    ↓
K3s
    ↓
FluxCD
    ↓
MetalLB
    ↓
ingress-nginx
    ↓
Ingress
    ↓
Service Kubernetes
    ↓
Pod nginx
```

## 1. Infrastructure

### Hyperviseur

- Proxmox VE 9.2.11
- Terraform 1.15.9

### Machines virtuelles

| VMID | Nom          | Adresse IP    | Rôle               |
|------|--------------|---------------|--------------------|
| 510  | k8s-cp       | 192.168.1.167 | K3s control-plane  |
| 511  | k8s-worker-1 | 192.168.1.168 | K3s worker         |
| 512  | k8s-worker-2 | 192.168.1.169 | K3s worker         |
| 513  | k8s-worker-3 | 192.168.1.170 | K3s worker         |

Les VMs sont créées à partir du template Debian cloud-init et configurées par Terraform.

## 2. Destruction complète

Une destruction complète de l'infrastructure gérée par Terraform a été effectuée.

Ressources détruites :

- 4 fichiers cloud-init
- 4 VMs Kubernetes
- 1 ressource `random_password.k3s_token`

Le template Debian n'a pas été détruit.

Résultat :

```text
Destroy complete! Resources: 9 destroyed.
```

## 3. Reconstruction Terraform

La plateforme a ensuite été reconstruite depuis zéro avec :

```bash
terraform apply
```

Résultat :

```text
Apply complete! Resources: 8 added, 0 changed, 0 destroyed.
```

Les quatre VMs ont été recréées et configurées automatiquement.

## 4. Installation K3s

K3s est installé automatiquement par cloud-init.

Version validée :

```text
v1.36.4+k3s1
```

Validation du cluster :

```bash
kubectl get nodes -o wide
```

Résultat :

```text
k8s-cp         Ready    control-plane   v1.36.4+k3s1   192.168.1.167
k8s-worker-1   Ready    <none>          v1.36.4+k3s1   192.168.1.168
k8s-worker-2   Ready    <none>          v1.36.4+k3s1   192.168.1.169
k8s-worker-3   Ready    <none>          v1.36.4+k3s1   192.168.1.170
```

Les quatre nœuds sont `Ready`.

## 5. Bootstrap FluxCD

FluxCD n'est pas installé par Terraform ou cloud-init.

Le bootstrap GitOps constitue une étape séparée :

```bash
flux bootstrap github \
  --owner=Banchereau \
  --repository=edge-platform \
  --branch=main \
  --path=clusters/platform-lab \
  --personal
```

Cette séparation permet de conserver les credentials GitHub côté opérateur et de ne pas les injecter dans les VMs.

Version Flux validée :

```text
flux-v2.9.5
```

Validation :

```bash
flux check
```

Résultat :

```text
✔ Kubernetes 1.36.4+k3s1 >=1.33.0-0
✔ distribution: flux-v2.9.5
✔ bootstrapped: true
✔ helm-controller: deployment ready
✔ kustomize-controller: deployment ready
✔ notification-controller: deployment ready
✔ source-controller: deployment ready
✔ all checks passed
```

## 6. Réconciliation GitOps

### GitRepository

```bash
flux get sources git -A
```

Résultat :

```text
NAMESPACE     NAME         REVISION              SUSPENDED   READY
flux-system   flux-system  main@sha1:f4f89349   False       True
```

Le dépôt GitHub est correctement utilisé comme source de configuration.

### HelmReleases

```bash
flux get helmreleases -A
```

Résultat :

```text
NAMESPACE        NAME            REVISION   SUSPENDED   READY
ingress-nginx    ingress-nginx   4.15.1     False       True
metallb-system   metallb         0.16.1     False       True
```

Les deux composants d'infrastructure sont correctement déployés par Flux.

### Kustomizations

```bash
flux get kustomizations -A
```

Résultat :

```text
NAMESPACE     NAME             REVISION              SUSPENDED   READY
flux-system   flux-system      main@sha1:f4f89349   False       True
flux-system   infrastructure   main@sha1:f4f89349   False       True
flux-system   metallb-config   main@sha1:f4f89349   False       True
flux-system   test-app         main@sha1:f4f89349   False       True
```

Toutes les Kustomizations sont `Ready`.

## 7. MetalLB

Le pool d'adresses est correctement réconcilié par Flux.

```bash
kubectl get ipaddresspools -n metallb-system
```

Résultat :

```text
NAME                AUTO ASSIGN   AVOID BUGGY IPS   ADDRESSES
platform-lab-pool   true          false             ["192.168.1.100/32"]
```

Le service `ingress-nginx` reçoit bien l'adresse :

```text
192.168.1.100
```

## 8. ingress-nginx

Validation :

```bash
kubectl get svc -A
```

Le service principal est :

```text
ingress-nginx-controller   LoadBalancer   192.168.1.100
```

L'Ingress de l'application de test est également présent :

```bash
kubectl get ingress -A
```

Résultat :

```text
NAMESPACE   NAME    CLASS   HOSTS                      PORTS
test-app    nginx   nginx   test.platform-lab.local   80
```

## 9. Test fonctionnel de bout en bout

### Accès sans Host

```bash
curl -i http://192.168.1.100
```

Résultat :

```text
HTTP/1.1 404 Not Found
```

Ce résultat est attendu : aucun Ingress ne correspond à une requête sans le Host attendu.

### Accès avec le Host attendu

```bash
curl -i \
  -H 'Host: test.platform-lab.local' \
  http://192.168.1.100/
```

Résultat :

```text
HTTP/1.1 200 OK
```

La page retournée est la page d'accueil nginx.

Cette validation démontre le chemin complet :

```text
Client
  ↓
192.168.1.100
  ↓
MetalLB
  ↓
ingress-nginx
  ↓
Ingress test-app
  ↓
Service nginx
  ↓
Pod nginx
```

## 10. État des pods

Après reconstruction :

```bash
kubectl get pods -A
```

Les composants suivants sont opérationnels :

- FluxCD
- ingress-nginx
- MetalLB
- CoreDNS
- local-path-provisioner
- metrics-server
- application de test

Aucun redémarrage n'a été observé sur les pods lors de la validation.

## 11. Résultat

La reconstruction complète de la plateforme a été validée.

La chaîne suivante est reproductible :

```text
Terraform
    ↓
Proxmox
    ↓
VMs Debian
    ↓
cloud-init
    ↓
K3s
    ↓
FluxCD bootstrap
    ↓
GitRepository
    ↓
HelmReleases
    ↓
Kustomizations
    ↓
MetalLB
    ↓
ingress-nginx
    ↓
Ingress
    ↓
Service
    ↓
Pod
```

### Niveau de validation

| Élément                  | Résultat |
|---------------------------|----------|
| Destruction Terraform      | ✅ |
| Recréation des VMs         | ✅ |
| Configuration cloud-init   | ✅ |
| K3s control-plane          | ✅ |
| K3s workers                | ✅ |
| Cluster Kubernetes         | ✅ |
| FluxCD                     | ✅ |
| GitRepository               | ✅ |
| HelmReleases                | ✅ |
| Kustomizations              | ✅ |
| MetalLB                     | ✅ |
| Attribution VIP             | ✅ |
| ingress-nginx               | ✅ |
| Ingress                     | ✅ |
| Application de test         | ✅ |
| Test HTTP de bout en bout   | ✅ |

La plateforme peut donc être considérée comme reproductible depuis l'infrastructure jusqu'à la couche GitOps et applicative.

## 12. Limite volontaire

Le bootstrap initial de FluxCD reste une opération effectuée par l'opérateur :

```text
terraform apply
        ↓
infrastructure Kubernetes prête
        ↓
flux bootstrap
        ↓
Git devient la source de vérité
```

Le credential GitHub n'est pas stocké dans Terraform, cloud-init ou les VMs.

Cette séparation constitue actuellement la frontière entre le provisionnement de l'infrastructure et l'initialisation du système GitOps.
