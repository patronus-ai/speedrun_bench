#!/bin/bash
# ASSERT THE BAN FROM THE ACTOR'S SIDE, before a run is allowed to count.
#
#   bash scripts/preflight_ban.sh <actor_container> <URL_ENV_NAME> [scorer_basename ...]
#   e.g. bash scripts/preflight_ban.sh e3l9-opus-scratch W3D_EVAL_URL wolf3d_boss_score.py
#
# WHY. "The compose says EVAL_BUDGET=0" is not evidence. Tonight alone produced four ways for a
# run to look healthy and mean nothing: an eval-service that was never created while the actor
# ran anyway; a squid proxy 403ing the scorer URL so no verdict ever arrived; a guard whose
# reference file was excluded by .dockerignore so it passed everything; and an agent that simply
# ran the scorer locally because it was still in the image. Each was invisible in `docker ps`
# and in the exit code.
#
# So this checks the two things that actually constitute a ban, from inside the actor:
#   1. THE MEANS ARE GONE   - no local scorer to execute.
#   2. THE BOUNDARY REFUSES - an UNPRIVILEGED POST returns 429, and the URL is reachable at all
#                             (a 403 from the proxy is NOT a ban, it is a broken run).
# Exit non-zero if either fails.
set -u
C="${1:?usage: preflight_ban.sh <actor_container> <URL_ENV_NAME> [scorer ...]}"
URLVAR="${2:?missing URL env var name, e.g. W3D_EVAL_URL}"
shift 2
SCORERS="$*"
FAIL=0
ok()  { echo "  [ ok ] $*"; }
bad() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

echo "=== BAN PREFLIGHT: $C ($URLVAR)"
docker ps --format '{{.Names}}' | grep -qx "$C" || { bad "actor container is not running"; exit 1; }

# ---------------------------------------------------------------- 1. means removed
for s in $SCORERS; do
  if docker exec "$C" sh -c "test -e /work/scripts/$s" 2>/dev/null; then
    bad "local scorer /work/scripts/$s EXISTS in the actor -- the ban is bypassable"
  else
    ok "no local /work/scripts/$s"
  fi
done

# ---------------------------------------------------------------- 2. boundary refuses
URL=$(docker exec "$C" sh -c "printf '%s' \"\${$URLVAR:-}\"" 2>/dev/null)
[ -n "$URL" ] || { bad "$URLVAR is EMPTY in the actor -- nothing to score against"; echo; echo "=== $FAIL failure(s)"; exit 1; }
ok "$URLVAR=$URL"

# Reachability first: a proxy 403 looks like a refusal but means NO verdict ever arrives.
# Two service shapes exist: stx/w3d/astray answer GET /, the generic eval_service.py answers
# GET /stats and 404s on /. Probe both -- a 404 from the wrong path is not an unreachable service.
CODE=$(docker exec "$C" sh -c "curl -s -o /dev/null -w '%{http_code}' '$URL/' 2>/dev/null")
if [ "$CODE" = "404" ]; then
  CODE=$(docker exec "$C" sh -c "curl -s -o /dev/null -w '%{http_code}' '$URL/stats' 2>/dev/null")
fi
case "$CODE" in
  200) ok "service reachable (GET / -> 200)" ;;
  403) bad "GET / -> 403: the PROXY is blocking it (add the host to no_proxy). Not a ban." ;;
  *)   bad "GET / -> ${CODE:-no response}: service unreachable" ;;
esac

# The real assertion: an agent-style POST, with NO secret, must be refused with 429.
POST=$(docker exec "$C" sh -c \
  "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
   --data '{\"actions\":[]}' '$URL/score' 2>/dev/null")
case "$POST" in
  429) ok "unprivileged POST /score -> 429 (BANNED, refused at the boundary)" ;;
  200) bad "unprivileged POST /score -> 200: the agent CAN score. EVAL_BUDGET is not 0." ;;
  403) bad "unprivileged POST /score -> 403: proxy again, not the service" ;;
  *)   bad "unprivileged POST /score -> ${POST:-no response}" ;;
esac

echo
if [ "$FAIL" -eq 0 ]; then
  echo "=== BAN HOLDS: means removed AND boundary refuses."
else
  echo "=== $FAIL FAILURE(S) -- this arm must NOT be reported as banned."
fi
exit $(( FAIL > 0 ))
