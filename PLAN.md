# fps-godot-on-eks — delivery plan

## Phase 1 — Terraform foundation

Stand up VPC, EKS cluster, and RDS first. Nothing else matters until this works. Use the envs/ structure from earlier — one tfvars per environment. RDS gets its own security group that only allows traffic from within the cluster.

Prefer an **RDS engine that matches local dev**: if Phase 2 uses MySQL in Compose, create **RDS MySQL (or Aurora MySQL)** so migrations and JDBC URLs stay aligned. If Phase 1 already committed to another engine, use portable DDL or dialect-specific migration sets.

---

## Phase 2 — The JVM cinematic universe

### Part 1 — Stand it up locally first (Docker Compose + MySQL)

Before EKS or RDS wiring, **Part 1 of Phase 2** is: all three JVM services run together on your machine via **Docker Compose**, backed by the official **`mysql`** image (not Postgres). Same fat-jar Dockerfile pattern everywhere; Compose wires `DATABASE_*` env vars and depends-on ordering so services hit MySQL once the schema exists.

Done when:

- Compose brings up **MySQL** plus **auth-service**, **score-service**, **session-service**.
- Smoke checks: health/ready endpoints and a minimal curl flow against all routes in `PLAN.md` (below) succeed against the Compose network.

Everything after Part 1 (Kubernetes, RDS endpoints, Secrets) stacks on top of containers and JDBC that already work locally.

---

### Microservices overview

#### auth-service (Kotlin)

- `POST /register` — hash password, insert into players table, return JWT  
- `POST /login` — verify password, return JWT  
- `POST /validate` — other services call this internally to verify tokens  

Framework: **Ktor** (lightweight, coroutines, fits in a fat jar cleanly).

#### score-service (Groovy)

- `POST /scores` — `{ player_id, score, wave_reached }` — insert row  
- `GET /leaderboard` — top 10 join with players  
- `GET /scores/:player` — personal best  

Framework: **Micronaut** or Groovy with `groovy.sql.Sql` directly — the service is so simple you barely need a framework.

#### session-service (Scala)

- `POST /session/start` — returns a `session_id`; shmup calls this on game start  
- `POST /session/end` — `{ session_id, score, waves, kills }` — finalizes the row  
- `GET /session/history/:player` — full run history  

Framework: **http4s** or Play — either works; http4s is more modern Scala.

All three share **one Dockerfile pattern**: Gradle builds a fat jar; `eclipse-temurin:21-jre-alpine` runs it. The chaos is entirely in the source.

Godot stays isolated until Phase 3 — no shmup HTTP calls required to finish Phase 2.

---

### Goals and success criteria

| Goal | Done when |
|------|-----------|
| Apps standing (Part 1) | Compose: MySQL + three services; `/health` (and `/ready` if implemented) return 200 |
| Apps standing (later) | Same images/secrets pattern on EKS against RDS |
| Single DB | One migration set (Flyway/Liquibase); **MySQL** DDL for local Compose; prod uses compatible RDS |
| Auth story | JWT from auth-service; others verify via **`POST /validate`** and/or shared HS256 secret |
| API surface | Endpoints below implemented with stable JSON bodies and stable error codes |

Non-goals for Phase 2: shmup ingress/CORS polish, CI/CD (Phase 4), observability stack (Phase 5).

---

### Architecture

```
                    ┌──────────────────┐
                    │ MySQL (Compose) / │
                    │ RDS MySQL (prod) │
                    └─────────┬────────┘
                              │
       ┌──────────────────────┼──────────────────────┐
       │                      │                      │
┌──────▼──────┐    ┌─────────▼─────────┐   ┌────────▼────────┐
│ auth-service │    │  score-service     │   │ session-service │
│   (Kotlin)   │    │    (Groovy)       │   │    (Scala)      │
│    Ktor      │    │ Micronaut / JDBC  │   │    http4s       │
└──────┬───────┘    └─────────┬─────────┘   └────────┬────────┘
       │ POST /validate       │                      │
       └──────────────────────┴──────────────────────┘
              (service-to-service; cluster DNS in prod)
```

JWT: recommend **HS256 + `JWT_SECRET`** for speed; optional RS256 later if `/validate` becomes a bottleneck.

---

### Data model (MySQL-oriented)

Align names with Phase 3 payloads (`player_id`, scores, waves, kills).

**players**

| Column | Type | Notes |
|--------|------|--------|
| `id` | `CHAR(36)` PK (UUID strings) | Returned as `player_id` |
| `email` | `VARCHAR(255)` UNIQUE | Or username |
| `password_hash` | `VARCHAR(255)` | bcrypt/argon2 |
| `created_at` | `DATETIME(6)` | |

**scores**

| Column | Type | Notes |
|--------|------|--------|
| `id` | `BIGINT` AUTO_INCREMENT PK | |
| `player_id` | `CHAR(36)` FK → players | |
| `score` | `INT` | |
| `wave_reached` | `INT` | |
| `created_at` | `DATETIME(6)` | |

**game_sessions**

