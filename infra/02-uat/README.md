# UAT (`infra/02-uat`)

End state and architecture are described in **[`docs/uat-plan.md`](../../docs/uat-plan.md)**. This directory holds **Terraform**, **Argo CD (argo-helm wrapper)**, and **Helm** for UAT.

## Edge architecture

```
Client → ALB (Terraform, ACM cert) → NodePort → Ingress controller → Ingress → Service → Pod
                                                 (Traefik | Kong)
```

- **ALB**, **ACM certificate**, **Route 53 record**, **VPC**, **EKS**, **RDS** — all Terraform-owned. `terraform destroy` cleans everything up with no orphaned ENIs.
- **Ingress controller** runs inside the cluster. Pick one with `var.ingress_controller` (Terraform) or `INGRESS_CONTROLLER` (install scripts):
  - `traefik` (default, `IngressClass: traefik`) — installed via `traefik/traefik` chart v34.2.0.
  - `kong` (`IngressClass: kong`) — installed via `kong/kong` chart v3.2.0, DB-less, ingress-controller mode, CRDs included.
- On EKS the controller Service is `NodePort` on `var.ingress_http_nodeport` (default 30080); the ALB target group forwards to that port. The port is **shared** between Traefik and Kong, so swapping controllers does **not** require `terraform apply` — uninstall one Helm release, install the other (`INGRESS_CONTROLLER=kong infra/02-uat/eks/install.sh`), and re-sync app charts so they pick up the new `ingressClassName`.
- Locally (Docker Desktop) the controller runs as `LoadBalancer` so it is reachable on `localhost`.
- **TLS** terminates at the ALB (ACM DNS-validated cert). The ingress controller speaks plain HTTP internally.
- App charts expose traffic with standard Kubernetes `Ingress` resources (no Gateway API). The `ingressClassName` is configurable per chart (`ingress.className`); the Argo CD ApplicationSet propagates a single top-level `ingressClassName` value to every app.

## Local testing (Docker Desktop)

Use this path to smoke-test the full UAT stack before provisioning EKS. No AWS account needed.

**Build images first** (Docker Desktop shares the daemon with the cluster, so local builds are available immediately):

```bash
docker build -f backend/docker/Dockerfile.jvm --build-arg MODULE=auth-service    -t auth-service:uat-latest    ./backend
docker build -f backend/docker/Dockerfile.jvm --build-arg MODULE=score-service   -t score-service:uat-latest   ./backend
docker build -f backend/docker/Dockerfile.jvm --build-arg MODULE=session-service -t session-service:uat-latest ./backend
docker build -f shooter/Dockerfile                                                -t shooter:uat-latest          ./shooter
```

**Then run the install script** (sets up everything: ingress controller, MySQL, secrets, all Helm charts):

```bash
infra/02-uat/local/install.sh
# or, try Kong instead of the default Traefik:
INGRESS_CONTROLLER=kong infra/02-uat/local/install.sh
```

The script checks that your `kubectl` context is `docker-desktop` before touching anything. Once complete, the shooter game is reachable at **http://localhost**.

**What the script installs:**

| Step                       | Resource                                | Notes                             |
| -------------------------- | --------------------------------------- | --------------------------------- |
| Namespaces                 | `argocd`, `uat`, `external-secrets`     | from `namespaces.yaml`            |
| Ingress controller         | Helm release in `traefik` or `kong`     | `type: LoadBalancer` → localhost; pick with `INGRESS_CONTROLLER` env (default `traefik`) |
| MySQL                      | StatefulSet in `uat`                    | schema auto-applied on first boot |
| App secrets                | `*-env` Secrets in `uat`                | DB creds + JWT secret             |
| platform chart             | ClusterSecretStore disabled locally     |                                   |
| auth/score/session/shooter | Helm releases in `uat`                  | local images, `env.enabled=true`  |

**Differences from EKS:**

| Local                        | EKS                                     |
| ---------------------------- | --------------------------------------- |
| MySQL StatefulSet in-cluster | RDS MySQL via Terraform                 |
| Plain k8s Secrets            | ExternalSecrets → Secrets Manager       |
| Controller `LoadBalancer`    | Controller `NodePort` + Terraform ALB   |
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

Provisions VPC, EKS, RDS MySQL, Route 53 zone + record, ACM cert, ALB + target group, IRSA for External Secrets. ECR repos live in `infra/00-setup`.

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

The install script reads Terraform outputs (cluster name, account id, IRSA ARN, ingress NodePort, ingress controller selection) and sets up the cluster:

```bash
infra/02-uat/eks/install.sh
# or, override the controller without re-applying Terraform:
INGRESS_CONTROLLER=kong infra/02-uat/eks/install.sh
```

**What it installs (in order):**

| Step | Resource | Notes |
|------|----------|-------|
| Namespaces | `argocd`, `uat`, `external-secrets` | from `namespaces.yaml` |
| Ingress controller | Traefik v34.2.0 *or* Kong v3.2.0 via Helm | `NodePort` (`var.ingress_http_nodeport`, default 30080) matching the Terraform ALB target group. Registers `IngressClass: traefik` or `IngressClass: kong`. Selected by `INGRESS_CONTROLLER` env (defaults to `terraform output ingress_controller`, default `traefik`). |
| External Secrets Operator | latest via Helm | IRSA-annotated from Terraform output |
| Argo CD | v7.8.8 (argo-helm) | `awsAccountId` and `ingressClassName` injected from Terraform / install flag |

### Switching ingress controllers

Both controllers bind the same NodePort (`var.ingress_http_nodeport`, default 30080) and the ALB target group health check accepts 200–404, so the Terraform-managed edge does not change when swapping. To switch from Traefik to Kong:

```bash
# 1. (Optional) record intent in Terraform so future runs default to Kong:
#    set ingress_controller = "kong" in terraform.tfvars and `terraform apply`.
# 2. Uninstall the current controller:
helm uninstall traefik -n traefik
# 3. Install the other one and re-render Argo CD with the new ingressClassName:
INGRESS_CONTROLLER=kong infra/02-uat/eks/install.sh
# 4. Argo will re-sync app Ingress resources with ingressClassName=kong.
```

Argo CD's **ApplicationSet** then deploys all apps (platform, auth-service, score-service, session-service, shooter) automatically from git. Each service gets:
- `image.repository` = `<accountId>.dkr.ecr.us-east-1.amazonaws.com/<app-name>`
- `env.enabled` = true (mount `<service>-env` Secret)
- `externalSecret.enabled` = true (ESO creates the Secret from Secrets Manager)

### 3. Post-install

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

---

## Known issues

### IRSA webhook not injecting tokens into ESO pods

**Symptom:** `ClusterSecretStore` shows `InvalidProviderConfig` / `unable to create session: an IAM role must be associated with service account`. The EKS pod-identity-webhook (`127.0.0.1:23443`) exists with `failurePolicy: Ignore` but silently fails to inject the projected service account token and `AWS_*` env vars into pods, even though the OIDC provider and IAM trust policy are correct.

**Current fix:** The install script passes explicit IRSA volume/env overrides to the ESO Helm release (`extraVolumes`, `extraVolumeMounts`, `extraEnv` for `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_ROLE_ARN`, `AWS_REGION`), bypassing the webhook entirely.

**To explore:**
- Check if installing the `eks-pod-identity-agent` EKS addon resolves the webhook issue (the cluster currently has no managed addons).
- Check if the webhook works on newer EKS versions (cluster is currently 1.31).
- Consider switching from IRSA to [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) (simpler, no OIDC provider needed).
