import json
import os
import time
import boto3

ec2 = boto3.client("ec2", region_name="us-east-1")
ssm = boto3.client("ssm", region_name="us-east-1")

SUBNET_ID = os.environ["SUBNET_ID"]
SG_ID = os.environ["SG_ID"]
AMI_ID = os.environ["AMI_ID"]
INSTANCE_PROFILE = os.environ["INSTANCE_PROFILE"]


def launch_instance():
    resp = ec2.run_instances(
        ImageId=AMI_ID,
        InstanceType="t3.medium",
        MinCount=1,
        MaxCount=1,
        IamInstanceProfile={"Name": INSTANCE_PROFILE},
        SubnetId=SUBNET_ID,
        SecurityGroupIds=[SG_ID],
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


def run_qa(instance_id, qa_images=""):
    commands = [
        "echo Downloading QA files from S3...",
        "export PATH=/home/ssm-user/.docker/cli-plugins:$PATH",
        f"export QA_IMAGES='{qa_images}'",
        "yum install -y jq",
        "aws s3 cp s3://godot-eks-qa-2025/qa ./qa --recursive --region us-east-1",
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
        result = run_qa(instance_id, qa_images)
        return {"statusCode": 200, "instance_id": instance_id, **result}
    except Exception as e:
        print(f"Error: {e}")
        return {"statusCode": 500, "error": str(e), "instance_id": instance_id}
    finally:
        if instance_id:
            print(f"Terminating instance: {instance_id}")
            ec2.terminate_instances(InstanceIds=[instance_id])
