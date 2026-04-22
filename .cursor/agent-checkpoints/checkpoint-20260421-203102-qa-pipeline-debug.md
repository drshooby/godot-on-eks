## TL;DR (read this first)

- **Task**: Complete `CURRENT_TODO.md` items 1 (ECR tagging scheme) + 2 Option A (QA Lambda user-data bootstrap) + 3 (e2e verification). Originally statically done; now mid-runtime-debug.
- **Status**: in progress — runtime failure in `qa-runner` Lambda at docker-compose `mysql` pull. Root cause unknown; SSM's 24KB output cap is hiding the tail of the log.
- **Single next action**: `cd infra/00-setup && terraform apply` (provisions new `aws_cloudwatch_log_group.qa_ssm` and redeploys Lambda with `CloudWatchOutputConfig`), then re-run the QA GH Actions workflow, then `aws logs tail /aws/ssm/qa-runner --region us-east-1 --since 15m --format short | tail -300` to read the real error.
- **Blocker**: none — deploy-ready. Next agent just needs to apply + trigger + read CloudWatch.

## Copy-paste

- **Branch**: `main` (user has been working directly on main; uncommitted changes in working tree — no commits made this session).
- **Verify repo**: `/Users/david/Desktop/godot-on-eks`
- **Re-run to reproduce**:
  ```bash
  cd /Users/david/Desktop/godot-on-eks/infra/00-setup
  terraform apply
  # Trigger from GH UI: "Manual Build and Push All to ECR" → waits for "QA" workflow_run
  # OR: gh workflow run build_all_manual.yaml
  # Watch:
  aws logs tail /aws/ssm/qa-runner --region us-east-1 --follow --format short
  ```
- **Get last failed SSM command output (inline, truncated)**:
  ```bash
  CMD_ID=$(aws ssm list-commands --region us-east-1 --max-results 10 \
    --filters key=DocumentName,value=AWS-RunShellScript \
    --query 'Commands[?Comment==`QA Run`] | [0].CommandId' --output text)
  aws ssm list-command-invocations --region us-east-1 --command-id "$CMD_ID" --details \
    --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text
  ```
- **Get full output from CloudWatch (once terraform apply runs)**:
  ```bash
  aws logs tail /aws/ssm/qa-runner --region us-east-1 \
    --log-stream-name-prefix "$CMD_ID" --since 30m --format short
  ```

## Truth (do not skip)

| Claim | Verified how |
|-------|--------------|
| Branch is `main`, uncommitted dirty tree with 4 files | `git status --short` + `git branch --show-current` this session |
| Terraform config validates | `terraform fmt -check -diff && terraform validate` ran clean (required `terraform init -upgrade` after null provider removal) |
| Python syntax of `qa_ec2.py` valid | `python3 -c "import ast; ast.parse(...)"` clean |
| Last QA Run SSM command exit code = 1, stdout/stderr truncated at MySQL layer pull | `aws ssm list-command-invocations ... --command-id 5570fb36-...` — `ResponseCode: 1`, ends mid-progress `bb5107df7baa Downloading [>] 487.6kB/47.31MB` |
| STS endpoint timeout was bug #1 | SSM cmd `44537e5a-...` showed `Connect timeout on endpoint URL: "https://sts.us-east-1.amazonaws.com/"` |
| VPC now has NAT + public subnet | `vpc.tf` lines 9-19 — `public_subnets = ["10.0.101.0/24"]`, `enable_nat_gateway=true`, `single_nat_gateway=true` |
| CloudWatch log group wired into SSM `send_command` | `qa_ec2.py` around L155 has `CloudWatchOutputConfig={"CloudWatchLogGroupName": SSM_LOG_GROUP, "CloudWatchOutputEnabled": True}` |
| Instance profile covers `logs:PutLogEvents` for `/aws/ssm/*` | `iam.tf:25` attaches `AmazonSSMManagedInstanceCore` which includes those perms |
| Manifest system (QA_IMAGES) still in use | User asked if it's overkill; we decided to keep it for cherry-pick future use |

**Guesses / not verified** (next agent must confirm or discard):

- The actual cause of the MySQL pull failure is **unknown**. My top guesses in order:
  1. Disk full on 8 GB default root EBS (MySQL ~600MB pulled + 4 ECR service images + docker overhead)
  2. MySQL pull connection reset / timeout on a later layer
  3. MySQL healthcheck in compose never goes ready → `depends_on: condition: service_healthy` times out
  4. Smoke test assertion failure after all containers come up
- User has **not yet run `terraform apply`** with the CloudWatch changes. All code is staged in working tree, unapplied.
- Whether NAT alone fixes docker hub pull: strongly suspected yes (error from last run was `registry-1.docker.io` timeout, explicitly fixed by NAT), but unverified post-NAT.

## Files touched (paths only, 1 line each)

Session started from clean state on `main` after commit `6170d73`. All edits are uncommitted:

