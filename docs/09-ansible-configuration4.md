# Validation de l'intégration Ansible

## 1. Objectif

Cette étape valide l'intégration d'Ansible dans le processus de déploiement de Platform Lab.

L'objectif est de vérifier que :

* les machines Debian sont accessibles en SSH ;
* Ansible configure correctement le système ;
* K3s est installé et géré par Ansible ;
* le token K3s est correctement transmis à Ansible ;
* les services K3s peuvent être redémarrés sans intervention manuelle ;
* le cluster Kubernetes reste fonctionnel après une reconfiguration ;
* l'exécution d'Ansible est idempotente.

À l'issue de cette étape, la configuration des nœuds est répartie ainsi :

```text
Terraform
    │
    ├── Proxmox
    ├── VMs
    ├── réseau
    └── token K3s
          │
          ▼
Cloud-init
    │
    └── bootstrap minimal de la VM
          │
          ▼
Ansible
    │
    ├── configuration système
    └── installation/configuration K3s
          │
          ▼
Kubernetes / K3s
          │
          ▼
FluxCD
```

---

## 2. Architecture Ansible

L'arborescence principale est :

```text
ansible/
├── group_vars/
│   └── all.yml
├── inventory/
│   └── platform-lab/
│       └── hosts.yml
├── roles/
│   ├── common/
│   ├── k3s_server/
│   └── k3s_agent/
└── site.yml
```

Les responsabilités sont séparées :

### `common`

Configuration commune aux machines :

* collecte des informations système ;
* installation des paquets nécessaires.

### `k3s_server`

Configuration du control-plane :

* vérification de la présence de K3s ;
* gestion de l'environnement systemd ;
* installation de K3s si nécessaire ;
* gestion du service `k3s`.

### `k3s_agent`

Configuration des workers :

* vérification de la présence de K3s ;
* gestion de l'environnement systemd ;
* installation de K3s si nécessaire ;
* gestion du service `k3s-agent`.

---

## 3. Gestion du token K3s

Le token K3s est généré et conservé dans l'état Terraform via :

```hcl
resource "random_password" "k3s_token" {
  # ...
}
```

Il est exposé par un output Terraform sensible :

```hcl
output "k3s_token" {
  description = "K3s cluster token"
  value       = random_password.k3s_token.result
  sensitive   = true
}
```

Le token n'est donc pas stocké dans le dépôt Git.

Avant d'exécuter Ansible manuellement :

```bash
cd ~/projects/platform-lab/terraform
export K3S_TOKEN="$(terraform output -raw k3s_token)"
cd ..
```

Vérification sans afficher le secret :

```bash
echo "K3S_TOKEN length = ${#K3S_TOKEN}"
```

Le token utilisé dans le lab possède actuellement une longueur de 32 caractères.

---

## 4. Problème rencontré

Une exécution manuelle d'Ansible avait été lancée sans exporter `K3S_TOKEN`.

Les fichiers d'environnement générés par Ansible contenaient alors un token vide.

Les workers produisaient notamment :

```text
token must not be empty
```

et les services `k3s-agent` ne pouvaient pas démarrer correctement.

Le problème provenait de l'utilisation de :

```jinja2
{{ lookup('ansible.builtin.env', 'K3S_TOKEN') }}
```

dans les templates Ansible.

Cette expression lit la variable d'environnement du processus Ansible. Si elle n'est pas définie, la valeur obtenue est vide.

Le template lui-même était donc correct ; c'était le contrat d'exécution qui n'était pas suffisamment protégé.

---

## 5. Protection ajoutée dans Ansible

Une validation explicite du token a été ajoutée dans `ansible/site.yml`.

Pour chaque play :

```yaml
pre_tasks:
  - name: Validate K3s token
    ansible.builtin.assert:
      that:
        - lookup('ansible.builtin.env', 'K3S_TOKEN') | length > 0
      fail_msg: "K3S_TOKEN must be exported before running Ansible"
      quiet: true
```

Ainsi, une exécution manuelle sans token échoue immédiatement avant toute modification des machines.

Cela évite notamment qu'un fichier systemd soit écrit avec :

```text
K3S_TOKEN=
```

---

## 6. Vérification syntaxique

Avant l'exécution :

```bash
cd ~/projects/platform-lab

ansible-playbook \
  -i ansible/inventory/platform-lab/hosts.yml \
  ansible/site.yml \
  --syntax-check
```

Résultat obtenu :

```text
playbook: ansible/site.yml
```

Le playbook est donc syntaxiquement valide.

---

## 7. Première exécution après correction

Avec le token correctement exporté :

```bash
test -n "$K3S_TOKEN" && echo "K3S_TOKEN is set"

ansible-playbook \
  -i ansible/inventory/platform-lab/hosts.yml \
  ansible/site.yml
```

