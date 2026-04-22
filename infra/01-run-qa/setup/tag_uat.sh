#!/bin/bash
# Promote the QA digests listed in qa_images.txt to the `uat-latest` pointer.
# The source immutable tag (e.g. qa-20260419-a1b2c3d) stays intact in ECR by
# virtue of digest-preserving `ecr put-image`; we only move the pointer.
set -euo pipefail

echo " Tagging QA images as UAT..."
REGION="us-east-1"
INPUT_FILE="$(pwd)/qa_images.txt"
POINTER_TAG="uat-latest"

if [ ! -f "$INPUT_FILE" ]; then
  echo " Error: $INPUT_FILE not found. Please run pull_images.sh first."
  exit 1
fi

while IFS=, read -r repo digest; do
  echo " Processing $repo with digest $digest..."

  if [ -z "$digest" ] || [ "$digest" == "None" ]; then
    echo " No digest information for $repo"
    continue
  fi

  manifest=$(aws ecr batch-get-image \
    --repository-name "$repo" \
    --image-ids imageDigest="$digest" \
    --region "$REGION" \
    --query "images[0].imageManifest" \
    --output text)

  if [ -z "$manifest" ] || [ "$manifest" == "None" ]; then
    echo " Failed to get manifest for $repo with digest $digest"
    continue
  fi

  echo " Deleting existing '$POINTER_TAG' tag (if present) for $repo..."
  aws ecr batch-delete-image \
    --repository-name "$repo" \
    --image-ids imageTag="$POINTER_TAG" \
    --region "$REGION" || true

  echo " Tagging $repo digest $digest as '$POINTER_TAG'..."
  aws ecr put-image \
    --repository-name "$repo" \
    --image-tag "$POINTER_TAG" \
    --image-manifest "$manifest" \
    --region "$REGION"

  echo " Tagged $repo image as '$POINTER_TAG'"
done < "$INPUT_FILE"

echo " All applicable images now tagged with '$POINTER_TAG'."
