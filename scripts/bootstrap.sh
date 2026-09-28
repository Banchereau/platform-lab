#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="${PROJECT_ROOT}/terraform"
ANSIBLE_DIR="${PROJECT_ROOT}/ansible"
ANSIBLE_INVENTORY="${ANSIBLE_DIR}/inventory/platform-lab/hosts.yml"
ANSIBLE_PLAYBOOK="${ANSIBLE_DIR}/site.yml"
EDGE_PLATFORM_DIR="${PROJECT_ROOT}/edge-platform"

KUBECONFIG_FILE="${HOME}/.kube/platform-lab.yaml"
TERRAFORM_PLAN="${TERRAFORM_DIR}/bootstrap.tfplan"

SSH_KNOWN_HOSTS="${HOME}/.ssh/known_hosts_platform-lab"

CONTROL_PLANE_IP="192.168.1.167"

PLATFORM_LAB_IPS=(
    "192.168.1.167"
    "192.168.1.168"
    "192.168.1.169"
    "192.168.1.170"
)

echo "==> Platform Lab bootstrap"
echo

# ----------------------------------------------------------------------
# 1. Prerequisites
# ----------------------------------------------------------------------

for cmd in terraform ansible-playbook kubectl flux ssh git gh jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $cmd"
        exit 1
    fi
done

echo "✓ Required commands available"

# ----------------------------------------------------------------------
# 2. SSH known_hosts
# ----------------------------------------------------------------------

mkdir -p "${HOME}/.ssh"
touch "$SSH_KNOWN_HOSTS"
chmod 600 "$SSH_KNOWN_HOSTS"

echo "✓ Platform Lab SSH known_hosts: $SSH_KNOWN_HOSTS"

# ----------------------------------------------------------------------
# 3. Validate GitOps repository
# ----------------------------------------------------------------------

if [ ! -d "${EDGE_PLATFORM_DIR}/.git" ]; then
    echo "ERROR: edge-platform is not a Git repository"
    exit 1
fi

if [ -n "$(git -C "$EDGE_PLATFORM_DIR" status --porcelain)" ]; then
    echo "ERROR: edge-platform has uncommitted changes"
    exit 1
fi

echo "✓ edge-platform working tree clean"

# ----------------------------------------------------------------------
# 4. Terraform
# ----------------------------------------------------------------------

cd "$TERRAFORM_DIR"

echo
echo "==> Terraform init"

terraform init

echo
echo "==> Terraform plan"

terraform plan -out="$TERRAFORM_PLAN"

# ----------------------------------------------------------------------
# 5. Detect VM replacement
# ----------------------------------------------------------------------

VM_REPLACEMENT_REQUIRED=false

if terraform show -json "$TERRAFORM_PLAN" | jq -e '
    [
        .resource_changes[]?
        | select(.type == "proxmox_virtual_environment_vm")
        | .change.actions
        | select(any(.[]; . == "delete"))
    ]
    | length > 0
' >/dev/null; then
    VM_REPLACEMENT_REQUIRED=true
fi

if [ "$VM_REPLACEMENT_REQUIRED" = true ]; then
    echo
    echo "⚠ Terraform plan contains VM deletion/replacement"
    echo "  Platform Lab SSH host keys will be refreshed after apply"
else
    echo "✓ No VM replacement detected"
fi

# ----------------------------------------------------------------------
# 6. Confirm Terraform apply
# ----------------------------------------------------------------------

echo
read -r -p "Apply this Terraform plan? [y/N] " answer

if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "Bootstrap cancelled."
    rm -f "$TERRAFORM_PLAN"
    exit 0
fi

echo
echo "==> Terraform apply"

terraform apply -auto-approve "$TERRAFORM_PLAN"

rm -f "$TERRAFORM_PLAN"

# ----------------------------------------------------------------------
# 7. Refresh SSH host keys after VM replacement
# ----------------------------------------------------------------------

