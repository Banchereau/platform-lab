# FluxCD / GitOps

## 1. Objectif

Cette partie du projet met en place une gestion GitOps de la plateforme Kubernetes.

L'objectif est de faire de Git la source de vérité pour :

- la configuration FluxCD ;
- les composants d'infrastructure Kubernetes ;
- les applications déployées dans le cluster.

La chaîne cible est :

```text
GitHub
   |
   v
FluxCD
   |
   v
Kubernetes
   |
   +--> Infrastructure
   |
   +--> Applications
```

La plateforme utilise :

- K3s ;
- FluxCD ;
- Kustomize ;
- Helm via FluxCD ;
- MetalLB ;
- ingress-nginx.

## 2. Dépôt GitOps

Le dépôt GitOps est :

```text
edge-platform
```

Il est hébergé sur GitHub et utilisé comme source par FluxCD.

Structure actuelle :

```text
edge-platform/
├── clusters/
│   └── platform-lab/
│       └── flux-system/
│           ├── gotk-components.yaml
│           ├── gotk-sync.yaml
│           ├── kustomization.yaml
│           ├── infrastructure.yaml
│           └── test-app.yaml
│
└── infrastructure/
    ├── kustomization.yaml
    │
    ├── ingress-nginx/
    │   ├── namespace.yaml
    │   ├── helmrepository.yaml
    │   ├── helmrelease.yaml
    │   └── kustomization.yaml
    │
    ├── metallb/
    │   ├── namespace.yaml
    │   ├── helmrepository.yaml
    │   ├── helmrelease.yaml
    │   ├── ipaddresspool.yaml
    │   ├── l2advertisement.yaml
    │   └── kustomization.yaml
    │
    └── test-app/
        ├── namespace.yaml
        ├── deployment.yaml
        ├── service.yaml
        ├── ingress.yaml
        └── kustomization.yaml
```

Le dépôt est utilisé uniquement comme source déclarative. Les ressources Kubernetes ne sont pas déployées manuellement avec `kubectl apply`.

## 3. Bootstrap FluxCD

FluxCD est installé dans le namespace :

```text
flux-system
```

Les composants principaux sont :

- source-controller ;
- kustomize-controller ;
- helm-controller ;
- notification-controller.

Les CRD Flux sont également installées pour permettre notamment l'utilisation de :

- `GitRepository` ;
- `Kustomization` ;
- `HelmRepository` ;
- `HelmRelease`.

### 3.1 GitRepository

Flux utilise un objet `GitRepository` pour récupérer le dépôt GitOps. Le dépôt est référencé par :

```text
ssh://git@github.com/Banchereau/edge-platform
```

La ressource utilise le secret :

```text
flux-system
```

pour l'authentification SSH.

La vérification du dépôt peut être effectuée avec :

```bash
kubectl -n flux-system get gitrepository
```

Le résultat attendu est :

```text
READY=True
```

### 3.2 Kustomization Flux principale

Flux utilise une Kustomization nommée :

```text
flux-system
```

Cette Kustomization assure le bootstrap du contenu du dépôt.

Une seconde Kustomization gère l'infrastructure :

```text
infrastructure
```

avec le chemin :

```text
./infrastructure
```

Une troisième Kustomization gère l'application de test :

```text
test-app
```

avec le chemin :

```text
./infrastructure/test-app
```

Cette séparation permet de distinguer :

```text
Flux bootstrap
      |
      +--> Infrastructure
      |
      +--> Applications
```

## 4. GitOps de l'infrastructure

Le fichier :

```text
clusters/platform-lab/flux-system/infrastructure.yaml
```

déclare la Kustomization Flux responsable de l'infrastructure.

Configuration :

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 5m
  path: ./infrastructure
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

L'option :

```text
prune: true
```

permet à Flux de supprimer du cluster les ressources précédemment gérées par cette Kustomization lorsqu'elles sont retirées de Git.

## 5. ingress-nginx

ingress-nginx fournit le contrôleur HTTP chargé de traiter les ressources Kubernetes `Ingress`.

Il est installé via Helm, mais Helm est lui-même piloté par FluxCD. La chaîne est donc :

```text
Git
 |
 +--> HelmRepository
 |
 +--> HelmRelease
       |
       v
     Helm
       |
       v
 ingress-nginx
```

Le `HelmRepository` utilise :

```text
https://kubernetes.github.io/ingress-nginx
```

Le `HelmRelease` installe le chart :

