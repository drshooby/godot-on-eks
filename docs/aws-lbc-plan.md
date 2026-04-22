# Add AWS Load Balancer Controller for Clean Terraform Destroys

## Context

When running `terraform destroy`, Envoy Gateway's LoadBalancer Service creates a Classic ELB via the in-tree AWS cloud provider. This ELB holds ENIs in subnets, blocking subnet and IGW deletion. The AWS Load Balancer Controller (LBC) manages NLB lifecycle with Kubernetes finalizers, ensuring the LB is cleaned up when the Service is deleted.

**Key decision**: Install LBC via Terraform Helm provider (not ArgoCD), because during `terraform destroy` ArgoCD is already gone. Terraform needs to own the LBC lifecycle to guarantee correct destroy ordering.

---

## Changes

### 1. `infra/02-uat/terraform/versions.tf` — Add provider requirements

Add `helm` and `kubernetes` providers alongside existing `aws`:
```hcl
helm = {
  source  = "hashicorp/helm"
  version = ">= 2.17.0"
}
kubernetes = {
  source  = "hashicorp/kubernetes"
  version = ">= 2.36.0"
}
```

### 2. `infra/02-uat/terraform/providers.tf` — Add Helm/K8s providers

Add `aws_eks_cluster_auth` data source, `kubernetes` provider, and `helm` provider, all wired to the EKS cluster endpoint/token.

### 3. `infra/02-uat/terraform/iam.tf` — Add LBC IRSA role

Follow existing `irsa_external_secrets` pattern:
- `aws_iam_policy.lbc` referencing a local policy JSON file
- `module.irsa_lbc` with OIDC binding to `kube-system:aws-load-balancer-controller`

### 4. `infra/02-uat/terraform/lbc-iam-policy.json` — **New file**

Official AWS LBC IAM policy JSON from `kubernetes-sigs/aws-load-balancer-controller` docs (v2.11.x).

### 5. `infra/02-uat/terraform/lbc.tf` — **New file**

`helm_release.aws_lbc` installing `aws-load-balancer-controller` chart from `https://aws.github.io/eks-charts` into `kube-system`, with:
- `clusterName`, `region`, `vpcId`
- ServiceAccount annotated with IRSA role ARN
- `depends_on = [module.eks, module.irsa_lbc]`

### 6. `infra/02-uat/terraform/outputs.tf` — Add LBC IRSA output

### 7. `infra/02-uat/eks/install.sh` — Configure Envoy Gateway for LBC

After Envoy Gateway install (step 2), add:
- `EnvoyProxy` custom resource in `envoy-gateway-system` with Service annotations:
  - `service.beta.kubernetes.io/aws-load-balancer-type: "external"`
  - `service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"`
  - `service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"`
- Update `GatewayClass` to include `parametersRef` pointing to the EnvoyProxy

### 8. `infra/02-uat/eks/teardown.sh` — Delete Gateway before Envoy Gateway

Add before the "Removing Envoy Gateway" step:
```bash
echo "==> Deleting Gateway (triggers LB cleanup via LBC finalizers)..."
kubectl delete gateway --all -A --timeout=120s 2>/dev/null || true
sleep 30
```

---

## Verification

1. `terraform apply` completes, then: `kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller` shows Running pods
2. After `install.sh`: `kubectl get gatewayclass eg -o yaml` shows `parametersRef` to EnvoyProxy
3. After ArgoCD syncs: `aws elbv2 describe-load-balancers` shows an NLB (not Classic ELB)
4. `teardown.sh` + `terraform destroy` completes without subnet/IGW dependency errors
