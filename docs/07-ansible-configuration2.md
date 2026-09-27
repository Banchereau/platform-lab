# Ansible — Configuration et gestion de la plateforme

## 1. Objectif

Ansible constitue la couche de configuration de la plateforme.

L'architecture cible est :

```text
Terraform
    │
    │ création des VM
    ▼
Proxmox
    │
    │ cloud-init minimal
    ▼
VM Debian
    │
    │ Ansible
    ▼
K3s
    │
    │ Flux
    ▼
edge-platform
```

La séparation des responsabilités est la suivante :

| Outil      | Responsabilité                                            |
| ---------- | --------------------------------------------------------- |
| Terraform  | Infrastructure Proxmox : VM, CPU, RAM, disque, réseau     |
| Cloud-init | Bootstrap minimal : utilisateur, SSH, hostname            |
| Ansible    | Configuration Debian et installation/configuration de K3s |
| FluxCD     | Configuration et workloads Kubernetes                     |

L'objectif de cette phase est de faire d'Ansible le propriétaire de la configuration logicielle des nœuds.

---

# 2. Installation d'Ansible

Version utilisée :

```bash
ansible --version
```

Ansible Core :

```text
2.19.11
```

Configuration :

```text
/etc/ansible/ansible.cfg
```

---

# 3. Inventaire

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

L'inventaire distingue donc :

```text
control_plane
    └── k8s-cp

workers
    ├── k8s-worker-1
    ├── k8s-worker-2
    └── k8s-worker-3
```

---

# 4. Validation de la connectivité

Test :

```bash
ansible all \
  -i ansible/inventory/platform-lab/hosts.yml \
  -m ping
```

Résultat :

```text
k8s-cp       → SUCCESS
k8s-worker-1 → SUCCESS
k8s-worker-2 → SUCCESS
k8s-worker-3 → SUCCESS
```

Ansible peut donc communiquer avec les quatre nœuds.

---

# 5. Organisation des rôles

Structure actuelle :

```text
ansible/
├── group_vars/
│   └── all.yml
├── inventory/
│   └── platform-lab/
│       └── hosts.yml
├── roles/
│   ├── common/
│   │   ├── handlers/
│   │   │   └── main.yml
│   │   └── tasks/
│   │       └── main.yml
│   │
│   ├── k3s_server/
│   │   ├── handlers/
│   │   └── tasks/
│   │       └── main.yml
│   │
│   └── k3s_agent/
│       ├── handlers/
│       └── tasks/
│           └── main.yml
│
└── site.yml
```

Les répertoires `handlers` des rôles K3s sont actuellement préparés mais encore vides.

Ils seront utilisés lorsque les rôles commenceront à gérer les fichiers de configuration et les redémarrages systemd.

---

# 6. Variables globales

Fichier :

```text
ansible/group_vars/all.yml
```

Configuration K3s actuelle :

```yaml
---
k3s_version: "v1.36.4+k3s1"

k3s_server_url: "https://192.168.1.167:6443"

k3s_server_options:
  - "--disable=traefik"
  - "--disable=servicelb"
  - "--write-kubeconfig-mode=0644"
```

Ces variables sont accessibles aux rôles Ansible.

Par exemple :

```yaml
{{ k3s_version }}
```

récupère :

```text
v1.36.4+k3s1
```

et :

```yaml
{{ k3s_server_options | join(' ') }}
```

transforme la liste :

```text
--disable=traefik
--disable=servicelb
--write-kubeconfig-mode=0644
```

en une chaîne :

```text
--disable=traefik --disable=servicelb --write-kubeconfig-mode=0644
```

---

# 7. Rôle `common`

Le rôle `common` constitue la base commune aux quatre nœuds.

Il :

* récupère les informations du système ;
* affiche hostname, distribution et kernel ;
* installe les paquets système communs.

Paquets actuels :

```text
ca-certificates
curl
gnupg
sudo
```

Exemple :

```yaml
- name: Install common system packages
  ansible.builtin.apt:
    name:
      - ca-certificates
      - curl
      - gnupg
      - sudo
    state: present
    update_cache: true
    cache_valid_time: 3600
```

---

# 8. Idempotence du rôle `common`

Premier passage :

```text
changed=1
```

Les paquets ont été installés.

Deuxième passage :

```text
changed=0
```

Aucune modification n'était nécessaire.

L'idempotence est donc validée pour cette partie.

---

# 9. Playbook principal

Fichier :

```text
ansible/site.yml
```

Configuration actuelle :

```yaml
---
- name: Configure control plane
  hosts: control_plane
  become: true

  roles:
    - common
    - k3s_server

- name: Configure workers
  hosts: workers
  become: true

  roles:
    - common
    - k3s_agent
```

`become: true` permet aux rôles d'exécuter les opérations nécessitant les privilèges root.

