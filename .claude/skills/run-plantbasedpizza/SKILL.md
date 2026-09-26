---
name: run-plantbasedpizza
description: Build, start, smoke-test, screenshot and stop the full PlantBasedPizza microservices stack (13 .NET services + Dapr sidecars, Mongo, Redis, Temporal, nginx gateway, React frontend) with podman or docker. Use when asked to run, launch, start, test end-to-end, place an order, screenshot the frontend, or verify an event flow (order -> payment -> kitchen) in this repo.
---

# Run PlantBasedPizza

Paths are relative to the repo root (`module5/`). The whole stack is started as one unit
from `docker-compose.yml` (infrastructure) and `docker-compose-services.yml` (apps). The agent drives it with:

- **`.claude/skills/run-plantbasedpizza/stack.sh`**: builds, brings up, checks status, smoke-tests and tears down the stack. `smoke` uses curl through the gateway at `:5051`.
- **`.claude/skills/run-plantbasedpizza/ui.mjs`**: a Playwright driver for the React UI at `:3000`. It takes screenshots.

Verified on Windows 11 + Podman 5.6 (WSL machine) + Git Bash, with docker-compose v2 as the
compose provider. There is **no Docker** on the machine where this was authored; `stack.sh` uses
podman if it exists and docker otherwise (`CE=docker` forces docker). It has not been
verified on docker.

## Prerequisites

- `podman` with a running machine (`podman machine list` shows "Currently running"), plus
  `podman compose` (it shells out to `docker-compose.exe`, which is fine).
- Node 18+ and a locally installed Google Chrome, for the UI driver only.
- The WSL VM needs about 4 GB of free RAM for 36 containers. The Podman machine reports "2GiB",
  but the WSL VM actually had 15 GB. Check with `podman machine ssh free -m`.

## Build (first time, or after code changes)

```bash
bash .claude/skills/run-plantbasedpizza/stack.sh build              # all 13 .NET images + frontend, ~15-20 min cold
bash .claude/skills/run-plantbasedpizza/stack.sh build order-api    # rebuild just the tags you changed
```

Each image is built from `src/` as the context with the service's `Dockerfile-x86`. The image
tags match what `docker-compose-services.yml` expects (e.g. `order-api`, `kitchen-worker`, `frontend`).
After rebuilding, run `up` again; compose recreates only the containers whose image changed.
**Under Podman, that recreate gets stuck for any service with a Dapr sidecar.** The old container is left
`Exited (137)`, and a `<hash>_local.<name>` twin sits in `Created`. Podman can't remove a
container whose network namespace the sidecar is using. Remove all three, then run `up` again:

```bash
podman rm -f module5-ordersworker-dapr-1 local.orders-worker $(podman ps -aq --filter name=_local.orders-worker)
bash .claude/skills/run-plantbasedpizza/stack.sh up
```

The first event delivered through a freshly recreated sidecar can take about 60s (Redis stream redelivery), so
the first `smoke` after a recreate may report `SMOKE FAIL` even though the order confirms later. Run it again.

## Run (agent path)

```bash
bash .claude/skills/run-plantbasedpizza/stack.sh up       # infra -> wait for Temporal -> services -> wait for :5051 and :3000
bash .claude/skills/run-plantbasedpizza/stack.sh smoke    # register/login/order/submit via gateway; prints "SMOKE OK"
cd .claude/skills/run-plantbasedpizza && npm install --silent && node ui.mjs   # UI flow; prints "UI OK"
```

`smoke` checks the async event chain. It passes only when the order history reaches
`"Payment taken" -> "Order confirmed"`. Both entries are written by Dapr pub/sub events, not by the submit call.

`ui.mjs` registers a new user, logs in, clicks "+" on Margherita, opens the cart, clicks
**Submit Order**, then opens `/orders`. Screenshots go to `.claude/skills/run-plantbasedpizza/shots/`
(`01-menu.png` is full-page, then `02-submitted.png` and `03-orders.png`; `error.png` is written on failure).
Set `HEADED=1` to watch it run.

Other commands:

