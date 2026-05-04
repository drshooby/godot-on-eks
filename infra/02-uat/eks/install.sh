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
#   ALB (Terraform) → NodePort (Kong) → Ingress → Service → Pod
#   TLS terminates at the ALB (ACM cert). Kong speaks plain HTTP internally.
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
# Kept for visibility / debugging; the ESO install no longer consumes it (Pod Identity
# handles the role binding in Terraform via aws_eks_pod_identity_association).
ESO_ROLE_ARN="$(terraform -chdir="$TF_DIR" output -raw external_secrets_irsa_role_arn)"
CLUSTER_NAME="$(terraform -chdir="$TF_DIR" output -raw cluster_name)"
INGRESS_NODEPORT="$(terraform -chdir="$TF_DIR" output -raw ingress_http_nodeport)"

echo "  Account:           $AWS_ACCOUNT_ID"
echo "  Region:            $AWS_REGION"
echo "  Cluster:           $CLUSTER_NAME"
echo "  ESO role: $ESO_ROLE_ARN (bound via EKS Pod Identity)"
echo "  Ingress controller: Kong"
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

# ── 1a. EKS Pod Identity agent ───────────────────────────────────────────────
# Installed as an EKS managed addon by Terraform (see eks.tf). Workloads get AWS
# creds via aws_eks_pod_identity_association — no IRSA token projection hackery.
# Fail fast if the addon DaemonSet isn't healthy, otherwise ESO will just spin
# on InvalidProviderConfig later.
echo ""
echo "==> Waiting for eks-pod-identity-agent DaemonSet to be Ready..."
kubectl -n kube-system rollout status daemonset/eks-pod-identity-agent --timeout=120s

# ── 2. Traefik ingress controller ────────────────────────────────────────────
# Service type=NodePort: the Terraform ALB target group forwards to
# INGRESS_NODEPORT on every EKS node. Registers IngressClass "kong" for app
# charts (shooter, …) via ingress.className.
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

# ── 3. External Secrets Operator ─────────────────────────────────────────────
echo ""
echo "==> Installing External Secrets Operator..."
helm repo add external-secrets https://charts.external-secrets.io --force-update
# Pod Identity supplies AWS creds directly via the eks-pod-identity-agent
# DaemonSet + aws_eks_pod_identity_association (see terraform/iam.tf). No
# serviceAccount annotation, no projected token volume, no AWS_* env wiring —
# the agent mutates the pod with an IMDS-style credential endpoint at admission.
# AWS_REGION is still useful so the SDK doesn't have to guess.
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --set "extraEnv[0].name=AWS_REGION" \
  --set "extraEnv[0].value=$AWS_REGION" \
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
  --set ingressClassName=kong \
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
echo "         → Kong NodePort $INGRESS_NODEPORT"
echo "           → Ingress → Services"
echo ""
echo "Next steps:"
echo ""
echo "  1. Check Argo apps are syncing:"
echo "     kubectl get applications -n argocd"
echo ""
echo "  2. Confirm Kong registered the IngressClass and is receiving targets:"
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
