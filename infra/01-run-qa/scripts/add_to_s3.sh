#!/bin/bash

set -euo pipefail

BUCKET_NAME="godot-eks-qa-2025"
SOURCE_DIR="./infra/01-run-qa/setup"

if [ ! -d "$SOURCE_DIR" ]; then
  echo " Directory '$SOURCE_DIR' does not exist."
  exit 1
fi

echo " Uploading all files from '$SOURCE_DIR/' to s3://$BUCKET_NAME/qa/"

aws s3 cp "$SOURCE_DIR" "s3://$BUCKET_NAME/qa/" --recursive

echo " Upload complete."
