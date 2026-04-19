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

# Delete existing tag if present
echo "Deleting existing $ENVIRONMENT tag (if present)..."
aws ecr batch-delete-image \
  --repository-name "$SERVICE_NAME" \
  --image-ids imageTag="$ENVIRONMENT" \
  --region "$REGION" || true

# Put new tag
echo "Promoting $SERVICE_NAME:$SORTABLE_TAG to $ENVIRONMENT"
aws ecr put-image \
  --repository-name "$SERVICE_NAME" \
  --image-tag "$ENVIRONMENT" \
  --image-manifest "$MANIFEST" \
  --region "$REGION"

echo "Successfully promoted:"
echo "   • $REPO:$SORTABLE_TAG"
echo "   • $REPO:$ENVIRONMENT (now points to $SORTABLE_TAG)"