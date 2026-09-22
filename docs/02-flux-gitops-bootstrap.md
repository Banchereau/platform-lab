# FluxCD bootstrap et premier déploiement GitOps

## Objectif

Valider une chaîne GitOps minimale et fonctionnelle sur le cluster K3s du projet `platform-lab`.

Le dépôt Git `edge-platform` constitue la source de vérité pour les ressources Kubernetes gérées par FluxCD.

La validation couvre :

* installation de FluxCD ;
* connexion de Flux à GitHub ;
* synchronisation du dépôt Git ;
* application d'une Kustomization ;
* déploiement automatique d'une application Kubernetes ;
* vérification de l'état du cluster depuis le poste local.

---

## Architecture validée

```text
GitHub
  │
  │ git push
  ▼
edge-platform
  │
  │ GitRepository
  ▼
FluxCD
  │
  │ Kustomization
  ▼
Kubernetes / K3s
  │
  ▼
test-app
  │
  ▼
nginx Pod
```

Le principe est le suivant :

1. Les manifests Kubernetes sont versionnés dans Git.
2. Flux surveille le dépôt Git.
3. Flux détecte les nouvelles révisions.
4. Flux applique les ressources déclarées dans le dépôt.
5. Kubernetes converge vers l'état décrit dans Git.

---

## Dépôt Git

Dépôt :

`Banchereau/edge-platform`

Structure minimale actuelle :

```text
edge-platform/
├── clusters/
│   └── platform-lab/
│       └── flux-system/
│           ├── gotk-components.yaml
│           ├── gotk-sync.yaml
│           ├── kustomization.yaml
│           └── test-app.yaml
│
└── infrastructure/
    └── test-app/
        ├── namespace.yaml
        ├── deployment.yaml
        └── kustomization.yaml
```

---

## FluxCD

Flux est installé dans le namespace :

```text
flux-system
```

Les composants principaux sont :

* source-controller
* kustomize-controller
* helm-controller
* notification-controller

Le dépôt Git est déclaré comme une ressource :

```text
GitRepository/flux-system
```

La synchronisation du cluster est réalisée par :

```text
Kustomization/flux-system
```

---

## Premier déploiement GitOps

Une première application de test a été ajoutée afin de valider le fonctionnement complet de la chaîne GitOps.

Namespace :

```text
test-app
```

Application :

```text
nginx
```

Image :

```text
nginx:1.29
```

La ressource Flux correspondante est :

```text
Kustomization/test-app
```

Elle pointe vers :

```text
./infrastructure/test-app
```

---

## Validation GitOps

La configuration Kustomize locale a été validée :

```bash
kubectl kustomize clusters/platform-lab/flux-system >/dev/null
```

Résultat :

```text
Kustomize OK
```

Après le commit et la synchronisation Git, Flux a appliqué la révision :

```text
main@sha1:137ca3e8a46b44e3268027ce78e7c6ee06dda1d7
```

Vérification :

```bash
kubectl get kustomizations -n flux-system
```

Résultat :

```text
NAME          AGE     READY   STATUS
flux-system   ...     True    Applied revision: main@sha1:137ca3e8a46b44e3268027ce78e7c6ee06dda1d7
test-app      ...     True    Applied revision: main@sha1:137ca3e8a46b44e3268027ce78e7c6ee06dda1d7
```

Le déploiement de l'application a ensuite été vérifié :

```bash
kubectl get pods -n test-app
```

Résultat :

```text
NAME                     READY   STATUS    RESTARTS   AGE
nginx-587495bc45-lw4ts   1/1     Running   0          ...
```

Le premier déploiement GitOps est donc validé.

---

## Kubeconfig après recréation du cluster

Lors de la validation, `kubectl` depuis le poste local retournait :

```text
tls: failed to verify certificate:
x509: certificate signed by unknown authority
```

Le cluster K3s était pourtant fonctionnel depuis le control-plane.

Le diagnostic a montré que le kubeconfig local contenait l'ancienne autorité de certification :

```text
CN=k3s-server-ca@1789305260
```

alors que le cluster actuel utilisait :

```text
CN=k3s-server-ca@1789912008
```

Le certificat présenté par l'API Kubernetes correspondait au cluster actuel.

Le problème provenait donc d'un kubeconfig local obsolète après la recréation du cluster.

Le kubeconfig actuel a été récupéré depuis :

```text
k8s-cp:/etc/rancher/k3s/k3s.yaml
```

puis adapté pour utiliser l'adresse réseau du control-plane :

```text
https://192.168.1.167:6443
```

Le fichier local a été sauvegardé avant remplacement :

```text
~/.kube/config.old
```

La connexion depuis le poste local fonctionne maintenant :

```bash
kubectl get nodes -o wide
```

avec les quatre nœuds en état `Ready`.

---

## État du cluster au moment de la validation

Cluster :

```text
K3s v1.36.4+k3s1
```

Nœuds :

```text
k8s-cp         192.168.1.167
k8s-worker-1   192.168.1.168
k8s-worker-2   192.168.1.169
k8s-worker-3   192.168.1.170
```

Les quatre nœuds sont :

```text
Ready
```

Le control-plane est opérationnel et le cluster accepte les déploiements provenant de FluxCD.

---

## Ce qui est désormais validé

À ce stade, les éléments suivants sont opérationnels :

* Proxmox automatisé par Terraform ;
* création des machines virtuelles ;
* configuration initiale par cloud-init ;
* installation automatisée de K3s ;
* control-plane et workers ;
* accès Kubernetes depuis le poste local ;
* FluxCD installé ;
* connexion FluxCD → dépôt GitHub ;
* synchronisation Git → cluster ;
* Kustomization Flux ;
* déploiement d'une application depuis Git ;
* vérification de l'état souhaité dans Kubernetes.

La chaîne suivante est donc fonctionnelle :

```text
Terraform
   │
   ▼
Proxmox
   │
   ▼
VMs Debian
   │
   ▼
K3s
   │
   ▼
FluxCD
   │
   ▼
GitHub
   │
   ▼
Kubernetes resources
```

---

## Prochaine étape

Le bootstrap GitOps étant validé, le dépôt `edge-platform` peut progressivement devenir le point de gestion des composants de la plateforme.

Les prochains composants pourront être intégrés progressivement, par exemple :

```text
infrastructure/
├── ingress-nginx/
├── metallb/
├── cert-manager/
└── monitoring/
```

L'objectif est de ne pas introduire tous ces composants simultanément.

Le principe reste :

```text
1. ajouter dans Git
2. valider Kustomize
3. commit
4. push
5. laisser Flux réconcilier
6. vérifier l'état Kubernetes
```

Cela permet de conserver une plateforme reproductible et de pouvoir ensuite tester une reconstruction complète du cluster à partir de l'infrastructure déclarative et du dépôt Git.
