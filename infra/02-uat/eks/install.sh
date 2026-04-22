#!/usr/bin/env bash
# Full UAT stack install on EKS.
# Run from anywhere; paths are resolved relative to the repo root.
#
# Prerequisites:
#   - Terraform applied (infra/02-uat/terraform)
#   - kubeconfig updated: eval "$(terraform -chdir=infra/02-uat/terraform output -raw configure_kubectl)"
#   - helm 3
#   - Images pushed to ECR (tag uat-latest)
#
# To tear everything down:
#   infra/02-uat/eks/teardown.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
UAT_DIR="$REPO_ROOT/infra/02-uat"
TF_DIR="$UAT_DIR/terraform"

# ── 0. Pull Terraform outputs ────────────────────────────────────────────────
echo "==> Reading Terraform outputs..."
AWS_ACCOUNT_ID="$(terraform -chdir="$TF_DIR" output -raw aws_account_id)"
AWS_REGION="$(terraform -chdir="$TF_DIR" output -raw aws_region)"
IRSA_ROLE_ARN="$(terraform -chdir="$TF_DIR" output -raw external_secrets_irsa_role_arn)"
CLUSTER_NAME="$(terraform -chdir="$TF_DIR" output -raw cluster_name)"

echo "  Account:  $AWS_ACCOUNT_ID"
echo "  Region:   $AWS_REGION"
echo "  Cluster:  $CLUSTER_NAME"
echo "  IRSA ARN: $IRSA_ROLE_ARN"

# Sanity-check kubectl points at the right cluster.
CONTEXT="$(kubectl config current-context)"
if [[ "$CONTEXT" != *"$CLUSTER_NAME"* ]]; then
  echo ""
  echo "WARNING: kubectl context '$CONTEXT' does not contain '$CLUSTER_NAME'."
  echo "  Run: $(terraform -chdir="$TF_DIR" output -raw configure_kubectl)"
  read -rp "Continue anyway? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || exit 1
fi

# ── 1. Namespaces ────────────────────────────────────────────────────────────
echo ""
echo "==> Applying namespaces..."
kubectl apply -f "$UAT_DIR/namespaces.yaml"

# ── 2. Envoy Gateway (includes Gateway API CRDs + GatewayClass) ──────────────
echo ""
echo "==> Installing Envoy Gateway (v1.3.1)..."
helm upgrade --install eg \
  oci://docker.io/envoyproxy/gateway-helm \
  --version v1.3.1 \
  -n envoy-gateway-system \
  --create-namespace \
  --wait

echo "Ensuring GatewayClass 'eg' exists..."
kubectl apply -f - <<'GWCLASS'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
GWCLASS

# ── 3. cert-manager ─────────────────────────────────────────────────────────
echo ""
echo "==> Installing cert-manager (v1.17.2)..."
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --version v1.17.2 \
  -n cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait

# ── 4. External Secrets Operator ─────────────────────────────────────────────
echo ""
echo "==> Installing External Secrets Operator..."
helm repo add external-secrets https://charts.external-secrets.io --force-update
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --set serviceAccount.annotations."eks\.amazonaws\.io/role-arn"="$IRSA_ROLE_ARN" \
  --wait

# ── 5. Argo CD ───────────────────────────────────────────────────────────────
echo ""
echo "==> Installing Argo CD CRDs..."
kubectl apply -k "https://github.com/argoproj/argo-cd/manifests/crds?ref=v2.14.11"

echo ""
echo "==> Installing Argo CD..."
helm dependency build "$UAT_DIR/argocd" 2>/dev/null || true
helm upgrade --install argo-cd "$UAT_DIR/argocd" \
  -f "$UAT_DIR/argocd/values.yaml" \
  --set awsAccountId="$AWS_ACCOUNT_ID" \
  -n argocd \
  --wait

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  UAT EKS stack installed."
echo "============================================================"
echo ""
echo "Argo CD deploys all apps via the ApplicationSet (platform,"
echo "auth-service, score-service, session-service, shooter)."
echo ""
echo "Next steps:"
echo ""
echo "  1. Check Argo apps are syncing:"
echo "     kubectl get applications -n argocd"
echo ""
echo "  2. Get the Gateway LoadBalancer address (may take a few minutes):"
echo "     kubectl get gateway uat-public -n uat"
echo ""
echo "  3. Once the LB has an address, update Terraform to create the"
echo "     Route 53 alias and re-apply:"
echo "       terraform -chdir=$TF_DIR apply \\"
echo "         -var uat_gateway_lb_dns_name=<LB_DNS> \\"
echo "         -var uat_gateway_lb_hosted_zone_id=<LB_ZONE_ID>"
echo ""
echo "  4. After the TLS Certificate is Ready, enable HTTPS in the"
echo "     platform chart (gateway.enableHttpsListener=true) and re-sync."
echo ""
echo "  Argo CD UI:  kubectl port-forward svc/argo-cd-argocd-server -n argocd 8080:443"
echo "  Admin pass:  kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
