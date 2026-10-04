# Observability

## 1. Objectif

La plateforme dispose d'une stack d'observabilité déployée entièrement par GitOps avec FluxCD.

L'objectif est de fournir :

* la collecte des métriques Kubernetes et système ;
* la supervision de l'état des nœuds et des workloads ;
* des dashboards Grafana ;
* des règles d'alerte Prometheus ;
* une base permettant ensuite de réaliser des tests de panne contrôlés.

La stack repose sur :

* Prometheus ;
* Grafana ;
* Alertmanager ;
* kube-state-metrics ;
* node-exporter ;
* Prometheus Operator ;
* kube-prometheus-stack.

L'ensemble est déployé dans le namespace `observability`.

---

## 2. Organisation GitOps

La configuration est stockée dans le dépôt `edge-platform`.

```text
infrastructure/
└── observability/
    ├── namespace.yaml
    ├── helmrepository.yaml
    ├── helmrelease.yaml
    └── kustomization.yaml
```

La Kustomization principale de l'infrastructure référence ce composant :

```yaml
resources:
  - ingress-nginx
  - metallb
  - observability
```

Flux déploie ensuite l'infrastructure à partir du dépôt Git.

La stack n'est donc pas installée manuellement avec Helm depuis le poste d'administration.

---

## 3. HelmRepository

Le chart `kube-prometheus-stack` est fourni par le repository Helm `prometheus-community`.

La version utilisée actuellement est :

```text
kube-prometheus-stack 91.8.2
```

Le `HelmRelease` est réconcilié par Flux.

Validation :

```bash
kubectl -n observability get helmrelease
```

État attendu :

```text
READY   True
```

---

## 4. Ressources et contraintes

La plateforme repose sur quatre VM relativement modestes :

```text
k8s-cp
k8s-worker-1
k8s-worker-2
k8s-worker-3
```

Chaque VM dispose de :

```text
4 CPU
4096 MiB RAM
20 GiB disque
```

La stack d'observabilité doit donc rester raisonnable en consommation mémoire.

### Prometheus

```yaml
prometheus:
  prometheusSpec:
    retention: 24h
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 768Mi
```

La rétention est volontairement limitée à 24 heures.

### Grafana

```yaml
grafana:
  resources:
    requests:
      cpu: 50m
      memory: 192Mi
    limits:
      cpu: 500m
      memory: 768Mi
```

### Alertmanager

```yaml
alertmanager:
  alertmanagerSpec:
    resources:
      requests:
        cpu: 25m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi
```

---

## 5. Incident initial : timeout du déploiement

Lors du premier déploiement de la stack, le `HelmRelease` a dépassé le timeout par défaut alors que Grafana était encore en cours de démarrage.

Le déploiement n'était cependant pas définitivement bloqué : Grafana a finalement démarré.

Le timeout du `HelmRelease` a donc été augmenté :

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

Cette configuration laisse davantage de temps aux composants lourds pour devenir disponibles sur les VM du lab.

---

## 6. Incident Grafana : OOMKilled

Après installation, Grafana a rencontré un dépassement de sa limite mémoire.

Observation :

```text
Reason: OOMKilled
Exit Code: 137
```

L'utilisation mémoire dépassait la limite initialement configurée à environ 384 MiB.

La limite a été augmentée à :

```text
request: 192Mi
limit: 768Mi
```

Après réconciliation Flux, Grafana est redevenu stable.

Cette modification a été effectuée dans le `HelmRelease`, et non directement sur le Deployment, afin de conserver Git comme source de vérité.

---

## 7. Validation Prometheus

Prometheus est accessible localement par port-forward :

```bash
kubectl -n observability port-forward \
  svc/kube-prometheus-stack-prometheus 9090:9090
```

Validation de disponibilité :

```bash
curl -s http://127.0.0.1:9090/-/ready
```

Résultat attendu :

```text
Prometheus Server is Ready.
```

Une requête simple permet également de vérifier que Prometheus collecte effectivement des séries :

```bash
curl -s \
  'http://127.0.0.1:9090/api/v1/query?query=up'
```

La réponse doit être de type :

```text
status: success
```

---

## 8. Targets Prometheus

La stack collecte notamment :

