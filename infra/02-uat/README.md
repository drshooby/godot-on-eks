# UAT (`infra/02-uat`)

End state and architecture are described in **[`docs/uat-plan.md`](../../docs/uat-plan.md)**. This directory holds **Terraform**, **Argo CD (argo-helm wrapper)**, and **Helm** for UAT.

## Edge architecture

```
Client → ALB (Terraform, ACM cert) → NodePort → Traefik → Ingress → Service → Pod
```

- **ALB**, **ACM certificate**, **Route 53 record**, **VPC**, **EKS**, **RDS** — all Terraform-owned. `terraform destroy` cleans everything up with no orphaned ENIs.
- **Traefik** runs inside the cluster as an **Ingress controller** (`IngressClass: traefik`). On EKS its Service is `NodePort`; the ALB target group forwards to that port. Locally (Docker Desktop) Traefik runs as `LoadBalancer` so it is reachable on `localhost`.
- **TLS** terminates at the ALB (ACM DNS-validated cert). Traefik speaks plain HTTP internally.
- App charts expose traffic with standard Kubernetes `Ingress` resources (no Gateway API).

## Local testing (Docker Desktop)

Use this path to smoke-test the full UAT stack before provisioning EKS. No AWS account needed.

**Build images first** (Docker Desktop shares the daemon with the cluster, so local builds are available immediately):

```bash
docker build -f backend/docker/Dockerfile.jvm --build-arg MODULE=auth-service    -t auth-service:uat-latest    ./backend
docker build -f backend/docker/Dockerfile.jvm --build-arg MODULE=score-service   -t score-service:uat-latest   ./backend
docker build -f backend/docker/Dockerfile.jvm --build-arg MODULE=session-service -t session-service:uat-latest ./backend
docker build -f shooter/Dockerfile                                                -t shooter:uat-latest          ./shooter
```

**Then run the install script** (sets up everything: Traefik, MySQL, secrets, all Helm charts):

```bash
infra/02-uat/local/install.sh
```

The script checks that your `kubectl` context is `docker-desktop` before touching anything. Once complete, the shooter game is reachable at **http://localhost**.

**What the script installs:**

| Step                       | Resource                                | Notes                             |
| -------------------------- | --------------------------------------- | --------------------------------- |
| Namespaces                 | `argocd`, `uat`, `external-secrets`     | from `namespaces.yaml`            |
| Traefik                    | Helm release in `traefik`               | `type: LoadBalancer` → localhost  |
| MySQL                      | StatefulSet in `uat`                    | schema auto-applied on first boot |
| App secrets                | `*-env` Secrets in `uat`                | DB creds + JWT secret             |
| platform chart             | ClusterSecretStore disabled locally     |                                   |
| auth/score/session/shooter | Helm releases in `uat`                  | local images, `env.enabled=true`  |

**Differences from EKS:**

| Local                        | EKS                                     |
| ---------------------------- | --------------------------------------- |
| MySQL StatefulSet in-cluster | RDS MySQL via Terraform                 |
| Plain k8s Secrets            | ExternalSecrets → Secrets Manager       |
| Traefik `LoadBalancer`       | Traefik `NodePort` + Terraform ALB      |
| No TLS                       | ACM cert on ALB (Let's Encrypt-free)    |
| No Argo CD                   | Full Argo CD ApplicationSet             |
| `awsAccountId` not needed    | Pass at `helm upgrade --install`        |

**Tear down:**

```bash
infra/02-uat/local/teardown.sh
```

---

## EKS deployment

### 1. Terraform

Provisions VPC, EKS, RDS MySQL, Route 53 zone + record, ACM cert, ALB + target group, and the IAM role + EKS Pod Identity association for External Secrets. ECR repos live in `infra/00-setup`.

```bash
cd infra/02-uat/terraform
terraform init
terraform apply
```

Delegate the child zone NS records at Cloudflare **before the first apply completes** — ACM DNS validation hangs otherwise:

```bash
terraform output route53_child_zone_name_servers
```

Configure kubectl:

```bash
eval "$(terraform output -raw configure_kubectl)"
```

### 2. Install script

The install script reads Terraform outputs (cluster name, account id, IRSA ARN, Traefik NodePort) and sets up the cluster:

```bash
infra/02-uat/eks/install.sh
```

**What it installs (in order):**

| Step | Resource | Notes |
|------|----------|-------|
| Namespaces | `argocd`, `uat`, `external-secrets` | from `namespaces.yaml` |
| Traefik | v34.x via Helm | `NodePort` matching the Terraform ALB target group; registers `IngressClass: traefik` |
| External Secrets Operator | latest via Helm | AWS creds via EKS Pod Identity (see below) |
| Argo CD | v7.8.8 (argo-helm) | `awsAccountId` injected from Terraform |

Argo CD's **ApplicationSet** then deploys all apps (platform, auth-service, score-service, session-service, shooter) automatically from git. Each service gets:
- `image.repository` = `<accountId>.dkr.ecr.us-east-1.amazonaws.com/<app-name>`
- `env.enabled` = true (mount `<service>-env` Secret)
- `externalSecret.enabled` = true (ESO creates the Secret from Secrets Manager)

### 3. Pod Identity (how ESO gets AWS creds)

External Secrets used to rely on **IRSA**: an OIDC provider, a role trust policy tied to a specific service account subject, and the in-cluster `pod-identity-webhook` mutating pods at admission to inject `AWS_WEB_IDENTITY_TOKEN_FILE` + a projected token volume. On this cluster the webhook silently no-opped (`failurePolicy: Ignore`), so the install script had to hand-roll the volume, mount, and env vars — the workaround the README used to call out under "Known issues".

This is now handled with **[EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)**:

- Terraform enables the `eks-pod-identity-agent` EKS managed addon (see `terraform/eks.tf`). The agent runs as a DaemonSet in `kube-system` and serves credentials to pods over a local IMDS-style endpoint.
- `terraform/iam.tf` defines one IAM role (`uat-external-secrets`) whose trust policy allows `pods.eks.amazonaws.com` with `sts:AssumeRole` + `sts:TagSession`. An `aws_eks_pod_identity_association` binds it to the `external-secrets/external-secrets` service account.
- The install script no longer passes `extraVolumes` / `extraVolumeMounts` / `extraEnv` for IRSA, and no longer needs the `eks.amazonaws.com/role-arn` annotation on the service account. It does wait for the `eks-pod-identity-agent` DaemonSet to be Ready before installing ESO, so startup failures surface immediately instead of later as `InvalidProviderConfig`.

The OIDC provider is still provisioned (module default) and the role's trust policy still accepts the old IRSA federated principal, so nothing left on IRSA breaks. This is transitional — once everything is confirmed on Pod Identity, the IRSA trust statement and the OIDC provider can be removed.

### 4. Post-install

1. **Check Argo apps sync:** `kubectl get applications -n argocd`
2. **Confirm ALB target group has healthy targets** (`aws elbv2 describe-target-health ...`).
3. **Verify:** `curl -vI https://$(terraform output -raw uat_fqdn)` — valid cert, 200/30x from shooter.

**Argo CD UI:**

```bash
kubectl port-forward svc/argo-cd-argocd-server -n argocd 8080:443
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
```

**Tear down** (Kubernetes resources only — Terraform infra stays):

```bash
infra/02-uat/eks/teardown.sh
```

Then `terraform -chdir=infra/02-uat/terraform destroy` removes the ALB, ACM cert, Route 53 record, RDS, EKS, and VPC in one go. No more subnet/IGW dependency hangs.

