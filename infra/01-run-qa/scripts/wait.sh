#!/bin/bash

set -euo pipefail

INSTANCE_ID="$1"
REGION="us-east-1"

echo " Waiting for EC2 instance $INSTANCE_ID to become SSM-managed..."

attempt=1
while true; do
  STATUS=$(aws ssm describe-instance-information \
    --region "$REGION" \
    --query "InstanceInformationList[?InstanceId=='${INSTANCE_ID}'].PingStatus | [0]" \
    --output text 2>/dev/null || echo "none")

  if [[ "$STATUS" == "Online" ]]; then
    echo " Instance $INSTANCE_ID is online in SSM and ready."
    exit 0
  fi

  if [[ $attempt -ge 40 ]]; then
    echo " Timed out waiting for SSM after $attempt attempts."
    exit 1
  fi

  echo " Attempt $attempt: SSM status: $STATUS. Waiting 7s..."
  sleep 7
  ((attempt++))
done