* kubelet ;
* node-exporter ;
* kube-apiserver ;
* CoreDNS ;
* kube-state-metrics ;
* Prometheus ;
* Alertmanager ;
* Grafana ;
* Prometheus Operator.

Les targets peuvent être inspectées avec :

```bash
curl -s http://127.0.0.1:9090/api/v1/targets
```

Le nombre et la nature des targets dépendent des composants effectivement activés dans le cluster.

---

## 9. Particularité K3s : composants du control plane

### Problème

Le chart `kube-prometheus-stack` fournit par défaut des règles et des mécanismes de scraping pour plusieurs composants Kubernetes classiques :

* kube-controller-manager ;
* kube-scheduler ;
* kube-proxy.

Sur cette plateforme, Kubernetes est fourni par K3s.

Les composants du control plane sont intégrés au processus :

```text
k3s-server
```

Une vérification du nœud control-plane montre :

```bash
ps aux | grep '[k]3s server'
```

avec un processus :

```text
/usr/local/bin/k3s server
```

Les ports metrics concernés sont également liés à localhost :

```text
127.0.0.1:10249   kube-proxy
127.0.0.1:10257   kube-controller-manager
127.0.0.1:10259   kube-scheduler
*:10250           kubelet
```

Prometheus, exécuté dans un Pod, ne peut donc pas utiliser les `ServiceMonitor` génériques de la même manière qu'avec une distribution Kubernetes classique où ces composants sont exposés séparément.

### Symptôme

Prometheus signalait initialement :

```text
KubeControllerManagerDown
KubeProxyDown
KubeSchedulerDown
```

avec une sévérité `critical`.

Les targets correspondantes n'étaient pourtant pas présentes comme targets actives.

Le diagnostic a montré qu'il ne s'agissait pas d'une panne réelle du control plane.

Il s'agissait de règles génériques incompatibles avec la manière dont K3s expose ses composants internes.

---

## 10. Correction GitOps

La correction a été appliquée dans le `HelmRelease`, afin que la configuration reste entièrement déclarative.

Les règles d'alerte génériques concernées ont été désactivées :

```yaml
defaultRules:
  rules:
    kubeControllerManager: false
    kubeProxy: false
    kubeSchedulerAlerting: false
```

Les mécanismes de scraping correspondants ont également été désactivés :

```yaml
kubeControllerManager:
  enabled: false

kubeProxy:
  enabled: false

kubeScheduler:
  enabled: false
```

Le point important est que cette correction ne désactive pas les composants Kubernetes eux-mêmes.

Elle indique simplement à `kube-prometheus-stack` de ne pas essayer de superviser ces composants avec son modèle générique incompatible avec cette installation K3s.

---

## 11. Diagnostic de la configuration générée

Après réconciliation Flux, la configuration réellement chargée par Prometheus a été vérifiée.

```bash
curl -s http://127.0.0.1:9090/api/v1/status/config \
  | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data["data"]["yaml"])
' \
  | grep -nE 'kubeControllerManager|kubeProxy|kubeScheduler|rule_files' \
  -A5 -B5
```

Prometheus utilise des fichiers de règles générés :

```text
/etc/prometheus/rules/prometheus-kube-prometheus-stack-prometheus-rulefiles-0/*.yaml
/etc/prometheus/rules/prometheus-kube-prometheus-stack-prometheus-rulefiles-1/*.yaml
/etc/prometheus/rules/prometheus-kube-prometheus-stack-prometheus-rulefiles-2/*.yaml
```

Le ConfigMap correspondant a ensuite été inspecté :

```bash
kubectl -n observability get configmap \
  prometheus-kube-prometheus-stack-prometheus-rulefiles-0 \
  -o json
```

Les fichiers de règles générés ne contenaient plus :

```text
KubeControllerManagerDown
KubeProxyDown
KubeSchedulerDown
```

Enfin, les règles réellement chargées par Prometheus ont été vérifiées directement :

```bash
curl -s http://127.0.0.1:9090/api/v1/rules
```

Aucune règle d'alerte correspondant aux trois composants n'était encore chargée.

---

## 12. Validation finale des alertes

L'état actuel peut être vérifié avec :

