#!/bin/bash
# GAME ADAPTER: Tuxemon (pygame RPG) — reach spyder_leather_gym in the fewest engine steps.
# Protocol: see scripts/scorers/_lib.sh. Shape copied from supertux.sh: a non-emulator game whose
# only evaluator is an external scorer reached over HTTP.
#
# WHY THIS TITLE IS SCORABLE AT ALL. Stock Tuxemon is nondeterministic -- the loop is driven by
# setTimeout-style wall-clock timing, so the same inputs advance a different number of ticks on a
# busy machine. A fixed-dt tick() loop gated on TUXEMON_DETERMINISTIC=1 fixes it. Verified:
# identical action sequences in two separate processes reproduce intro_steps 2291, 2606 engine
# ticks, tile [1,2], state hash 39ed364696e197a6.
#
# THE FLAG NAME IS A TRAP. TUXEMON_DETERMINISTIC=1 enables determinism. TUXEMON_DETERMINISTIC_DRAW=1
# only forces DRAWING. Setting the latter alone leaves deterministic_mode false and identical tapes
# then score differently, which reads exactly like an engine bug -- it cost a wrong "screen
# resolution changes the run" conclusion during development. The eval service sets the real flag.
#
# THE CLOCK IS ENGINE STEPS, and it INCLUDES the intro. Character creation is a fixed cutscene the
# driver auto-answers; every candidate pays it identically, so it is a constant, not a lever.
# tux_score.py reports steps_after_handoff alongside engine_steps so the constant can be netted out.
#
# THIS FILE IS READABLE BY THE AGENT -- KEEP BASELINE FACTS OUT OF IT.
# The agent image ships the repo, so a from-scratch arm can `cat` this adapter. An earlier version
# of this header stated the baseline's step count, its map route, and how many times it lost the
# mandatory battle. The very first scratch arm read all three and wrote them into its PLAN.md under
# "Hard facts (authoritative, from scripts/scorers/tuxemon.sh)" -- so an arm that was supposed to
# DISCOVER the route had been handed it, plus the number to beat. Eleven arms ran that way before
# it was caught, and their data was discarded.
#
# The same header also carried the line "Nothing here may state an achieved step count: these
# strings reach the prompt", twelve lines below the step count it stated. A rule written next to
# its own violation is not a control. So: no step counts, no map names beyond the goal, no
# battle-loss counts, no route ordering -- anywhere in this file, comments included. What the
# agent legitimately learns comes from the verdicts (final_map, maps_seen, maps_reached), which is
# the same channel a player would have.
set -u
cd "$(dirname "$0")/../.." || exit 1
. scripts/scorers/_lib.sh

X_RESULT="results/speedrun/tuxemon_oracle_last.json"

_cfg() {
  dflt GAME_LABEL      "Tuxemon — reach the leather-town gym in the fewest engine steps"
  dflt BEST_PREFIX     "tuxemon"
  dflt TUX_SCORER      "${TUX_DIR:-}/tools/tux_score.py"
  dflt TUX_PY          "${TUX_DIR:-}/.venv312/bin/python"
  dflt TUX_TARGET      "spyder_leather_gym.tmx"
  dflt TUX_MAX_STEPS   "200000"
  # Tuxemon resolves its mods RELATIVE TO CWD. Run from anywhere else and it dies with
  # "Metadata for mod 'tuxemon' not found" before a single step executes -- which the
  # adapter then reports as an empty score rather than an error. The eval service already
  # sets this; the local path must too.
  dflt TUX_CWD         "${TUX_DIR:-}"
  dflt ORACLE_SCORER   "the Tuxemon scorer"
  dflt ORACLE_ARTIFACT "a JSON list of [ACTION, COUNT] pairs, e.g. [[\"DOWN\", 12], [\"INTERACT\", 1], [\"RIGHT\", 30]] — valid actions are UP, DOWN, LEFT, RIGHT, INTERACT, BACK, NOOP, and each pair repeats that action COUNT times"
  dflt ORACLE_BASELINE "the current VALIDATED best in results/speedrun/best/"
  dflt ORACLE_FIELDS   "maps_reached"
  # From-scratch arms start with an empty best/, so this sentinel is what a first arrival must
  # beat -- any validated arrival is promotable.
  dflt BROWSER_BEST_FLOOR "999999"
}

