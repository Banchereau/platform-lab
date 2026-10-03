# Platform Lab — Bootstrap automatisé et gestion des recréations

## 1. Objectif

Cette étape transforme le bootstrap du Platform Lab en un processus capable de :

- créer ou recréer les VMs avec Terraform ;
- détecter les VMs recréées ;
- renouveler automatiquement leurs clés SSH connues ;
- récupérer le token K3s depuis Terraform ;
- configurer les machines avec Ansible ;
- installer K3s si nécessaire ;
- gérer automatiquement le cas d'un worker Kubernetes recréé ;
- supprimer un ancien objet `Node` K3s devenu obsolète ;
- réintégrer le worker dans le cluster ;
- récupérer un kubeconfig fonctionnel ;
- vérifier l'état du cluster ;
- vérifier FluxCD ;
- rester idempotent lors des exécutions suivantes.

L'objectif n'est donc plus seulement de réaliser une installation initiale, mais de disposer d'un **processus de reconstruction reproductible**.

---

## 2. Architecture du bootstrap

Le processus est organisé ainsi :

```text
                    Terraform
                       │
                       │ plan
                       ▼
              ┌──────────────────┐
              │ bootstrap.sh     │
              │                  │
              │ détecte les      │
              │ VMs recréées     │
              └────────┬─────────┘
                       │
             ┌─────────┴─────────┐
             │                   │
             ▼                   ▼
       clés SSH              workers recréés
       à rafraîchir                 │
             │                      │
             └──────────┬───────────┘
                        ▼
                     Ansible
                        │
          ┌─────────────┴─────────────┐
          │                           │
     control-plane                 workers
          │                           │
       K3s server                 K3s agents
                                      │
                              si recréé :
                                      │
                              suppression du
                              stale Node K3s
                                      │
                                      ▼
                               réintégration
                               dans le cluster
```

---

## 3. Détection des VMs recréées

Terraform produit un plan avant toute modification :

```bash
terraform plan -out="$TERRAFORM_PLAN"
```

Le script inspecte ensuite le plan Terraform au format JSON :

```bash
terraform show -json "$TERRAFORM_PLAN"
```

`jq` est utilisé pour identifier les ressources de type :

```text
proxmox_virtual_environment_vm
```

dont les actions contiennent `create` ou `delete`.

Les VMs concernées sont stockées dans :

```bash
RECREATED_VMS=()
```

Exemple :

```text
k8s_cp
k8s_worker_1
k8s_worker_3
```

---

## 4. Identification des workers recréés

Toutes les VMs recréées ne nécessitent pas le même traitement :

- le renouvellement des clés SSH concerne **toutes** les VMs recréées ;
- la réconciliation Kubernetes concerne **uniquement les workers**.

Le script construit donc une seconde liste :

```bash
RECREATED_WORKERS=()
```

à partir des VMs correspondant à :

```text
k8s_worker_*
```

Les noms Terraform sont convertis vers les noms Kubernetes/Ansible :

```text
k8s_worker_3
        ↓
k8s-worker-3
```

Cela permet ensuite à Ansible de savoir exactement quels workers ont été recréés pendant le bootstrap courant.

---

## 5. Gestion automatique des clés SSH

Lorsqu'une VM est détruite puis recréée avec la même adresse IP, sa clé SSH change.

Une ancienne entrée dans :

```text
~/.ssh/known_hosts_platform-lab
```

provoquerait alors une erreur de type :

```text
REMOTE HOST IDENTIFICATION HAS CHANGED
```

Le bootstrap utilise un fichier `known_hosts` dédié :

```bash
SSH_KNOWN_HOSTS="${HOME}/.ssh/known_hosts_platform-lab"
```

Lorsqu'une VM est recréée, son ancienne clé est supprimée :

```bash
ssh-keygen \
    -f "$SSH_KNOWN_HOSTS" \
    -R "$ip"
```

La nouvelle clé est ensuite acceptée lors de la reconnexion grâce à :

```text
StrictHostKeyChecking=accept-new
```

> **Important :** seules les VMs réellement recréées sont concernées. Cela évite de supprimer inutilement les clés SSH des machines qui n'ont pas changé.

---

## 6. Transmission de l'information à Ansible

