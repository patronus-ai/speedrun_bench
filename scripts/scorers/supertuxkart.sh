#!/usr/bin/env bash
# GAME ADAPTER: supertuxkart — drive a lap of Black Forest in the fewest seconds, scored by an
# eval-service in ANOTHER container. Protocol: see scripts/scorers/_lib.sh.
#
# The actor holds no engine: the 13MB native binary and the 1.5GB stk-assets checkout live only
# in the eval-service, so EVAL_BUDGET=0 is a control rather than a request. The oracle is
# privileged via X-Eval-Secret from the orchestrator — the boundary is the CONTAINER boundary,
# and pk_eval_service.py's 186-turn dead run is what happens when that is missing.
#
# THE OBJECTIVE IS TIME, BUT NOTHING FINISHES A LAP YET, AND THAT IS THE POINT.
# tools/ghosts/episode.py:score_key ranks
#     finished    -> (1, 1.0,  -total_time)
#     unfinished  -> (0, alive,  max_distance)
#     timeout     -> below everything
# so an unfinished run still carries a gradient (metres) and any finish beats every non-finish.
# Today the human tape re-drives 369.88m of ~2614m and the re-derived line dies at pad 3
# (t=96.94), so early fleets live entirely in the `unfinished` branch and the leaderboard reads
# in METRES. Say so to the agent rather than implying a lap time is achievable.
#
# A MISSING max_distance IS REFUSED, NOT SCORED ZERO. episode.py raises on it, and this adapter
# propagates that: "a search would climb the hole for the rest of the run" is the failure mode,
# and it is the same class as the flag_get sampling bug that faked a 0-clear rate on SMB.
set -u
cd "$(dirname "$0")/../.." || exit 1
. scripts/scorers/_lib.sh

S_RESULT="results/speedrun/stk_oracle_last.json"

_cfg() {
  dflt GAME_LABEL      "SuperTuxKart — one lap of Black Forest in the fewest seconds"
  dflt BEST_PREFIX     "stk"
  dflt STK_EVAL_URL    "${EVAL_SERVICE_URL:-http://127.0.0.1:8940}"
  dflt STK_TRACK       "black_forest"
  dflt STK_KART        "tux"
  dflt ORACLE_SCORER   "the SuperTuxKart eval-service"
  # THIS STRING REACHES THE PROMPT EVERY TURN, so it outweighs an agent card read
  # once at the start. It described the DSL while the card described the tape, and
  # the agent kept authoring DSL -- the same contradiction shape as MK64's PLAN vs
  # EXEC hints.
  dflt ORACLE_ARTIFACT "a compiled history.dat TAPE, replayed verbatim: a header of \`History-version:\`, \
\`track:\`, \`laps:\`, \`difficulty:\`, \`reverse:\`, \`sim_cap:\`, \`model 0:\`, \`count:\` lines, then one \
\`<world_tick> <kart_index> <action> <value>\` event per line at 120 ticks/s. Actions are STK PlayerAction \
ids: 0=steer-left, 1=steer-right (0.0..1.0 magnitude), 2=accel (0.0..1.0), 3=brake, 4=nitro, 5=drift, \
7=fire. Values are STICKY -- an action holds until changed. Ticks must be non-decreasing."
  dflt ORACLE_BASELINE "the current VALIDATED best in results/speedrun/best/"
  dflt ORACLE_FIELDS   "max_distance"
}

case "${1:-}" in

vocab)
  _cfg
  emit GAME_LABEL; emit BEST_PREFIX
  emit ORACLE_SCORER; emit ORACLE_ARTIFACT; emit ORACLE_BASELINE; emit ORACLE_FIELDS
  emit STK_EVAL_URL; emit STK_TRACK; emit STK_KART
  emit_val CAND               "results/speedrun/candidate.traj"
  emit_val BEST_FRAME_MODE    best_dir
  # Metres, not frames: with nothing finishing, the promotion bar is a DISTANCE and larger is
  # better — the inverse of every other game here. A frames-style bar would promote the shortest
  # crash. The loop compares numerically, so the adapter emits distance*-1 via O_GF below.
  emit_val BEST_FRAME_FALLBACK "999999"
  emit_val BIZHAWK_AUTHORITATIVE 0
  emit_val BIZHAWK_CONFIG     "${BIZHAWK_CONFIG:-}"
  emit_val ORACLE_REVERIFY    0
  emit_val ORACLE_NAME        "stk"
  emit_val ORACLE_LOG_TAG     "(stk)"
  emit_val ORACLE_REACH_VERB  "finished the lap"
  emit_val ORACLE_GOAL_FAIL   "did NOT finish the lap"
  emit_val ORACLE_FEEDBACK_BY "the SuperTuxKart eval-service"
  dflt GAME_PLAN_HINTS "You are driving ONE lap of Black Forest, open-loop: the tape is a \
TICK-indexed list of control events and the engine replays it exactly. Two things a trajectory CANNOT \
express: ZIPPER PADS are a consequence of POSITION, not an input, so an open-loop tape can cross \
the track without ever triggering one and never exceeds the kart's normal speed cap. And NITRO is \
available but unspent. Aiming AT a pad is measured to be actively harmful: it catches the boost \
and then loses the line in the very next corner."
  # NO SEED FACTS IN THIS FILE. It ships inside the actor image, so a FROM-SCRATCH agent can read
  # it; any measured property of the seed written here is a leak into the scratch condition. The
  # seeded compose passes its seed-specific GAME_EXEC_HINTS / ORACLE_ARTIFACT through the
  # environment instead (dflt only fills what is unset), and compose files are not in the image.
  dflt GAME_EXEC_HINTS "You are scored on total_time once a lap finishes, and on max_distance \
(METRES, higher is better) until one does. Read the failure: \`reason\` and \`last_gain_time\` tell you \
WHERE progress stopped, which is worth more than the distance itself. Submit exactly ONE trajectory per \
turn; the budget is enforced by the service and you cannot reset it."
  emit GAME_PLAN_HINTS; emit GAME_EXEC_HINTS
  emit_val EVAL_BUDGET_ADVISORY 0
  emit_val PROMOTE_MODE rescore
  emit_val TAS_VOCAB_OK 1
  ;;

