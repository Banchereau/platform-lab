# 3. Ansible — Configuration et prise en charge progressive de K3s

## Objectif

La phase v0.3 introduit Ansible dans la chaîne d'administration de la plateforme.

L'objectif est de faire évoluer progressivement l'architecture vers :

    Terraform
        ↓
    VM + bootstrap minimal
        ↓
    Ansible
        ↓
    K3s
        ↓
    FluxCD
        ↓
    edge-platform

La responsabilité de chaque outil est ainsi clairement séparée :

- Terraform : infrastructure Proxmox
- Cloud-init : bootstrap initial minimal
- Ansible : configuration des machines et installation/configuration de K3s
- K3s : plateforme Kubernetes
- FluxCD : configuration et workloads Kubernetes via GitOps

La migration vers une gestion complète de K3s par Ansible est progressive afin de ne pas perturber le cluster existant.

---

## 1. État de la plateforme

Infrastructure actuelle :

| Élément | Valeur |
|---|---|
| Hyperviseur | Proxmox VE 9.2.11 |
| OS | Debian 13.6 |
| Kubernetes | K3s v1.36.4+k3s1 |
| Control plane | k8s-cp — 192.168.1.167 |
| Worker 1 | k8s-worker-1 — 192.168.1.168 |
| Worker 2 | k8s-worker-2 — 192.168.1.169 |
| Worker 3 | k8s-worker-3 — 192.168.1.170 |
| Ansible Core | 2.19.11 |
| Python | 3.13.5 |

Le cluster K3s existant est opérationnel avant l'introduction d'Ansible.

---

# 2. Inventaire Ansible

L'inventaire est situé dans :

    ansible/inventory/platform-lab/hosts.yml

Structure :

    all
    ├── control_plane
    │   └── k8s-cp
    └── workers
        ├── k8s-worker-1
        ├── k8s-worker-2
        └── k8s-worker-3

Les connexions SSH utilisent l'utilisateur :

    xcode

Les adresses IP sont celles attribuées par Terraform/Proxmox.

L'inventaire a été validé avec :

    ansible-inventory \
      -i ansible/inventory/platform-lab/hosts.yml \
      --graph

Puis :

    ansible-inventory \
      -i ansible/inventory/platform-lab/hosts.yml \
      --list

---

# 3. Validation de la connectivité

La connectivité Ansible est testée avec :

    cd ~/projects/platform-lab

    ansible all \
      -i ansible/inventory/platform-lab/hosts.yml \
      -m ping

Résultat attendu :

    k8s-cp       SUCCESS
    k8s-worker-1 SUCCESS
    k8s-worker-2 SUCCESS
    k8s-worker-3 SUCCESS

Chaque nœud répond :

    "ping": "pong"

Aucune modification n'est effectuée par ce test.

---

# 4. Rôle common

Le rôle `common` constitue la première couche de configuration système commune.

Structure :

    ansible/roles/common/
    ├── tasks/
    │   └── main.yml
    └── handlers/
        └── main.yml

## Responsabilités actuelles

Le rôle :

1. récupère les informations système ;
2. affiche le hostname, la distribution et le kernel ;
3. installe les paquets système communs.

Paquets actuellement installés :

    ca-certificates
    curl
    gnupg
    sudo

La tâche d'installation utilise :

    state: present

et :

    update_cache: true

avec un cache valide pendant une heure.

---

# 5. Idempotence du rôle common

Le rôle a été exécuté plusieurs fois.

Lors de la première exécution, les paquets absents ont été installés.

Lors des exécutions suivantes :

    changed=0

sur tous les nœuds.

Cela valide le comportement idempotent attendu d'Ansible :

    état absent → modification nécessaire
    état conforme → aucune modification

L'idempotence est une propriété essentielle pour l'exploitation d'une plateforme.

L'objectif n'est pas seulement de pouvoir installer la plateforme, mais de pouvoir rejouer régulièrement la configuration sans provoquer de modifications inutiles.

---

# 6. Variables K3s

Les variables communes sont définies dans :

    ansible/group_vars/all.yml

Configuration actuelle :

    k3s_version: "v1.36.4+k3s1"

    k3s_server_url: "https://192.168.1.167:6443"

Options du serveur :

    --disable=traefik
    --disable=servicelb
    --write-kubeconfig-mode=0644

Ces paramètres correspondent à la configuration actuelle du cluster.

---

# 7. Rôle k3s_server

Structure :

    ansible/roles/k3s_server/
    ├── tasks/
    │   └── main.yml
    └── handlers/
        └── main.yml

À ce stade, le rôle est volontairement en mode **inspection**.

Il ne réinstalle pas K3s.

Il vérifie :

- la présence du binaire `/usr/local/bin/k3s` ;
- l'existence du service `k3s` ;
- l'état du service ;
- son activation au démarrage ;
- la configuration K3s attendue ;
- la disponibilité du token K3s.

Exemple de vérification :

    K3s binary present: True
    K3s service active: active
    K3s service enabled: enabled

---

# 8. Rôle k3s_agent

Structure :

    ansible/roles/k3s_agent/
    ├── tasks/
    │   └── main.yml
    └── handlers/
        └── main.yml

Comme pour le control plane, le rôle est actuellement en mode inspection.

Il vérifie :

- la présence du binaire K3s ;
- l'existence du service `k3s-agent` ;
- l'état du service ;
- son activation ;
- la disponibilité du token K3s.

Résultat observé sur les trois workers :

    K3s binary present: True
    K3s agent service active: active
    K3s agent service enabled: enabled