case "${1:-}" in

vocab)
  _cfg
  emit GAME_LABEL; emit BEST_PREFIX
  emit ORACLE_SCORER; emit ORACLE_ARTIFACT; emit ORACLE_BASELINE; emit ORACLE_FIELDS
  emit TUX_SCORER; emit TUX_PY; emit TUX_TARGET; emit TUX_MAX_STEPS; emit TUX_CWD
  emit BROWSER_BEST_FLOOR
  emit_val BIZHAWK_AUTHORITATIVE 0
  emit_val BIZHAWK_CONFIG "${BIZHAWK_CONFIG:-}"
  emit_val BEST_FRAME_MODE     best_dir
  emit_val BEST_FRAME_FALLBACK "$BROWSER_BEST_FLOOR"
  emit_val ORACLE_REVERIFY    1
  emit_val ORACLE_NAME        "tuxemon"
  emit_val ORACLE_LOG_TAG     "(tuxemon)"
  emit_val ORACLE_REACH_VERB  "reached the gym"
  emit_val ORACLE_GOAL_FAIL   "did NOT reach the gym"
  emit_val ORACLE_FEEDBACK_BY "the Tuxemon scorer"
  # Keep apostrophes balanced: an ODD number breaks ${VAR:-...} and would silently leave the SML
  # platformer hints in force.
  dflt GAME_PLAN_HINTS "This is a top-down tile-based RPG. The player walks one TILE per \
directional input, talks to characters and confirms menus with INTERACT, and backs out of menus \
with BACK. The route crosses several maps, and entering a map edge moves you to the next one. \
Two things dominate the clock and neither is walking speed. FIRST, battles: wild encounters and \
trainer fights interrupt movement and are resolved automatically, but LOSING a fight warps the \
player back to where they started and the route has to be walked again -- a loss is worth far more \
lost steps than any amount of inefficient walking. SECOND, dead inputs: a direction pressed into \
a wall consumes steps and moves nothing, and an INTERACT with nothing in front opens and closes \
menus for free steps. Think in terms of: (a) which map the run ends on, which tells you where it \
stalled; (b) whether it ended on a battle loss or simply ran out of actions; (c) stretches where \
the tile position stops changing, which means inputs are being eaten by geometry."
  dflt GAME_EXEC_HINTS "Edit the tape, then RE-SCORE it and keep the edit ONLY if reached_target \
is still true AND engine_steps went down. The main failure mode: this is an OPEN-LOOP script \
through a state machine, so inserting or removing an early action shifts every later action into \
a different game state -- a tape that walked a corridor now walks into a wall, or presses \
INTERACT during a dialog and dismisses something it needed. When that happens do NOT mark the \
item blocked -- RE-AIM: the scorer reports final_map and maps_reached, so find the map where \
progress stopped and repair the tape THERE, then re-score. A run that stops on the SAME map on \
every variant needs a different route through it, not a differently timed one. Only mark \
[BLOCKED] after that search also fails."
  emit GAME_PLAN_HINTS; emit GAME_EXEC_HINTS
  emit_val EVAL_BUDGET_ADVISORY 0
  emit_val PROMOTE_MODE filename
  emit_val TAS_VOCAB_OK 1
  ;;

