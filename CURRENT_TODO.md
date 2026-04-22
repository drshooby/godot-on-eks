# Current TODO

## 1. Fix Docker Image Tagging Strategy

**Problem:** Bare `latest` + bare env tags (`qa`, `uat`) create ambiguity. ECR lifecycle policy only catches `v*`-prefixed tags, so mutable pointers pile up and non-versioned builds are never pruned.

### Current state (verified)

| File | Current behavior |
|------|------------------|
| `scripts/build_and_push.sh:18` | Builds `${VERSION}-${DATE}` (e.g. `v0.0.1-20260419`) |
| `scripts/build_and_push.sh:51` | Also tags same digest as `${ENV}` and `latest` |
| `infra/01-run-qa/setup/tag_uat.sh:42` | Retags QA digest as bare `uat` |
| `infra/01-run-qa/setup/pull_images.sh:38` | Falls back to bare `qa` tag if manifest missing |
| `infra/00-setup/ecr.tf:27` | Lifecycle keeps last 10 of `tagPrefixList=["v"]` — works for current sortable tags by accident (VERSION file starts with `v`), but breaks under any new scheme |

### Proposed scheme

- **Immutable build tag:** `{service}:{env}-{date}-{gitsha7}`  
  e.g. `auth-service:qa-20260419-a1b2c3d`
- **Release tag:** `{service}:{semver}` — e.g. `auth-service:v0.0.1` (only on release cuts)
- **Mutable env pointer:** `{service}:{env}-latest`  
  e.g. `auth-service:qa-latest`, `auth-service:uat-latest`, `auth-service:prod-latest`
- **Drop bare `latest` entirely.**

### Task breakdown

- [ ] `scripts/build_and_push.sh`
  - Accept/derive `GITSHA` (GitHub Actions provides `GITHUB_SHA`; locally `git rev-parse --short HEAD`)
  - Primary tag: `${ENV}-${DATE}-${GITSHA7}`
  - Pointer tag: `${ENV}-latest` (not `latest`)
  - Write `${ENV}-${DATE}-${GITSHA7}` to `/tmp/qa-manifest/${SERVICE_NAME}`
- [ ] `.github/workflows/nightly_build.yaml`
  - Pass `GITHUB_SHA` into build script (already has checkout, just needs env passthrough)
- [ ] `infra/01-run-qa/setup/pull_images.sh:38`
  - Fallback from bare `qa` → `qa-latest`
- [ ] `infra/01-run-qa/setup/tag_uat.sh:42`
  - Retag as `uat-latest` (keep digest-preserving `ecr put-image` flow)
  - Also copy/retain source `${env}-${date}-${gitsha7}` tag for traceability
- [ ] `infra/00-setup/ecr.tf`
  - Expand lifecycle: one rule for versioned builds (`tagPrefixList=["qa-","uat-","prod-","dev-"]`, keep N by count), separate rule for `v*` semver (keep more/forever)
  - Never expire `*-latest` pointers (exclude via `tagStatus=tagged` + regex isn't supported; use separate prefix rule with high count or tag-exempt logic)
- [ ] `compose.yaml` — no change needed (builds locally, no image tags referenced)
- [ ] `infra/01-run-qa/setup/compose.yml` — no change needed (pulls retag to bare service name via `pull_images.sh`)

### Acceptance

- Every pushed image has a unique, immutable, traceable tag (env + date + sha).
- `{env}-latest` is the only mutable pointer per env; bare `latest` no longer exists.
- ECR lifecycle prunes old non-release builds but keeps all `v*` release tags.

---

## 2. Fix QA Lambda AMI / Bootstrap

**Problem:** `qa_ec2.py` launches an instance then SSM-execs `docker compose`, but the configured AMI (`ami-098e39bafa7e7303d`, stock Amazon Linux x86) has neither Docker nor the compose plugin installed. Nothing bootstraps them. End-to-end QA flow dead-ends on first `docker` call inside `qa_run_all.sh`.

### Evidence

- `infra/00-setup/variables.tf:13-17` — default AMI is stock AL; description says "must have Docker + SSM agent" but this AMI has neither Docker.
- `infra/00-setup/lambda.tf:7-29` — no `user_data` passed; launch relies on AMI having Docker pre-baked.
- `infra/01-run-qa/lambda/qa_ec2.py:57` — `export PATH=/home/ssm-user/.docker/cli-plugins:$PATH` assumes a pre-baked custom AMI that was never built.
- `infra/01-run-qa/setup/qa_run_all.sh:14-18` — script warns on missing Docker but continues, then fails at `./compose.sh`.

### Options (pick one)

**A) User data bootstrap (fast, no AMI build)**
- Add `UserData` param to `ec2.run_instances` in `qa_ec2.py` (base64 shell script)
- Script: `yum install -y docker jq && systemctl enable --now docker && curl compose plugin → /usr/libexec/docker/cli-plugins/docker-compose`
- `wait_for_ssm` already polls — extend to also wait for Docker daemon before `send_command`
- Pro: zero infra churn. Con: ~60-90s added to every QA run.

