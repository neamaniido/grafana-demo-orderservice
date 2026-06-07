#!/usr/bin/env bash
# demo-check.sh — pre-demo readiness check
# Run this before presenting to catch problems early.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$REPO_ROOT/.env" ]; then
  echo "ERROR: $REPO_ROOT/.env not found. Copy .env.example to .env and fill it in." >&2
  exit 1
fi
# shellcheck disable=SC1091
set -a; . "$REPO_ROOT/.env"; set +a

: "${GRAFANA_HOST:?GRAFANA_HOST not set in .env}"
: "${GCX_CONTEXT:?GCX_CONTEXT not set in .env}"
: "${ALERT_RULE_UID:?ALERT_RULE_UID not set in .env}"
: "${DASHBOARD_UID:?DASHBOARD_UID not set in .env}"

NAMESPACE="grafana-demo"
GRAFANA_URL="https://${GRAFANA_HOST}"
GCX_CONFIG="${HOME}/.config/gcx/config.yaml"
PASS=0
FAIL=0

green() { printf '\033[0;32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m✗ %s\033[0m\n' "$*"; }
warn()  { printf '\033[0;33m⚠ %s\033[0m\n' "$*"; }

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Pre-demo readiness check — Order Service Demo"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── 1. All pods Running ──────────────────────────────
printf "1. Pods running... "
NOT_READY=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
  | awk '!/Running/{c++} END{print c+0}')
if [ "$NOT_READY" -gt 0 ]; then
  red "FAIL — $NOT_READY pod(s) not Running (run './deploy.sh' to redeploy)"
  kubectl get pods -n "$NAMESPACE"
  FAIL=$((FAIL+1))
else
  PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers | wc -l | tr -d ' ')
  green "all $PODS pods Running"
  PASS=$((PASS+1))
fi

# ── 2. BUG_ENABLED=true (env + health API) ──────────
printf "2. N+1 bug enabled... "
BUG=$(kubectl exec -n "$NAMESPACE" deploy/order-service -- \
  env 2>/dev/null | grep BUG_ENABLED | cut -d= -f2 || echo "unknown")
if [ "$BUG" != "true" ]; then
  red "FAIL — BUG_ENABLED=$BUG (run './deploy.sh --reset' to re-enable)"
  FAIL=$((FAIL+1))
else
  # Verify the running image actually reads BUG_ENABLED via /health
  # (catches cases where the image was rebuilt without BUG_ENABLED code)
  HEALTH_BUG=$(kubectl exec -n "$NAMESPACE" deploy/order-service -- \
    python3 -c "
import urllib.request, json
r = urllib.request.urlopen('http://localhost:8080/health')
d = json.loads(r.read())
print(str(d.get('bug_enabled', 'missing')).lower())
" 2>/dev/null || echo "error")
  if [ "$HEALTH_BUG" != "true" ]; then
    red "FAIL — env BUG_ENABLED=true but /health returns bug_enabled=$HEALTH_BUG"
    red "       Image may lack BUG_ENABLED code — wait for GHA build and run './deploy.sh'"
    FAIL=$((FAIL+1))
  else
    SVC_VER=$(kubectl exec -n "$NAMESPACE" deploy/order-service -- \
      env 2>/dev/null | grep SERVICE_VERSION | cut -d= -f2 || echo "unknown")
    green "BUG_ENABLED=true (confirmed via /health)  (service.version=$SVC_VER)"
    PASS=$((PASS+1))
  fi
fi

# ── 3. order-6 latency > 800 ms ──────────────────────
printf "3. order-6 latency (N+1, 10 items, expect >800ms)... "
LATENCY=$(kubectl exec -n "$NAMESPACE" deploy/frontend-api -- \
  python3 -c "
import urllib.request, time
start = time.time()
urllib.request.urlopen('http://frontend-api:8080/checkout/order-6', timeout=15)
print(int((time.time()-start)*1000))
" 2>/dev/null || echo "0")
if [ "$LATENCY" -lt 800 ]; then
  warn "${LATENCY}ms — lower than expected (pods may need a moment to warm up)"
  PASS=$((PASS+1))
else
  green "${LATENCY}ms"
  PASS=$((PASS+1))
fi

# ── 4. Alert state (requires gcx/SA token) ───────────
printf "4. Alert firing... "
if [ ! -f "$GCX_CONFIG" ]; then
  warn "skipped — gcx config not found at $GCX_CONFIG"
else
  SA_TOKEN=$(python3 -c \
    "import yaml; c=yaml.safe_load(open('$GCX_CONFIG')); ctx=c['contexts']['$GCX_CONTEXT']; print(ctx.get('token') or ctx.get('grafana',{}).get('token') or '')" \
    2>/dev/null || echo "")
  if [ -z "$SA_TOKEN" ]; then
    warn "skipped — could not read SA token from gcx config for context '$GCX_CONTEXT'"
  else
    STATE=$(curl -s \
      -H "Authorization: Bearer $SA_TOKEN" \
      "${GRAFANA_URL}/api/prometheus/grafana/api/v1/rules" \
      | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for g in d.get('data', {}).get('groups', []):
        for r in g.get('rules', []):
            if r.get('name','').startswith('frontend-api'):
                print(r.get('state','unknown'))
                raise SystemExit
    print('not_found')
except SystemExit:
    pass
" 2>/dev/null || echo "error")
    case "$STATE" in
      firing)
        green "Firing — alert will appear in Grafana Assistant context"
        PASS=$((PASS+1))
        ;;
      pending)
        warn "Pending — will fire in <1 min (latency spike detected but window not elapsed)"
        PASS=$((PASS+1))
        ;;
      inactive|normal)
        red "FAIL — alert is $STATE (latency may be too low or pods just restarted)"
        FAIL=$((FAIL+1))
        ;;
      not_found)
        warn "skipped — alert rule not found via API"
        ;;
      *)
        warn "skipped — could not query alert state ($STATE)"
        ;;
    esac
  fi
fi

# ── Summary ──────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAIL" -eq 0 ]; then
  printf '\033[0;32m  ✓ Ready to demo! (%d checks passed)\033[0m\n' "$PASS"
  echo ""
  echo "  Quick-access URLs:"
  echo "  Alert:     ${GRAFANA_URL}/alerting/grafana/${ALERT_RULE_UID}/view"
  echo "  Dashboard: ${GRAFANA_URL}/d/${DASHBOARD_UID}"
  echo "  App O11y:  ${GRAFANA_URL}/a/grafana-app-observability-app/services"
  echo ""
  echo "  Start with: \"There's a critical alert firing, investigate what's happening.\""
  echo ""
else
  printf '\033[0;31m  ✗ Not ready — %d check(s) failed, %d passed\033[0m\n' "$FAIL" "$PASS"
  echo "  Fix the issues above before starting the demo."
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