```text
ingress-nginx
```

Le contrôleur est déployé dans :

```text
ingress-nginx
```

### 5.1 Service ingress-nginx

Le contrôleur est exposé par un Service Kubernetes de type :

```text
LoadBalancer
```

Le service possède notamment :

```text
ClusterIP : 10.43.83.116
```

et reçoit de MetalLB l'adresse :

```text
192.168.1.100
```

Les ports exposés sont :

```text
80  -> NodePort 32449
443 -> NodePort 31725
```

## 6. MetalLB

MetalLB fournit des adresses IP `LoadBalancer` pour le cluster K3s.

Dans ce laboratoire, une seule adresse est utilisée :

```text
192.168.1.100
```

Le pool d'adresses est :

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: platform-lab-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.100/32
```

### 6.1 Annonce L2

L'adresse est annoncée sur le réseau local par MetalLB en mode L2.

Configuration :

```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: platform-lab
  namespace: metallb-system
spec:
  ipAddressPools:
    - platform-lab-pool
```

MetalLB sélectionne un speaker pour annoncer la VIP. Lors de la validation, le speaker sélectionné était situé sur :

```text
k8s-worker-1
```

### 6.2 Validation ARP

La résolution ARP de :

```text
192.168.1.100
```

a été observée depuis un autre nœud du cluster. Le réseau a notamment retourné :

```text
192.168.1.100 dev eth0
lladdr bc:24:11:20:d5:da
REACHABLE
```

Une capture réseau sur `k8s-worker-1` a également montré les échanges ARP pour la VIP.

Cela confirme que l'annonce L2 de MetalLB fonctionne.

## 7. Application de test

Une application simple nginx est utilisée pour valider la chaîne GitOps et le routage HTTP.

Elle est déployée dans :

```text
test-app
```

Le Deployment utilise :

```text
nginx:1.29
```

Configuration principale :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: test-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          ports:
            - containerPort: 80
```

Le pod est donc sélectionné par :

```text
app: nginx
```

## 8. Service Kubernetes

Le Deployment est exposé par un Service :

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: test-app
spec:
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
```

Le Service est de type :

```text
ClusterIP
```

Il fournit le point d'accès Kubernetes utilisé par l'Ingress.

La chaîne interne est :

```text
Ingress
   |
   v
Service nginx:80
   |
   v
Pod nginx:80
```

## 9. Ingress

L'application est exposée par une ressource Kubernetes `Ingress`.

Le nom d'hôte choisi pour le test est :

```text
test.platform-lab.local
```

Configuration :

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx
  namespace: test-app
spec:
  ingressClassName: nginx
  rules:
    - host: test.platform-lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx
                port:
                  number: 80
```

Le contrôleur utilisé est :

```text
nginx
```

La requête correspondant au host :

```text
test.platform-lab.local
```

est donc envoyée vers :

```text
Service/nginx:80
```

## 10. Déploiement de l'application par FluxCD

La Kustomization Flux associée à l'application est :

```text
test-app
```

Elle utilise :

```yaml
spec:
  interval: 5m
  path: ./infrastructure/test-app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

La Kustomization Kustomize de l'application référence :

```yaml
resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

Le cycle de déploiement est donc :

```text
Modification Git
      |
      v
git push
      |
      v
GitRepository Flux
      |
      v
Kustomization Flux
      |
      v
Kustomize
      |
      v
Kubernetes
```

Aucun `kubectl apply` manuel n'est nécessaire.

## 11. Validation du LoadBalancer

Avant l'ajout de l'Ingress et du Service, un test HTTP direct vers la VIP a été effectué depuis `k8s-worker-2` :

```bash
curl -v http://192.168.1.100
```

La connexion TCP vers le port 80 a réussi.

La réponse était :

```text
HTTP/1.1 404 Not Found
```

avec une page générée par nginx.

Ce résultat était attendu. Il indiquait que :

- la VIP était accessible ;
- MetalLB fonctionnait ;
- le Service `LoadBalancer` était accessible ;
- ingress-nginx recevait la requête.

En revanche, aucune règle Ingress ne correspondait encore à la requête. Le `404` ne constituait donc pas une erreur de MetalLB.

## 12. Validation du routage Ingress

Après ajout du Service et de l'Ingress dans le dépôt GitOps, FluxCD a déployé automatiquement les nouvelles ressources.

Le test final a été effectué depuis :

```text
k8s-worker-2
```