score)
  _cfg
  CAND="$2"
  rm -f "$X_RESULT"
  # TUX_EVAL_URL set -> score via the metered eval-service, which owns the scorer in a container
  # the agent cannot exec into. This is the ONLY supported path for a metered arm: SuperTux's
  # in-container scorer is exactly what let GLM self-score 244 times while being told each turn
  # that it may not. A :ro mount prevents modification, not execution.
  if [ -n "${TUX_EVAL_URL:-}" ]; then
    X_OUT=$("$TAS_PY" - "$CAND" "$X_RESULT" "$TUX_EVAL_URL" <<'PY' 2>&1
import json, os, sys, urllib.request, urllib.error
cand, out, url = sys.argv[1], sys.argv[2], sys.argv[3]
body = json.dumps({"tape": json.load(open(cand))}).encode()
hdrs = {"Content-Type": "application/json"}
# The ORACLE is privileged: it holds EVAL_RESET_SECRET, the agent does not. Without this header
# the harness's own scoring is metered like the agent's and EVAL_BUDGET=0 would block the run
# entirely. Privileged calls also do not consume the agent's per-turn budget.
sec = os.environ.get("EVAL_RESET_SECRET", "")
if sec:
    hdrs["X-Eval-Secret"] = sec
req = urllib.request.Request(url.rstrip("/") + "/score", data=body, headers=hdrs)
try:
    with urllib.request.urlopen(req, timeout=2400) as r:
        json.dump(json.load(r).get("result", {}), open(out, "w"))
except urllib.error.HTTPError as e:
    # A 429 is the BUDGET refusing, not a scorer fault -- surface it verbatim.
    sys.stderr.write(e.read().decode()[:400])
except Exception as e:
    sys.stderr.write(f"eval-service unreachable: {e!r}")
PY
    )
  else
    # SEEDED SCORING NEEDS THE SEED'S OWN REPLAY CONDITIONS, OR THE SEED SCORES AS A BAD TAPE.
    # A driver-derived seed only reproduces with combat NOT auto-resolved (auto_combat=True makes
    # the env discard the tape's battle inputs and break out of its busy loop early, shifting
    # every later input off its frame: 11 maps becomes 4) and with the same intro replayed, so
    # the handoff position matches. These stay EMPTY for the from-scratch fleet, whose condition
    # is unchanged.
    X_OUT=$(cd "$TUX_CWD" && TUXEMON_DETERMINISTIC=1 "$TUX_PY" "$TUX_SCORER" \
              --tape "$CAND" --out "$OLDPWD/$X_RESULT" \
              --target "$TUX_TARGET" --max-steps "$TUX_MAX_STEPS" \
              ${TUX_AUTO_COMBAT:+--auto-combat} ${TUX_NO_AUTO_COMBAT:+--no-auto-combat} \
              ${TUX_INTRO_ROUTE:+--intro-route "$TUX_INTRO_ROUTE"} \
              ${TUX_HANDOFF_STEP:+--handoff-step "$TUX_HANDOFF_STEP"} 2>&1)
  fi
  SC=$("$TAS_PY" - "$X_RESULT" <<'PY' 2>/dev/null
import json, sys
try:
    r = json.load(open(sys.argv[1])) or {}
    reached = bool(r.get("reached_target"))
    print("O_REACHED=%d" % (1 if reached else 0))
    print("O_GF=%s" % (r.get("engine_steps") if reached and r.get("engine_steps") is not None else ''))
    # Tuxemon has no death state that ends a run: losing a battle warps the player back and the
    # run continues. Always 0 -- the cost of a loss shows up as extra steps, not as died=1.
    print("O_DIED=0")
    # How much of the route was covered. FEEDBACK ONLY -- promotion is gated on reached_target,
    # so a tape cannot be rewarded for merely wandering through more maps.
    mr = r.get("maps_reached")
    print("O_MP=%s" % ('' if mr is None else mr))
    print("O_EXTRA='ended on %s, %s maps reached, %s of %s actions used'" % (
        str(r.get("final_map")).replace("'", ""), r.get("maps_reached"),
        r.get("n_actions_used"), r.get("n_actions_supplied")))
    # OPT-IN (TUX_MAP_TRAIL on the eval service). Rendered as `action_index:map` so the agent
    # can bound a route SEGMENT by action index -- the one thing the plain verdict never told it.
    # Emitted as a separate variable so the default feedback string is byte-identical when off.
    tr = r.get("map_trail")
    if tr:
        print("O_TRAIL='map trail (action_index:map): %s'" % (
            " ".join("%s:%s" % (a, str(m).replace("spyder_", "").replace(".tmx", ""))
                     for a, m in tr)[:1800].replace("'", "")))
except Exception as e:
    print("O_REACHED=0"); print("O_GF="); print("O_DIED=0"); print("O_MP=")
    print("O_ERR=%s" % str(e)[:120].replace(chr(10), ' '))
PY
)
  printf 'O_REACHED=0\nO_GF=\nO_DIED=0\nO_MP=\nO_ERR=\nO_EXTRA=\nO_TRAIL=\n%s\n' "$SC"
  O_REACHED=0; O_GF=""; O_DIED=0; O_MP=""; O_ERR=""; O_EXTRA=""; O_TRAIL=""
  eval "$SC" 2>/dev/null
  O_NOT_SCORED=0
  if [ ! -s "$X_RESULT" ]; then
    # A BUDGET REFUSAL IS NOT A FAILED RUN. On a banned arm the in-loop call is 429'd by design --
    # the orchestrator scores the candidate between turns -- and without this flag the loop would
    # tell the agent "REJECTED" every turn about a tape that was never run. (SuperTuxKart already
    # did this; Tuxemon did not, so its banned arms were shown a failure verdict each turn.)
    if printf '%s' "$X_OUT" | grep -qE 'scoring is DISABLED|EVAL_BUDGET'; then
      O_NOT_SCORED=1
      O_ERR=""   # the missing result file is EXPECTED on a refusal; do not report it as an error
      O_EXTRA="the metered eval-service declined to run it; the orchestrator scores your candidate between turns"
      olog "--- tuxemon ORACLE: not scored in-loop (banned); left for the orchestrator"
    else
      O_ERR="Tuxemon scorer produced no result: $(printf '%s' "$X_OUT" | tail -1 | cut -c1-160)"
      emit O_ERR
      olog "--- tuxemon ORACLE: scorer FAILED — $O_ERR"
    fi
  fi
  emit_val O_NOT_SCORED  "$O_NOT_SCORED"
  emit_val O_METRICS     "maps reached=${O_MP:-?} (feedback only — nothing is promoted for getting part-way; only reaching the gym counts). ${O_EXTRA:-} ${O_TRAIL:-}"
  emit_val O_FAIL_DETAIL "${O_EXTRA:-no detail}"
  emit_val O_TAIL        "${O_ERR:+ NOTE: $O_ERR}"
  emit_val O_LOG_EXTRA   " | measured=${O_GF:-none} maps=${O_MP:-none}"
  ;;

