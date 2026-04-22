# godot-on-eks

Godot shmup + JVM backend (Phase 2: auth / score / session services, MySQL).

**Run the stack locally (Compose, env vars, ports, curl examples):** see **[LOCAL-DOCKER.md](./LOCAL-DOCKER.md)**.

High-level delivery plan: [PLAN.md](./PLAN.md).

Game code from [KidsCanCode: Your First 2D Game](https://kidscancode.org/godot_recipes/4.x/games/first_2d/first_2d_01/index.html).

---

## UAT (EKS, Gateway API, Argo CD)

**Public URL (target):** `https://uat.shmup.ettukube.com` — DNS is **Route 53 (Terraform)** under a delegated child zone; **`ettukube.com` stays in Cloudflare** for registrar/NS delegation to that zone (one-time manual at Cloudflare). Full sequence, TLS, and promotion flow: **[`docs/uat-plan.md`](./docs/uat-plan.md)**.

| Area | Location |
|------|-----------|
| UAT Terraform (VPC, EKS, RDS MySQL, Route 53, IRSA for External Secrets) | [`infra/02-uat/terraform/`](./infra/02-uat/terraform/) |
| Argo CD wrapper chart (`argo-helm`, pinned) + example `Application` CRs | [`infra/02-uat/argocd/`](./infra/02-uat/argocd/) |
| Platform + app Helm (Gateway / HTTPRoute, optional ESO) | [`infra/02-uat/helm/`](./infra/02-uat/helm/) |
| Operator bootstrap order + commands | [`infra/02-uat/README.md`](./infra/02-uat/README.md) |

**Promotion:** after QA passes, **`infra/01-run-qa/setup/tag_uat.sh`** moves validated digests to the ECR pointer tag **`uat-latest`** (immutable QA tags unchanged). Clusters and Helm values default to **`uat-latest`**.

**Prereqs:** AWS account/region, optional GitHub OIDC for CI (see below), Cloudflare access to delegate **`shmup.ettukube.com`** (or your chosen label) to the Route 53 name servers Terraform prints.

---

## CI/CD Pipeline

### Day 0 Setup (`infra/00-setup/`)

One-time Terraform apply to provision foundational infrastructure:

```bash
cd infra/00-setup
terraform init
terraform apply
```

Creates:

- **VPC** with private subnet + VPC endpoints (SSM, ECR, S3 — no NAT gateway)
- **ECR** repos for shooter, auth-service, score-service, session-service
- **S3** bucket for QA artifacts
- **Lambda** function (`qa-runner`) that manages ephemeral EC2 for QA
- **IAM** roles for EC2 (SSM + ECR + S3) and Lambda (EC2 + SSM management)
- **Security groups** for EC2 (egress-only) and VPC endpoints (HTTPS from VPC)

### GitHub Actions Secrets

| Secret               | Description                                      |
| -------------------- | ------------------------------------------------ |
| `AWS_ROLE_TO_ASSUME` | OIDC role ARN for GitHub Actions to assume       |
| `AWS_ACCOUNT_ID`     | AWS account ID (used for ECR login)              |
| `PAT`                | PAT for downloading different workflow artifacts |

### Workflows

**`nightly_build.yaml`** — Detects changed services via `SERVICE_LIST`, builds only what changed, pushes to ECR with version + `qa` + `latest` tags. Uploads a build manifest artifact for QA.

**`force_build.yaml`** — Manual trigger. Builds and pushes all services. Uploads manifest artifact, then dispatches to external infra repo.

**`qa.yaml`** — Triggered by build completion or manually. Downloads the build manifest (if available), uploads QA setup scripts to S3, then invokes the `qa-runner` Lambda asynchronously. The Lambda:

1. Launches an ephemeral EC2 instance in the private subnet
2. Waits for SSM agent to come online
3. Sends SSM commands to run the full QA suite (pull images, Docker Compose, smoke tests)
4. Tags passing images as `uat` in ECR
5. Terminates the EC2 instance

### Terraform Variables (`infra/00-setup/variables.tf`)

| Variable         | Default                             | Description                 |
| ---------------- | ----------------------------------- | --------------------------- |
| `region`         | `us-east-1`                         | AWS region                  |
| `qa_bucket_name` | `godot-eks-qa-2025`                 | S3 bucket for QA artifacts  |
| `qa_ami_id`      | `ami-03e4e59b20d79eeab`             | AMI with Docker + SSM agent |
| `services`       | shooter, auth/score/session-service | ECR repository names        |
