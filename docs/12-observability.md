# Observabilité de la plateforme

## 1. Objectif

La plateforme Kubernetes dispose d'une stack d'observabilité déployée et maintenue par FluxCD.

L'objectif de cette première étape est de disposer de métriques permettant de suivre :

* l'état des nœuds Kubernetes ;
* la consommation CPU et mémoire ;
* l'état des pods et workloads ;
* les composants Kubernetes ;
* les composants de la plateforme ;
* Prometheus lui-même ;
* les métriques système exposées par `node-exporter`.

La stack retenue est `kube-prometheus-stack`, déployée via Helm et pilotée par FluxCD.

---

## 2. Architecture

L'observabilité est intégrée au dépôt GitOps `edge-platform`.

```text
GitHub
  │
  │ GitRepository
  ▼
FluxCD
  │
  │ HelmRelease
  ▼
kube-prometheus-stack
  │
  ├── Prometheus
  │     ├── kubelet
  │     ├── cAdvisor
  │     ├── node-exporter
  │     ├── kube-state-metrics
  │     ├── Kubernetes API Server
  │     └── composants Kubernetes
  │
  ├── Grafana
  │
  └── Alertmanager
```

Le déploiement est réalisé dans le namespace :

```text
observability
```

---

## 3. Organisation GitOps

Les manifests sont situés dans :

```text
infrastructure/
└── observability/
    ├── namespace.yaml
    ├── helmrepository.yaml
    ├── helmrelease.yaml
    └── kustomization.yaml
```

Le répertoire est inclus dans la Kustomization principale :

```yaml
resources:
  - ingress-nginx
  - metallb
  - observability
```

Flux applique donc automatiquement la configuration depuis le dépôt Git.

Aucune installation Helm manuelle n'est nécessaire sur la machine d'administration.

---

## 4. HelmRepository

Le dépôt officiel Prometheus Community est déclaré dans Flux :

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: prometheus-community
  namespace: flux-system
spec:
  interval: 1h
  url: https://prometheus-community.github.io/helm-charts
```

---

## 5. HelmRelease

La stack utilise :

```text
Chart : kube-prometheus-stack
Version : 91.8.2
```

La rétention Prometheus est volontairement limitée à :

```text
24h
```

Les ressources sont également limitées afin de conserver une marge sur les VM du Platform Lab.

### Prometheus

```yaml
requests:
  cpu: 100m
  memory: 256Mi

limits:
  cpu: 500m
  memory: 768Mi
```

### Grafana

```yaml
requests:
  cpu: 50m
  memory: 128Mi

limits:
  cpu: 300m
  memory: 384Mi
```

### Alertmanager

```yaml
requests:
  cpu: 25m
  memory: 64Mi

limits:
  cpu: 100m
  memory: 128Mi
```

---

## 6. Gestion du timeout Helm

Lors du premier déploiement, Helm a échoué après son timeout par défaut.

Le message était :

```text
timeout waiting for:
[Deployment/observability/kube-prometheus-stack-grafana status: 'InProgress']
```

Le problème concernait principalement le démarrage initial de Grafana.

Le pod Grafana a notamment rencontré temporairement :

```text
Readiness probe failed
connection refused
```

puis :

```text
Liveness probe failed
connection refused
```

Grafana a ensuite redémarré et est devenu opérationnel.

Le problème n'était donc pas une ressource Kubernetes définitivement défaillante : le délai de démarrage dépassait simplement le timeout utilisé par l'installation Helm.

---

## 7. Remédiation

Le HelmRelease a été configuré avec un timeout explicite de 10 minutes pour les opérations d'installation et de mise à jour :

```yaml
install:
  timeout: 10m
  remediation:
    retries: 2

upgrade:
  timeout: 10m
  remediation:
    retries: 2
```

Cette configuration évite de dépendre du timeout Helm par défaut et autorise plusieurs tentatives en cas d'échec transitoire.

La correction a été appliquée exclusivement via Git :

```text
Git
 ↓
Flux
 ↓
HelmRelease
 ↓