---

# 9. Gestion du token K3s

Le token K3s est généré par Terraform et conservé dans le state Terraform.

Il est exposé comme output sensible :

    output "k3s_token" {
      description = "K3s cluster token"
      value       = random_password.k3s_token.result
      sensitive   = true
    }

Le token peut être récupéré localement avec :

    terraform -chdir=terraform output -raw k3s_token

Il ne doit jamais être commité dans Git.

Pour les tests Ansible, il est fourni au contrôleur via la variable d'environnement :

    K3S_TOKEN

Le rôle vérifie sa présence avec :

    lookup('ansible.builtin.env', 'K3S_TOKEN')

Cette vérification concerne l'environnement du contrôleur Ansible. Le token n'est donc pas stocké dans l'inventaire.

La valeur du token ne doit jamais être affichée dans les logs ou dans Git.

---

# 10. Playbook principal

Le playbook principal est :

    ansible/site.yml

Il distingue le control plane des workers.

Structure logique :

    Configure control plane
        common
        k3s_server

    Configure workers
        common
        k3s_agent

Le `become: true` est utilisé pour les opérations nécessitant les privilèges root.

---

# 11. Validation complète

Le playbook est exécuté avec :

    cd ~/projects/platform-lab

    ansible-playbook \
      -i ansible/inventory/platform-lab/hosts.yml \
      ansible/site.yml

Dernière exécution validée :

    PLAY RECAP

    k8s-cp       : ok=9  changed=0  unreachable=0  failed=0
    k8s-worker-1 : ok=8  changed=0  unreachable=0  failed=0
    k8s-worker-2 : ok=8  changed=0  unreachable=0  failed=0
    k8s-worker-3 : ok=8  changed=0  unreachable=0  failed=0

Cette exécution valide :

- la connectivité Ansible ;
- la collecte des informations système ;
- la configuration commune ;
- la présence de K3s ;
- l'état des services K3s ;
- la disponibilité du token ;
- l'idempotence du playbook actuel.

Aucune modification du cluster n'a été nécessaire.

---

# 12. Pourquoi K3s n'est pas encore installé par Ansible

La migration n'est volontairement pas effectuée directement sur le cluster existant.

Le cluster actuel fonctionne et constitue notre état de référence.

La stratégie retenue est :

    1. Observer la configuration actuelle
    2. Reproduire cette configuration dans Ansible
    3. Tester l'installation sur une machine isolée
    4. Vérifier l'idempotence
    5. Retirer progressivement l'installation K3s de Cloud-init
    6. Tester une reconstruction complète
    7. Valider la reproductibilité

Cette approche évite de réinstaller K3s inutilement sur un cluster fonctionnel.

---

# 13. Responsabilités après migration

L'objectif final de la phase v0.3 est :

### Terraform

Responsable de l'infrastructure :

- VMs Proxmox
- VMID
- CPU
- mémoire
- disque
- réseau
- adresses IP
- DNS/gateway
- template
- accès SSH initial
- génération du token K3s

### Cloud-init

Responsable uniquement du bootstrap initial :

- hostname
- utilisateurs
- clé SSH
- sudo
- configuration minimale nécessaire au premier accès

L'installation de K3s doit à terme être retirée de Cloud-init.

### Ansible

Responsable de la configuration système :

- paquets
- configuration Debian
- éventuels modules kernel/sysctl
- installation K3s
- configuration K3s
- services systemd
- configuration des nœuds

### FluxCD

Responsable de Kubernetes et des workloads :

- ingress-nginx
- MetalLB
- cert-manager
- applications
- configuration Kubernetes
- GitOps

Ansible ne doit pas devenir un outil de déploiement des workloads Kubernetes déjà gérés par Flux.

---

# 14. Prochaine étape

Avant d'implémenter l'installation K3s dans Ansible, inspecter la configuration réellement générée par l'installation actuelle.

Control plane :

    ansible control_plane \
      -i ansible/inventory/platform-lab/hosts.yml \
      -b \
      -m command \
      -a "systemctl cat k3s"

Workers :

    ansible workers \
      -i ansible/inventory/platform-lab/hosts.yml \
      -b \
      -m command \
      -a "systemctl cat k3s-agent"

Ces commandes sont en lecture seule.

Attention à ne pas publier une éventuelle valeur de token apparaissant dans la configuration.

L'objectif est de déterminer précisément :

- la commande `ExecStart` ;
- les options K3s ;
- les éventuels fichiers de configuration ;
- la façon dont le service systemd a été généré.

Cela permettra de construire le rôle Ansible K3s sans modifier le cluster existant.

---

# 15. État de la phase v0.3

| Élément | État |
|---|---|
| Installation Ansible | Terminé |
| Inventaire | Validé |
| Connectivité SSH | Validée |
| Rôle common | Validé |
| Idempotence common | Validée |
| Variables K3s | Validées |
| Inspection K3s server | Validée |
| Inspection K3s agents | Validée |
| Vérification token server | Validée |
| Vérification token agents | Validée |
| Installation K3s par Ansible | À faire |
| Test sur machine isolée | À faire |
| Suppression K3s de Cloud-init | À faire |
| Reconstruction complète | À faire |
| Validation idempotence complète | À faire |
| Tag v0.3 | À faire |

La plateforme reste fonctionnelle pendant toute cette phase.

La règle de travail est :

    ne pas casser un état fonctionnel pour apprendre l'outil ;
    reproduire d'abord l'état existant, puis migrer la responsabilité.