```bash
bash .claude/skills/run-plantbasedpizza/stack.sh status                   # "running: 36 containers (expect 36)" + any EXITED
bash .claude/skills/run-plantbasedpizza/stack.sh logs local.orders-worker # TAIL=200 for more lines
bash .claude/skills/run-plantbasedpizza/stack.sh down                     # remove all containers + network (images kept)
```

Useful endpoints:

| Endpoint | What it is |
|---|---|
| `http://localhost:5051/{recipes,account,order,kitchen,delivery,loyalty}` | nginx gateway |
| `http://localhost:3000` | Frontend |
| `http://localhost:3000/admin/login` | Admin UI: `admin@plantbasedpizza.com` / `AdminAccount!23` |
| `:8090` | Temporal UI |
| `:16686` | Jaeger |
| `:27017` | Mongo |

## Run (human path)

The README's `make build` + `docker-compose up` only works with real Docker and `make`.
Neither is installed here, and the gotchas below still apply. Use `stack.sh up`, then open http://localhost:3000.

## Gotchas

- **`postgres:latest` is now v18**, which refuses to start with the repo's
  `/var/lib/postgresql/data` volume layout ("there appears to be PostgreSQL data in … unused
  mount"). Temporal then loops on `nc: bad address 'postgresql'`, and **orders-worker dies**
  with a Temporal `ConnectionRefused`. Its exit code 139 looks like a segfault but isn't one.
  `infra.override.yml` pins `postgres:17`. This breaks on Docker too, not just Podman.
- **Podman rejects `expose: "8085:8080"`** (`invalid range format for --expose`) on
  account-api and delivery-api; Docker ignores it. `stack.sh` writes a patched copy to
  `.generated/services.yml`, rewriting only `expose:` entries. Don't use a blanket sed:
  the same `"NNNN:8080"` pattern appears under `ports:`, and those mappings must stay.
- **The frontend container exits right after start**: CRA sees the WSL kernel in the Podman VM
  and spawns `/mnt/c/Windows/.../powershell.exe` to open a browser (ENOENT).
  `services.override.yml` sets `BROWSER=none`.
- **Order matters.** orders-worker has no restart policy and dies if Temporal isn't up yet.
  Restarting it alone isn't enough: its Dapr sidecar (`network_mode: service:`) also exits and
  must be started after it. `stack.sh up` avoids this by waiting for Temporal's frontend log line first.
- **A port probe doesn't prove readiness under Podman.** gvproxy accepts connections on published
  ports before the backend listens. Wait on log lines or HTTP 200s instead.
- **Every `podman compose` call must use `-p module5 --project-directory <repo root>`.**
  Otherwise running `down` from `src/` fails with "cannot find docker-compose-services.yml". Also,
  both compose files share project `module5`, so `down` on either one removes **all** 36 containers.
- **`DAPR_HOST=host.docker.internal`** in the compose file is unused by the code. The Dapr SDK
  talks to the sidecar on `localhost:5101` through the shared network namespace.
- **Menu cards sit below a full-height hero.** A viewport screenshot of `/` shows only
  "Italian Pizza. Plant Based. Simple.", so `01-menu.png` is taken full-page.
- **"Payment taken for 0!"** in the order history is what the app actually prints, even for a
  4.99 order. That's existing behaviour, not a harness bug.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Error response from daemon: fill out specgen: invalid range format for --expose: 8085:8080/tcp` | You ran the raw compose file. Use `stack.sh up`. |
| `temporal-postgresql Exited (1)`, `temporal` logs `Waiting for PostgreSQL to startup` | The `infra.override.yml` postgres pin wasn't applied. Run `podman rm -f -v temporal-postgresql`, then `stack.sh up`. |
| `local.orders-worker Exited (139)` and `module5-ordersworker-dapr-1 Exited (1)` | Temporal wasn't ready. Run `podman start local.orders-worker`, then `podman start module5-ordersworker-dapr-1` (in that order), or run `down` + `up`. |
| `module5-frontend-1 Exited (1)`, logs `spawn /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ENOENT` | `BROWSER=none` is missing. Use `stack.sh up`. |
| `open …\src\docker-compose-services.yml: The system cannot find the file specified` | The command ran from the wrong cwd. Use `stack.sh`, which pins the project directory. |
| `docker: command not found` | Expected here. `stack.sh` falls back to podman. |