Les workers recréés sont transformés en tableau JSON :

```bash
RECREATED_WORKERS_JSON="$(
    printf '%s\n' "${RECREATED_WORKERS[@]}" |
        jq -Rsc 'split("\n") | map(select(length > 0))'
)"
```

Ansible reçoit ensuite :

```bash
--extra-vars "{\"recreated_nodes\":${RECREATED_WORKERS_JSON}}"
```

Par exemple :

```yaml
recreated_nodes:
  - k8s-worker-3
```

La variable possède une valeur par défaut dans `ansible/group_vars/all.yml` :

```yaml
recreated_nodes: []
```

Ainsi, une exécution manuelle d'Ansible reste possible sans avoir à fournir cette variable.

---

## 7. Gestion d'un worker Kubernetes recréé

Un worker recréé par Terraform possède une nouvelle installation système. Cependant, Kubernetes peut encore connaître l'ancien objet `Node`.

Cela peut provoquer une erreur K3s du type :

```text
Node password rejected, duplicate hostname
```

Le rôle `ansible/roles/k3s_agent` effectue donc un traitement spécifique lorsqu'un worker est marqué comme recréé.

### Vérification de l'ancien Node

Ansible exécute sur le control-plane :

```bash
k3s kubectl get node <worker>
```

La tâche est déléguée à :

```yaml
delegate_to: k8s-cp
```

### Suppression du Node obsolète

Si l'ancien `Node` existe encore, il est supprimé :

```bash
k3s kubectl delete node <worker>
```

Cette opération est conditionnée par trois éléments :

```yaml
when:
  - not k3s_binary.stat.exists
  - inventory_hostname in recreated_nodes
  - existing_kubernetes_node.rc == 0
```

La suppression n'est donc effectuée que lorsque :

1. K3s n'est pas encore installé sur la nouvelle machine ;
2. le worker a été identifié comme recréé par Terraform ;
3. l'ancien `Node` existe réellement dans Kubernetes.

---

## 8. Pourquoi cette logique est idempotente

Lors d'une exécution normale :

```yaml
recreated_nodes: []
```

Le traitement de suppression du `Node` est donc ignoré.

De même, si K3s est déjà installé, la condition :

```yaml
not k3s_binary.stat.exists
```

est fausse, et les tâches d'installation sont ignorées.

Le bootstrap peut ainsi être relancé sans provoquer de modifications inutiles.

---

## 9. Gestion du token K3s

Le token K3s est généré par Terraform avec `random_password.k3s_token`.

Il est exposé comme output sensible :

```hcl
output "k3s_token" {
  description = "K3s cluster token"
  value       = random_password.k3s_token.result
  sensitive   = true
}
```

Le bootstrap récupère le token :

```bash
export K3S_TOKEN="$(terraform output -raw k3s_token)"
```

Ansible vérifie ensuite sa présence :

```yaml
- name: Validate K3s token
  ansible.builtin.assert:
    that:
      - lookup('ansible.builtin.env', 'K3S_TOKEN') | length > 0
```

Le token n'est **jamais** écrit dans le dépôt Git. Il est également retiré de l'environnement après utilisation :

```bash
unset K3S_TOKEN
```

---

## 10. Séquence complète du bootstrap

Le script `scripts/bootstrap.sh` réalise les étapes suivantes :

1. vérification des prérequis ;
2. préparation du fichier `known_hosts` dédié ;
3. vérification du dépôt GitOps ;
4. `terraform init` ;
5. `terraform plan` ;
6. détection des VMs recréées ;
7. identification des workers recréés ;
8. confirmation interactive du `terraform apply` ;
9. `terraform apply` ;
10. renouvellement des clés SSH des VMs recréées ;
11. récupération du token K3s ;
12. attente de la disponibilité SSH ;
13. exécution d'Ansible ;
14. récupération du kubeconfig ;
15. attente de l'API Kubernetes ;
16. vérification des prérequis Flux ;
17. vérification ou bootstrap Flux ;
18. validation finale du cluster.

---

## 11. Test de recréation d'un worker

Pour valider réellement le mécanisme, le worker-3 a volontairement été détruit :

