# v0.3 — Configuration de la plateforme avec Ansible

## Objectif

Faire évoluer la plateforme vers une séparation claire des responsabilités :

```text
Terraform
    ↓
Proxmox / VMs / réseau / accès SSH
    ↓
Ansible
    ↓
Configuration système + K3s
    ↓
FluxCD
    ↓
edge-platform
```

L'objectif de cette phase est de retirer progressivement la configuration logicielle des VMs de Terraform/cloud-init afin de confier la configuration des machines à Ansible.

---

## 1. État initial

La plateforme est composée de quatre VMs Debian 13 :

| VM             | Rôle                       | Adresse         |
| -------------- | -------------------------- | --------------- |
| `k8s-cp`       | K3s server / control plane | `192.168.1.167` |
| `k8s-worker-1` | K3s agent                  | `192.168.1.168` |
| `k8s-worker-2` | K3s agent                  | `192.168.1.169` |
| `k8s-worker-3` | K3s agent                  | `192.168.1.170` |

K3s :

```text
v1.36.4+k3s1
```

Tous les nœuds sont `Ready`.

---

## 2. Architecture des responsabilités

### Terraform

Terraform reste responsable de l'infrastructure :

* création et suppression des VMs ;
* VMID ;
* CPU ;
* mémoire ;
* disque ;
* réseau ;
* adresse IP ;
* passerelle ;
* DNS Proxmox ;
* clonage depuis le template Debian ;
* clé SSH ;
* génération du token K3s.

Terraform ne doit progressivement plus installer K3s lui-même.

### Cloud-init

Cloud-init doit devenir minimal.

Il conserve notamment :

* hostname ;
* configuration initiale des utilisateurs ;
* clé SSH ;
* sudo ;
* accès initial à la VM.

L'installation de K3s doit être retirée progressivement de `cloud-init.tf`.

### Ansible

Ansible devient responsable de la configuration des machines :

* paquets système ;
* configuration Linux ;
* installation de K3s ;
* configuration du serveur K3s ;
* configuration des agents K3s ;
* fichiers d'environnement systemd ;
* redémarrage contrôlé des services ;
* idempotence.

### FluxCD

FluxCD reste responsable de la configuration Kubernetes et des applications.

Ansible ne doit pas devenir un outil de déploiement des workloads Kubernetes.

---

# 3. Inventaire Ansible

Inventaire :

```text
ansible/inventory/platform-lab/hosts.yml
```

Structure :

```yaml
all:
  children:

    control_plane:
      hosts:
        k8s-cp:
          ansible_host: 192.168.1.167

    workers:
      hosts:
        k8s-worker-1:
          ansible_host: 192.168.1.168
        k8s-worker-2:
          ansible_host: 192.168.1.169
        k8s-worker-3:
          ansible_host: 192.168.1.170

  vars:
    ansible_user: xcode
    ansible_python_interpreter: /usr/bin/python3
```

La connectivité a été validée avec :

```bash
ansible all \
  -i ansible/inventory/platform-lab/hosts.yml \
  -m ping
```

Résultat : les quatre machines répondent avec :

```text
"ping": "pong"
```

Aucune modification n'est effectuée par ce test.

---

# 4. Role `common`

Le rôle `common` réalise la configuration système commune.

Fichier :

```text
ansible/roles/common/tasks/main.yml
```

Il :

* récupère les informations système ;
* affiche hostname, distribution et kernel ;
* installe les paquets communs.

Paquets actuellement installés :

```text
ca-certificates
curl
gnupg
sudo
```

Exécution :

```bash
ansible-playbook \
  -i ansible/inventory/platform-lab/hosts.yml \
  ansible/site.yml \
  -b
```

Premier passage :

```text
changed=1
```

Deuxième passage :

```text
changed=0
```

Cette validation démontre l'idempotence réelle du rôle `common`.

---

# 5. Variables K3s

Variables communes :

```text
ansible/group_vars/all.yml
```

Configuration actuelle :

```yaml
---
k3s_version: "v1.36.4+k3s1"

k3s_server_url: "https://192.168.1.167:6443"

k3s_server_options:
  - "--disable=traefik"
  - "--disable=servicelb"
  - "--write-kubeconfig-mode=0644"
```

Les variables sont automatiquement disponibles pour les rôles Ansible concernés.

---

# 6. Rôle `k3s_server`

Structure :

```text
ansible/roles/k3s_server/
├── tasks/
│   └── main.yml
├── handlers/
│   └── main.yml
└── templates/
    └── k3s.service.env.j2
```

Le rôle :

1. vérifie si le binaire K3s existe ;
2. déploie le fichier d'environnement systemd ;
3. installe K3s si le binaire n'existe pas ;
4. supprime le script d'installation temporaire ;
5. redémarre K3s si sa configuration a changé.

La vérification du binaire utilise :

