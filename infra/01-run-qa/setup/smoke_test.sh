#!/bin/bash

set -euo pipefail

echo " Running smoke tests..."
echo " Checking service health endpoints..."

check_service() {
  local name=$1
  local url=$2
  local expected=$3

  response=$(curl -fs "$url" || true)
  if [[ "$response" == *"$expected"* ]]; then
    echo " $name is up"
  else
    echo " $name failed"
    echo "$response"
    exit 1
  fi
}

check_service "auth-service"    "http://localhost:8081/health"  "ok"
check_service "score-service"   "http://localhost:8082/health"  "ok"
check_service "session-service" "http://localhost:8083/health"  "ok"
# skip shooter for now