```bash
terraform destroy \
  -target='proxmox_virtual_environment_vm.k8s["k8s_worker_3"]'
```

Puis :

```bash
./scripts/bootstrap.sh
```

Déroulement observé :

- Terraform a recréé la VM ;
- le bootstrap a détecté `k8s_worker_3` et identifié `k8s-worker-3` comme worker recréé ;
- la clé SSH correspondant à `192.168.1.170` a été supprimée de `~/.ssh/known_hosts_platform-lab` ;
- Ansible a détecté l'ancien `Node` Kubernetes (tâche *Check whether recreated worker still exists in Kubernetes*) ;
- puis l'a supprimé (tâche *Remove stale Kubernetes Node for recreated worker*) ;
- le nouvel agent K3s a ensuite été installé.

Résultat :

```text
k8s-cp         Ready
k8s-worker-1   Ready
k8s-worker-2   Ready
k8s-worker-3   Ready
```

---

## 12. Validation de l'idempotence

Après la reconstruction, Ansible a été exécuté une nouvelle fois manuellement :

```bash
export K3S_TOKEN="$(terraform -chdir=terraform output -raw k3s_token)"

ansible-playbook \
  -i ansible/inventory/platform-lab/hosts.yml \
  ansible/site.yml

unset K3S_TOKEN
```

Résultat final :

```text
k8s-cp                     : ok=7    changed=0    failed=0
k8s-worker-1               : ok=7    changed=0    failed=0
k8s-worker-2               : ok=7    changed=0    failed=0
k8s-worker-3               : ok=7    changed=0    failed=0
```

Cette exécution confirme que la configuration Ansible est idempotente.

---

## 13. Validation FluxCD

Après reconstruction, le cluster a également été contrôlé avec :

```bash
flux check
```

Les contrôleurs Flux étaient opérationnels :

- `helm-controller`
- `kustomize-controller`
- `notification-controller`
- `source-controller`

Les Kustomizations et HelmReleases du Platform Lab étaient également prêts.

---

## 14. Résultat de l'étape

Cette étape apporte une propriété importante au Platform Lab :

> **Une machine peut être détruite et recréée sans nécessiter de réparation manuelle du cluster.**

Le processus sait maintenant gérer automatiquement :

```text
VM détruite
   ↓
VM recréée par Terraform
   ↓
nouvelle clé SSH
   ↓
ancienne clé supprimée automatiquement
   ↓
configuration Ansible
   ↓
ancien Node Kubernetes supprimé si nécessaire
   ↓
nouvel agent K3s installé
   ↓
worker réintégré
   ↓
cluster validé
```

Le bootstrap devient donc un mécanisme de reconstruction reproductible, et non plus uniquement un script d'installation.

---

## 15. Fichiers concernés

Les principaux fichiers de cette étape sont :

```text
scripts/bootstrap.sh

ansible/
├── site.yml
├── group_vars/
│   └── all.yml
├── inventory/
│   └── platform-lab/
│       └── hosts.yml
└── roles/
    └── k3s_agent/
        └── tasks/
            └── main.yml
```

Le dépôt GitOps reste séparé :

```text
edge-platform/
```

Il s'agit d'un dépôt Git indépendant, qui ne doit **pas** être ajouté au dépôt parent avec :

```bash
git add -A
```

---

## 16. Commit de référence

Cette évolution a été validée et commitée dans le dépôt `platform-lab` :

```text
73d57d4 Handle recreated K3s workers during bootstrap
```

Le commit précédent était :

```text
51b8d6a Validate Ansible platform configuration
```

Le dépôt distant est synchronisé avec `origin/main`.

---

## 17. État du Platform Lab

À la fin de cette étape :

- Terraform provisionne l'infrastructure ;
- Ansible configure les machines ;
- K3s fournit le cluster Kubernetes ;
- FluxCD gère le GitOps ;
- le bootstrap détecte les recréations ;
- les clés SSH sont automatiquement réconciliées ;
- les workers K3s recréés sont automatiquement réintégrés ;
- Ansible est idempotent ;
- la reconstruction complète a déjà été validée.

La plateforme dispose désormais d'un socle suffisamment reproductible pour passer de la phase **construction/reconstruction** à la phase **exploitation et administration** de la plateforme.