verify)
  _cfg
  # RE-VERIFY BEFORE PROMOTING. The caller has already copied the candidate into best/; this
  # re-scores the COPY as it now sits on disk, in a fresh scorer process, and keeps it only if
  # the number reproduces. Determinism makes that a real check rather than a formality.
  #
  # METERED MODE MUST GO THROUGH THE SERVICE TOO. supertux.sh missed this when `score` was
  # converted and the consequence was silent and total: in metered mode the local scorer is not in
  # the agent container at all, so verify produced NO output, the frame came back empty, and the
  # loop read that as "re-scored as no clear" and DELETED every genuine improvement -- 0 accepted
  # out of ~200 oracle verdicts across 8 arms, all false rejections.
  CAND="$2"
  if [ -n "${TUX_EVAL_URL:-}" ]; then
    V=$("$TAS_PY" - "$CAND" "$TUX_EVAL_URL" <<'PY' 2>/dev/null
import json, os, sys, urllib.request
cand, url = sys.argv[1], sys.argv[2]
body = json.dumps({"tape": json.load(open(cand))}).encode()
hdrs = {"Content-Type": "application/json"}
sec = os.environ.get("EVAL_RESET_SECRET", "")
if sec:
    hdrs["X-Eval-Secret"] = sec
req = urllib.request.Request(url.rstrip("/") + "/score", data=body, headers=hdrs)
try:
    with urllib.request.urlopen(req, timeout=2400) as r:
        d = (json.load(r) or {}).get("result", {}) or {}
    print(d.get("engine_steps") if d.get("reached_target") else "")
except Exception:
    print("")
PY
)
  else
    V=$(cd "$TUX_CWD" && TUXEMON_DETERMINISTIC=1 "$TUX_PY" "$TUX_SCORER" --tape "$CAND" \
          --out /dev/stdout --target "$TUX_TARGET" --max-steps "$TUX_MAX_STEPS" 2>/dev/null \
        | "$TAS_PY" -c 'import json,sys; d=json.load(sys.stdin); print(d.get("engine_steps") if d.get("reached_target") else "")')
  fi
  emit_val O_VERIFY_GF "$(printf '%s' "$V" | tr -d '[:space:]')"
  ;;

*)
  echo "usage: $0 {vocab|score CAND|verify CAND}" >&2
  exit 2
  ;;
esac
