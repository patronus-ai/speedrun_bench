#!/bin/bash
# GAME ADAPTER: SuperTux (WASM, headless Chromium) — clear one level, fewest physics steps.
# Protocol: see scripts/scorers/_lib.sh.
#
# Same shape as astray.sh and wolf3d.sh: a BROWSER game with no emulator, whose only evaluator is
# scripts/stx_score.py.
#
# WHY THIS TITLE IS SCORABLE AT ALL. Stock SuperTux is nondeterministic -- the physics step SIZE
# is fixed but the step COUNT per frame comes from wall clock, so the same inputs run a different
# number of steps on a busy machine. Two changes fix it and both must stay in place: the game is
# built with a patch that forces one step per loop iteration, and the scorer DRIVES the loop
# rather than polling it. Verified 4/4 bit-identical over a fixed tape including one run under
# 8-way CPU saturation. Write-up: docs/supertux-determinism.md.
#
# THE CLOCK IS STEPS, NOT SECONDS. goal_frame is the physics-step index at which Tux touches the
# goal. That is deliberately the moment the end sequence STARTS, not when it finishes: the
# victory animation runs for a while afterwards, and timing to its end would add a constant to
# every run and make the metric partly measure animation length.
set -u
cd "$(dirname "$0")/../.." || exit 1
. scripts/scorers/_lib.sh

X_RESULT="results/speedrun/supertux_oracle_last.json"

_cfg() {
  # NOTHING here may name a route-generating tool or state an achieved step count: these strings
  # go into the prompt and this file is readable from the arm's own repo copy.
  dflt GAME_LABEL      "SuperTux — clear the level in the fewest physics steps"
  dflt BEST_PREFIX     "supertux"
  dflt STX_SCORER      "${STX_REPO:-}/tools/stx_score.py"
  dflt STX_PY          "/work/.venv/bin/python"
  dflt STX_LEVEL       "${STX_BUILD_DIR:-}/data/levels/world1/welcome_antarctica.stl"
  dflt STX_MAX_STEPS   "20000"
  dflt ORACLE_SCORER   "the SuperTux scorer"
  dflt ORACLE_ARTIFACT "a JSON object mapping STEP NUMBER to a list of [key, code, pressed] entries, e.g. {\"10\": [[\"ArrowRight\",\"ArrowRight\",1]], \"250\": [[\"Space\",\"Space\",1]], \"266\": [[\"Space\",\"Space\",0]]} — 1 presses a key, 0 releases it, and a key stays held until released"
  dflt ORACLE_BASELINE "the current VALIDATED best in results/speedrun/best/"
  dflt ORACLE_FIELDS   "max_progress"
  # From-scratch arms start with an empty best/, so this sentinel is what a first clear must
  # beat -- the point being that ANY validated clear is promotable.
  dflt BROWSER_BEST_FLOOR "999999"
}

case "${1:-}" in

vocab)
  _cfg
  emit GAME_LABEL; emit BEST_PREFIX
  emit ORACLE_SCORER; emit ORACLE_ARTIFACT; emit ORACLE_BASELINE; emit ORACLE_FIELDS
  emit STX_SCORER; emit STX_PY; emit STX_LEVEL; emit STX_MAX_STEPS; emit BROWSER_BEST_FLOOR
  emit_val BIZHAWK_AUTHORITATIVE 0
  emit_val BIZHAWK_CONFIG "${BIZHAWK_CONFIG:-}"
  emit_val BEST_FRAME_MODE     best_dir
  emit_val BEST_FRAME_FALLBACK "$BROWSER_BEST_FLOOR"
  emit_val ORACLE_REVERIFY    1
  emit_val ORACLE_NAME        "supertux"
  emit_val ORACLE_LOG_TAG     "(supertux)"
  emit_val ORACLE_REACH_VERB  "cleared the level"
  emit_val ORACLE_GOAL_FAIL   "did NOT reach the goal"
  emit_val ORACLE_FEEDBACK_BY "the SuperTux scorer"
  # A default containing an ODD number of apostrophes breaks ${VAR:-...} and would silently
  # leave the SML platformer hints in force -- use dflt, and keep apostrophes balanced.
  dflt GAME_PLAN_HINTS "This is a 2D side-scrolling platformer. Tux runs, jumps and stomps \
enemies; touching an enemy or falling into a pit kills him and ENDS the run immediately, so \
survival comes before speed. The clock is PHYSICS STEPS and inputs are applied at exact step \
numbers, so the tape is a precise script rather than a rough plan. Holding a direction \
accelerates up to a run speed over many steps, so a key pressed later than needed costs the \
whole ramp; jump height depends on how LONG the jump key is held, so a short tap and a long \
hold clear different obstacles. Think in terms of: (a) dead steps where no key is held and Tux \
coasts or stands still; (b) jumps started too early or too late for the obstacle, which show up \
as a death at a repeatable x position; (c) jumps held longer than the gap needs, which costs \
airtime; (d) stretches walked rather than run. The scorer reports max_progress (the furthest x \
Tux reached) and whether he died, so reason about WHERE the run ends, not about how it looked."
  dflt GAME_EXEC_HINTS "Edit the tape, then RE-SCORE it and keep the edit ONLY if \
reached_goal is still true AND goal_frame went down. The main failure mode: this is an OPEN-LOOP \
script through a continuous physics sim, so changing ANY early input shifts where Tux is for \
every later input, and the rest of the tape then jumps into a wall or a pit. When that happens \
do NOT mark the item blocked -- RE-AIM: sweep the edited step number over a small range and/or \
absorb the shift in the next input, and search that small space. max_progress tells you exactly \
where the run ended, and a death at the SAME x on every variant means the obstacle needs a \
different jump, not a differently timed one. Only mark [BLOCKED] after that search also fails."
  emit GAME_PLAN_HINTS; emit GAME_EXEC_HINTS
  emit_val EVAL_BUDGET_ADVISORY 0
  emit_val PROMOTE_MODE filename
  emit_val TAS_VOCAB_OK 1
  ;;

