#!/usr/bin/env bash
# Tears down the UAT Kubernetes resources (not Terraform infra).
# RDS, VPC, EKS cluster, ALB, ACM cert etc. are managed by Terraform — destroy those separately.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
UAT_DIR="$REPO_ROOT/infra/02-uat"

echo "==> Removing Argo CD..."
helm uninstall argo-cd -n argocd 2>/dev/null && echo "  argo-cd removed" || echo "  argo-cd not found (skipped)"

echo ""
echo "==> Removing External Secrets Operator..."
helm uninstall external-secrets -n external-secrets 2>/dev/null && echo "  external-secrets removed" || echo "  external-secrets not found (skipped)"

echo ""
echo "==> Removing Kong..."
helm uninstall kong -n kong 2>/dev/null && echo "  kong removed" || echo "  kong not found (skipped)"

echo ""
echo "==> Deleting namespaces..."
kubectl delete namespace uat argocd external-secrets kong --ignore-not-found

echo ""
echo "Done. Kubernetes resources removed."
echo ""
echo "Terraform owns the ALB, ACM cert, Route53 record, RDS, EKS, and VPC."
echo "To tear those down: terraform -chdir=$UAT_DIR/terraform destroy"