**B) Custom AMI via Packer/EC2 Image Builder (slower, reusable)**
- Build AMI with Docker + compose plugin + SSM agent pre-baked
- Store AMI ID in SSM Parameter Store, read in `lambda.tf` via `data "aws_ssm_parameter"`
- Pro: fast cold start, clean. Con: new build pipeline to maintain.

**Recommendation:** Start with **A** to unblock e2e. Migrate to **B** once tagging scheme stabilizes.

### Task breakdown (Option A)

- [ ] Write bootstrap `user_data` script (Docker + compose plugin install)
- [ ] Pass as `UserData=...` in `ec2.run_instances` call in `qa_ec2.py:17`
- [ ] In `wait_for_ssm`, also poll until `docker info` succeeds via a throwaway SSM command, before running the real QA command
- [ ] Remove misleading `/home/ssm-user/.docker/cli-plugins` PATH line in `qa_ec2.py:57` (compose plugin will be in system path after bootstrap)
- [ ] Update `variables.tf:13-17` comment to reflect actual AMI requirement (stock AL + bootstrap vs pre-baked)

---

## 3. End-to-End QA Flow Verification

**Current chain (verified working up to Lambda invoke):**

```
nightly_build.yaml → build_and_push.sh → ECR push
  → qa.yaml workflow_run trigger
  → upload manifest + S3 artifacts
  → lambda invoke (qa-runner)
  → [FAILS HERE: EC2 boots but no Docker]
```

### Verification checklist (post items 1 + 2)

- [ ] Push triggers `nightly_build` — produces `{service}:{env}-{date}-{sha7}` tags in ECR
- [ ] `qa.yaml` picks up manifest artifacts, builds `QA_IMAGES` env var with new tag format
- [ ] Lambda launches EC2, bootstrap completes, SSM online + Docker online
- [ ] `qa_run_all.sh` pulls exact manifest tags, runs compose, smoke tests pass
- [ ] `tag_uat.sh` promotes to `uat-latest` cleanly
- [ ] Instance terminates in `finally` block (already in `qa_ec2.py:108-111`)
- [ ] ECR lifecycle prunes expected images, keeps release tags

### Notes / gotchas

- Lambda timeout is 900s (`lambda.tf:12`) — watch budget across bootstrap + pull + compose + smoke
- `QA_BUCKET` upload happens from GH runner (`add_to_s3.sh`), not Lambda — keep that
- `tag_uat.sh` runs *on the ephemeral EC2* (pulled from S3 via `qa_run_all.sh:44`). Its AWS creds come from the instance profile `aws_iam_instance_profile.qa_ec2` — verify it has `ecr:BatchGetImage` + `ecr:PutImage`.
