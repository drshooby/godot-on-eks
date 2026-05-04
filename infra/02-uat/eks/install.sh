#!/usr/bin/env bash
# Full UAT stack install on EKS.
# Run from anywhere; paths are resolved relative to the repo root.
#
# Prerequisites:
#   - Terraform applied (infra/02-uat/terraform) — creates VPC, EKS, RDS,
#     ALB, ACM cert, Route53 record
#   - kubeconfig updated: eval "$(terraform -chdir=infra/02-uat/terraform output -raw configure_kubectl)"
#   - helm 3
#   - Images pushed to ECR (tag uat-latest)
#
# Edge architecture:
#   ALB (Terraform) → NodePort (Traefik|Kong) → Ingress → Service → Pod
#   TLS terminates at the ALB (ACM cert). The ingress controller speaks plain
#   HTTP internally.
#
# Ingress controller selection:
#   - Default: Traefik (matches Terraform var.ingress_controller default).
#   - Override: INGRESS_CONTROLLER=kong infra/02-uat/eks/install.sh
#     (or set var.ingress_controller="kong" in terraform.tfvars and re-apply
#     so the output drives this script).
#   Both controllers bind the same NodePort (var.ingress_http_nodeport, default
#   30080) so the ALB target group is identical and switching does not require
#   a Terraform apply — uninstall one helm release, install the other, flip
#   ingressClassName on app charts.
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
INGRESS_NODEPORT="$(terraform -chdir="$TF_DIR" output -raw ingress_http_nodeport)"

# Env var wins over the Terraform output so you can flip controllers without a
# re-apply (the ALB target group port is the same either way).
INGRESS_CONTROLLER="${INGRESS_CONTROLLER:-$(terraform -chdir="$TF_DIR" output -raw ingress_controller 2>/dev/null || echo traefik)}"
case "$INGRESS_CONTROLLER" in
  traefik|kong) ;;
  *) echo "ERROR: INGRESS_CONTROLLER must be 'traefik' or 'kong' (got '$INGRESS_CONTROLLER')."; exit 1 ;;
esac

echo "  Account:           $AWS_ACCOUNT_ID"
echo "  Region:            $AWS_REGION"
echo "  Cluster:           $CLUSTER_NAME"
echo "  IRSA ARN:          $IRSA_ROLE_ARN"
echo "  Ingress controller:$INGRESS_CONTROLLER"
echo "  Ingress NodePort:  $INGRESS_NODEPORT"

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

# ── 2. Ingress controller ────────────────────────────────────────────────────
# Service type=NodePort: the Terraform ALB target group forwards to
# INGRESS_NODEPORT on every EKS node. Registers an IngressClass that app
# charts (shooter, …) attach to via ingress.className.
if [[ "$INGRESS_CONTROLLER" == "traefik" ]]; then
  echo ""
  echo "==> Installing Traefik (v34.x)..."
  helm repo add traefik https://traefik.github.io/charts --force-update
  helm upgrade --install traefik traefik/traefik \
    --version 34.2.0 \
    -n traefik \
    --create-namespace \
    --set "service.type=NodePort" \
    --set "ports.web.nodePort=${INGRESS_NODEPORT}" \
    --set "ports.web.redirectTo=null" \
    --set "ingressClass.enabled=true" \
    --set "ingressClass.isDefaultClass=true" \
    --set "ingressClass.name=traefik" \
    --wait
else
  # Kong DB-less, ingress-controller-only mode. Same NodePort as Traefik so the
  # ALB target group does not change. ingressController.installCRDs=true lets
  # the chart install Kong's CRDs (KongPlugin, KongClusterPlugin, …) so
  # konghq.com annotations work on Ingress resources later.
  echo ""
  echo "==> Installing Kong (v3.2.0)..."
  helm repo add kong https://charts.konghq.com --force-update
  helm upgrade --install kong kong/kong \
    --version 3.2.0 \
    -n kong \
    --create-namespace \
    --set "ingressController.installCRDs=true" \
    --set "ingressController.ingressClass=kong" \
    --set "proxy.type=NodePort" \
    --set "proxy.http.enabled=true" \
    --set "proxy.http.nodePort=${INGRESS_NODEPORT}" \
    --set "proxy.tls.enabled=false" \
    --wait
