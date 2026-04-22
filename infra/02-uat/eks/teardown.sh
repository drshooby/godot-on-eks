#!/usr/bin/env bash
# Tears down the UAT Kubernetes resources (not Terraform infra).
# RDS, VPC, EKS cluster etc. are managed by Terraform — destroy those separately.
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
echo "==> Removing cert-manager..."
helm uninstall cert-manager -n cert-manager 2>/dev/null && echo "  cert-manager removed" || echo "  cert-manager not found (skipped)"

echo ""
echo "==> Removing Envoy Gateway..."
helm uninstall eg -n envoy-gateway-system 2>/dev/null && echo "  eg removed" || echo "  eg not found (skipped)"

echo ""
echo "==> Deleting namespaces..."
kubectl delete namespace uat argocd external-secrets cert-manager envoy-gateway-system --ignore-not-found

echo ""
echo "==> Removing Gateway API CRDs..."
kubectl delete crd \
  gatewayclasses.gateway.networking.k8s.io \
  gateways.gateway.networking.k8s.io \
  grpcroutes.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io \
  referencegrants.gateway.networking.k8s.io \
  --ignore-not-found

echo ""
echo "Done. Kubernetes resources removed."
echo "To destroy the EKS cluster, VPC, and RDS: terraform -chdir=$UAT_DIR/terraform destroy"
