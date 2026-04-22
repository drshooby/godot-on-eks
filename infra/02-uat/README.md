# UAT (`infra/02-uat`)

End state and architecture are described in **[`docs/uat-plan.md`](../../docs/uat-plan.md)**. This directory holds **Terraform**, **Argo CD (argo-helm wrapper)**, and **Helm** for UAT.

## Local testing (Docker Desktop)

Use this path to smoke-test the full UAT stack before provisioning EKS. No AWS account needed.

**Build images first** (Docker Desktop shares the daemon with the cluster, so local builds are available immediately):

```bash
docker build -f backend/docker/Dockerfile.jvm --build-arg MODULE=auth-service    -t auth-service:uat-latest    ./backend
docker build -f backend/docker/Dockerfile.jvm --build-arg MODULE=score-service   -t score-service:uat-latest   ./backend
docker build -f backend/docker/Dockerfile.jvm --build-arg MODULE=session-service -t session-service:uat-latest ./backend
docker build -f shooter/Dockerfile                                                -t shooter:uat-latest          ./shooter
```

**Then run the install script** (sets up everything: Gateway API CRDs, Envoy Gateway, MySQL, secrets, all Helm charts):

```bash
infra/02-uat/local/install.sh
```

The script checks that your `kubectl` context is `docker-desktop` before touching anything. Once complete, the shooter game is reachable at **http://localhost**.

**What the script installs:**

| Step                       | Resource                                  | Notes                             |
| -------------------------- | ----------------------------------------- | --------------------------------- |
| Namespaces                 | `argocd`, `uat`, `external-secrets`       | from `namespaces.yaml`            |
| Gateway API CRDs           | v1.2.1 standard install                   |                                   |
| Envoy Gateway              | v1.3.1 via Helm                           | GatewayClass `eg`                 |
| MySQL                      | StatefulSet in `uat`                      | schema auto-applied on first boot |
| App secrets                | `*-env` Secrets in `uat`                  | DB creds + JWT secret             |
| platform chart             | Gateway (no TLS, no cert-manager, no ESO) |                                   |
| auth/score/session/shooter | Helm releases in `uat`                    | local images, `env.enabled=true`  |

**Differences from EKS:**

| Local                        | EKS                               |
| ---------------------------- | --------------------------------- |
| MySQL StatefulSet in-cluster | RDS MySQL via Terraform           |
| Plain k8s Secrets            | ExternalSecrets → Secrets Manager |
| No cert-manager / TLS        | cert-manager + Let's Encrypt      |
| No Argo CD                   | Full Argo CD ApplicationSet       |
| `awsAccountId` not needed    | Pass at `helm upgrade --install`  |

**Tear down:**

```bash
infra/02-uat/local/teardown.sh
```

---

## EKS deployment

### 1. Terraform

Provisions VPC, EKS, RDS MySQL, Route 53, and IRSA. ECR repos are created in `infra/00-setup`.

```bash
cd infra/02-uat/terraform
terraform init
terraform apply
```

Delegate the child zone NS records at Cloudflare:

```bash
terraform output route53_child_zone_name_servers
```

Configure kubectl:

```bash
eval "$(terraform output -raw configure_kubectl)"
```

### 2. Install script

The install script reads Terraform outputs and sets up everything on the cluster:

```bash
infra/02-uat/eks/install.sh
```

**What it installs (in order):**

| Step | Resource | Notes |
|------|----------|-------|
| Namespaces | `argocd`, `uat`, `external-secrets` | from `namespaces.yaml` |
| Envoy Gateway | v1.3.1 via Helm | includes Gateway API CRDs + GatewayClass `eg` |
| cert-manager | v1.17.2 via Helm | for Let’s Encrypt TLS |
| External Secrets Operator | latest via Helm | IRSA-annotated from Terraform output |
| Argo CD | v7.8.8 (argo-helm) | `awsAccountId` injected from Terraform |

Argo CD’s **ApplicationSet** then deploys all apps (platform, auth-service, score-service, session-service, shooter) automatically from git. Each service gets:
- `image.repository` = `<accountId>.dkr.ecr.us-east-1.amazonaws.com/<app-name>`
- `env.enabled` = true (mount `<service>-env` Secret)
- `externalSecret.enabled` = true (ESO creates the Secret from Secrets Manager)

### 3. Post-install

1. **Wait for Gateway LB address:**
   ```bash
   kubectl get gateway uat-public -n uat -w
   ```

2. **Update Terraform** with the LB DNS for the Route 53 alias, then re-apply:
   ```bash
   terraform -chdir=infra/02-uat/terraform apply \
     -var uat_gateway_lb_dns_name=<LB_DNS> \
     -var uat_gateway_lb_hosted_zone_id=<LB_ZONE_ID>
   ```

3. **Enable HTTPS** after the TLS Certificate is Ready (`kubectl get certificate -n uat`):
   Set `gateway.enableHttpsListener: true` in the platform chart and re-sync via Argo.

**Argo CD UI:**

```bash
kubectl port-forward svc/argo-cd-argocd-server -n argocd 8080:443
# admin password:
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath=’{.data.password}’ | base64 -d
```

**Tear down** (Kubernetes resources only — Terraform infra stays):

```bash
infra/02-uat/eks/teardown.sh
```

---

## Known issues

### IRSA webhook not injecting tokens into ESO pods

**Symptom:** `ClusterSecretStore` shows `InvalidProviderConfig` / `unable to create session: an IAM role must be associated with service account`. The EKS pod-identity-webhook (`127.0.0.1:23443`) exists with `failurePolicy: Ignore` but silently fails to inject the projected service account token and `AWS_*` env vars into pods, even though the OIDC provider and IAM trust policy are correct.

**Current fix:** The install script passes explicit IRSA volume/env overrides to the ESO Helm release (`extraVolumes`, `extraVolumeMounts`, `extraEnv` for `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_ROLE_ARN`, `AWS_REGION`), bypassing the webhook entirely.

**To explore:**
- Check if installing the `eks-pod-identity-agent` EKS addon resolves the webhook issue (the cluster currently has no managed addons).
- Check if the webhook works on newer EKS versions (cluster is currently 1.31).
- Consider switching from IRSA to [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) (simpler, no OIDC provider needed).
