#!/usr/bin/env bash
# Usage: ./build_and_push.sh DIR_PATH AWS_ACCOUNT_ID ENV [REGION]
#   DIR_PATH: "backend/<service>" or "shooter"
#   Backend services use the shared Dockerfile.jvm with MODULE arg.
#   Shooter builds directly from its own Dockerfile.
set -euo pipefail

DIR="$1"                  # e.g. "backend/auth-service" or "shooter"
ACCOUNT="$2"
ENVIRONMENT="$3"          # e.g. "qa", "uat", etc.
REGION="${4:-us-east-1}"

SERVICE_NAME="$(basename "$DIR")"
REPO="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$SERVICE_NAME"

VERSION="$(tr -d '[:space:]' < VERSION)"
DATE="$(date +%Y%m%d)"
SORTABLE_TAG="${VERSION}-${DATE}"

echo "Building $SERVICE_NAME from $DIR"

if [[ "$DIR" == backend/* ]]; then
  docker buildx build --platform linux/amd64 \
    -f backend/docker/Dockerfile.jvm \
    --build-arg "MODULE=$SERVICE_NAME" \
    -t "$REPO:$SORTABLE_TAG" \
    backend
else
  docker buildx build --platform linux/amd64 \
    -t "$REPO:$SORTABLE_TAG" \
    "$DIR"
fi

echo "Pushing $REPO:$SORTABLE_TAG"
docker push "$REPO:$SORTABLE_TAG"

echo "Fetching image manifest for $SORTABLE_TAG"
MANIFEST=$(aws ecr batch-get-image \
  --repository-name "$SERVICE_NAME" \
  --image-ids imageTag="$SORTABLE_TAG" \
  --query 'images[].imageManifest' \
  --output text \
  --region "$REGION")

if [[ -z "$MANIFEST" || "$MANIFEST" == "None" ]]; then
  echo "Failed to fetch manifest for tag $SORTABLE_TAG"
  exit 1
fi

# Apply environment and latest tags to the same image
for TAG in "$ENVIRONMENT" "latest"; do
  echo "Deleting existing $TAG tag (if present)..."
  aws ecr batch-delete-image \
    --repository-name "$SERVICE_NAME" \
    --image-ids imageTag="$TAG" \
    --region "$REGION" || true

  echo "Tagging $SERVICE_NAME:$SORTABLE_TAG as $TAG"
  aws ecr put-image \
    --repository-name "$SERVICE_NAME" \
    --image-tag "$TAG" \
    --image-manifest "$MANIFEST" \
    --region "$REGION"
done

echo "Successfully promoted:"
echo "   • $REPO:$SORTABLE_TAG"
echo "   • $REPO:$ENVIRONMENT (now points to $SORTABLE_TAG)"
echo "   • $REPO:latest (now points to $SORTABLE_TAG)"

# Write manifest entry for downstream QA consumption
mkdir -p /tmp/qa-manifest
echo "$SORTABLE_TAG" > "/tmp/qa-manifest/${SERVICE_NAME}"