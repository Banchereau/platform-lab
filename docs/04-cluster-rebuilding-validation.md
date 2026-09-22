# Validation de la reconstruction de la plateforme

## Objectif

Valider que la plateforme peut être reconstruite à partir du code source et de la configuration GitOps, sans configuration Kubernetes manuelle après la création des VMs.

La chaîne validée est :

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
Application de test
```

## Reconstruction

Les quatre VMs Kubernetes ont été recréées par Terraform :

| VM           | Adresse       |
| ------------ | ------------- |
| k8s-cp       | 192.168.1.167 |
| k8s-worker-1 | 192.168.1.168 |
| k8s-worker-2 | 192.168.1.169 |
| k8s-worker-3 | 192.168.1.170 |

K3s a été installé automatiquement par cloud-init.

Le cluster a ensuite été vérifié avec `kubectl` et les quatre nœuds étaient `Ready`.

Le kubeconfig du control-plane a été récupéré afin de permettre l'administration du cluster depuis la machine d'administration.

## Bootstrap FluxCD

FluxCD a été bootstrapé sur le dépôt :

```text
https://github.com/Banchereau/edge-platform.git
```

avec le chemin :

```text
clusters/platform-lab
```

Les composants Flux sont opérationnels et la synchronisation Git fonctionne.

La configuration Kubernetes est donc désormais pilotée par Git.

## Déploiement de l'infrastructure

Flux déploie notamment :

* MetalLB
* ingress-nginx
* l'application de test

La configuration MetalLB est séparée de son installation afin de respecter l'ordre de déploiement des CRDs.

Structure utilisée :

```text
infrastructure/
├── ingress-nginx/
├── metallb/
├── metallb-config/
└── test-app/
```

La configuration MetalLB dépend de la Kustomization `infrastructure` :

```text
infrastructure
      ↓
metallb-config
```

Cela garantit que les CRDs MetalLB sont disponibles avant l'application de `IPAddressPool` et `L2Advertisement`.

## Correction de l'API MetalLB

Une première configuration utilisait :

```yaml
apiVersion: metallb.io/v1
```

Cependant, le CRD installé par MetalLB `0.16.1` dans cette plateforme expose actuellement :

```text
metallb.io/v1beta1
```

La version réellement disponible a été vérifiée directement sur le cluster :

```bash
kubectl get crd l2advertisements.metallb.io \
  -o jsonpath='{.spec.versions[*].name}'
```

Résultat :

```text
v1beta1
```

Les manifests GitOps ont donc été corrigés pour utiliser :

```yaml
apiVersion: metallb.io/v1beta1
```

Après commit et push, Flux a réconcilié automatiquement la configuration.

## MetalLB

Le pool d'adresses est :

```text
192.168.1.100/32
```

Vérification :

```bash
kubectl get ipaddresspools -n metallb-system
```

Résultat :

```text
NAME                AUTO ASSIGN   AVOID BUGGY IPS   ADDRESSES
platform-lab-pool   true          false             ["192.168.1.100/32"]
```

L'annonce L2 est également présente :

```bash
kubectl get l2advertisements -n metallb-system
```

Résultat :

```text
NAME           IPADDRESSPOOLS
platform-lab   ["platform-lab-pool"]
```

## ingress-nginx

Le service ingress-nginx est exposé par MetalLB :

```bash
kubectl get svc -n ingress-nginx
```

Résultat :

```text
NAME                       TYPE           EXTERNAL-IP
ingress-nginx-controller   LoadBalancer   192.168.1.100
```

Le VIP `192.168.1.100` est donc correctement attribué au contrôleur Ingress.

## Validation réseau

Depuis la machine d'administration :

```bash
curl -i http://192.168.1.100
```

Résultat :

```text
HTTP/1.1 404 Not Found
```

Ce résultat est attendu : le trafic atteint bien ingress-nginx, mais aucune règle Ingress ne correspond au Host utilisé.

La résolution de l'Ingress a ensuite été vérifiée avec :

```bash
curl -i \
  -H 'Host: test.platform-lab.local' \
  http://192.168.1.100/
```

Résultat :

```text
HTTP/1.1 200 OK
```

avec la page nginx de l'application de test.

Cette validation démontre que le trafic suit correctement la chaîne :

```text
Client
  ↓
192.168.1.100
  ↓
MetalLB
  ↓
ingress-nginx
  ↓
Ingress test.platform-lab.local
  ↓
Service test-app
  ↓
Pod nginx
```

## État de Flux

Après la correction, toutes les Kustomizations principales sont `Ready` :

```text
flux-system       Ready
infrastructure    Ready
metallb-config     Ready
test-app           Ready
```

La configuration finale a été appliquée depuis le commit Git :

```text
f4f89349
```

## Résultat

La reconstruction complète de la plateforme a été validée.

Les éléments suivants sont désormais reproductibles :

* création des VMs par Terraform ;
* configuration initiale par cloud-init ;
* installation de K3s ;
* bootstrap de FluxCD ;
* installation de MetalLB ;
* configuration du pool d'adresses MetalLB ;
* installation d'ingress-nginx ;
* attribution du VIP `192.168.1.100` ;
* configuration de l'Ingress ;
* déploiement de l'application de test.

Aucune ressource MetalLB, ingress-nginx ou application de test n'a été appliquée manuellement avec `kubectl`.

La configuration applicative et d'infrastructure Kubernetes provient du dépôt Git et est appliquée par FluxCD.

**La chaîne Terraform → Proxmox → cloud-init → K3s → FluxCD → Kubernetes est donc validée de bout en bout.**