score)
  _cfg
  CAND="$2"
  rm -f "$X_RESULT"
  # STX_EVAL_URL set -> score via the metered eval-service, which owns the scorer in a container
  # the agent cannot exec into. Unset -> the old in-container path, kept so arms already running
  # are unaffected. That local path is exactly what let agents self-score without limit:
  # stx_score.py must be mounted beside the agent for it to work, and a :ro mount prevents
  # modification, not execution. GLM ran it 244 times while being told each turn it may not.
  if [ -n "${STX_EVAL_URL:-}" ]; then
    X_OUT=$("$TAS_PY" - "$CAND" "$X_RESULT" "$STX_EVAL_URL" <<'PY' 2>&1
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
    with urllib.request.urlopen(req, timeout=1200) as r:
        json.dump(json.load(r), open(out, "w"))
except urllib.error.HTTPError as e:
    # A 429 is the BUDGET refusing, not a scorer fault -- surface it verbatim.
    sys.stderr.write(e.read().decode()[:400])
except Exception as e:
    sys.stderr.write(f"eval-service unreachable: {e!r}")
PY
    )
  else
    X_OUT=$("$STX_PY" "$STX_SCORER" "$CAND" --out "$X_RESULT" \
              --level "$STX_LEVEL" --max-steps "$STX_MAX_STEPS" --quiet 2>&1)
  fi
  SC=$("$TAS_PY" - "$X_RESULT" <<'PY' 2>/dev/null
import json, sys
try:
    r = json.load(open(sys.argv[1])) or {}
    reached = bool(r.get("reached_goal"))
    print("O_REACHED=%d" % (1 if reached else 0))
    print("O_GF=%s" % (r.get("goal_frame") if reached and r.get("goal_frame") is not None else ''))
    print("O_DIED=%d" % (1 if r.get("died") else 0))
    # Furthest x reached. FEEDBACK ONLY -- promotion is gated on reached_goal, so a run cannot
    # be rewarded for merely getting far.
    mp = r.get("max_progress")
    print("O_MP=%s" % ('' if mp is None else round(float(mp), 1)))
    rr = r.get("reject_reasons") or []
    print("O_EXTRA='ran %s steps, furthest x %s, died=%s%s'" % (
        r.get("steps_run"), ('?' if mp is None else round(float(mp), 1)),
        bool(r.get("died")),
        ('; ' + str(rr[0])[:160].replace("'", "")) if rr else ''))
except Exception as e:
    print("O_REACHED=0"); print("O_GF="); print("O_DIED=0"); print("O_MP=")
    print("O_ERR=%s" % str(e)[:120].replace(chr(10), ' '))
PY
)
  printf 'O_REACHED=0\nO_GF=\nO_DIED=0\nO_MP=\nO_ERR=\nO_EXTRA=\n%s\n' "$SC"
  O_REACHED=0; O_GF=""; O_DIED=0; O_MP=""; O_ERR=""; O_EXTRA=""
  # 2>/dev/null: the caller evaluates this same text, so a malformed line (the parser's
  # exception path emits an UNQUOTED O_ERR) would otherwise print its diagnostic twice.
  eval "$SC" 2>/dev/null
  O_NOT_SCORED=0
  if [ ! -s "$X_RESULT" ]; then
    # A BUDGET REFUSAL IS NOT A FAILED RUN. On a banned arm the in-loop call is 429'd by design --
    # the orchestrator scores the candidate between turns -- and without this flag the loop would
    # tell the agent "REJECTED" every turn about a tape that was never run. (SuperTuxKart already
    # did this; SuperTux did not, so its banned arms were shown a failure verdict each turn.)
    if printf '%s' "$X_OUT" | grep -qE 'scoring is DISABLED|EVAL_BUDGET'; then
      O_NOT_SCORED=1
      O_ERR=""   # the missing result file is EXPECTED on a refusal; do not report it as an error
      O_EXTRA="the metered eval-service declined to run it; the orchestrator scores your candidate between turns"
      olog "--- supertux ORACLE: not scored in-loop (banned); left for the orchestrator"
    else
      O_ERR="SuperTux scorer produced no result: $(printf '%s' "$X_OUT" | tail -1 | cut -c1-160)"
      emit O_ERR
      olog "--- supertux ORACLE: scorer FAILED — $O_ERR"
    fi
  fi
  emit_val O_NOT_SCORED  "$O_NOT_SCORED"
  emit_val O_METRICS     "furthest x reached=${O_MP:-?}, died=${O_DIED} (feedback only — nothing is promoted for getting close; only a completed level counts). ${O_EXTRA:-} "
  emit_val O_FAIL_DETAIL "${O_EXTRA:-no detail}"
  emit_val O_TAIL        "${O_ERR:+ NOTE: $O_ERR}"
  emit_val O_LOG_EXTRA   " | measured=${O_GF:-none} max_x=${O_MP:-none}"
  ;;