fi

# ── 3. External Secrets Operator ─────────────────────────────────────────────
echo ""
echo "==> Installing External Secrets Operator..."
helm repo add external-secrets https://charts.external-secrets.io --force-update
# Explicit IRSA volume/env — the EKS pod-identity-webhook silently fails to inject
# these on some clusters (failurePolicy: Ignore). See README "Known issues".
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$IRSA_ROLE_ARN" \
  --set "extraVolumes[0].name=aws-iam-token" \
  --set "extraVolumes[0].projected.sources[0].serviceAccountToken.audience=sts.amazonaws.com" \
  --set "extraVolumes[0].projected.sources[0].serviceAccountToken.expirationSeconds=86400" \
  --set "extraVolumes[0].projected.sources[0].serviceAccountToken.path=token" \
  --set "extraVolumeMounts[0].name=aws-iam-token" \
  --set "extraVolumeMounts[0].mountPath=/var/run/secrets/eks.amazonaws.com/serviceaccount" \
  --set "extraVolumeMounts[0].readOnly=true" \
  --set "extraEnv[0].name=AWS_WEB_IDENTITY_TOKEN_FILE" \
  --set "extraEnv[0].value=/var/run/secrets/eks.amazonaws.com/serviceaccount/token" \
  --set "extraEnv[1].name=AWS_ROLE_ARN" \
  --set "extraEnv[1].value=$IRSA_ROLE_ARN" \
  --set "extraEnv[2].name=AWS_REGION" \
  --set "extraEnv[2].value=$AWS_REGION" \
  --wait

# ── 4. Argo CD ───────────────────────────────────────────────────────────────
echo ""
echo "==> Installing Argo CD CRDs..."
kubectl apply -k "https://github.com/argoproj/argo-cd/manifests/crds?ref=v2.14.11"

echo ""
echo "==> Installing Argo CD..."
helm dependency build "$UAT_DIR/argocd" 2>/dev/null || true
helm upgrade --install argo-cd "$UAT_DIR/argocd" \
  -f "$UAT_DIR/argocd/values.yaml" \
  --set awsAccountId="$AWS_ACCOUNT_ID" \
  --set ingressClassName="$INGRESS_CONTROLLER" \
  -n argocd \
  --wait

# ── Done ─────────────────────────────────────────────────────────────────────
UAT_FQDN="$(terraform -chdir="$TF_DIR" output -raw uat_fqdn)"
ALB_DNS="$(terraform -chdir="$TF_DIR" output -raw alb_dns_name)"

echo ""
echo "============================================================"
echo "  UAT EKS stack installed."
echo "============================================================"
echo ""
echo "Argo CD deploys all apps via the ApplicationSet (platform,"
echo "auth-service, score-service, session-service, shooter)."
echo ""
echo "Edge:  ALB ($ALB_DNS)"
echo "         → $INGRESS_CONTROLLER NodePort $INGRESS_NODEPORT"
echo "           → Ingress → Services"
echo ""
echo "Next steps:"
echo ""
echo "  1. Check Argo apps are syncing:"
echo "     kubectl get applications -n argocd"
echo ""
echo "  2. Confirm $INGRESS_CONTROLLER registered the IngressClass and is receiving targets:"
echo "     kubectl get ingressclass"
echo "     aws elbv2 describe-target-health \\"
echo "       --target-group-arn \"\$(aws elbv2 describe-target-groups \\"
echo "         --names \$(terraform -chdir=$TF_DIR output -raw ingress_target_group_name) \\"
echo "         --query 'TargetGroups[0].TargetGroupArn' --output text)\""
echo ""
echo "  3. Once Argo syncs shooter, verify: https://$UAT_FQDN"
echo ""
echo "  Argo CD UI:  kubectl port-forward svc/argo-cd-argocd-server -n argocd 8080:443"
echo "  Admin pass:  kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