- `scripts/build_and_push.sh` — feat: new tag scheme `{env}-{YYYYMMDD}-{gitsha7}` + `{env}-latest` pointer, drops bare `latest`
- `.github/workflows/nightly_build.yaml` — feat: pass `GITHUB_SHA` env to build step
- `.github/workflows/build_all_manual.yaml` — feat: pass `GITHUB_SHA` env to build step
- `infra/01-run-qa/setup/pull_images.sh` — fix: fallback bare `qa` → `qa-latest`
- `infra/01-run-qa/setup/tag_uat.sh` — fix: retag as `uat-latest` (not bare `uat`)
- `infra/00-setup/ecr.tf` — feat: lifecycle rules (`qa-2`/`uat-2`/`prod-2`/`dev-2` prefix — leading `2` of YYYY excludes `-latest` pointers; `v*` semver kept long)
- `infra/00-setup/variables.tf` — fix: `qa_ami_id` description; removed `compose_version` (added/removed in-session)
- `infra/00-setup/lambda.tf` — feat: `aws_cloudwatch_log_group.qa_ssm` (`/aws/ssm/qa-runner`, 14d retention); `SSM_LOG_GROUP` env var
- `infra/00-setup/vpc.tf` — feat: `aws_vpc_endpoint.sts` + public subnet + single NAT gateway via terraform-aws-modules/vpc
- `infra/00-setup/s3.tf` — no net change (added then removed `null_resource.docker_compose_upload` when we switched from S3-hosted compose binary approach to NAT approach)
- `infra/00-setup/versions.tf` — no net change (added then removed `null` provider)
- `infra/01-run-qa/lambda/qa_ec2.py` — feat: `USER_DATA` bootstrap (dnf install docker+jq, curl compose plugin from github, symlink for v1 compat, sentinel `/var/lib/qa-bootstrap.done`); `wait_for_docker` with SSM polling (sentinel+`docker info` as SINGLE shell line so `&&` short-circuits); `InstanceType="t3.large"`; `CloudWatchOutputConfig` on QA Run SSM command; stdout/stderr dump on failure; removed stale `/home/ssm-user/.docker/cli-plugins` PATH line; removed runtime `yum install jq` (now in bootstrap)

## Decisions already made (avoid redoing)

- **Tagging scheme**: `{env}-{YYYYMMDD}-{gitsha7}` immutable, `{env}-latest` mutable pointer, `v*` semver on releases. Bare `latest` dropped. ECR lifecycle uses `{env}-2` prefix trick because ECR lifecycle `tagPrefixList` has no regex/exclude — leading `2` of year `20xx` naturally excludes `-latest` pointers. Safe until year 3000.
- **QA bootstrap path**: Option A (user-data shell script) per user's explicit choice. Not Option B (custom AMI / Packer).
- **Egress strategy**: single NAT gateway + keep all VPC endpoints (SSM, ECR, S3, STS). User explicitly rejected the S3-hosted-compose-binary approach as "scuffed" — chose NAT for simplicity. Endpoints still take precedence over NAT (gateway endpoints via more-specific prefix-list routes, interface endpoints via private DNS override).
- **Instance size**: `t3.large` (2 vCPU, 8 GB RAM) — bumped from t3.medium by user for OOM headroom.
- **Manifest/QA_IMAGES system**: keep — user decided it's worth it for future cherry-pick. Not removing.
- **Observability**: stream SSM stdout/stderr to CloudWatch (`/aws/ssm/qa-runner`) because SSM inline response caps at 24KB and silently truncates docker-compose output.
- **wait_for_docker sentinel**: must be ONE shell command with `&&` — previous version passed `["test -f sentinel", "docker info"]` as two list entries, which SSM ran as separate commands. Overall exit code = last command's, so sentinel check was a silent no-op.
- **STS endpoint**: kept even with NAT added. Free, harmless, faster path for AWS SDK calls.

## User / constraints (verbatim or near-verbatim)

- "as for options go A" (re: CURRENT_TODO section 2 — user-data bootstrap vs custom AMI)
- "nah just add the sts endpoint and that should be fine right" (prior iteration, pre-NAT)
- "we can just add the nat its fine, i dont wanna do any scuffed stuff, so just clean up that S3 null resource thing and add a nat, lets simplify. I believe regardless endpoints take precendence so its cool" (final egress decision)
- "i just keep getting this: Poll 19/60: Failed" (triggered the whole runtime-debug arc)
- "and do we need the QA images built list and stuff? Doesnt look like its getting used" → then kept manifest after explanation
- User hasn't asked for git commits. **Do not commit without explicit ask.** Session has touched 8+ files, all uncommitted.

## If stuck

1. Re-read (in order):
   - `CURRENT_TODO.md` — original spec
   - `infra/01-run-qa/lambda/qa_ec2.py` — main logic, has bootstrap + SSM polling + CloudWatch wiring
   - `infra/00-setup/vpc.tf` — NAT + endpoints
   - `infra/00-setup/lambda.tf` — log group + env
   - `infra/01-run-qa/setup/qa_run_all.sh` + `compose.sh` + `pull_images.sh` — what runs on the EC2
2. Run:
   ```bash
   cd infra/00-setup && terraform plan   # confirm expected diff before apply
   terraform apply
   # trigger workflow, then:
   aws logs tail /aws/ssm/qa-runner --region us-east-1 --since 15m --format short | tail -300
   ```
3. Expected fixes queued if log reveals specific failures:
   - **Disk full**: add `BlockDeviceMappings=[{DeviceName: "/dev/xvda", Ebs: {VolumeSize: 20, VolumeType: "gp3", DeleteOnTermination: True}}]` to `ec2.run_instances` call in `qa_ec2.py:launch_instance`
   - **MySQL healthcheck timing**: bump `start_period` in `infra/01-run-qa/setup/compose.yml` mysql service from 20s → 60s
   - **Smoke test assertions**: look at `infra/01-run-qa/setup/smoke_test.sh`
   - **Noisy output drowning buffer** (even with CloudWatch, Lambda logs still get spammy): change `compose.sh` to `docker-compose pull --quiet && docker-compose up -d --no-color`
4. If user wants to stop paying for NAT later: revisit the S3-hosted-compose-binary + docker-image-pull-from-ECR-mirror approach. MySQL would need to be mirrored to a private ECR repo.

## What stays authoritative

The repo files (especially `CURRENT_TODO.md`, `infra/01-run-qa/lambda/qa_ec2.py`, and terraform state) beat anything here. This checkpoint is routing.