---

# 10. Rôle `k3s_server`

Le rôle `k3s_server` commence maintenant à prendre en charge l'installation de K3s.

Il vérifie d'abord :

```yaml
- name: Check whether K3s server is installed
  ansible.builtin.stat:
    path: /usr/local/bin/k3s
  register: k3s_binary
```

La variable enregistrée permet ensuite de tester :

```yaml
when: not k3s_binary.stat.exists
```

Ainsi, l'installation n'est exécutée que si K3s n'est pas déjà présent.

---

# 11. Installation du serveur K3s

Si K3s est absent, Ansible :

1. télécharge l'installateur K3s ;
2. le rend exécutable ;
3. lance l'installation ;
4. supprime le script temporaire.

L'installation utilise :

```yaml
INSTALL_K3S_VERSION: "{{ k3s_version }}"
K3S_TOKEN: "{{ lookup('ansible.builtin.env', 'K3S_TOKEN') }}"
```

et :

```yaml
{{ k3s_server_options | join(' ') }}
```

pour transmettre les options du serveur.

La commande obtenue est conceptuellement :

```bash
/tmp/install-k3s.sh server \
  --disable=traefik \
  --disable=servicelb \
  --write-kubeconfig-mode=0644
```

---

# 12. Rôle `k3s_agent`

Les workers utilisent également le binaire :

```text
/usr/local/bin/k3s
```

mais fonctionnent en mode agent.

Le service systemd est :

```text
k3s-agent.service
```

Le rôle `k3s_agent` suit la même logique que le serveur :

```yaml
- name: Check whether K3s agent is installed
  ansible.builtin.stat:
    path: /usr/local/bin/k3s
  register: k3s_binary
```

Puis :

```yaml
when: not k3s_binary.stat.exists
```

L'installation utilise :

```yaml
INSTALL_K3S_VERSION: "{{ k3s_version }}"
K3S_URL: "{{ k3s_server_url }}"
K3S_TOKEN: "{{ lookup('ansible.builtin.env', 'K3S_TOKEN') }}"
```

`K3S_URL` indique au worker l'adresse du serveur K3s :

```text
https://192.168.1.167:6443
```

---

# 13. Gestion du token K3s

Le token K3s est généré et conservé par Terraform.

Il peut être récupéré depuis le state Terraform avec :

```bash
export K3S_TOKEN="$(terraform -chdir=terraform output -raw k3s_token)"
```

Le token n'est jamais affiché.

Ansible le récupère côté contrôleur avec :

```yaml
lookup('ansible.builtin.env', 'K3S_TOKEN')
```

Il est ensuite transmis à la tâche d'installation via l'environnement :

```yaml
environment:
  K3S_TOKEN: "{{ lookup('ansible.builtin.env', 'K3S_TOKEN') }}"
```

Les tâches manipulant ce secret utilisent :

```yaml
no_log: true
```

afin d'éviter son affichage dans la sortie Ansible.

Chaîne actuelle :

```text
Terraform state
      │
      │ terraform output
      ▼
K3S_TOKEN
      │
      │ environnement du shell
      ▼
Ansible
      │
      │ environment
      ▼
Installateur K3s
```

---

# 14. Vérification de la présence du token

Le rôle `k3s_agent` vérifie également que le token est disponible :

```yaml
- name: Check K3s token is available
  ansible.builtin.assert:
    that:
      - lookup('ansible.builtin.env', 'K3S_TOKEN') | length > 0
    fail_msg: "K3S_TOKEN environment variable is not set"
    success_msg: "K3S_TOKEN is available"
```

Cette vérification a permis de détecter un shell dans lequel `K3S_TOKEN` n'était plus exporté.

Après :

```bash
export K3S_TOKEN="$(terraform -chdir=terraform output -raw k3s_token)"
```

la vérification a réussi.

---

# 15. Protection contre une réinstallation

Le cluster actuel possède déjà K3s.

Le `--check` Ansible a confirmé que l'installation est ignorée :

```text
k3s_server : Download K3s install script → skipping
k3s_server : Install K3s server           → skipping
k3s_server : Remove K3s install script    → skipping
```

Sur les workers :

```text
k3s_agent : Download K3s install script → skipping
k3s_agent : Install K3s agent           → skipping
k3s_agent : Remove K3s install script   → skipping
```

Cela permet de développer les rôles sans réinstaller K3s sur le cluster actuellement fonctionnel.

---

# 16. Validation actuelle

Commande :

```bash
ansible-playbook \
  -i ansible/inventory/platform-lab/hosts.yml \
  ansible/site.yml \
  --syntax-check
```

Résultat :

```text
playbook: ansible/site.yml
```

La syntaxe est valide.

Test en mode check :

