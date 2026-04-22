#!/usr/bin/env bash
# Tears down the local UAT stack deployed by install.sh.
set -euo pipefail

CONTEXT=$(kubectl config current-context)
if [[ "$CONTEXT" != "docker-desktop" ]]; then
  echo "ERROR: current kubectl context is '$CONTEXT', expected 'docker-desktop'."
  exit 1
fi

echo "==> Removing service Helm releases..."
for SVC in shooter session-service score-service auth-service platform; do
  helm uninstall "$SVC" -n uat 2>/dev/null && echo "  $SVC removed" || echo "  $SVC not found (skipped)"
done

echo ""
echo "==> Deleting namespaces (uat, external-secrets)..."
kubectl delete namespace uat external-secrets --ignore-not-found

echo ""
echo "==> Removing Envoy Gateway..."
helm uninstall eg -n envoy-gateway-system 2>/dev/null && echo "  eg removed" || echo "  eg not found (skipped)"
kubectl delete namespace envoy-gateway-system --ignore-not-found

echo ""
echo "==> Removing Gateway API CRDs..."
kubectl delete crd gatewayclasses.gateway.networking.k8s.io \
  gateways.gateway.networking.k8s.io \
  grpcroutes.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io \
  referencegrants.gateway.networking.k8s.io \
  --ignore-not-found

echo ""
echo "Done. Cluster is clean."
