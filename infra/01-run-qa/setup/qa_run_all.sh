#!/bin/bash

set -euo pipefail

echo " Starting QA..."

cd ./qa

chmod +x *.sh

echo " Verifying contents of $(pwd)..."
ls -la

echo " Docker version:"
docker --version || echo " Docker not installed"

echo " Docker daemon status:"
systemctl is-active docker || echo " Docker not running"

echo " Pulling latest QA images..."
./pull_images.sh

echo "Docker ps -a before compose!"
docker ps -a

echo "Checking pulled images"
docker images

echo " Spinning up QA environment..."
./compose.sh

echo " Waiting for containers to initialize..."
sleep 10

echo "Docker ps -a after compose!"
docker ps -a

echo " Running smoke tests..."
./smoke_test.sh

echo " QA complete."

echo " Tagging images for UAT..."
./tag_uat.sh

echo " Successfully retagged images for UAT."