```bash
ansible-playbook \
  -i ansible/inventory/platform-lab/hosts.yml \
  ansible/site.yml \
  --check
```

Dernier résultat validé :

```text
k8s-cp       : ok=5  changed=0  failed=0  skipped=3
k8s-worker-1 : ok=5  changed=0  failed=0  skipped=3
k8s-worker-2 : ok=5  changed=0  failed=0  skipped=3
k8s-worker-3 : ok=5  changed=0  failed=0  skipped=3
```

Aucune modification n'a été effectuée sur le cluster.

---

# 17. Inspection du K3s actuellement installé

Avant de faire gérer K3s par Ansible, la configuration existante a été inspectée.

Serveur :

```text
/etc/systemd/system/k3s.service
```

Service :

```text
k3s.service
```

Commande exécutée :

```text
/usr/local/bin/k3s server
```

avec :

```text
--disable=traefik
--disable=servicelb
--write-kubeconfig-mode=0644
```

Le service utilise notamment :

```text
/etc/systemd/system/k3s.service.env
```

Ce fichier est :

```text
root:root
0600
```

et contient le token K3s.

---

# 18. Configuration des agents

Les workers utilisent :

```text
/etc/systemd/system/k3s-agent.service
```

avec :

```text
/usr/local/bin/k3s agent
```

Le service utilise :

```text
/etc/systemd/system/k3s-agent.service.env
```

Ce fichier est également :

```text
root:root
0600
```

Il contient les paramètres nécessaires à l'agent, notamment :

```text
K3S_TOKEN
K3S_URL
```

Les valeurs sensibles n'ont pas été affichées.

---

# 19. Permissions des fichiers K3s

Les fichiers contenant le token sont protégés par les permissions Unix :

```text
-rw------- root root
```

soit :

```text
0600
```

Cela signifie :

```text
propriétaire : lecture + écriture
groupe       : aucun droit
autres       : aucun droit
```

La configuration des permissions sera importante lorsque Ansible commencera à gérer directement ces fichiers.

---

# 20. Handlers

Les rôles `k3s_server` et `k3s_agent` possèdent déjà un répertoire :

```text
handlers/
```

Les handlers seront utilisés lorsqu'Ansible commencera à gérer les fichiers de configuration K3s.

Principe :

```text
configuration modifiée
        │
        ▼
notify
        │
        ▼
handler
        │
        ▼
systemctl restart k3s
```

ou :

```text
systemctl restart k3s-agent
```

Cela permettra de redémarrer les services uniquement lorsqu'une modification de configuration le nécessite.

---

# 21. État de la migration

La migration vers Ansible n'est pas encore terminée.

État :

| Élément                           | État          |
| --------------------------------- | ------------- |
| Inventaire Ansible                | Validé        |
| Connexion SSH                     | Validée       |
| Rôle `common`                     | Validé        |
| Idempotence `common`              | Validée       |
| Variables K3s                     | Validées      |
| Inspection K3s server             | Validée       |
| Inspection K3s agent              | Validée       |
| Gestion du token                  | Validée       |
| Installation `k3s_server`         | Préparée      |
| Installation `k3s_agent`          | Préparée      |
| Test `--check`                    | Validé        |
| Configuration systemd K3s         | À gérer       |
| Handlers K3s                      | À implémenter |
| Suppression de K3s de cloud-init  | À faire       |
| Reconstruction complète           | À faire       |
| Validation complète d'idempotence | À faire       |

---

# 22. Prochaine étape

La prochaine étape consiste à faire gérer par Ansible la configuration systemd de K3s :

```text
/etc/systemd/system/k3s.service.env
/etc/systemd/system/k3s-agent.service.env
```

avec notamment :

* propriétaire `root`;
* groupe `root`;
* permissions `0600`;
* token ;
* `K3S_URL` pour les agents ;
* handlers systemd ;
* redémarrage uniquement si la configuration change.

Cette étape permettra de passer d'un rôle qui sait **installer K3s** à un rôle qui sait réellement **administrer K3s de manière idempotente**.

---

# 23. Principe architectural retenu

À terme :

```text
Terraform
    │
    ├── VM
    ├── CPU / RAM / disque
    ├── réseau
    ├── IP
    └── accès initial
          │
          ▼
Cloud-init minimal
    │
    ├── hostname
    ├── utilisateur
    └── SSH
          │
          ▼
Ansible
    │
    ├── Debian
    ├── configuration système
    ├── K3s server
    └── K3s agents
          │
          ▼
Kubernetes / K3s
          │
          ▼
FluxCD
          │
          ▼
edge-platform
```

Cette séparation permet de distinguer clairement :

**Terraform = infrastructure**

**Ansible = configuration des machines**

**K3s = orchestration Kubernetes**

**FluxCD = configuration GitOps du cluster**
