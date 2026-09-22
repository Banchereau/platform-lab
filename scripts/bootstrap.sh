#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="${PROJECT_ROOT}/terraform"
EDGE_PLATFORM_DIR="${PROJECT_ROOT}/edge-platform"
KUBECONFIG_FILE="${HOME}/.kube/platform-lab.yaml"
TERRAFORM_PLAN="${TERRAFORM_DIR}/bootstrap.tfplan"

CONTROL_PLANE_IP="192.168.1.167"

echo "==> Platform Lab bootstrap"
echo

# ----------------------------------------------------------------------
# 1. Prerequisites
# ----------------------------------------------------------------------

for cmd in terraform kubectl flux ssh git gh; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $cmd"
        exit 1
    fi
done

echo "✓ Required commands available"

# ----------------------------------------------------------------------
# 2. Validate GitOps repository
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
# 3. Terraform
# ----------------------------------------------------------------------

cd "$TERRAFORM_DIR"

echo
echo "==> Terraform init"

terraform init

echo
echo "==> Terraform plan"

terraform plan -out="$TERRAFORM_PLAN"

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
# 4. Wait for control-plane SSH
# ----------------------------------------------------------------------

echo
echo "==> Waiting for control-plane SSH"

for attempt in {1..30}; do
    if ssh \
        -o ConnectTimeout=3 \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "xcode@${CONTROL_PLANE_IP}" \
        'true' >/dev/null 2>&1; then

        echo "✓ Control-plane SSH available"
        break
    fi

    if [ "$attempt" -eq 30 ]; then
        echo "ERROR: control-plane SSH did not become available"
        exit 1
    fi

    sleep 5
done

# ----------------------------------------------------------------------
# 5. Retrieve fresh kubeconfig
# ----------------------------------------------------------------------

echo
echo "==> Retrieving kubeconfig"

mkdir -p "${HOME}/.kube"

ssh \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
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
# 6. Wait for Kubernetes
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

kubectl get nodes

# ----------------------------------------------------------------------
# 7. Flux prerequisites
# ----------------------------------------------------------------------

echo
echo "==> Flux prerequisite check"

flux check --pre

# ----------------------------------------------------------------------
# 8. Flux bootstrap
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
# 9. Final validation
# ----------------------------------------------------------------------

echo
echo "==> Final validation"

kubectl get nodes -o wide

echo
flux check

echo
echo "✓ Platform bootstrap completed successfully"
