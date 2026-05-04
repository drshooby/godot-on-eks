#!/usr/bin/env bash
# Full UAT stack install for Docker Desktop Kubernetes.
# Run from anywhere; paths are resolved relative to the repo root.
#
# Prerequisites:
#   - Docker Desktop with Kubernetes enabled
#   - kubectl context set to docker-desktop
#   - helm 3
#   - Images built locally (see "Build images" section below)
#
# Build images first:
#   docker build -f backend/docker/Dockerfile.jvm --build-arg MODULE=auth-service    -t auth-service:uat-latest    ./backend
#   docker build -f backend/docker/Dockerfile.jvm --build-arg MODULE=score-service   -t score-service:uat-latest   ./backend
#   docker build -f backend/docker/Dockerfile.jvm --build-arg MODULE=session-service -t session-service:uat-latest ./backend
#   docker build -f shooter/Dockerfile                                                -t shooter:uat-latest          ./shooter
#
# To tear everything down:
#   infra/02-uat/local/teardown.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
UAT_DIR="$REPO_ROOT/infra/02-uat"

# ── 0. Sanity check ──────────────────────────────────────────────────────────
CONTEXT=$(kubectl config current-context)
if [[ "$CONTEXT" != "docker-desktop" ]]; then
  echo "ERROR: current kubectl context is '$CONTEXT', expected 'docker-desktop'."
  echo "  Switch with: kubectl config use-context docker-desktop"
  exit 1
fi
echo "Context: $CONTEXT  ✓"

# ── 1. Namespaces ────────────────────────────────────────────────────────────
echo ""
echo "==> Applying namespaces..."
kubectl apply -f "$UAT_DIR/namespaces.yaml"

# ── 2. Kong Ingress Controller ───────────────────────────────────────────────
# Locally Kong runs as LoadBalancer so Docker Desktop exposes it on localhost.
# On EKS the service is NodePort behind a Terraform-managed ALB.
echo ""
echo "==> Installing Kong (v3.2.0)..."
helm repo add kong https://charts.konghq.com --force-update
helm upgrade --install kong kong/kong \
  --version 3.2.0 \
  -n kong \
  --create-namespace \
  --set "ingressController.installCRDs=true" \
  --set "ingressController.ingressClass=kong" \
  --set "proxy.type=LoadBalancer" \
  --set "proxy.http.enabled=true" \
  --set "proxy.tls.enabled=false" \
  --wait

# ── 3. MySQL ─────────────────────────────────────────────────────────────────
echo ""
echo "==> Deploying MySQL..."
kubectl apply -f "$SCRIPT_DIR/mysql.yaml"

echo "Waiting for MySQL to be ready (this can take ~60s on first pull)..."
kubectl rollout status statefulset/mysql -n uat --timeout=180s

# ── 4. App secrets ───────────────────────────────────────────────────────────
# Credentials must match mysql-local-creds in mysql.yaml.
# JWT_SECRET must be the same across all three services.
echo ""
echo "==> Creating app secrets..."

JWT_SECRET="local-dev-jwt-secret-minimum-32-chars!!"

for SVC in auth-service score-service session-service; do
  kubectl create secret generic "${SVC}-env" -n uat \
    --from-literal=DATABASE_HOST=mysql \
    --from-literal=DATABASE_PORT=3306 \
    --from-literal=DATABASE_NAME=fps \
    --from-literal=DATABASE_USER=fps \
    --from-literal=DATABASE_PASSWORD=fps-local \
    --from-literal=JWT_SECRET="$JWT_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -
done

# ── 5. Platform chart (ClusterSecretStore only; skipped locally) ─────────────
echo ""
echo "==> Installing platform chart..."
helm upgrade --install platform "$UAT_DIR/helm/platform" \
  -n uat \
  -f "$SCRIPT_DIR/platform-values.yaml" \
  --wait

# ── 6. Service charts ────────────────────────────────────────────────────────
echo ""
echo "==> Installing service charts..."

for SVC in auth-service score-service session-service; do
  helm upgrade --install "$SVC" "$UAT_DIR/helm/$SVC" \
    -n uat \
    --set image.repository="$SVC" \
    --set image.tag=uat-latest \
    --set env.enabled=true \
    --set externalSecret.enabled=false \
    --wait
done

helm upgrade --install shooter "$UAT_DIR/helm/shooter" \
  -n uat \
  --set image.repository=shooter \
  --set image.tag=uat-latest \
  --set ingress.className=kong \
  --set ingress.hosts[0]=localhost \
  --wait

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "Done. Kong LoadBalancer should be reachable at http://localhost"
echo ""
echo "Check pod status:      kubectl get pods -n uat"
echo "Check Kong proxy:      kubectl get svc -n kong"
echo "Check Ingress:         kubectl get ingress -n uat"
echo "Shooter logs:          kubectl logs -n uat -l app.kubernetes.io/name=shooter"
