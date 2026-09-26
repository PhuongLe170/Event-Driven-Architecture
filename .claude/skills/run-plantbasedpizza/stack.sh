#!/usr/bin/env bash
# Build / start / smoke-test / stop the full PlantBasedPizza stack with podman (or docker).
# Usage: stack.sh build|up|smoke|status|logs <container>|down
# Run from anywhere; paths resolve relative to the repo root (<unit>).
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
GEN="$SKILL_DIR/.generated"
CE="${CE:-$(command -v podman >/dev/null && echo podman || echo docker)}"
GW=http://localhost:5051

compose() { (cd "$ROOT" && $CE compose -p module5 --project-directory . "$@"); }

# Podman rejects `expose: "HOST:CONTAINER"` (docker silently accepts it). Rewrite only
# entries under `expose:` blocks into a generated copy; the repo file stays untouched.
gen_services() {
  mkdir -p "$GEN"
  awk '/^\s+expose:/{e=1;print;next} e && /^\s+- "[0-9]+:[0-9]+"/{sub(/"[0-9]+:/,"\"");print;next} {e=0;print}' \
    "$ROOT/docker-compose-services.yml" > "$GEN/services.yml"
}

build() {
  local src="$ROOT/src" failed=()
  local -a b=(
    "PlantBasedPizza.Account/application/PlantBasedPizza.Account.Api/Dockerfile-x86 account-api"
    "PlantBasedPizza.Delivery/application/PlantBasedPizza.Delivery.Api/Dockerfile-x86 delivery-api"
    "PlantBasedPizza.Delivery/application/PlantBasedPizza.Delivery.Worker/Dockerfile-x86 delivery-worker"
    "PlantBasedPizza.Kitchen/application/PlantBasedPizza.Kitchen.Api/Dockerfile-x86 kitchen-api"
    "PlantBasedPizza.Kitchen/application/PlantBasedPizza.Kitchen.Worker/Dockerfile-x86 kitchen-worker"
    "PlantBasedPizza.LoyaltyPoints/application/PlantBasedPizza.LoyaltyPoints.Api/Dockerfile-x86 loyalty-api"
    "PlantBasedPizza.LoyaltyPoints/application/PlantBasedPizza.LoyaltyPoints.Internal/Dockerfile-x86 loyalty-internal-api"
    "PlantBasedPizza.LoyaltyPoints/application/PlantBasedPizza.LoyaltyPoints.Worker/Dockerfile-x86 loyalty-worker"
    "PlantBasedPizza.Orders/application/PlantBasedPizza.Orders.Api/Dockerfile-x86 order-api"
    "PlantBasedPizza.Orders/application/PlantBasedPizza.Orders.Worker/Dockerfile-x86 order-worker"
    "PlantBasedPizza.Orders/application/PlantBasedPizza.Orders.Internal/Dockerfile-x86 order-internal"
    "PlantBasedPizza.Payments/application/PlantBasedPizza.Payments/Dockerfile-x86 payment-api"
    "PlantBasedPizza.Recipes/applications/PlantBasedPizza.Recipes.Api/Dockerfile-x86 recipe-api"
  )
  # Optional: `stack.sh build order-api kitchen-worker` rebuilds just those tags.
  for entry in "${b[@]}"; do
    set -- $entry
    if [ ${#ONLY[@]} -gt 0 ] && [[ ! " ${ONLY[*]} " =~ " $2 " ]]; then continue; fi
    echo "===== BUILD $2"
    $CE build -q -f "$src/$1" -t "$2" "$src" || failed+=("$2")
  done
  if [ ${#ONLY[@]} -eq 0 ] || [[ " ${ONLY[*]} " =~ " frontend " ]]; then
    echo "===== BUILD frontend"; $CE build -q -t frontend "$src/frontend" || failed+=(frontend)
  fi
  echo "FAILED: ${failed[*]:-none}"; [ ${#failed[@]} -eq 0 ]
}

up() {
  gen_services
  echo "== infra"; compose -f docker-compose.yml -f "$SKILL_DIR/infra.override.yml" up -d 2>&1 | grep -E "Started|Error" || true
  # orders-worker exits (no restart policy) if Temporal isn't accepting connections yet.
  echo -n "== waiting for temporal :7233"
  for i in $(seq 1 60); do
    $CE logs temporal 2>&1 | grep -q '"service":"frontend"' && (exec 3<>/dev/tcp/127.0.0.1/7233) 2>/dev/null && break
    echo -n .; sleep 3
  done; echo; sleep 10
  echo "== services"; compose -f "$GEN/services.yml" -f "$SKILL_DIR/services.override.yml" up -d 2>&1 | grep -E "Error" || true
  echo -n "== waiting for gateway $GW/recipes"
  for i in $(seq 1 40); do curl -sf "$GW/recipes" >/dev/null && break; echo -n .; sleep 3; done; echo
  echo -n "== waiting for frontend :3000 (CRA dev server compiles on start)"
  for i in $(seq 1 40); do curl -sf http://localhost:3000 >/dev/null && break; echo -n .; sleep 3; done; echo
  status
}

status() {
  local bad; bad=$($CE ps -a --filter label=com.docker.compose.project=module5 --filter status=exited --format '{{.Names}} {{.Status}}')
  echo "running: $($CE ps -q --filter label=com.docker.compose.project=module5 | wc -l) containers (expect 36)"
  if [ -n "$bad" ]; then echo "EXITED:"; echo "$bad"; return 1; fi
}

smoke() {
  # register -> login -> pickup order -> add item -> submit -> wait for payment/confirmation events
  local email="smoke$(date +%s)@test.com" pw='Smoke!Pass123' tok on body
  j() { curl -s -H 'Content-Type: application/json' "$@"; }
  echo "## GET /recipes"; j "$GW/recipes" | cut -c1-120; echo
  echo "## register $email"; j -X POST "$GW/account/register" -d "{\"emailAddress\":\"$email\",\"password\":\"$pw\"}"; echo
  tok=$(j -X POST "$GW/account/login" -d "{\"emailAddress\":\"$email\",\"password\":\"$pw\"}" | sed -E 's/.*"authToken":"([^"]+)".*/\1/')
  echo "## login token ${tok:0:20}..."
  local A="Authorization: Bearer $tok"
  on=$(j -H "$A" -X POST "$GW/order/pickup" -d '{"customerIdentifier":""}' | sed -E 's/.*"orderNumber":"([^"]+)".*/\1/')
  echo "## order $on"
  j -H "$A" -X POST "$GW/order/$on/items" -d "{\"OrderIdentifier\":\"$on\",\"RecipeIdentifier\":\"marg\",\"Quantity\":1}" >/dev/null
  j -H "$A" -o /dev/null -w "## submit HTTP %{http_code}\n" -X POST "$GW/order/$on/submit" -d "{\"OrderIdentifier\":\"$on\",\"CustomerIdentifier\":\"\"}"
  for i in $(seq 1 15); do
    body=$(j -H "$A" "$GW/order/$on/detail")
    echo "$body" | grep -q 'Order confirmed' && break; sleep 2
  done
  echo "## history:"; echo "$body" | grep -o '"description":"[^"]*"' | sed 's/"description"://'
  echo "$body" | grep -q 'Order confirmed' && echo "SMOKE OK" || { echo "SMOKE FAIL: order never confirmed (payment/event flow broken)"; return 1; }
}

down() {
  gen_services
  compose -f "$GEN/services.yml" -f "$SKILL_DIR/services.override.yml" down 2>&1 | tail -1
  compose -f docker-compose.yml -f "$SKILL_DIR/infra.override.yml" down 2>&1 | tail -1
  status
}

cmd="${1:-}"; shift || true; ONLY=("$@")
case "$cmd" in
  build) build ;; up) up ;; smoke) smoke ;; status) status ;; down) down ;;
  logs) $CE logs --tail "${TAIL:-40}" "$1" ;;
  *) echo "usage: $0 build [tag...]|up|smoke|status|logs <container>|down"; exit 2 ;;
esac