Helm upgrade
```

Après modification, Flux a effectué une nouvelle opération d'upgrade et a finalement indiqué :

```text
Helm upgrade succeeded for release observability/kube-prometheus-stack.v3
```

Le HelmRelease est désormais :

```text
READY=True
```

---

## 8. Composants déployés

La stack déploie notamment :

* Prometheus
* Grafana
* Alertmanager
* Prometheus Operator
* kube-state-metrics
* node-exporter

Quatre pods `node-exporter` sont présents, correspondant aux quatre nœuds du cluster :

```text
k8s-cp
k8s-worker-1
k8s-worker-2
k8s-worker-3
```

Prometheus est également configuré avec plusieurs `ServiceMonitor` pour découvrir automatiquement les composants à surveiller.

---

## 9. Validation du déploiement

### HelmRelease

La commande :

```bash
flux get helmreleases -n observability
```

retourne :

```text
NAME                    REVISION   SUSPENDED   READY   MESSAGE
kube-prometheus-stack   91.8.2    False       True    Helm upgrade succeeded
```

### Pods

Les composants sont opérationnels :

```bash
kubectl -n observability get pods
```

Les pods suivants sont notamment `Running` :

```text
alertmanager
grafana
kube-state-metrics
operator
prometheus
node-exporter
```

---

## 10. Validation de Prometheus

Prometheus est exposé temporairement par port-forward pour les tests :

```bash
kubectl -n observability port-forward \
  svc/kube-prometheus-stack-prometheus 9090:9090
```

La disponibilité de Prometheus est vérifiée avec :

```bash
curl -s http://127.0.0.1:9090/-/ready
```

Résultat attendu :

```text
Prometheus Server is Ready.
```

---

## 11. Validation des métriques

La présence de targets actives est vérifiée avec la requête Prometheus :

```bash
curl -s \
  'http://127.0.0.1:9090/api/v1/query?query=up' \
  | python3 -m json.tool
```

La réponse doit contenir des séries `up` avec :

```json
"1"
```

Une valeur :

```text
up = 1
```

indique que la target correspondante est joignable et que Prometheus collecte effectivement ses métriques.

Lors de la validation de la plateforme, les targets observées étaient toutes `up`.

---

## 12. Targets validées

La collecte couvre notamment :

### Nœuds Kubernetes

Les quatre kubelets sont surveillés :

```text
k8s-cp
k8s-worker-1
k8s-worker-2
k8s-worker-3
```

avec notamment les endpoints :

```text
/metrics
/metrics/cadvisor
/metrics/probes
```

### Node Exporter

Chaque nœud possède un `node-exporter` :

```text
192.168.1.167:9100
192.168.1.168:9100
192.168.1.169:9100
192.168.1.170:9100
```

### Composants Kubernetes

La collecte inclut notamment :

```text
Kubernetes API Server
CoreDNS
kube-state-metrics
kubelet
cAdvisor
```

### Composants de l'observabilité

Prometheus collecte également ses propres métriques ainsi que celles de :

```text
Grafana
Alertmanager
Prometheus Operator
```

---

## 13. État actuel

L'observabilité est considérée comme **fonctionnelle**.

La chaîne complète a été validée :

```text
Git
 ↓
FluxCD
 ↓
HelmRelease
 ↓
kube-prometheus-stack
 ↓
Prometheus
 ↓
targets Kubernetes
 ↓
métriques effectivement collectées
```

La validation ne se limite donc pas à vérifier que les pods sont `Running`.

Elle vérifie également que Prometheus :

1. démarre correctement ;
2. répond à son endpoint de readiness ;
3. expose son API ;
4. découvre ses targets ;
5. collecte effectivement les métriques ;
6. obtient `up = 1` pour les targets fonctionnelles.

---

## 14. Prochaine étape

La prochaine étape consiste à exploiter les métriques collectées.

Ordre prévu :

1. validation de Grafana ;
2. connexion de Grafana à Prometheus ;
3. vérification des dashboards Kubernetes ;
4. observation CPU / mémoire / disque des nœuds ;
5. observation de l'état des workloads ;
6. mise en place des premières alertes ;
7. tests de panne contrôlés ;
8. vérification de la détection et de la récupération.

Grafana ne sera pas exposé publiquement dans un premier temps. La première validation peut être réalisée avec un `kubectl port-forward`.

L'objectif est de construire progressivement une observabilité réellement exploitable avant de passer à la partie sécurité, supply chain et CI/CD.