```yaml
ansible.builtin.stat:
  path: /usr/local/bin/k3s
```

avec :

```yaml
register: k3s_binary
```

Puis l'installation est conditionnée par :

```yaml
when: not k3s_binary.stat.exists
```

Cela évite de réinstaller K3s à chaque exécution.

---

# 7. Rôle `k3s_agent`

Structure :

```text
ansible/roles/k3s_agent/
├── tasks/
│   └── main.yml
├── handlers/
│   └── main.yml
└── templates/
    └── k3s-agent.service.env.j2
```

Le rôle est analogue à `k3s_server`, mais configure les agents K3s.

Les workers utilisent :

```text
k3s-agent.service
```

et non :

```text
k3s.service
```

Le binaire reste cependant :

```text
/usr/local/bin/k3s
```

---

# 8. Gestion du token K3s

Le token K3s est généré par Terraform avec `random_password`.

Il n'est pas stocké dans Git.

Terraform expose désormais le token sous la forme d'un output sensible :

```hcl
output "k3s_token" {
  description = "K3s cluster token"
  value       = random_password.k3s_token.result
  sensitive   = true
}
```

Le fichier :

```text
terraform/outputs.tf
```

a été ajouté au commit :

```text
9b4131f Expose K3s token for Ansible
```

Le token peut être récupéré localement avec :

```bash
export K3S_TOKEN="$(terraform -chdir=terraform output -raw k3s_token)"
```

La valeur du token n'est jamais affichée.

La présence de la variable peut être vérifiée sans révéler son contenu :

```bash
test -n "$K3S_TOKEN" && echo "K3S_TOKEN est défini"
```

---

# 9. Fichiers d'environnement systemd

Ansible déploie les variables nécessaires à K3s dans des fichiers séparés.

## Serveur

```text
/etc/systemd/system/k3s.service.env
```

Contenu logique :

```text
K3S_TOKEN=<secret>
```

Permissions :

```text
root:root
0600
```

## Agents

```text
/etc/systemd/system/k3s-agent.service.env
```

Contenu logique :

```text
K3S_TOKEN=<secret>
K3S_URL=https://192.168.1.167:6443
```

Permissions :

```text
root:root
0600
```

Les fichiers ne sont donc lisibles que par `root`.

Les templates Jinja correspondants sont :

```text
ansible/roles/k3s_server/templates/k3s.service.env.j2
ansible/roles/k3s_agent/templates/k3s-agent.service.env.j2
```

Les tâches qui manipulent ces fichiers utilisent `no_log: true` afin d'éviter d'exposer le secret dans la sortie Ansible.

---

# 10. Intégration avec systemd

L'installation K3s crée les services systemd.

Le service serveur contient notamment :

```text
EnvironmentFile=-/etc/systemd/system/k3s.service.env
```

et démarre :

```text
/usr/local/bin/k3s server
```

Les agents utilisent :

```text
EnvironmentFile=-/etc/systemd/system/k3s-agent.service.env
```

et démarrent :

```text
/usr/local/bin/k3s agent
```

Le token et l'URL du serveur ne sont donc pas placés directement dans `ExecStart`.

Ansible gère les fichiers d'environnement et utilise des handlers pour redémarrer les services lorsqu'ils changent.

---

# 11. Handlers

Serveur :

```yaml
- name: Restart K3s server
  ansible.builtin.systemd:
    name: k3s
    state: restarted
    daemon_reload: true
```

Agent :

```yaml
- name: Restart K3s agent
  ansible.builtin.systemd:
    name: k3s-agent
    state: restarted
    daemon_reload: true
```

Les handlers ne sont exécutés que lorsqu'une tâche les notifie.

Exemple :

```text
template modifié
      ↓
notify
      ↓
handler
      ↓
restart K3s
```

Cela évite les redémarrages inutiles.

---

# 12. Validation en mode check

Le playbook a été testé avec :

```bash
ansible-playbook \
  -i ansible/inventory/platform-lab/hosts.yml \
  ansible/site.yml \
  -b \
  --check
```

Le mode `--check` a correctement identifié les modifications potentielles des fichiers d'environnement et les redémarrages associés, sans modifier le cluster réel.

Les tâches d'installation K3s ont été ignorées puisque le binaire existait déjà.

---

# 13. Validation réelle

Après définition de :

```bash
export K3S_TOKEN="$(terraform -chdir=terraform output -raw k3s_token)"
```

le playbook a été exécuté réellement.

Résultat :

```text
k8s-cp       ok=7 changed=2 failed=0 skipped=3
k8s-worker-1 ok=7 changed=2 failed=0 skipped=3
k8s-worker-2 ok=7 changed=2 failed=0 skipped=3
k8s-worker-3 ok=7 changed=2 failed=0 skipped=3
```

Les services K3s ont été redémarrés après modification de leurs fichiers d'environnement.

Le cluster est resté opérationnel.

