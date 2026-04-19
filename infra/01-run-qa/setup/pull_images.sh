#!/bin/bash
set -euo pipefail

REPOS=("shooter" "auth-service" "score-service" "session-service")
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
REGION="us-east-1"
ECR_URL="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
OUTPUT_FILE="$(pwd)/qa_images.txt"

> "$OUTPUT_FILE"

# Parse QA_IMAGES into an associative array if set (format: "service1:tag1,service2:tag2")
declare -A IMAGE_TAGS
if [ -n "${QA_IMAGES:-}" ]; then
  echo " Using exact image tags from build manifest"
  IFS=',' read -ra PAIRS <<< "$QA_IMAGES"
  for pair in "${PAIRS[@]}"; do
    SERVICE="${pair%%:*}"
    TAG="${pair#*:}"
    IMAGE_TAGS["$SERVICE"]="$TAG"
  done
fi

echo " Logging into ECR..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_URL"

for repo in "${REPOS[@]}"; do
  if [ -n "${IMAGE_TAGS[$repo]:-}" ]; then
    TAG="${IMAGE_TAGS[$repo]}"
    echo " Pulling $repo:$TAG (exact tag from manifest)"
    docker pull "$ECR_URL/$repo:$TAG"
    docker tag "$ECR_URL/$repo:$TAG" "$repo"

    DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$ECR_URL/$repo:$TAG" | cut -d'@' -f2)
    echo "$repo,$DIGEST" >> "$OUTPUT_FILE"
  else
    echo " No manifest entry for $repo, pulling qa tag..."
    docker pull "$ECR_URL/$repo:qa"
    docker tag "$ECR_URL/$repo:qa" "$repo"

    DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$ECR_URL/$repo:qa" | cut -d'@' -f2)
    echo "$repo,$DIGEST" >> "$OUTPUT_FILE"
  fi
done

echo " QA image pull and tagging complete. Image information saved to $OUTPUT_FILE"