L'exécution s'est terminée avec succès :

```text
k8s-cp                     : ok=8    changed=2    failed=0
k8s-worker-1               : ok=8    changed=2    failed=0
k8s-worker-2               : ok=8    changed=2    failed=0
k8s-worker-3               : ok=8    changed=2    failed=0
```

Les modifications correspondaient principalement à la correction des fichiers d'environnement K3s et au redémarrage des services.

---

## 8. Validation du cluster Kubernetes

Après la reconfiguration :

```bash
export KUBECONFIG="$HOME/.kube/platform-lab.yaml"

kubectl get nodes -o wide
```

Résultat :

```text
NAME           STATUS   ROLES           INTERNAL-IP
k8s-cp         Ready    control-plane   192.168.1.167
k8s-worker-1   Ready    <none>          192.168.1.168
k8s-worker-2   Ready    <none>          192.168.1.169
k8s-worker-3   Ready    <none>          192.168.1.170
```

Les quatre nœuds sont donc `Ready`.

---

## 9. Validation des workloads

Vérification des pods :

```bash
kubectl get pods -A
```

Les composants principaux du cluster étaient opérationnels :

* FluxCD ;
* ingress-nginx ;
* CoreDNS ;
* local-path-provisioner ;
* metrics-server ;
* MetalLB ;
* test-app.

Le `source-controller` de Flux était temporairement `0/1` juste après les redémarrages, puis est revenu automatiquement à :

```text
1/1 Running
```

Ce comportement est normal pendant la phase de stabilisation suivant un redémarrage des services.

---

## 10. Validation de FluxCD

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

Le CLI local signale uniquement qu'une version plus récente du CLI Flux est disponible :

```text
flux 2.9.5 <2.9.6
```

Cela ne constitue pas un problème pour le cluster : les composants Flux déployés restent en `v2.9.5`.

---

## 11. Validation de l'idempotence

Une deuxième exécution d'Ansible a été réalisée sans modification de la configuration :

```bash
cd ~/projects/platform-lab

ansible-playbook \
  -i ansible/inventory/platform-lab/hosts.yml \
  ansible/site.yml
```

Résultat :

```text
k8s-cp                     : ok=7    changed=0    failed=0
k8s-worker-1               : ok=7    changed=0    failed=0
k8s-worker-2               : ok=7    changed=0    failed=0
k8s-worker-3               : ok=7    changed=0    failed=0
```

Aucun handler n'a été déclenché.

En particulier :

```text
Manage K3s server environment file
ok
```

et :

```text
Manage K3s agent environment file
ok
```

Cela confirme que les fichiers de configuration sont maintenant stables.

### Conclusion

L'idempotence Ansible est validée :

```text
changed=0
failed=0
unreachable=0
```

sur les quatre machines.

---

## 12. État fonctionnel obtenu

La configuration du Platform Lab peut maintenant être décrite ainsi :

```text
Terraform
    │
    │ crée/configure
    ▼
Proxmox VMs
    │
    │ bootstrap minimal
    ▼
Cloud-init
    │
    │ configuration complète
    ▼
Ansible
    │
    ├── common
    ├── k3s_server
    └── k3s_agent
    │
    ▼
K3s
    │
    ├── control-plane
    └── 3 workers
    │
    ▼
FluxCD
    │
    ▼
Infrastructure + applications
```

Le socle est désormais :

* reproductible par Terraform ;
* configuré par Ansible ;
* idempotent ;
* vérifiable ;
* piloté par GitOps avec FluxCD.

---

## 13. Problème restant : remplacement d'une VM

Un cas d'exploitation reste à automatiser.

Lorsqu'un worker est détruit puis recréé par Terraform avec le même hostname, l'ancien objet Kubernetes `Node` peut encore exister.

Le nouveau K3s agent peut alors être rejeté avec un message du type :

```text
Node password rejected
duplicate hostname
```

La procédure manuelle consiste actuellement à supprimer l'ancien Node :

```bash
kubectl delete node k8s-worker-3
```

puis à redémarrer le nouvel agent.

Ce comportement doit être intégré au processus de bootstrap afin qu'un remplacement de VM soit entièrement automatisé.

La prochaine évolution sera donc :

```text
Terraform détecte un remplacement
        │
        ▼
Terraform recrée la VM
        │
        ▼
bootstrap.sh rafraîchit les clés SSH
        │
        ▼
détection/suppression de l'ancien Node Kubernetes
        │
        ▼
Ansible configure la nouvelle VM
        │
        ▼
K3s agent rejoint automatiquement le cluster
```

Cette étape permettra de rapprocher davantage le Platform Lab d'un comportement de plateforme exploitable et reproductible.
