# UAT (`infra/02-uat`)

End state and architecture are described in **[`docs/uat-plan.md`](../../docs/uat-plan.md)**. This directory holds **Terraform**, **Argo CD (argo-helm wrapper)**, and **Helm** for UAT.

## Terraform (`terraform/`)

Dedicated VPC + **EKS** + **RDS MySQL** (Secrets Manager master password) + **Route 53** child zone for delegation. Public **`uat.shmup.ettukube.com`** alias is **optional on first apply**: set `uat_gateway_lb_dns_name` and `uat_gateway_lb_hosted_zone_id` after your Gateway controller exposes a load balancer, then re-apply.

```bash
cd infra/02-uat/terraform
terraform init
terraform apply
terraform output route53_child_zone_name_servers   # delegate at Cloudflare → Route 53
terraform output configure_kubectl
terraform output external_secrets_irsa_role_arn  # annotate ESO serviceAccount
```

## Gateway API stack (decision: Envoy Gateway)

Install **Gateway API CRDs** + **Envoy Gateway** (version-pinned Helm release from upstream docs), then **cert-manager** and **External Secrets Operator**. Annotate the `external-secrets` service account with `eks.amazonaws.com/role-arn` from Terraform.

## Platform Helm (`helm/platform`)

Shared **`Gateway`** (class `eg`), **ClusterIssuer** (Let’s Encrypt HTTP-01 via **Gateway API** solver), **Certificate** for `uat.shmup.ettukube.com`, and **ClusterSecretStore** (IRSA). The HTTPS listener is **off** until the TLS Secret exists: set `gateway.enableHttpsListener: true` after `uat-public-tls` is **Ready**, then re-sync.

## App charts (`helm/*`)

Replace **`REPLACE_ACCOUNT`** in each chart’s `values.yaml` with `terraform output -raw aws_account_id` (or override in Argo). Default image tag is **`uat-latest`** (promoted by `infra/01-run-qa/setup/tag_uat.sh`).

## Argo CD (`argocd/`)

If `helm dependency build` cannot fetch the dependency, add the upstream repo once: `helm repo add argo https://argoproj.github.io/argo-helm`

```bash
cd infra/02-uat/argocd
helm dependency build
helm upgrade --install argo-cd . -f values.yaml -n argocd --create-namespace
```

Edit **`argocd/apps/*.yaml`** `repoURL` / `targetRevision`, then `kubectl apply -f argocd/apps/`.