avec :

```bash
curl -v \
  -H 'Host: test.platform-lab.local' \
  http://192.168.1.100/
```

Résultat :

```text
HTTP/1.1 200 OK
Content-Type: text/html
Content-Length: 896
```

Le corps de la réponse contenait :

```text
Welcome to nginx!
```

Le routage basé sur le header HTTP `Host` fonctionne donc correctement.

## 13. Chaîne complète validée

La validation permet de confirmer la chaîne suivante :

```text
GitHub
   |
   v
FluxCD
   |
   v
Kubernetes
   |
   +------------------+
   |                  |
   v                  v
Deployment          Ingress
   |                  |
   v                  v
Pod nginx        ingress-nginx
                      |
                      v
                  MetalLB
                      |
                      v
               192.168.1.100
                      |
                      v
                 Service nginx
                      |
                      v
                  Pod nginx
                      |
                      v
                  HTTP 200
```

La chaîne logique complète peut être résumée ainsi :

```text
Git
 ↓
FluxCD
 ↓
Kubernetes
 ↓
Ingress
 ↓
ingress-nginx
 ↓
MetalLB
 ↓
Service
 ↓
Pod
 ↓
Application
```

## 14. Résultats de la validation

Les éléments suivants sont validés.

**FluxCD**

- Le dépôt GitHub est utilisé comme source de vérité.
- Flux récupère correctement le dépôt.
- Les Kustomizations sont réconciliées.
- Les modifications Git sont appliquées au cluster.
- Les ressources supprimées de Git peuvent être supprimées du cluster grâce à `prune: true`.

**MetalLB**

- Le pool d'adresses est correctement configuré.
- La VIP `192.168.1.100` est attribuée au Service `LoadBalancer`.
- L'annonce L2 fonctionne.
- La résolution ARP de la VIP fonctionne.

**ingress-nginx**

- Le contrôleur est correctement déployé.
- Le Service `LoadBalancer` est fonctionnel.
- Les requêtes HTTP atteignent le contrôleur.
- Les règles `Ingress` sont prises en compte.

**Kubernetes**

- Le Deployment nginx fonctionne.
- Le Service sélectionne correctement le pod.
- L'Ingress pointe vers le Service.
- Le trafic est transmis jusqu'au pod.

**Validation fonctionnelle**

Le test :

```bash
curl -H 'Host: test.platform-lab.local' \
     http://192.168.1.100/
```

retourne :

```text
HTTP/1.1 200 OK
```

La plateforme n'est donc pas seulement installée : la chaîne GitOps et réseau est fonctionnelle de bout en bout.

## 15. Architecture actuelle

La plateforme dispose maintenant de deux niveaux déclaratifs.

**Infrastructure**

Terraform et cloud-init sont responsables de la création et de l'initialisation des VM :

```text
Terraform
   |
   v
Proxmox
   |
   v
VMs Debian
   |
   v
cloud-init
   |
   v
K3s
```

**Kubernetes / applications**

FluxCD prend ensuite le relais :

```text
GitHub
   |
   v
FluxCD
   |
   v
Kubernetes
   |
   +--> MetalLB
   |
   +--> ingress-nginx
   |
   +--> Applications
```

La chaîne globale est donc :

```text
Terraform
    |
    v
Proxmox
    |
    v
VMs
    |
    v
cloud-init
    |
    v
K3s
    |
    v
FluxCD
    |
    v
Infrastructure Kubernetes
    |
    v
Applications
```

## 16. Prochaine validation

L'installation manuelle des différents composants étant maintenant validée, l'étape suivante est de vérifier la reproductibilité complète de la plateforme.

L'objectif est de pouvoir partir d'un environnement Proxmox vide et reconstruire :

```text
Terraform
    ↓
VMs
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
Applications
```

La validation cible sera donc :

1. vérifier que l'état Terraform est cohérent ;
2. détruire les VMs du cluster ;
3. recréer les VMs avec Terraform ;
4. laisser cloud-init installer et configurer K3s ;
5. vérifier le cluster ;
6. vérifier le bootstrap FluxCD ;
7. vérifier la réconciliation de l'infrastructure ;
8. vérifier le déploiement de `test-app` ;
9. vérifier à nouveau l'accès HTTP via `192.168.1.100`.

Le véritable objectif devient alors : **reconstruire la plateforme de manière reproductible à partir des sources déclaratives, sans configuration manuelle persistante.**