if [ "$VM_REPLACEMENT_REQUIRED" = true ]; then
    echo
    echo "==> Refreshing Platform Lab SSH host keys"

    for ip in "${PLATFORM_LAB_IPS[@]}"; do
        ssh-keygen \
            -f "$SSH_KNOWN_HOSTS" \
            -R "$ip" \
            >/dev/null 2>&1 || true
    done

    echo "✓ Old Platform Lab SSH host keys removed"
fi

# ----------------------------------------------------------------------
# 8. Export K3s token for Ansible
# ----------------------------------------------------------------------

echo
echo "==> Retrieving K3s token from Terraform"

export K3S_TOKEN="$(terraform output -raw k3s_token)"

if [ -z "$K3S_TOKEN" ]; then
    echo "ERROR: K3S_TOKEN is empty"
    exit 1
fi

echo "✓ K3s token available to Ansible"

# ----------------------------------------------------------------------
# 9. Wait for control-plane SSH
# ----------------------------------------------------------------------

echo
echo "==> Waiting for control-plane SSH"

for attempt in {1..30}; do
    if ssh \
        -o ConnectTimeout=3 \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" \
        "xcode@${CONTROL_PLANE_IP}" \
        'true' >/dev/null 2>&1; then

        echo "✓ Control-plane SSH available"
        break
    fi

    if [ "$attempt" -eq 30 ]; then
        echo "ERROR: control-plane SSH did not become available"
        unset K3S_TOKEN
        exit 1
    fi

    sleep 5
done

# ----------------------------------------------------------------------
# 10. Configure machines and install K3s with Ansible
# ----------------------------------------------------------------------

echo
echo "==> Running Ansible"

cd "$PROJECT_ROOT"

ansible-playbook \
    -i "$ANSIBLE_INVENTORY" \
    "$ANSIBLE_PLAYBOOK"

echo "✓ Ansible configuration completed"

# The token is no longer needed after Ansible.
unset K3S_TOKEN

# ----------------------------------------------------------------------
# 11. Retrieve fresh kubeconfig
# ----------------------------------------------------------------------

echo
echo "==> Retrieving kubeconfig"

mkdir -p "${HOME}/.kube"

ssh \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" \
    "xcode@${CONTROL_PLANE_IP}" \
    'sudo cat /etc/rancher/k3s/k3s.yaml' \
    > "${KUBECONFIG_FILE}"

chmod 600 "${KUBECONFIG_FILE}"

sed -i \
    "s#https://127.0.0.1:6443#https://${CONTROL_PLANE_IP}:6443#" \
    "${KUBECONFIG_FILE}"

export KUBECONFIG="${KUBECONFIG_FILE}"

echo "✓ Fresh kubeconfig configured"

# ----------------------------------------------------------------------
# 12. Wait for Kubernetes
# ----------------------------------------------------------------------

echo
echo "==> Waiting for Kubernetes"

for attempt in {1..30}; do
    if kubectl get nodes >/dev/null 2>&1; then
        echo "✓ Kubernetes API available"
        break
    fi

    if [ "$attempt" -eq 30 ]; then
        echo "ERROR: Kubernetes API did not become available"
        exit 1
    fi

    sleep 5
done

echo
kubectl get nodes -o wide

# ----------------------------------------------------------------------
# 13. Flux prerequisites
# ----------------------------------------------------------------------

echo
echo "==> Flux prerequisite check"

flux check --pre

# ----------------------------------------------------------------------
# 14. Flux bootstrap
# ----------------------------------------------------------------------

echo
echo "==> Checking Flux"

if kubectl get namespace flux-system >/dev/null 2>&1; then

    echo "✓ flux-system namespace already exists"
    echo "==> Validating existing Flux installation"

    flux check

else

    echo "==> Bootstrapping Flux"

    cd "$EDGE_PLATFORM_DIR"

    GITHUB_TOKEN="$(gh auth token)" \
        flux bootstrap github \
        --owner=Banchereau \
        --repository=edge-platform \
        --branch=main \
        --path=clusters/platform-lab \
        --personal
fi

# ----------------------------------------------------------------------
# 15. Final validation
# ----------------------------------------------------------------------

echo
echo "==> Final validation"

kubectl get nodes -o wide

echo
flux check

echo
echo "✓ Platform bootstrap completed successfully"