```bash
curl -s http://127.0.0.1:9090/api/v1/alerts \
  | python3 -c '
import json, sys

data = json.load(sys.stdin)["data"]["alerts"]

for a in data:
    print(
        "ALERT :", a["labels"].get("alertname"),
        "\nSTATE :", a["state"],
        "\nACTIVE:", a.get("activeAt"),
        "\nVALUE :", a.get("value"),
        "\nLABELS:", a["labels"],
        "\n"
    )
'
```

L'état final observé est :

```text
ALERT : Watchdog
STATE : firing
```

Les alertes suivantes ne sont plus présentes :

```text
KubeControllerManagerDown
KubeProxyDown
KubeSchedulerDown
```

La présence de `Watchdog` en état `firing` est normale : cette alerte est conçue pour être constamment active et permet notamment de vérifier le chemin d'alerting.

---

## 13. Principe d'exploitation retenu

Cet incident illustre un principe important de la plateforme :

> Une alerte `critical` n'est pas nécessairement la preuve d'une panne. Il faut vérifier la chaîne complète : règle → target → endpoint → architecture du composant → état réel du système.

La démarche utilisée a été :

```text
Alerte Prometheus
      ↓
Vérification des targets
      ↓
Vérification des endpoints K3s
      ↓
Identification du modèle d'exécution k3s-server
      ↓
Inspection des règles générées
      ↓
Correction du HelmRelease
      ↓
Réconciliation Flux
      ↓
Vérification des règles réellement chargées
      ↓
Validation des alertes
```

La correction n'a donc pas consisté à supprimer manuellement une alerte ou à redémarrer arbitrairement Prometheus.

La source de vérité GitOps a été corrigée.

---

## 14. Grafana

Grafana est actuellement accessible uniquement en interne par `ClusterIP`.

Port-forward :

```bash
kubectl -n observability port-forward \
  svc/kube-prometheus-stack-grafana 3000:80
```

Les identifiants administrateur sont stockés dans le Secret Kubernetes généré par le chart.

Récupération du mot de passe :

```bash
kubectl -n observability get secret \
  kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' \
  | base64 -d

echo
```

---

## 15. Dashboard Nodes Status

Un dashboard Grafana `Nodes Status` a été créé pour suivre l'état général des nœuds.

### Kubernetes Nodes — Status

```promql
up{job="kubelet",metrics_path="/metrics"}
```

### Nodes — CPU Usage

```promql
100 * (1 - avg by (instance) (
  rate(node_cpu_seconds_total{mode="idle"}[5m])
))
```

### Nodes — Memory Usage

```promql
100 * (
  1 -
  node_memory_MemAvailable_bytes
  /
  node_memory_MemTotal_bytes
)
```

### Pods — Restarts

```promql
sum by (namespace, pod) (
  increase(kube_pod_container_status_restarts_total[1h])
)
```

Les requêtes sont utilisées en mode `Range`.

La période d'affichage utilisée pour le dashboard est actuellement :

```text
Last 1 hour
```

---

## 16. État actuel

La stack d'observabilité est opérationnelle.

État :

```text
Prometheus       Ready
Grafana          Running
Alertmanager     Running
kube-state-metrics   Running
node-exporter        Running
Flux HelmRelease     Ready
```

Le `HelmRelease` est actuellement :

```text
kube-prometheus-stack
revision: 91.8.2
ready: True
```

La configuration spécifique à K3s est désormais déclarative et versionnée dans Git.

---

## 17. Suite

Les prochaines étapes d'exploitation sont :

1. compléter les dashboards workloads ;
2. examiner les règles Alertmanager réellement pertinentes ;
3. définir quelques alertes utiles à la plateforme ;
4. réaliser des tests de panne contrôlés ;
5. vérifier la détection et la récupération après panne d'un worker ;
6. étudier la collecte des logs ;
7. intégrer progressivement les contrôles de sécurité et de supply chain.

La trajectoire visée est :

```text
Git
 ↓
GitHub Actions
 ↓
Build / Test
 ↓
Security Scan
 ↓
Signature
 ↓
Registry
 ↓
FluxCD
 ↓
Kubernetes
 ↓
Prometheus / Grafana / Alertmanager
 ↓
Diagnostic et exploitation
```

L'observabilité devient ainsi une partie intégrante de la plateforme, et non un composant ajouté uniquement pour afficher des dashboards.
