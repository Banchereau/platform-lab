#!/usr/bin/env bash

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="${PROJECT_ROOT}/terraform"
EDGE_PLATFORM_DIR="${PROJECT_ROOT}/edge-platform"

KUBECONFIG_FILE="${HOME}/.kube/platform-lab.yaml"
SSH_KNOWN_HOSTS="${HOME}/.ssh/known_hosts_platform-lab"

CONTROL_PLANE_IP="192.168.1.167"

PLATFORM_LAB_IPS=(
    "192.168.1.167"
    "192.168.1.168"
    "192.168.1.169"
    "192.168.1.170"
)

OK=0
WARN=0
FAIL=0

pass() {
    echo "[ OK ] $1"
    OK=$((OK + 1))
}

warn() {
    echo "[WARN] $1"
    WARN=$((WARN + 1))
}

fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

section() {
    echo
    echo "==> $1"
}

echo "========================================"
echo " Platform Lab Health Check"
echo "========================================"

# --------------------------------------------------
# 1. Local prerequisites
# --------------------------------------------------

section "Local prerequisites"

for cmd in terraform kubectl flux ssh git jq; do
    if command -v "$cmd" >/dev/null 2>&1; then
        pass "$cmd available"
    else
        fail "$cmd not found"
    fi
done

# --------------------------------------------------
# 2. Git repositories
# --------------------------------------------------

section "Git repositories"

if [ -z "$(
    git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all |
        grep -v '^?? edge-platform/'
)" ]; then
    pass "platform-lab working tree clean"
else
    warn "platform-lab has uncommitted or unexpected files"
fi

if [ -d "${EDGE_PLATFORM_DIR}/.git" ]; then
    if [ -z "$(git -C "$EDGE_PLATFORM_DIR" status --porcelain)" ]; then
        pass "edge-platform working tree clean"
    else
        warn "edge-platform has uncommitted changes"
    fi
else
    fail "edge-platform is not a Git repository"
fi

# --------------------------------------------------
# 3. Terraform
# --------------------------------------------------

section "Terraform"

if [ -d "$TERRAFORM_DIR" ]; then
    if terraform -chdir="$TERRAFORM_DIR" state list >/dev/null 2>&1; then
        pass "Terraform state accessible"
    else
        fail "Terraform state unavailable"
    fi
else
    fail "Terraform directory not found"
fi

# --------------------------------------------------
# 4. SSH
# --------------------------------------------------

section "SSH connectivity"

if [ -f "$SSH_KNOWN_HOSTS" ]; then
    pass "Platform Lab SSH known_hosts exists"
else
    warn "Platform Lab SSH known_hosts not found"
fi

for ip in "${PLATFORM_LAB_IPS[@]}"; do
    if ssh \
        -o ConnectTimeout=3 \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" \
        "xcode@${ip}" \
        'true' >/dev/null 2>&1; then

        pass "SSH ${ip}"
    else
        fail "SSH ${ip}"
    fi
done

# --------------------------------------------------
# 5. K3s services
# --------------------------------------------------

section "K3s services"

if ssh \
    -o ConnectTimeout=3 \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" \
    "xcode@${CONTROL_PLANE_IP}" \
    'systemctl is-active --quiet k3s'
then
    pass "k3s service on control-plane"
else
    fail "k3s service on control-plane"
fi

WORKER_IPS=(
    "192.168.1.168"
    "192.168.1.169"
    "192.168.1.170"
)

for ip in "${WORKER_IPS[@]}"; do
    if ssh \
        -o ConnectTimeout=3 \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" \
        "xcode@${ip}" \
        'systemctl is-active --quiet k3s-agent'
    then
        pass "k3s-agent service on ${ip}"
    else
        fail "k3s-agent service on ${ip}"
    fi
done

# --------------------------------------------------
# 6. Kubernetes
# --------------------------------------------------

section "Kubernetes"

if [ ! -f "$KUBECONFIG_FILE" ]; then
    fail "Kubeconfig not found: $KUBECONFIG_FILE"
else
    export KUBECONFIG="$KUBECONFIG_FILE"

    if kubectl version --request-timeout=5s >/dev/null 2>&1; then
        pass "Kubernetes API reachable"
    else
        fail "Kubernetes API unreachable"
    fi

    if kubectl get nodes >/dev/null 2>&1; then
        pass "Kubernetes nodes query"

        while IFS=$'\t' read -r node status; do
            if [ "$status" = "True" ]; then
                pass "Node ${node} Ready"
            else
                fail "Node ${node} Ready=${status}"
            fi
        done < <(
            kubectl get nodes -o json |
                jq -r '
                    .items[] |
                    .metadata.name as $name |
                    [
                        $name,
                        (
                            (.status.conditions // [])
                            | map(select(.type == "Ready"))
                            | .[0].status // "Unknown"
                        )
                    ] |
                    @tsv
                '
        )
    else
        fail "Unable to query Kubernetes nodes"
    fi
fi

# --------------------------------------------------
# 7. Flux
# --------------------------------------------------

section "Flux"

if flux check >/dev/null 2>&1; then
    pass "Flux healthy"
else
    fail "Flux check failed"
fi

if kubectl get kustomizations.kustomize.toolkit.fluxcd.io \
    -A >/dev/null 2>&1; then

    if kubectl get kustomizations.kustomize.toolkit.fluxcd.io \
        -A \
        -o json |
        jq -e '
            all(
                .items[];
                any(
                    .status.conditions[]?;
                    .type == "Ready" and .status == "True"
                )
            )
        ' >/dev/null 2>&1; then

        pass "Flux Kustomizations Ready"
    else
        warn "Some Flux Kustomizations are not Ready"
    fi
fi

if kubectl get helmreleases.helm.toolkit.fluxcd.io \
    -A >/dev/null 2>&1; then

    if kubectl get helmreleases.helm.toolkit.fluxcd.io \
        -A \
        -o json |
        jq -e '
            all(
                .items[];
                any(
                    .status.conditions[]?;
                    .type == "Ready" and .status == "True"
                )
            )
        ' >/dev/null 2>&1; then

        pass "Flux HelmReleases Ready"
    else
        warn "Some Flux HelmReleases are not Ready"
    fi
fi

# --------------------------------------------------
# 8. Summary
# --------------------------------------------------

echo
echo "========================================"
echo " Summary"
echo "========================================"

echo "OK   : $OK"
echo "WARN : $WARN"
echo "FAIL : $FAIL"

if [ "$FAIL" -gt 0 ]; then
    echo
    echo "Platform Lab: UNHEALTHY"
    exit 1
fi

if [ "$WARN" -gt 0 ]; then
    echo
    echo "Platform Lab: HEALTHY WITH WARNINGS"
    exit 0
fi

echo
echo "Platform Lab: HEALTHY"
exit 0
