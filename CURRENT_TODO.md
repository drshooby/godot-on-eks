# Current TODO

## 1. Update Docker Image Tagging Strategy

**Problem:** Current tagging creates ambiguity and poor traceability across 3 services × 4 envs × multiple builds.

Current chaos:
```
qa
v0.0.1-20260419
latest              ← which environment?
dev
v0.0.2-20260419
latest              ← which environment?
```

**Solution:** Implement scalable tagging convention with clear semantics:

- **Development/Testing:** `{service}:{env}-{date}-{gitsha[:7]}`
  - Example: `auth-service:qa-20260419-a1b2c3d`
  - Traceability: environment + date + commit
  - No ambiguity, easy to track

- **Release:** `{service}:{semver}`
  - Example: `auth-service:v0.0.1`
  - Clean, canonical release identifier
  - Matches version semantics

- **Environment Latest:** `{service}:{env}-latest`
  - Example: `auth-service:prod-latest` (not just `latest`)
  - Always know which environment's "latest" you're looking at
  - Avoids the "which latest?" problem

**Files to update:**
- `.github/workflows/nightly_build.yaml` — tag generation logic
- `scripts/build_and_push.sh` — build/push tagging
- `compose.yaml` — reference new tags
- ECR lifecycle policies — align retention with tagging scheme

---

## 2. Fix Lambda AMI Configuration

**Problem:** Lambda is triggering QA flow but has no actual AMI configured, blocking end-to-end testing.

**Blockers:**
- Lambda needs to reference a valid, working AMI
- Current setup missing the link between Lambda kickoff and actual EC2 instance launch
- Affects QA flow verification (build → ECR → QA start → Lambda → ???)

**Tasks:**
- Verify/create base AMI with required dependencies
- Update Lambda environment variables/config to reference correct AMI
- Test Lambda execution path end-to-end

**Files likely involved:**
- `infra/00-setup/ecr.tf` (or lambda-specific TF)
- Lambda function code/configuration
- Any EC2 AMI builder configs

---

## 3. Complete QA Flow Testing

**Current working chain:**
```
build all → upload to ECR → start QA → Lambda kickoff → [missing: actual AMI]
```

**Goal:** Verify full end-to-end QA pipeline once AMI is wired in.

**Verification checklist:**
- [ ] Build all services successfully
- [ ] Push to ECR with new tagging scheme
- [ ] QA environment spins up
- [ ] Lambda triggers and launches EC2 instance (once AMI fixed)
- [ ] Services running and healthy
- [ ] Can tear down cleanly

**Notes:**
- Keep existing setup—it's working up to the Lambda handoff
- Focus on bridging the Lambda → EC2 AMI gap
- Document any gotchas for future QA runs
