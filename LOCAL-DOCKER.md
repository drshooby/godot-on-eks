# Local Docker stack (Phase 2 Part 1)

This repo runs **MySQL 8** plus three JVM microservices (**auth**, **score**, **session**) through **Docker Compose**. There is also an optional **Godot shooter** static build on another port.

If you only care about “make it run,” skip to [Quick start](#quick-start).

---

## What runs where

| Service           | Host port | Inside container | What it does |
|-------------------|-----------|------------------|--------------|
| **mysql**         | `3306`    | 3306             | Database; schema loaded from `db/migrations/` on **first** volume create |
| **auth-service**  | **8081**  | 8080             | Register / login / JWT / `POST /validate` |
| **score-service** | **8082**  | 8080             | Scores + leaderboard |
| **session-service** | **8083** | 8080           | Game sessions |
| **shooter**       | **8090**  | 80               | nginx + WASM game (not required for backend dev) |

All three APIs use **`JWT_SECRET`** to sign or verify the same HS256 tokens. **Use one secret for every service** (Compose already wires the same value).

---

## Prerequisites

- **Docker** with Compose v2 (`docker compose` command).
- You do **not** need Java or Gradle on your machine **unless** you want to compile outside Docker (see [Build without Docker](#build-without-docker-optional)).

---

## Quick start

From the **repository root** (where `compose.yaml` lives):

1. **Create your env file**

   ```bash
   cp .env.example .env
   ```

2. **Edit `.env`** and set at least:

   - `MYSQL_ROOT_PASSWORD`
   - `MYSQL_USER` / `MYSQL_PASSWORD` (app user MySQL creates)
   - `MYSQL_DATABASE` (default `fps` is fine)
   - `JWT_SECRET` (long random string; **32+ characters** recommended for HS256)

   Compose substitutes these into `compose.yaml`. The JVM services read **`DATABASE_*`** and **`JWT_SECRET`** from the environment Compose sets (and optionally merge overrides from `.env` via `env_file`).

3. **Start the backend**

   ```bash
   docker compose up -d mysql auth-service score-service session-service
   ```

   First run pulls **mysql:8.4** and builds the three images (Gradle runs **inside** the Dockerfile — can take a few minutes).

4. **Smoke checks**

   ```bash
   curl -s http://127.0.0.1:8081/health
   curl -s http://127.0.0.1:8081/ready
   curl -s http://127.0.0.1:8082/health
   curl -s http://127.0.0.1:8083/health
   ```

   Expect JSON like `{"status":"ok"}` or `{"status":"ready"}`.

5. **Optional: Godot shooter**

   ```bash
   docker compose up -d shooter
   ```

   Open **http://127.0.0.1:8090** in a browser.

---

## Environment variables (the part everyone forgets)

### File: `.env` (you create from `.env.example`)

Docker Compose automatically loads a file named **`.env`** in the same directory as `compose.yaml` for **variable substitution** in the YAML (`${MYSQL_USER}` etc.). Your services also use `env_file: .env` so you can add extra keys later without editing `compose.yaml`.

| Variable | Required | Used by | Purpose |
|----------|----------|---------|---------|
| `MYSQL_ROOT_PASSWORD` | **Yes** (for a real DB) | **mysql** container | Root password; healthcheck uses it |
| `MYSQL_DATABASE` | No (default **`fps`**) | mysql + apps | Database name |
| `MYSQL_USER` | **Yes** | mysql | Non-root user Compose creates |
| `MYSQL_PASSWORD` | **Yes** | mysql | Password for `MYSQL_USER` |
| `JWT_SECRET` | Strongly recommended | auth, score, session | Same HS256 secret everywhere |

The three JVM services get **derived** wiring from Compose (you usually **do not** set these manually in `.env` unless you customize):

| Set by Compose | Value | Meaning |
|----------------|-------|---------|
| `DATABASE_HOST` | `mysql` | DNS name of the DB container on the Compose network |
| `DATABASE_PORT` | `3306` | MySQL port |
| `DATABASE_NAME` | `${MYSQL_DATABASE:-fps}` | Same DB name as MySQL |
| `DATABASE_USER` | `${MYSQL_USER}` | App login (**must match** user MySQL created) |
| `DATABASE_PASSWORD` | `${MYSQL_PASSWORD}` | App password |
| `JWT_SECRET` | `${JWT_SECRET:-...}` | Long dev default exists; **override in `.env`** for anything serious |
| `PORT` | `8080` inside Dockerfile | Apps listen on 8080 **inside** the container; host ports are 8081–8083 |

**Important:** If `MYSQL_*` are empty when Compose parses the file, substitution can warn and MySQL may misconfigure. Fill `.env` before `docker compose up`.

---

## Useful commands

```bash
# Logs (follow all)
docker compose logs -f

# Logs one service
docker compose logs -f auth-service

# Stop everything in this compose file
docker compose down

# Stop and delete DB volume (reset schema + data — destructive)
docker compose down -v
```

Rebuild after code changes:

```bash
docker compose build auth-service score-service session-service
docker compose up -d mysql auth-service score-service session-service
```

---

## Database / migrations

- SQL files live in **`db/migrations/`** and are mounted into MySQL’s **`/docker-entrypoint-initdb.d`**.
- Scripts run only when the **`mysql_data`** volume is **empty** (first boot).  
  To re-apply from scratch: `docker compose down -v` (deletes volume), then `up` again.

---

## Minimal API flow (copy-paste)

Replace email/password if you want.

```bash
BASE=http://127.0.0.1:8081
EMAIL="you@example.com"
PASS='yourpassword-at-least-8-chars'

# Register
curl -sS -X POST "$BASE/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}"

# Save token from JSON, then:
TOKEN='paste-token-here'
PLAYER_ID='paste-player_id-here'

curl -sS -X POST "$BASE/validate" \
  -H 'Content-Type: application/json' \
  -d "{\"token\":\"$TOKEN\"}"

curl -sS -X POST http://127.0.0.1:8082/scores \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"score\":1234,\"wave_reached\":7}"

curl -sS http://127.0.0.1:8082/leaderboard

SID=$(curl -sS -X POST http://127.0.0.1:8083/session/start \
  -H "Authorization: Bearer $TOKEN" | jq -r .session_id)

curl -sS -X POST http://127.0.0.1:8083/session/end \
  -H 'Content-Type: application/json' \
  -d "{\"session_id\":\"$SID\",\"score\":100,\"waves\":3,\"kills\":10}"

curl -sS "http://127.0.0.1:8083/session/history/$PLAYER_ID"
```

(`jq` optional — use Python or your eyes to grab `token` / `session_id`.)

---

## Build without Docker (optional)

Requires **JDK 21** compatible toolchain (Gradle may auto-download 21 via Foojay resolver).

```bash
chmod +x ./gradlew
./gradlew :auth-service:shadowJar :score-service:shadowJar :session-service:shadowJar
```

Fat jars:

- `services/auth-service/build/libs/auth-service.jar`
- `services/score-service/build/libs/score-service.jar`
- `services/session-service/build/libs/session-service.jar`

Run locally only if MySQL is reachable at whatever you set for `DATABASE_*` (often `localhost` and a tunneled or local MySQL).

---

## Manual image build (optional)

Same Dockerfile for every service; **`MODULE`** picks which Gradle project to build:

```bash
docker build -f docker/Dockerfile.jvm --build-arg MODULE=auth-service -t fps-auth .
```

---

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| Compose warns about unset `MYSQL_*` | `.env` missing or variables empty |
| Apps exit / “Communications link failure” | MySQL not healthy yet; wait for **`mysql` healthy** (`docker compose ps`). Check `DATABASE_*` match `MYSQL_*` |
| `401` on score/session | Wrong/expired JWT or **`JWT_SECRET`** changed between register and request |
| Schema wrong after editing SQL | Volume already initialized — use `docker compose down -v` and recreate (data loss) |

---

## Where this fits in the plan

Phase 2 Part 1 goal: **everything talks to MySQL in Compose with health checks and stable APIs.** Kubernetes/RDS comes later; same images and env **names** are intended to carry forward.
