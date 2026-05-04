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
echo "==> Removing Kong..."
helm uninstall kong -n kong 2>/dev/null && echo "  kong removed" || echo "  kong not found (skipped)"
kubectl delete namespace kong --ignore-not-found

echo ""
echo "Done. Cluster is clean."