score)
  _cfg
  CAND="$2"
  rm -f "$S_RESULT"
  mkdir -p results/speedrun/oracle_history
  # Post the trajectory SOURCE inline. Path scoring would need a directory the actor can also
  # read, and that is the leak this topology exists to avoid.
  "$TAS_PY" - "$CAND" > "${SCRATCH_TMP:-/tmp}/stk_req.json" <<'PY'
import json, sys
print(json.dumps({"name": "candidate", "src": open(sys.argv[1]).read()}))
PY
  curl -s --max-time 1900 -X POST "$STK_EVAL_URL/score" \
       -H 'Content-Type: application/json' \
       ${EVAL_RESET_SECRET:+-H "X-Eval-Secret: $EVAL_RESET_SECRET"} \
       --data-binary @"${SCRATCH_TMP:-/tmp}/stk_req.json" -o "$S_RESULT"
  cp -f "$S_RESULT" "results/speedrun/oracle_history/turn_${TAS_ITER:-0}.json" 2>/dev/null || true
  "$TAS_PY" - "$S_RESULT" <<'PY' 2>/dev/null
import json, sys
try:
    r = json.load(open(sys.argv[1])) or {}
except Exception:
    r = {}
fin = bool(r.get("finished"))
tt  = r.get("total_time")
reach = r.get("max_distance")
# O_REACHED means "finished the lap", NOT "made progress". Conflating them would promote a crash.
print("O_REACHED=%d" % (1 if (fin and isinstance(tt, (int, float))) else 0))
# UNFINISHED GETS A FLAT SENTINEL, NOT A DISTANCE.
#
# The bar must be in TIME. An unfinished run has no time, so it gets one constant that every
# unfinished run shares: 9999999, above the 999999 fallback, so nothing unfinished can ever
# promote and all unfinished runs rank equal. `finished` still scores its real lap time and
# therefore beats every non-finish outright -- the lexicographic order episode.py defines.
#
# FLAT IS THE WHOLE POINT. A distance-dependent variant (9999999 - metres, or the
# 1_000_000 - metres I briefly shipped on 2026-09-19 and reverted in a3c3a9e) turns this into
# a gradient the search can climb WITHOUT finishing, and that is a measured failure, not a
# hypothetical: told to beat a metres bar, the agent produced max_distance 2653.22 / 2647.78 /
# 2620.04 against a ~2614m lap with laps_done=0 on every one. Distance is maximisable by going
# off-route or doubling back, so it rewards exactly what the task excludes. One subtraction is
# the difference between a sentinel and a reward hack.
#
# Empty string worked too -- this is the same behaviour with the field always populated, so
# `best=` stops reading as a phantom and nothing has to special-case None.
# max_distance stays where it already was: O_MP, feedback only, never the objective.
print("O_GF=%s" % (tt if (fin and isinstance(tt, (int, float))) else '9999999'))
print("O_DIED=0")
print("O_MP=%s" % (reach if isinstance(reach, (int, float)) else ''))
err = (r.get("error") or "")[:400].replace('"', "'").replace("\n", " ")
# A BUDGET REFUSAL IS NOT A LAP FAILURE. On EVAL_BUDGET=0 the service answers 429 with
# {"error": "scoring is DISABLED for the agent this turn ..."} and no result fields, so
# `fin` is False and O_REACHED is 0 -- which the loop would otherwise render as
# "REJECTED — did NOT finish the lap". Measured on stk-glm53: 199 of 200 turns said that
# while the arm was finishing laps at 164.5s. Flag it so the loop can say NOT SCORED.
_refused = ("EVAL_BUDGET" in err) or ("scoring is DISABLED" in err) or ("budget" in err.lower())
print("O_NOT_SCORED=%d" % (1 if (_refused and not fin) else 0))
why = r.get("reason") or r.get("not_alive_because") or ""
lg  = r.get("last_gain_time")
bits = []
if isinstance(reach, (int, float)): bits.append("max_distance=%.2fm of ~2614m" % reach)
if lg is not None: bits.append("last_gain_time=%s" % lg)
if why: bits.append("reason=%s" % why)
detail = "; ".join(bits) or "no diagnostic"
print('O_METRICS="%s (feedback only — a lap must FINISH to score a time) "' % detail)
print('O_FAIL_DETAIL="%s"' % (err or detail))
print('O_TAIL="%s"' % (" NOTE: " + err if err else ""))
print('O_LOG_EXTRA=" | %s"' % detail)
PY
  ;;

verify) emit_val O_VERIFY_GF "" ;;   # unreachable: ORACLE_REVERIFY=0
post) : ;;
*) echo "usage: $0 {vocab|score <cand>|verify <path>|post}" >&2; exit 2 ;;
esac