Validation :

```bash
kubectl get nodes
```

Résultat :

```text
k8s-cp         Ready   control-plane   v1.36.4+k3s1
k8s-worker-1   Ready   <none>          v1.36.4+k3s1
k8s-worker-2   Ready   <none>          v1.36.4+k3s1
k8s-worker-3   Ready   <none>          v1.36.4+k3s1
```

---

# 14. Validation d'idempotence

Le playbook a ensuite été exécuté une deuxième fois sans modification de configuration.

Résultat :

```text
changed=0
failed=0
```

sur les quatre machines.

Aucun handler n'a été déclenché.

Cette étape est importante : elle montre que la configuration actuelle n'est pas seulement exécutable, mais également **idempotente**.

---

# 15. Vérification des services

Sur le control plane :

```bash
systemctl is-active k3s k3s-agent
```

Résultat attendu :

```text
active
inactive
```

Sur les workers :

```text
inactive
active
```

C'est normal :

```text
control plane → k3s.service
workers       → k3s-agent.service
```

Les deux types de machines utilisent le même binaire :

```text
/usr/local/bin/k3s
```

mais avec des services et des rôles différents.

---

# 16. DNS

La configuration actuelle de `/etc/resolv.conf` est statique :

```text
nameserver 192.168.1.254
nameserver 1.1.1.1
```

Terraform configure également les DNS au niveau de l'initialisation Proxmox.

Pour le moment, cette configuration est volontairement conservée telle quelle.

Il n'est pas nécessaire de déplacer cette responsabilité vers Ansible avant la reconstruction contrôlée de la plateforme.

À distinguer de CoreDNS :

```text
/etc/resolv.conf
    ↓
résolution DNS de la machine Linux

CoreDNS
    ↓
résolution DNS à l'intérieur de Kubernetes
```

---

# 17. État actuel de la migration

La migration n'est pas encore terminée.

État actuel :

```text
Terraform
   ↓
VM + cloud-init
   ↓
cloud-init installe encore K3s
   ↓
Ansible configure désormais K3s
```

Il existe donc actuellement une responsabilité temporairement partagée.

L'objectif final est :

```text
Terraform
   ↓
VM + configuration minimale
   ↓
Ansible
   ↓
Installation + configuration K3s
   ↓
FluxCD
   ↓
edge-platform
```

---

# 18. Prochaine étape

La prochaine étape consiste à retirer l'installation K3s du `cloud-init.tf`.

Avant toute reconstruction, le code sera modifié pour que cloud-init ne fasse plus :

```text
curl https://get.k3s.io
```

Ansible deviendra alors l'unique mécanisme d'installation et de configuration de K3s.

Le bootstrap global devra ensuite suivre cette séquence :

```text
1. Terraform
       ↓
2. création / configuration des VMs
       ↓
3. Ansible
       ↓
4. installation et configuration K3s
       ↓
5. récupération du kubeconfig
       ↓
6. validation Kubernetes
       ↓
7. Flux bootstrap / validation
       ↓
8. edge-platform
```

Une reconstruction complète du cluster ne sera réalisée qu'une fois cette chaîne stabilisée, afin de vérifier la reproductibilité de bout en bout.

---

# 19. État Git

Le dépôt principal :

```text
~/projects/platform-lab
```

est synchronisé avec GitHub.

Dernier commit :

```text
9b4131f Expose K3s token for Ansible
```

Les commits précédents incluent :

```text
32ea3f0 doc: add the following of ansible configuration
d120582 doc: add the following of ansible configuration
3c35c0d Add platform bootstrap script
ef62293 Document reproducible platform state
```

Le dépôt `edge-platform` reste un dépôt Git indépendant et ne doit pas être ajouté au dépôt parent `platform-lab`.

État local attendu :

```text
ansible/        → nouveau chantier v0.3, à versionner
edge-platform/  → dépôt Git indépendant
```

---

# 20. Bilan v0.3 à ce stade

Les éléments suivants sont validés :

* [x] Inventaire Ansible
* [x] Connectivité SSH
* [x] Role `common`
* [x] Idempotence du rôle `common`
* [x] Role `k3s_server`
* [x] Role `k3s_agent`
* [x] Gestion du token K3s
* [x] Templates Jinja2
* [x] Fichiers d'environnement systemd
* [x] Permissions `0600`
* [x] Handlers
* [x] Installation conditionnelle de K3s
* [x] Mode `--check`
* [x] Exécution réelle
* [x] Idempotence réelle de l'ensemble
* [x] Cluster Kubernetes toujours `Ready`

Reste à réaliser :

* [ ] Retirer l'installation K3s de cloud-init
* [ ] Adapter le bootstrap global
* [ ] Tester une reconstruction complète contrôlée
* [ ] Valider la reproductibilité de bout en bout
* [ ] Versionner/taguer l'état v0.3
