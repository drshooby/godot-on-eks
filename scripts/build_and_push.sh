#!/usr/bin/env bash
# Usage: ./build_and_push.sh DIR_PATH AWS_ACCOUNT_ID ENV [REGION]
#   DIR_PATH: "backend/<service>" or "shooter"
#   Backend services use the shared Dockerfile.jvm with MODULE arg.
#   Shooter builds directly from its own Dockerfile.
#
# Tagging scheme:
#   Immutable build tag:  {service}:{env}-{date}-{gitsha7}
#   Mutable env pointer:  {service}:{env}-latest
#   (Semver release tags {service}:{vX.Y.Z} are added separately on release cuts.)
set -euo pipefail

DIR="$1"                  # e.g. "backend/auth-service" or "shooter"
ACCOUNT="$2"
ENVIRONMENT="$3"          # e.g. "qa", "uat", etc.
REGION="${4:-us-east-1}"

SERVICE_NAME="$(basename "$DIR")"
REPO="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$SERVICE_NAME"

DATE="$(date +%Y%m%d)"

# Prefer CI-provided GITHUB_SHA; fall back to local git rev-parse.
RAW_SHA="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo '')}"
if [[ -z "$RAW_SHA" ]]; then
  echo "Unable to determine git SHA (set GITHUB_SHA or run inside a git repo)" >&2
  exit 1
fi
GITSHA7="${RAW_SHA:0:7}"

BUILD_TAG="${ENVIRONMENT}-${DATE}-${GITSHA7}"
POINTER_TAG="${ENVIRONMENT}-latest"

echo "Building $SERVICE_NAME from $DIR"
echo "   build tag   : $BUILD_TAG"
echo "   pointer tag : $POINTER_TAG"

# Opt-in buildx cache wiring. When BUILDX_CACHE_FROM / BUILDX_CACHE_TO are set
# (e.g. in CI with type=gha,scope=<service>), append the flags to both buildx
# invocations. Local runs with the vars unset stay unchanged.
CACHE_ARGS=()
if [[ -n "${BUILDX_CACHE_FROM:-}" ]]; then
  CACHE_ARGS+=(--cache-from "$BUILDX_CACHE_FROM")
fi
if [[ -n "${BUILDX_CACHE_TO:-}" ]]; then
  CACHE_ARGS+=(--cache-to "$BUILDX_CACHE_TO")
fi

if [[ "$DIR" == backend/* ]]; then
  docker buildx build --platform linux/amd64 \
    -f backend/docker/Dockerfile.jvm \
    --build-arg "MODULE=$SERVICE_NAME" \
    "${CACHE_ARGS[@]}" \
    -t "$REPO:$BUILD_TAG" \
    --load \
    backend
else
  docker buildx build --platform linux/amd64 \
    "${CACHE_ARGS[@]}" \
    -t "$REPO:$BUILD_TAG" \
    --load \
    "$DIR"
fi

echo "Pushing $REPO:$BUILD_TAG"
docker push "$REPO:$BUILD_TAG"

echo "Fetching image manifest for $BUILD_TAG"
MANIFEST=$(aws ecr batch-get-image \
  --repository-name "$SERVICE_NAME" \
  --image-ids imageTag="$BUILD_TAG" \
  --query 'images[].imageManifest' \
  --output text \
  --region "$REGION")

if [[ -z "$MANIFEST" || "$MANIFEST" == "None" ]]; then
  echo "Failed to fetch manifest for tag $BUILD_TAG"
  exit 1
fi

# Move the mutable env pointer to the new build digest.
echo "Deleting existing $POINTER_TAG tag (if present)..."
aws ecr batch-delete-image \
  --repository-name "$SERVICE_NAME" \
  --image-ids imageTag="$POINTER_TAG" \
  --region "$REGION" || true

echo "Tagging $SERVICE_NAME:$BUILD_TAG as $POINTER_TAG"
aws ecr put-image \
  --repository-name "$SERVICE_NAME" \
  --image-tag "$POINTER_TAG" \
  --image-manifest "$MANIFEST" \
  --region "$REGION"

echo "Successfully pushed:"
echo "   • $REPO:$BUILD_TAG (immutable)"
echo "   • $REPO:$POINTER_TAG (now points to $BUILD_TAG)"

# Write manifest entry for downstream QA consumption.
mkdir -p /tmp/qa-manifest
echo "$BUILD_TAG" > "/tmp/qa-manifest/${SERVICE_NAME}"