verify)
  _cfg
  # RE-VERIFY BEFORE PROMOTING. The caller has already copied the candidate into best/; this
  # re-scores the COPY as it now sits on disk, in a fresh scorer process, and the caller keeps it
  # only if the number reproduces. Determinism makes that a real check rather than a formality.
  #
  # Unlike astray.sh, stderr is NOT folded into the captured value: the scorer runs Playwright,
  # which does emit occasional warnings, and astray's `2>&1 >/dev/null` shape would turn any such
  # warning into a failed string comparison and refuse a legitimate promotion.
  # METERED MODE: re-verify through the eval-service too. This path was missed when `score` was
  # converted, and the consequence was silent and total: in metered mode the local scorer is not
  # in the agent container at all, so this produced NO output, O_VERIFY_GF came back empty, and
  # the loop read that as "re-scored as 'no clear'" and DELETED every genuine improvement.
  # 0 accepted out of ~200 oracle verdicts across 8 arms, all of them false rejections.
  if [ -n "${STX_EVAL_URL:-}" ]; then
    "$TAS_PY" - "$2" "$X_RESULT.verify" "$STX_EVAL_URL" <<'PY' >/dev/null 2>&1
import json, os, sys, urllib.request
cand, out, url = sys.argv[1], sys.argv[2], sys.argv[3]
hdrs = {"Content-Type": "application/json"}
sec = os.environ.get("EVAL_RESET_SECRET", "")
if sec:
    hdrs["X-Eval-Secret"] = sec          # privileged: not metered, not counted
req = urllib.request.Request(url.rstrip("/") + "/score",
                             data=json.dumps({"tape": json.load(open(cand))}).encode(),
                             headers=hdrs)
try:
    with urllib.request.urlopen(req, timeout=1200) as r:
        json.dump(json.load(r), open(out, "w"))
except Exception:
    pass
PY
  else
    "$STX_PY" "$STX_SCORER" "$2" --out "$X_RESULT.verify" \
        --level "$STX_LEVEL" --max-steps "$STX_MAX_STEPS" --quiet >/dev/null 2>&1
  fi
  X_VER=$("$TAS_PY" - "$X_RESULT.verify" <<'PY' 2>/dev/null
import json, sys
try:
    r = json.load(open(sys.argv[1])) or {}
    print("%s" % (r.get("goal_frame") if r.get("reached_goal") else ""))
except Exception:
    print("")
PY
)
  emit_val O_VERIFY_GF "$X_VER"
  rm -f "$X_RESULT.verify"
  ;;

post) : ;;
*) echo "usage: $0 {vocab|score <cand>|verify <path>|post}" >&2; exit 2 ;;
esac