| Column | Type | Notes |
|--------|------|--------|
| `id` | `CHAR(36)` PK | **`session_id`** returned to clients |
| `player_id` | `CHAR(36)` FK → players | Nullable only if you allow anonymous sessions |
| `started_at` | `DATETIME(6)` | |
| `ended_at` | `DATETIME(6)` NULL | Set on `/session/end` |
| `score`, `waves`, `kills` | `INT` NULL | Final stats |

Indexes: `scores(player_id)`, `scores(score DESC)`; `game_sessions(player_id, started_at DESC)`.

One **`db/migrations`** tree; apply against Compose MySQL in Part 1, same migrations against RDS in prod.

---

### API contracts

**auth-service**

| Method | Path | Body | Response |
|--------|------|------|----------|
| POST | `/register` | `{ "email", "password" }` | `{ "token", "player_id" }` |
| POST | `/login` | `{ "email", "password" }` | `{ "token", "player_id" }` |
| POST | `/validate` | `{ "token": "..." }` | `{ "valid": true, "player_id": "..." }` or 401 |

**score-service**

| Method | Path | Notes |
|--------|------|--------|
| POST | `/scores` | `{ "player_id", "score", "wave_reached" }`; Bearer JWT |
| GET | `/leaderboard` | Top 10 join players |
| GET | `/scores/:player` | Personal best (define: max score vs best run) |

**session-service**

| Method | Path | Notes |
|--------|------|--------|
| POST | `/session/start` | Returns `{ "session_id" }` |
| POST | `/session/end` | `{ "session_id", "score", "waves", "kills" }` |
| GET | `/session/history/:player` | History list |

Errors: stable JSON shape, e.g. `{ "error": "invalid_credentials", "message": "..." }`.

---

### Cross-cutting

- Env: `DATABASE_URL` / host+port+database, `DATABASE_USER`, `DATABASE_PASSWORD`, `JWT_SECRET`, `AUTH_SERVICE_URL` (for `/validate` calls), `PORT` (default 8080). K8s Secrets in prod; Compose env file locally.
- **`GET /health`** liveness; **`GET /ready`** optional DB check for Kubernetes.
- Parameterized SQL only; hash passwords; restrict `/validate` to cluster network in prod (NetworkPolicy optional).

---

### Repository layout (recommended)

```
services/
  auth-service/
  score-service/
  session-service/
db/
  migrations/
docker/
  Dockerfile.jvm    # Gradle → temurin:21-jre-alpine; build-arg for which service
```

Gradle: composite build + version catalog, or three independent roots — pick one.

Extend root **`compose.yaml`**: **mysql** service + three app services; shared env contract with future K8s.

---

### Implementation sequence

1. **`db/migrations`** — validate on **Compose MySQL** (Part 1 gate).  
2. **`Dockerfile.jvm` + hello jar** — prove build once.  
3. **`auth-service`** — register / login / validate + JWT.  
4. **`score-service` and `session-service` in parallel** — after JWT + schema are frozen.

Critical path: migrations → auth → (scores ∥ sessions).

Lock before parallelizing: JWT claims (`player_id` / `sub`), and whether scores tie to sessions.

---

### When to deploy subagents

| Situation | Pattern |
|-----------|---------|
| Gradle layout exploration | One readonly explore pass |
| **auth-service** end-to-end | One agent — owns JWT + DB |
| After auth MVP: **score** + **session** | **Two agents in parallel** — separate dirs; shared `db/` + contract only |
| Dockerfile hardening | One agent after jars exist |
| Works locally, fails on EKS | Sequential debug — networking/RDS first |

Do **not** parallelize three greenfield services before migrations and JWT rules exist.

---

### Verification gates

1. Integration tests: auth; scores + leaderboard; session start/end + history.  
2. **Compose + MySQL**: full smoke (Part 1 complete).  
3. EKS + RDS: same smoke from a pod inside the cluster.  
4. Optional: committed `examples/*.http` or similar.

---

### Phase 2 risks

| Risk | Mitigation |
|------|------------|
| Three languages / Gradle configs | Shared version catalog; JDK 21 everywhere |
| JWT drift | Shared test vectors (same token → same `player_id`) |
| Local MySQL vs RDS | Same major MySQL version family; test migrations on both |

---

## Phase 3 — Shmup integration

The shmup needs to make these HTTP calls:

```gdscript
# On game start
session_service.POST /session/start

# On game over
score_service.POST /scores
session_service.POST /session/end

# Leaderboard screen
score_service.GET /leaderboard
```

That's it. The game stays simple; the backend does the work.

---

## Phase 4 — CI/CD pipeline

- push to dev → build all images, deploy to dev env  
- RC1 commit → promote to QA (nightly build gate)  
- PR merge to uat → promote to UAT  
- v1.0.0 tag → Blue/Green cutover to prod  

The headless Godot export step in CI is the thing that makes everyone's jaw drop — that's your demo moment.

---

## Phase 5 — Observability

```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack
helm install loki grafana/loki-stack
```

Grafana OAuth via GitHub — short config work, kills the username/password requirement. CPU, memory, disk dashboards come free with kube-prometheus-stack. Add email alert rules for >80% thresholds.
