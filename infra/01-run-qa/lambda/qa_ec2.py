import base64
import os
import time
import boto3

ec2 = boto3.client("ec2", region_name="us-east-1")
ssm = boto3.client("ssm", region_name="us-east-1")

SUBNET_ID = os.environ["SUBNET_ID"]
SG_ID = os.environ["SG_ID"]
AMI_ID = os.environ["AMI_ID"]
INSTANCE_PROFILE = os.environ["INSTANCE_PROFILE"]
QA_BUCKET = os.environ["QA_BUCKET"]

# Bootstrap script executed as root via EC2 user data on first boot.
# Installs Docker + the compose plugin on stock Amazon Linux so the ephemeral
# QA instance can run docker-compose workloads. Kept small and idempotent so
# it re-runs safely if we ever retry.
#
# We also symlink the v2 compose plugin to /usr/local/bin/docker-compose
# because existing QA scripts (compose.sh) still call the hyphenated v1 name.
USER_DATA = r"""#!/bin/bash
set -eux
exec > >(tee -a /var/log/qa-bootstrap.log) 2>&1

if command -v dnf >/dev/null 2>&1; then
  PKG=dnf
else
  PKG=yum
fi

$PKG install -y docker jq
systemctl enable --now docker

COMPOSE_VERSION="v2.27.0"
COMPOSE_DIR="/usr/libexec/docker/cli-plugins"
mkdir -p "$COMPOSE_DIR"
curl -fsSL \
  "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  -o "$COMPOSE_DIR/docker-compose"
chmod +x "$COMPOSE_DIR/docker-compose"

# Backwards-compat shim for scripts that still invoke v1-style `docker-compose`.
ln -sf "$COMPOSE_DIR/docker-compose" /usr/local/bin/docker-compose

echo "qa-bootstrap: docker $(docker --version)"
echo "qa-bootstrap: compose $(docker compose version)"
touch /var/lib/qa-bootstrap.done
"""


def launch_instance():
    resp = ec2.run_instances(
        ImageId=AMI_ID,
        InstanceType="t3.medium",
        MinCount=1,
        MaxCount=1,
        IamInstanceProfile={"Name": INSTANCE_PROFILE},
        SubnetId=SUBNET_ID,
        SecurityGroupIds=[SG_ID],
        UserData=base64.b64encode(USER_DATA.encode("utf-8")).decode("ascii"),
        TagSpecifications=[{
            "ResourceType": "instance",
            "Tags": [
                {"Key": "Name", "Value": "QA-ephemeral"},
                {"Key": "Purpose", "Value": "qa-ephemeral"},
                {"Key": "CreatedAt", "Value": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
            ],
        }],
    )
    instance_id = resp["Instances"][0]["InstanceId"]
    print(f"Launched instance: {instance_id}")
    return instance_id


def wait_for_ssm(instance_id, max_attempts=40, interval=7):
    for attempt in range(1, max_attempts + 1):
        resp = ssm.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
        )
        info_list = resp.get("InstanceInformationList", [])
        if info_list and info_list[0].get("PingStatus") == "Online":
            print(f"Instance {instance_id} is SSM-online (attempt {attempt})")
            return
        print(f"Attempt {attempt}/{max_attempts}: waiting for SSM...")
        time.sleep(interval)
    raise TimeoutError(f"Instance {instance_id} did not become SSM-online after {max_attempts} attempts")


def _run_ssm_blocking(instance_id, commands, timeout_seconds, label, poll_interval=5, poll_attempts=24):
    """Send a short SSM command and block until it succeeds/fails/times out."""
    resp = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Comment=label,
        Parameters={"commands": commands},
        TimeoutSeconds=timeout_seconds,
    )
    command_id = resp["Command"]["CommandId"]
    for _ in range(poll_attempts):
        time.sleep(poll_interval)
        try:
            inv = ssm.get_command_invocation(CommandId=command_id, InstanceId=instance_id)
        except ssm.exceptions.InvocationDoesNotExist:
            continue
        status = inv["Status"]
        if status in ("Success", "Failed", "Cancelled", "TimedOut"):
            return status, inv.get("StandardOutputContent", ""), inv.get("StandardErrorContent", "")
    return "TimedOut", "", ""


def wait_for_docker(instance_id, max_attempts=30, interval=10):
    """Poll the instance via SSM until the user-data bootstrap finished and
    the Docker daemon answers. Bootstrap drops a sentinel file at
    /var/lib/qa-bootstrap.done once it's complete."""
    check = [
        "test -f /var/lib/qa-bootstrap.done",
        "docker info >/dev/null 2>&1",
    ]
    for attempt in range(1, max_attempts + 1):
        status, stdout, stderr = _run_ssm_blocking(
            instance_id,
            check,
            timeout_seconds=30,
            label=f"qa-docker-readiness-{attempt}",
            poll_interval=3,
            poll_attempts=10,
        )
        if status == "Success":
            print(f"Docker is ready (attempt {attempt})")
            return
        print(f"Attempt {attempt}/{max_attempts}: docker not ready yet ({status})")
        time.sleep(interval)
    raise TimeoutError(f"Instance {instance_id} Docker did not come online in time")


def run_qa(instance_id, qa_images=""):
    commands = [
        "echo Downloading QA files from S3...",
        f"export QA_IMAGES='{qa_images}'",
        f"aws s3 cp s3://{QA_BUCKET}/qa ./qa --recursive --region us-east-1",
        "chmod +x ./qa/*.sh",
        "./qa/qa_run_all.sh",
    ]
    resp = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Comment="QA Run",
        Parameters={"commands": commands},
        TimeoutSeconds=600,
    )
    command_id = resp["Command"]["CommandId"]
    print(f"Sent SSM command: {command_id}")

    for attempt in range(1, 61):
        time.sleep(10)
        resp = ssm.list_command_invocations(
            CommandId=command_id, Details=True
        )
        invocations = resp.get("CommandInvocations", [])
        if not invocations:
            print(f"Poll {attempt}/60: no invocations yet")
            continue
        status = invocations[0]["Status"]
        print(f"Poll {attempt}/60: {status}")
        if status in ("Success", "Failed", "Cancelled", "TimedOut"):
            output_resp = ssm.get_command_invocation(
                CommandId=command_id, InstanceId=instance_id
            )
            return {
                "status": status,
                "stdout": output_resp.get("StandardOutputContent", ""),
                "stderr": output_resp.get("StandardErrorContent", ""),
            }

    raise TimeoutError(f"SSM command {command_id} did not complete in time")


def handler(event, context):
    instance_id = None
    try:
        qa_images = event.get("qa_images", "")
        instance_id = launch_instance()
        wait_for_ssm(instance_id)
        wait_for_docker(instance_id)
        result = run_qa(instance_id, qa_images)
        return {"statusCode": 200, "instance_id": instance_id, **result}
    except Exception as e:
        print(f"Error: {e}")
        return {"statusCode": 500, "error": str(e), "instance_id": instance_id}
    finally:
        if instance_id:
            print(f"Terminating instance: {instance_id}")
            ec2.terminate_instances(InstanceIds=[instance_id])
