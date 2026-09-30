#!/bin/bash
# Drive the `sml-tas` OpenCode agent in a loop to optimize the SML 1-1 speedrun.
# Iteration 1 starts a session; later iterations continue it (-c) so the agent keeps
# its context. Runs for N iterations; CONVERGED is not a valid status (a failed step is SEARCHING).
#
# Requires: SWEEP_API_BASE, SWEEP_API_KEY in the environment (the Kimi /v1 endpoint),
# the kimi provider configured in opencode.json, and `opencode` on PATH.
#
# Usage:  SWEEP_API_BASE=https://...kimi.../v1 SWEEP_API_KEY=kimi-sk-... \
#         scripts/opencode_tas_loop.sh [N]
set -u
cd "$(dirname "$0")/.."
# These two are the OPENCODE provider's credentials. They are still REQUIRED for every opencode
# arm (unset => hard stop, unchanged). A HARNESS=codex arm authenticates through its own
# CODEX_HOME/auth.json and has no use for them, so demanding them there would only force a
# compose file to invent fake values — which is worse than a gate, because a fake credential in
# an env var is indistinguishable from a real one when you read the run's metadata later.
HARNESS=${HARNESS:-opencode}
if [ "$HARNESS" = "opencode" ]; then
  : "${SWEEP_API_BASE:?set SWEEP_API_BASE to the Kimi /v1 endpoint}"
  : "${SWEEP_API_KEY:?set SWEEP_API_KEY to the Kimi API key}"
fi
N=${1:-10}
AGENT=${AGENT:-sml-tas}   # override (e.g. sml-tas-mimo) to drive a different model's agent
# ============================ GAME ADAPTER LOOKUP (game-agnostic) ===========================
# GAME IS REQUIRED. It used to default to super_mario_land — and so did GAME_LABEL, BEST_PREFIX
# and, most damagingly, ORACLE_BASELINE (a human-gold seed). A new game that
# forgot one override therefore inherited Super Mario Land's framing SILENTLY, and a wrong
# baseline reached its prompt. There is no fallback any more: everything that is true of one
# game lives in that game's ADAPTER, scripts/scorers/$GAME.sh, and a game without one refuses to
# start. See scripts/scorers/_lib.sh for the adapter protocol and docs/TAS_HARNESS.md for the
# (short) checklist a new game has to satisfy.
if [ -z "${GAME:-}" ]; then
  echo "FATAL: GAME is not set. It has no default any more — set GAME=<name> where" >&2
  echo "       scripts/scorers/<name>.sh exists. Available:" >&2
  ls -1 "$(dirname "$0")/scorers"/*.sh 2>/dev/null | sed -e 's#.*/##' -e 's#\.sh$##' -e '/^_/d' -e '/^selftest$/d' -e 's/^/         /' >&2
  exit 1
fi
TAS_SCORER="$(dirname "$0")/scorers/${GAME}.sh"
if [ ! -f "$TAS_SCORER" ]; then
  echo "FATAL: GAME=$GAME has no adapter at $TAS_SCORER." >&2
  echo "       Every game-specific string and every scoring call now lives in an adapter;" >&2
  echo "       there is deliberately no Super Mario Land fallback. Available:" >&2
  ls -1 "$(dirname "$0")/scorers"/*.sh 2>/dev/null | sed -e 's#.*/##' -e 's#\.sh$##' -e '/^_/d' -e '/^selftest$/d' -e 's/^/         /' >&2
  exit 1
fi
# One call, evaluated here, defines every per-game string the prompts and the oracle need.
TAS_VOCAB_OK=0
eval "$(LOG="${LOG:-}" "$TAS_SCORER" vocab)"
if [ "${TAS_VOCAB_OK:-0}" != "1" ]; then
  echo "FATAL: $TAS_SCORER vocab failed (no TAS_VOCAB_OK). Refusing to run with a half-built" >&2
  echo "       configuration — that is how an arm ends up prompted for the wrong game." >&2
  exit 1
fi
# Every key the generic code below dereferences must have been declared by the adapter. An
# adapter that forgets one fails HERE, loudly, instead of silently borrowing another game's.
for _v in GAME_LABEL BEST_PREFIX ORACLE_SCORER ORACLE_ARTIFACT ORACLE_BASELINE ORACLE_FIELDS \
          GAME_PLAN_HINTS GAME_EXEC_HINTS ORACLE_REACH_VERB ORACLE_GOAL_FAIL ORACLE_FEEDBACK_BY \
          ORACLE_NAME ORACLE_LOG_TAG ORACLE_REVERIFY BEST_FRAME_MODE BEST_FRAME_FALLBACK \
          BIZHAWK_AUTHORITATIVE BIZHAWK_CONFIG PROMOTE_MODE EVAL_BUDGET_ADVISORY; do
  if [ -z "${!_v+x}" ]; then
    echo "FATAL: scripts/scorers/${GAME}.sh did not declare $_v in its vocab." >&2
    exit 1
  fi
done
# SCRATCH_TMP — the scratch directory the AGENT (and every child process it spawns) writes to.
# Inside a container this is /tmp and belongs to that container alone, so the default keeps the
# old behaviour exactly. On the HOST, N parallel arms all run as the same UNIX user and would
# share one /tmp: the artifact-copy globs further down (`/tmp/*best*.json`, the per-iteration
# snapshot) would then sweep OTHER arms' candidates into this arm's export dir, and the agents
# could read each other's scratch files. Arms launched by scripts/launch_wolf3d_arms.sh therefore
# export a private TMPDIR; the globs below are anchored to it so they can only ever match this
# arm's own files. mkdir is best-effort so an unwritable TMPDIR degrades, never aborts the run.
SCRATCH_TMP="${TMPDIR:-/tmp}"; SCRATCH_TMP="${SCRATCH_TMP%/}"
mkdir -p "$SCRATCH_TMP" 2>/dev/null || true
[ -d "$SCRATCH_TMP" ] && [ -w "$SCRATCH_TMP" ] || SCRATCH_TMP=/tmp
export TMPDIR="$SCRATCH_TMP" TMP="$SCRATCH_TMP" TEMP="$SCRATCH_TMP"
# Overridable so PARALLEL arms don't all write to (and truncate) one shared log file, which
# leaves every arm's exported loop_log.txt an interleaved mix of all of them. Default unchanged.
LOG=${LOG:-$SCRATCH_TMP/opencode_tas_loop.log}
# SINGLE-TURN mode (set TAS_TURN_INDEX): run EXACTLY that one iteration and exit, instead of the
# full 1..N loop. Used by the external orchestrator (scripts/tas_orchestrator.sh) which drives one
# turn per `docker exec` so the per-turn budget RESET (and its secret) live OUTSIDE the agent
# container — the agent never holds EVAL_RESET_SECRET. Cross-turn state (opencode -c session,
# PLAN.md, results/) persists on the agent's disk across execs. Unset => the normal full loop
# (fully backward compatible).
[ -n "${TAS_TURN_INDEX:-}" ] || : > "$LOG"   # don't wipe the log each turn in single-turn mode
# Unique id for THIS loop launch, so an append-only host log can distinguish runs across
# restarts (the container's own /tmp log is wiped on --force-recreate; the host one isn't).
# Overridable so the orchestrator pins ONE id across all its per-turn execs.
# Stamp is UTC (same shape as before; this host already runs UTC, so existing ids are unchanged)
# because the per-run output directory below is derived from it and must sort chronologically.
RUN_ID="${RUN_ID:-$(date -u +%Y%m%d-%H%M%S)-$AGENT}"

# ---------------------------- DECODING PARAMETERS (one place) -------------------------------
# scripts/tas_decoding.sh is the single definition of temperature / top_p / seed for EVERY arm.
# Sourcing it here exports them; .opencode/plugin/tas-decoding.js reads them and applies them to
# every request opencode makes, whatever the agent card says; run_meta.txt below records them,
# so a run always carries the decoding it was produced under. See scripts/verify_decoding.sh for
# the check that they actually reach the endpoint (they are dropped silently if they do not).
_DECODING_FILE="$(dirname "$0")/tas_decoding.sh"
if [ -f "$_DECODING_FILE" ]; then
  # shellcheck disable=SC1090
  . "$_DECODING_FILE"
else
  echo "WARNING: $_DECODING_FILE is missing — this run's decoding is the provider default and is NOT pinned." >&2
fi

STATUS="End your reply with EXACTLY one line: 'STATUS: IMPROVED <new_goal_frame>' if the \
validated new best has STRICTLY FEWER frames than the previous best (any reduction counts); \
otherwise 'STATUS: SEARCHING', and say which axis you will vary next. A small win is still a win. \
NEVER write 'STATUS: CONVERGED' - it is not a valid status in this loop. There is always another \
axis to vary, so a step that found nothing is one negative result, NOT a finished search. If you \
believe you are out of ideas, widen a range, change a structure, or re-read the vision feedback, \
and report SEARCHING."
FIRST="Start optimizing $GAME_LABEL. Find the current best trajectory and its \
validated goal_frame, run ONE improvement step, validate it, and report 'prev -> new (delta)'. \
$STATUS"
CONT="Continue improving from the current best. Run ONE more improvement step, validate, \
and report 'prev -> new (delta)'. $STATUS"

# Game-specific TACTICS injected into the PLAN/EXEC prompts ($GAME_PLAN_HINTS /
# $GAME_EXEC_HINTS) come from the game's own adapter vocab, above. There is no default: SML
# movement tactics ("turn the walk into a B+RIGHT dash") reaching a Pokemon or a Wolfenstein
# run was the exact failure the adapter split exists to prevent.

# Optional PLANNING PHASE (set PLAN=1). Iteration 1 builds a prioritized PLAN.md instead of
# optimizing; every later iteration executes the highest-priority OPEN plan item and updates
# the plan. This replaces greedy free-poking with plan-driven prioritization (e.g. attack the
# long early WALKING stretches that bare-poking ignores). Default off so other agents are
# unaffected.
PLAN_MODE=${PLAN:-0}
PLAN_PROMPT="Do NOT optimize yet. First build a PLAN. Find the current best trajectory and its \
validated goal_frame. Survey the WHOLE run for frame-saving opportunities and RANK them by how \
many frames each could save. $GAME_PLAN_HINTS \
Write a prioritized checklist to PLAN.md (highest expected savings first). Report the top 3 items. \
End with EXACTLY one line: 'STATUS: PLANNED'."
# REPLAN_EVERY: 0 = plan once (iter 1) + incremental updates on each execute turn (cheap, but the
# plan's frame ranges drift stale as the trajectory mutates). K>=1 = re-SURVEY the current best and
# refresh PLAN.md on every Kth execute turn (K=1 => every turn) so item frame-ranges stay aligned.
REPLAN_EVERY=${REPLAN_EVERY:-0}
EXEC_PROMPT="Read PLAN.md. Take the HIGHEST-PRIORITY still-OPEN item and run ONE improvement step \
targeting that specific region. $GAME_EXEC_HINTS \
If it improved: update the best, CHECK OFF that item in PLAN.md, and record the gain. If it failed: \
annotate the item in PLAN.md with WHY, then move to the next item. Keep PLAN.md \
current. Report 'prev -> new (delta)'. $STATUS"

# Re-survey variant (used every Kth execute turn when REPLAN_EVERY>=1): refresh the plan against
# the CURRENT trajectory first, since frame ranges drift as you edit, THEN do the execute step.
EXEC_REPLAN_PROMPT="FIRST re-survey the CURRENT best trajectory and REFRESH PLAN.md before anything \
else: the frame ranges DRIFT every time you edit, so re-scan the current best for the remaining \
WALKING spans / idle / stalls, recompute their CURRENT frame ranges, re-rank by frames-saveable, and \
drop items that no longer exist. THEN $EXEC_PROMPT"

# OPTIONAL open-loop / no-emulator mode (set NO_EMULATOR=1). Default off => everything above is
# unchanged and all existing agents behave exactly as before. When on, the agent is told it CANNOT
# run PyBoy / the scorer (enforcement is also applied via the agent's opencode `permission` deny
# patterns) and must improve the trajectory PURELY by reasoning about the frame-keyed JSON + the TAS
# skills, then WRITE an edited trajectory. Results are PREDICTED, not validated — score them later
# with the real emulator outside the sandbox for the true frame count.
NO_EMULATOR=${NO_EMULATOR:-0}
if [ "$NO_EMULATOR" = "1" ]; then
  NOEMU="HARD CONSTRAINT — OPEN LOOP: PyBoy and the scorer (score_speedrun_ctx, \
safe_score_speedrun_ctx, speedrun_fused.py, run_sweeps.sh, speedrun_suffix.py, replay_to_video.py) \
are NOT available and any attempt to run them is DENIED. You CANNOT replay, simulate, render, or \
validate any trajectory. Work entirely open-loop: reason from the frame-keyed segment JSON and the \
loaded TAS skills (running speed, velocity-coupled jumps, frame timing) and WRITE an improved \
trajectory file directly. Your goal_frame is a PREDICTION you cannot confirm."
  FIRST="$NOEMU Start optimizing $GAME_LABEL. Find the current best trajectory and its \
goal_frame, make ONE open-loop improvement, and report 'prev -> new (predicted delta)'. $STATUS"
  CONT="$NOEMU Continue from the current best: make ONE more open-loop improvement and report \
'prev -> new (predicted delta)'. $STATUS"
  PLAN_PROMPT="$NOEMU Do NOT edit yet. Build PLAN.md: read the current best trajectory JSON and \
classify every segment (RIGHT-only walk / idle / LEFT backtrack / B-dash) STRUCTURALLY from the \
JSON alone, then RANK frame-saving opportunities (long walks to dash + co-shift, idle/stall \
deletes, LEFT backtracks, obstacle clusters) by estimated savings. No emulator measurements — \
estimate pace from physics. Write a prioritized checklist to PLAN.md. Report the top 3. End with \
EXACTLY one line: 'STATUS: PLANNED'."
  EXEC_PROMPT="$NOEMU Read PLAN.md. Take the HIGHEST-PRIORITY still-OPEN item and make ONE \
improvement by editing the trajectory (frozen-prefix suffix re-author: freeze frames < k, \
re-author frames >= k). Save it as the new best and update PLAN.md (check off / annotate). You \
cannot validate, so reason carefully about desync and downstream jump timing. Report 'prev -> new \
(predicted delta)'. $STATUS"
  EXEC_REPLAN_PROMPT="$NOEMU FIRST re-read the CURRENT best trajectory JSON and REFRESH PLAN.md \
(recompute frame ranges, re-rank, drop stale items) — structurally, no emulator. THEN $EXEC_PROMPT"
fi

# OPTIONAL ORACLE FEEDBACK (set ORACLE_FEEDBACK=1; pairs with NO_EMULATOR=1). The agent still CANNOT
# run PyBoy / the scorer — it edits BLIND and writes its single proposal to results/speedrun/candidate.json.
# After each turn the LOOP HARNESS (plain bash/python, NOT an agent tool call, so it bypasses the agent's
# permission denies) scores that candidate with the real emulator and feeds the TRUE result back into the
# next prompt, promoting it to the validated best only if it actually reached the goal in fewer frames.
# => the agent gets genuine closed-loop feedback without the PyBoy/scorer code ever being exposed to it.
# A game whose ONLY scoring path is an external oracle pins ORACLE_FEEDBACK=1 in its own vocab
# (super_mario_bros: promotion must pass through the trusted NesHawk oracle; pokemon_blue_offline:
# the actor holds no emulator at all), so the value is already 1 by the time we get here.
ORACLE_FEEDBACK=${ORACLE_FEEDBACK:-0}
# Warn — loudly, in the log and in run_meta — when a game is about to put ANOTHER game's prompt
# nouns in front of a model. An adapter that borrows Super Mario Land's wording says so in
# TAS_INHERITED_SML; those strings are harmless while ORACLE_FEEDBACK=0 (nothing reads them) and
# are a wrong baseline the moment it is 1.
if [ "$ORACLE_FEEDBACK" = "1" ] && [ -n "${TAS_INHERITED_SML:-}" ]; then
  echo "WARNING: GAME=$GAME runs with ORACLE_FEEDBACK=1 but its adapter borrows Super Mario \
Land's wording for: ${TAS_INHERITED_SML}. Those strings go into the prompt. Give this game its \
own wording in scripts/scorers/${GAME}.sh." >&2
fi
# Most games' candidate artifact is a frame-keyed JSON trajectory; a game whose artifact is
# something else (pokemon_blue_offline: a closed-loop ROUTE PROGRAM, .py) sets CAND in its vocab.
CAND="${CAND:-results/speedrun/candidate.json}"
FEEDBACK=""
# ORCHESTRATED ARMS: SEED THE FEEDBACK FROM DISK.
# FEEDBACK is normally carried in this variable from one iteration to the next INSIDE a single
# long-lived process. An orchestrator-driven arm starts a FRESH process per turn (tas_orchestrator
# execs this script once per turn), so that variable is empty at every turn start and the agent
# never sees the oracle's verdict -- it writes route after route with no idea why the last one
# failed. Measured on pkblueun/glm53: the oracle produced a real RouteError ("menu stuck after
# B x6") that the agent was never shown. The orchestrator writes the verdict here instead.
if [ -n "${ORACLE_FEEDBACK_FILE:-}" ] && [ -s "${ORACLE_FEEDBACK_FILE}" ]; then
  FEEDBACK=$(cat "${ORACLE_FEEDBACK_FILE}")
fi
# BEST_FRAME — the bar a candidate has to beat to be promoted. Two bootstrap policies exist and
# the adapter names the one its game uses (BEST_FRAME_MODE), instead of the loop carrying a chain
# of per-game `if`s:
#   human_gold — the frame count of the human-gold trajectory in results/speedrun/ (SML lineage).
#   best_dir   — the LOWEST validated frame count already in results/speedrun/best/, i.e. the seed
#                if the arm is seeded. Games with no human demo (the browser games, SMB) use this;
#                on a FROM-SCRATCH arm best/ is empty and it resolves to the adapter's sentinel,
#                which is the point: the arm's FIRST validated clear must be promotable.
case "$BEST_FRAME_MODE" in
  human_gold)
    BEST_FRAME=$(ls results/speedrun/*human*[0-9]*f*.json 2>/dev/null | grep -oE '[0-9]+f' | grep -oE '[0-9]+' | sort -n | tail -1) ;;
  best_dir)
    # BOTH EXTENSIONS. Pokemon promotes route PROGRAMS (best_pk_<N>f.py); every other game
    # promotes tapes (.json). Globbing only .json silently returned empty for pk, so BEST_FRAME
    # fell through to BEST_FRAME_INIT and the agent was told its validated best was the SEED for
    # all 200 turns, even while holding a strictly better validated route.
    #
    # NO FRAME COUNTS IN THIS FILE. It ships to every agent container via `COPY . /work`
    # (sandbox/Dockerfile:105), so a concrete achieved score here would hand the arm both the
    # answer and the knowledge that its stated bar is not the real frontier.
    BEST_FRAME=$(ls results/speedrun/best/*[0-9]f.json results/speedrun/best/*[0-9]f.py 2>/dev/null | grep -oE '[0-9]+f\.(json|py)' | grep -oE '[0-9]+' | sort -n | head -1) ;;
  *)
    echo "FATAL: scripts/scorers/${GAME}.sh declared BEST_FRAME_MODE=$BEST_FRAME_MODE (expected human_gold or best_dir)." >&2
    exit 1 ;;
esac
BEST_FRAME=${BEST_FRAME:-$BEST_FRAME_FALLBACK}
# BEST_FRAME_INIT: explicitly pin the bar the oracle promotes against. Needed by a FROM-SCRATCH
# oracle arm: with no seed on disk the bar falls back to a human-gold time, so the agent's
# FIRST clear (necessarily slower than gold) is REJECTED and never promoted — the arm can then
# run 200 turns and leave results/speedrun/best/ empty. Scratch arms should pass 999999.
# Unset => previous behaviour exactly.
BEST_FRAME=${BEST_FRAME_INIT:-$BEST_FRAME}
if [ "$ORACLE_FEEDBACK" = "1" ]; then
  CC="You CANNOT run ${ORACLE_SCORER} (denied). WRITE your single proposed improved trajectory to the \
EXACT path $CAND (${ORACLE_ARTIFACT}). Do NOT try to score it — an external oracle scores it for \
you and the TRUE result is fed back to you next turn; TRUST that result over your own prediction. Each \
turn, start from ${ORACLE_BASELINE}."
  FIRST="$CC Make ONE improvement and write $CAND. Report prev -> predicted. $STATUS"
  CONT="$CC Make ONE more improvement and write $CAND. Report prev -> predicted. $STATUS"
  EXEC_PROMPT="$CC Read PLAN.md, take the highest-priority still-OPEN item, make ONE improvement, write \
$CAND, and update PLAN.md (check off / annotate). Report prev -> predicted. $STATUS"
  EXEC_REPLAN_PROMPT="$CC FIRST re-read the current best and REFRESH PLAN.md (structurally, no emulator), \
THEN $EXEC_PROMPT"
fi

# ============ OPTIONAL LOCAL SEARCH (SMB_LOCAL_SEARCH=1), SMB ONLY ==========================
# Default OFF => every existing arm's prompts are byte-identical to before.
#
# READ THIS BEFORE ASSUMING ORACLE_FEEDBACK=0 DOES ANYTHING HERE. For GAME=super_mario_bros
# the block above HARD-FORCES ORACLE_FEEDBACK=1, because the trusted NesHawk oracle is the
# ONLY thing in this harness that can promote an SMB candidate: with it off, nothing scores
# and nothing is ever accepted. So passing ORACLE_FEEDBACK=0 in the environment of an SMB arm
# is a NO-OP, and this flag is what actually changes the condition.
#
# WHAT IT CHANGES. Only the FRAMING. With ORACLE_FEEDBACK=1 the prompt tells the agent it may
# not run any emulator and gets exactly one scored probe per turn — ~40 usable probes over a
# whole run, against the tens of thousands of rerecords a human TASer spends. This flag
# instead tells the agent the truth about what is in its image: nes-py and the ROM are both
# there, it may run as many LOCAL replays per turn as it likes, and those results are
# PROVISIONAL — the host oracle still adjudicates and only the oracle can promote. That is a
# change in EVALUATION BANDWIDTH, not in authority.
#
# WHAT IT DOES NOT DO. It hands over no calibration and no answer. The local emulator's frame
# indexing does not necessarily match the oracle's; the agent is told that, and told the one
# legitimate way to fix it (replay the current best, whose oracle goal_frame it already
# knows, and solve for the offset). Discovering that is part of using the tool.
#
# BUDGET HONESTY: EVAL_BUDGET is NOT enforceable on this path. scripts/speedrun.py's
# _bump_eval_counter only fires inside score_speedrun[_ctx], and a raw `import nes_py` loop —
# which is exactly what a local search here looks like — never touches EVAL_COUNT_FILE. The
# real per-turn backstop is TURN_TIMEOUT. Do not set EVAL_BUDGET on these arms and claim a cap.
if [ "$GAME" = "super_mario_bros" ] && [ "${SMB_LOCAL_SEARCH:-0}" = "1" ]; then
  CC="LOCAL SEARCH IS AVAILABLE TO YOU, AND IT IS THE POINT OF THIS RUN. Your image contains \
the Super Mario Bros. ROM (roms/super_mario_bros_ntsc.nes) and a working nes-py, so you CAN \
replay a whole candidate yourself, in process, in tens of seconds, as many times per turn as \
you have time for. A full-route replay of the current best takes well under a minute. USE THAT: \
sweep an axis, keep what survives, and throw away what dies, instead of spending a whole turn on \
one blind guess. Two things constrain you. FIRST, your local results are PROVISIONAL: the \
authoritative evaluator is an external power-on NesHawk oracle you may NOT run (scripts/smb_tas_score.py, \
BizHawk, fceux and the replay drivers are all denied), it scores ONE candidate per turn, and only \
it can promote. So local search is for FILTERING — submit only your single best survivor. SECOND, \
your local emulator's frame numbering and input alignment are NOT guaranteed to match the \
oracle's; calibrate before you trust a number, by replaying the CURRENT VALIDATED BEST (whose \
oracle goal_frame you are told every turn) and solving for the offset and the input-drop that \
reproduce it with zero deaths through all eight stages. If your local replay of the current best \
does not reproduce its known oracle result, your harness is wrong and every number it gives you is \
worthless until you fix it. WRITE your single chosen proposal to the EXACT path $CAND \
(${ORACLE_ARTIFACT}). Each turn, start from ${ORACLE_BASELINE}."
  FIRST="$CC Build your local replay harness, calibrate it against the current best, then make \
ONE improvement and write $CAND. Report prev -> your locally measured new value. $STATUS"
  CONT="$CC Search locally, then write your best survivor to $CAND. Report prev -> locally \
measured. $STATUS"
  EXEC_PROMPT="$CC Read PLAN.md, take the highest-priority still-OPEN item, SEARCH IT LOCALLY \
(sweep, do not guess once), write your best survivor to $CAND, and update PLAN.md (check off / \
annotate with what you measured locally). Report prev -> locally measured. $STATUS"
  EXEC_REPLAN_PROMPT="$CC FIRST re-read the current best and REFRESH PLAN.md, THEN $EXEC_PROMPT"
fi

# ============ OPTIONAL STAGE PROBES (SMB_STAGE_PROBE=1), SMB ONLY ===========================
# Default OFF => every existing arm's prompts are byte-identical to before.
#
# HOW THIS DIFFERS FROM SMB_LOCAL_SEARCH ABOVE, WHICH IT DELIBERATELY DOES NOT REUSE.
# That block tells the arm to go and use the nes-py + ROM that are sitting in the image, with
# no cap at all. This block does NOT: it leaves the oracle framing above exactly as the control
# arm receives it (byte-identical, by APPENDING to $CC rather than replacing it) and adds one
# paragraph about a HOST service the arm may POST to, exactly like the oracle, which replays ONE
# STAGE from a savestate captured at that stage's entry. So the delta between this arm's prompt
# and the control's is precisely: a metered, stage-scoped evaluation channel. Nothing else.
#
# WHAT THIS BLOCK MUST NEVER SAY. It must not claim the image has no emulator. VERIFIED
# 2026-08-18 against smb374v2-tas-oracle:latest and against the running control container:
# /work/roms/super_mario_bros_ntsc.nes and /work/.venv/.../nes_py BOTH EXIST in this image, in
# BOTH arms. BizHawk, mono, fceux and /work/.tools do not. So the honest framing is the control's
# own ("you cannot run the scorer or any emulator"), not a false statement about the filesystem
# that the arm would disprove with one `ls` and then have reason to distrust everything else.
#
# WHY A STAGE PROBE IS NOT A BACK DOOR TO PROMOTION. scripts/smb_segment_probe.lua stamps
# authoritative=false and start_condition="savestate" into every result unconditionally, and
# those are the two fields scripts/smb_tas_score.py's judge() requires to be true and
# "power_cycle". The service re-stamps them on the way out too. A probe result cannot be
# laundered into an oracle verdict by any route.
#
# THE BUDGET HERE IS REAL, UNLIKE EVAL_BUDGET. EVAL_BUDGET counts bytes in a file that lives
# in the agent's own container and is only bumped from inside score_speedrun[_ctx]; it is a
# suggestion, and the comment on the SMB_LOCAL_SEARCH block says so. The cap named below is
# enforced on the HOST, under a flock, keyed by an arm identity that comes from a bearer token
# the arm cannot mint and a turn counter the arm cannot advance. Past the cap the service
# returns budget_exceeded and runs nothing.
#
# NOTHING IN THE TEXT BELOW MAY NAME A FRAME COUNT, A STAGE'S SLACK, OR ANY PROPERTY OF THE
# SCORING QUANTUM. Where the savings are is the task; this block only says the tool exists.
if [ "$GAME" = "super_mario_bros" ] && [ "${SMB_STAGE_PROBE:-0}" = "1" ] \
   && [ -n "${SMB_STAGE_PROBE_URL:-}" ]; then
  SP_BUDGET="${SMB_STAGE_PROBE_BUDGET:-20}"
  # $CC here is the ORACLE_FEEDBACK framing the control arm gets, VERBATIM. Appending rather
  # than replacing is what makes the two arms' prompts differ by exactly one paragraph.
  CC="$CC
STAGE PROBES ARE AVAILABLE TO YOU, AND USING THEM WELL IS THE POINT OF THIS RUN. The sentence \
above still holds — you may not run the scorer, and the oracle is the only thing that promotes. \
What you have IN ADDITION is a HOST SERVICE at ${SMB_STAGE_PROBE_URL} that holds a SAVESTATE \
taken at the entry of every stage of the run, and will replay ONE STAGE of your candidate from \
that savestate instead of replaying the whole route from power-on. A stage probe takes well \
under a minute, where a full authoritative replay takes several minutes, so you can afford to \
TEST a change instead of guessing at it. \
Authenticate with the header 'X-Eval-Token: \${SMB_STAGE_PROBE_TOKEN}' (that \
variable is already in your environment; read it, never print it) and always pass --noproxy '*' \
so curl does not send a host address through the model proxy. \
GET ${SMB_STAGE_PROBE_URL}/stages tells you which stages exist, the ABSOLUTE replay frame each \
one starts at, how long its window is, and which candidate the savestates were captured from \
(compare captured_from_fm2_sha256, which is derived from the per-frame input alone, not the \
candidate sha, which is a hash of the service's own re-serialised copy). \
POST ${SMB_STAGE_PROBE_URL}/probe with a body of {\"candidate\": <your WHOLE candidate JSON, \
same format you write to the oracle>, \"stages\": [\"<stage>\", ...]} replays your own input \
for each named stage. For each stage you get back load_ok, death_count, the frame the stage \
ENDED on, which stage it went to next, and exit_delta_vs_captured — negative means that stage \
finished EARLIER than it did in the captured run. GET ${SMB_STAGE_PROBE_URL}/stats tells you \
what you have spent. \
FIVE THINGS CONSTRAIN YOU, AND THEY ARE NOT NEGOTIABLE. \
(1) COST: you may run at most $SP_BUDGET stage probes PER TURN. One named stage is one probe. \
The meter is on the host, keyed to you, and it is checked before the emulator starts; past the \
cap the reply carries budget_exceeded and NOTHING is run. When that happens, STOP probing and \
finish your turn — the budget resets on the NEXT turn, which cannot begin until you return, so \
retrying and sleeping both just waste your wall clock. \
(2) PROVISIONAL: a probe starts from a savestate, not from power-on, so its numbers are a HINT. \
The authoritative evaluator is the external power-on oracle, it scores ONE candidate per turn, \
and only it can promote. A stage probe is for FILTERING; submit only your single best survivor. \
(3) PROBE EVERY STAGE YOUR EDIT TOUCHES, not just the one you meant to change. An edit that \
looks free where you made it very often breaks the run somewhere it also reaches; a single-stage \
probe of a change that spans two stages is the classic way to be confidently wrong. You may name \
several stages in one request and they will be chained, each starting from the state the \
previous one actually produced — that is how you check that a saving survives into the next \
stage. Each named stage costs one probe. \
(4) PREFIX IDENTITY: the savestates were captured from ONE specific candidate, so a probe of \
stage S is only sound if your input is unchanged before S's entry frame. If it is not, the \
service refuses the request and tells you the exact frame where you diverged; that frame names \
the earliest stage you should be probing. \
(5) FRESHNESS: after the oracle promotes a new best the savestates are re-captured from it \
automatically, in the background. /stages reports which candidate they currently come from and \
whether a re-capture is in flight, so check it rather than assuming. \
WRITE your single chosen proposal to the EXACT path $CAND (${ORACLE_ARTIFACT}). Each turn, start \
from ${ORACLE_BASELINE}."
  FIRST="$CC Get the stage list, probe to orient yourself, then make ONE improvement and write \
$CAND. Report prev -> what your probes measured. $STATUS"
  CONT="$CC Probe, then write your best survivor to $CAND. Report prev -> what your probes \
measured. $STATUS"
  EXEC_PROMPT="$CC Read PLAN.md, take the highest-priority still-OPEN item, PROBE IT (test, do \
not guess once, and probe every stage your edit touches), write your best survivor to $CAND, and \
update PLAN.md (check off / annotate with what the probes measured). Report prev -> probed. \
$STATUS"
  EXEC_REPLAN_PROMPT="$CC FIRST re-read the current best and REFRESH PLAN.md, THEN $EXEC_PROMPT"
fi

# ============================ PER-RUN OUTPUT DIRECTORY ======================================
# Every launch gets its OWN output directory, so two runs of the same game+agent can never
# overwrite each other's run_log.csv / PLAN.md / artifacts. Layout:
#
#     $RUNS_ROOT/<run_id>-<game>-<seedmode>-oracle<0|1>/
#         run_log.csv        one row per turn (see the logging block in the loop)
#         eval_log.csv       per-turn emulator-evaluation counts
#         loop_log.txt       a copy of $LOG, refreshed every turn
#         run_meta.txt       the exact configuration this run was launched with
#         PLAN.md            the agent's plan, if it wrote one
#         *.json             exported best / candidate artifacts
#         iters/<run_id>/iter_NNN/   full per-iteration snapshot
#
# RUN_ID already carries "<UTC timestamp>-<agent>", and the orchestrator PINS it across all of
# its per-turn `docker exec`s, so deriving the directory from RUN_ID keeps every turn of one
# run in one place instead of minting a new directory per exec.
#
# Precedence, most specific first:
#   1. EXPORT_DIR set by the caller -> honored verbatim (backward compatible; this is how the
#      existing SML/MK64 launch scripts pin an arm's directory)
#   2. /work/exported exists        -> the mounted sandbox volume (containers, unchanged)
#   3. otherwise                    -> a fresh per-run directory under RUNS_ROOT
RUNS_ROOT="${RUNS_ROOT:-$HOME/runs}"
if [ "${NO_SEED:-0}" = "1" ]; then RUN_SEEDMODE="scratch"; else RUN_SEEDMODE="${SEED_MODE:-seeded}"; fi
RUN_TAG=$(printf '%s' "${RUN_ID}-${GAME}-${RUN_SEEDMODE}-oracle${ORACLE_FEEDBACK}" \
          | tr -c 'A-Za-z0-9._-' '_')
if [ -n "${EXPORT_DIR:-}" ]; then
  :                                   # caller pinned it — do not second-guess
elif [ -d /work/exported ]; then
  EXPORT_DIR=/work/exported
else
  EXPORT_DIR="$RUNS_ROOT/$RUN_TAG"
fi
export EXPORT_DIR
# CREATE IT NOW, before ANY logging happens. The old code created/checked this only inside the
# loop and then guarded the whole logging block with `[ -d "$EXPORT_DIR" ]`, so a non-existent
# directory silently discarded every single row — that is how four 200-turn runs were lost.
# A failure here is FATAL: a run whose results cannot be recorded is not worth the GPU hours.
if ! mkdir -p "$EXPORT_DIR" 2>/dev/null || [ ! -w "$EXPORT_DIR" ]; then
  echo "FATAL: EXPORT_DIR=$EXPORT_DIR is not creatable/writable — refusing to run blind." >&2
  exit 1
fi
RUNLOG="$EXPORT_DIR/run_log.csv"
EVLOG="$EXPORT_DIR/eval_log.csv"
# Header is UNCHANGED (8 columns) so existing awk/pandas readers of run_log.csv keep working.
[ -f "$RUNLOG" ] || echo "epoch,iso_time,run_id,agent,iteration,status,goal_frame,measured_best" > "$RUNLOG"
# eval_log.csv gains three columns ONLY when the metered host-side fast scorer is in use
# (SMB_FAST_EVAL_URL). `emulator_evaluations` alone is not an audit trail: it is the delta of a
# counter the AGENT's container owns, so it reads 0 for any scorer that never bumps it and it is
# writable by the thing it measures. fast_eval_used/limit come from the HOST meter
# (scripts/smb_fast_eval_service.py /stats) and are the run's real metered spend.
# Legacy runs (no SMB_FAST_EVAL_URL) keep the exact 7-column file, so existing readers and every
# already-exported eval_log.csv are untouched.
if [ -n "${SMB_FAST_EVAL_URL:-}" ]; then
  [ -f "$EVLOG" ] || echo "epoch,run_id,agent,iteration,emulator_evaluations,status,goal_frame,fast_eval_used,fast_eval_limit,fast_eval_turn" > "$EVLOG"
else
  [ -f "$EVLOG" ] || echo "epoch,run_id,agent,iteration,emulator_evaluations,status,goal_frame" > "$EVLOG"
fi
# ---------------------- EVAL_BUDGET: ONE MEANING, STATED OUT LOUD ---------------------------
# EVAL_BUDGET is read by three parties and they MUST agree. They did not.
#
#     eval_service.py:21   UNSET or NEGATIVE => uncapped;  0 => BANNED;  n>0 => n per turn
#     this loop (until now)                    0 => "none (uncapped)"
#
# So on any arm with an eval-service and EVAL_BUDGET=0 the SERVICE refused the agent every
# time while the PROMPT announced it was uncapped. That is not a cosmetic disagreement: it
# is exactly how pkblueun-glm53 was voided -- 186 turns, 0 evaluations, and no line anywhere
# saying scoring had been switched off. The agent spent the whole run believing it could
# measure, and /stats `total` was the only place the truth existed.
#
# The eval-service is the side that ENFORCES, so it defines the semantics and this loop
# follows it:
#
#     EVAL_BUDGET = scored evaluations allowed IN A SINGLE TURN.
#     unset/empty = no cap.   negative = no cap.   0 = BANNED.   n>0 = n per turn.
#
# NOTE THE ASYMMETRY, because it is the whole point: unset and 0 used to be the same branch
# here and are now opposites. Any arm that relied on `EVAL_BUDGET=0` meaning "uncapped" must
# switch to leaving it UNSET. As of 2026-09-19 that is 63 tuxemon agents on
# `${TUX_EVAL_BUDGET:-0}` -- they were already being refused by the service, so this change
# makes their prompt honest rather than changing what they can do.
#
# Every run records which enforcement it actually had. See docs/TAS_HARNESS.md.
if [ "${EVAL_BUDGET:-}" = "0" ]; then
  # BANNED. Say so loudly: a silent ban is the failure this whole comment exists for.
  _EVAL_BUDGET_SCOPE="BANNED (EVAL_BUDGET=0; the agent may not score at all this turn)"
  if [ -z "${EVAL_SERVICE_URL:-}" ] && [ -z "${TAS_TURN_INDEX:-}" ]; then
    echo "WARNING: EVAL_BUDGET=0 means the agent is BANNED from scoring, but this arm has no \
eval-service to enforce it -- nothing will actually refuse a score. Leave EVAL_BUDGET UNSET if \
you meant 'uncapped'." >&2
  fi
elif [ -z "${EVAL_BUDGET:-}" ] || [ "${EVAL_BUDGET}" -lt 0 ] 2>/dev/null; then
  _EVAL_BUDGET_SCOPE="none (uncapped)"
elif [ -n "${TAS_TURN_INDEX:-}" ]; then
  _EVAL_BUDGET_SCOPE="per-turn, reset by the external orchestrator (orchestrated shape)"
elif [ -n "${EVAL_SERVICE_URL:-}" ]; then
  _EVAL_BUDGET_SCOPE="per-turn, reset by this loop against $EVAL_SERVICE_URL (standalone shape)"
else
  _EVAL_BUDGET_SCOPE="per-turn, ADVISORY ONLY (nothing enforces it here)"
  echo "WARNING: EVAL_BUDGET=$EVAL_BUDGET is set but nothing can enforce it on this arm: there is \
no eval-service and the per-turn counter is only bumped from inside score_speedrun[_ctx], which a \
raw emulator loop never touches. The prompt will still announce the cap. Do not report this run as \
budget-capped." >&2
fi
{
  echo "run_id=$RUN_ID"
  echo "run_tag=$RUN_TAG"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname 2>/dev/null)"
  echo "repo=$PWD"
  echo "game=$GAME"
  echo "game_label=$GAME_LABEL"
  echo "agent=$AGENT"
  echo "seed_mode=$RUN_SEEDMODE"
  echo "iterations=$N"
  echo "oracle_feedback=$ORACLE_FEEDBACK"
  echo "no_emulator=$NO_EMULATOR"
  echo "plan_mode=$PLAN_MODE"
  echo "replan_every=$REPLAN_EVERY"
  echo "eval_budget=${EVAL_BUDGET:-none}"
  echo "turn_timeout=${TURN_TIMEOUT:-0}"
  echo "best_frame_init=$BEST_FRAME"
  echo "bizhawk_authoritative=$BIZHAWK_AUTHORITATIVE"
  echo "measure_best=${MEASURE_BEST:-1}"
  # The two SMB treatment flags. Recorded here because they, not ORACLE_FEEDBACK, are what
  # distinguishes one SMB arm's CONDITION from another's, and a run whose condition is not in
  # its own artifacts is a run someone will later put in the wrong column of a table.
  [ "$GAME" = "super_mario_bros" ] && echo "smb_vision=${SMB_VISION:-0}"
  [ "$GAME" = "super_mario_bros" ] && echo "smb_local_search=${SMB_LOCAL_SEARCH:-0}"
  [ "$GAME" = "super_mario_bros" ] && echo "smb_stage_probe=${SMB_STAGE_PROBE:-0}"
  [ "$GAME" = "super_mario_bros" ] && echo "smb_stage_probe_budget=${SMB_STAGE_PROBE_BUDGET:-none}"
  # Decoding, so the run records what sampling it was produced under (see scripts/tas_decoding.sh).
  echo "decode_temperature=${TAS_TEMPERATURE:-provider-default}"
  echo "decode_top_p=${TAS_TOP_P:-provider-default}"
  echo "decode_seed=${TAS_SEED:-none}"
  echo "decode_source=scripts/tas_decoding.sh+.opencode/plugin/tas-decoding.js"
  # EVAL_BUDGET means different things in the two run shapes; say which one this is so a number
  # in eval_log.csv can be read correctly later. See docs/TAS_HARNESS.md.
  echo "run_shape=$([ -n "${TAS_TURN_INDEX:-}" ] && echo orchestrated || echo standalone)"
  echo "eval_budget_scope=${_EVAL_BUDGET_SCOPE}"
  echo "max_consecutive_errors=${MAX_CONSECUTIVE_ERRORS:-0}"
  echo "export_dir=$EXPORT_DIR"
} >> "$EXPORT_DIR/run_meta.txt" 2>/dev/null || true
echo "=== output directory: $EXPORT_DIR ===" | tee -a "$LOG"
# ============================================================================================

# Per-turn emulator-evaluation counting: every full replay (score_speedrun[_ctx]) appends 1 byte to
# this file (see scripts/speedrun.py:_bump_eval_counter), so the size delta per iteration = the number
# of emulator evaluations that turn. Exported so the agent's sweep subprocesses AND the harness scorer
# both write to the same file. Closed-loop sweeps do many per turn; the oracle harness does ~1.
export EVAL_COUNT_FILE="${EVAL_COUNT_FILE:-$SCRATCH_TMP/eval_count}"
: > "$EVAL_COUNT_FILE" 2>/dev/null || true

# Per-turn WALL-CLOCK cap (seconds; 0 = none). opencode has no native max-step flag, so this is the
# step backstop: a single `opencode run` turn that exceeds it is killed, the loop logs/exports what
# was produced (bests are saved to disk as they're found) and advances. Stops 22h mega-turns like
# iter 12, and catches non-emulator runaways (e.g. a model looping on reasoning) that EVAL_BUDGET won't.
TURN_TIMEOUT=${TURN_TIMEOUT:-0}
TO=""
[ "$TURN_TIMEOUT" -gt 0 ] 2>/dev/null && TO="timeout --signal=TERM ${TURN_TIMEOUT}s"

# ===================== CONSECUTIVE-ERROR TRIPWIRE (additive, default OFF) ===================
# WHY THIS EXISTS. A provider auth failure is NOT fatal to this loop by construction: the turn
# returns whatever the CLI printed (e.g. "Your API key has been invalidated"), the oracle block
# finds no candidate, the promote step re-promotes the seed unchanged, a row is appended to
# run_log.csv with status SEARCHING, and the loop advances. On one dead launch that produced
# ~3 s per turn and reached iteration 34/200 having done nothing at all — and would have written
# 200 rows that are indistinguishable, in the CSV, from 200 real negative results. A run whose
# failure mode looks exactly like its null result is worse than a crashed run.
#
# WHAT COUNTS AS A DEAD TURN. Deliberately narrow, because a false abort throws away a real run:
#     the turn was NOT killed by TURN_TIMEOUT (rc 124 is a different, already-handled failure and
#     a killed turn usually did real work), AND the reply contains no STATUS: line at all, AND
#     the reply is either empty/whitespace or matches a hard provider-failure signature.
# A working agent emits a STATUS line every turn, so a working arm can never trip this.
#
# DEFAULT IS OFF (0) ON PURPOSE. Every arm alive today runs the copy of this script BAKED INTO
# ITS IMAGE, so editing this file cannot reach them; but an arm that bind-mounts this script
# would pick the change up mid-run, and a live run's behaviour must not change under it. Arms
# that want the tripwire opt in with MAX_CONSECUTIVE_ERRORS=<n> in their compose environment.
MAX_CONSECUTIVE_ERRORS=${MAX_CONSECUTIVE_ERRORS:-0}
DEAD_STREAK=0
PROVIDER_ERROR_RE=${PROVIDER_ERROR_RE:-'API key|api[_ -]?key|AuthenticationError|authentication_error|invalid_api_key|unauthorized|forbidden|insufficient_quota|model_not_found|no such model|ProviderAuth|ECONNREFUSED|Connection error|rate limit'}
# Sets DEAD_TURN=1/0 for the turn whose reply is in $1 and whose CLI exit code is $2.
classify_turn() {
  DEAD_TURN=0
  [ "${MAX_CONSECUTIVE_ERRORS:-0}" -gt 0 ] 2>/dev/null || return 0
  [ "$2" = "124" ] && return 0
  printf '%s' "$1" | grep -q 'STATUS:' && return 0
  if [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]; then DEAD_TURN=1; return 0; fi
  printf '%s' "$1" | grep -qiE "$PROVIDER_ERROR_RE" && DEAD_TURN=1
  return 0
}

# Single-turn mode runs only TAS_TURN_INDEX (display total = TAS_NUM_TURNS); else the full 1..N loop.
if [ -n "${TAS_TURN_INDEX:-}" ]; then N="${TAS_NUM_TURNS:-$N}"; ITERS="$TAS_TURN_INDEX"; else ITERS=$(seq 1 "$N"); fi
# Continue the opencode session with -c (the core cross-turn reasoning loop). ROOT CAUSE of the
# earlier stall: a turn KILLED by TURN_TIMEOUT (SIGTERM mid-stream) leaves the session with an
# incomplete message, so every subsequent `-c` continuation fast-fails (~14s, empty). FIX: keep -c
# normally, but RESET (fresh session) for exactly one turn after a kill, to escape the broken session.
# In single-turn mode the kill is signalled across `docker exec`s via a flag file. NO_CONTINUE=1 forces
# fresh always; full-loop mode keeps -c. Default unchanged => backward compatible.
# Overridable: /work only exists INSIDE the sandbox container. A host-run arm could not create
# this flag, so the reset-after-kill escape never fired and every turn after the first timeout
# kill fast-failed on a broken -c session. Default is unchanged for containers.
KILL_FLAG="${KILL_FLAG:-/work/.tas_killed_last_turn}"
if [ "${NO_CONTINUE:-0}" = "1" ]; then
  CONT_FLAG=""
elif [ -f "$KILL_FLAG" ]; then
  CONT_FLAG=""; rm -f "$KILL_FLAG"
  echo "(previous turn was timeout-killed -> FRESH session this turn to escape the broken -c session)" | tee -a "$LOG"
else
  CONT_FLAG="-c"
fi

# ============================ AGENT-HARNESS DISPATCH (ADDITIVE, GATED) ======================
# HARNESS names WHICH agent CLI drives a turn. Everything else in this script — the prompts, the
# oracle, promotion, logging, export, the seed, the per-turn cadence — is shared and untouched, so
# swapping HARNESS isolates the harness as the ONLY independent variable.
#
#   HARNESS=opencode (default) -> `opencode run [-c] --agent $AGENT "<prompt>"`, byte-identical to
#                                 the command this script has always issued. Every existing arm is
#                                 unaffected: nothing below runs unless HARNESS is set to something
#                                 else, and the opencode branch is a literal copy of the old lines.
#   HARNESS=codex              -> scripts/codex_harness.sh defines codex_turn() (OpenAI Codex CLI).
#
# agent_turn <new|cont> <prompt>  — writes the agent's final message to stdout (that is what
# `opencode run` emits, so the STATUS-line parsing downstream is unchanged) and returns the CLI's
# exit code (124 => the turn was timeout-killed; the reset-after-kill escape still applies).
HARNESS=${HARNESS:-opencode}
if [ "$HARNESS" != "opencode" ]; then
  _HARNESS_LIB="$(dirname "$0")/${HARNESS}_harness.sh"
  if [ ! -f "$_HARNESS_LIB" ]; then
    echo "FATAL: HARNESS=$HARNESS but $_HARNESS_LIB does not exist." >&2; exit 1
  fi
  # shellcheck disable=SC1090
  . "$_HARNESS_LIB"
  if ! command -v "${HARNESS}_turn" >/dev/null 2>&1; then
    echo "FATAL: $_HARNESS_LIB did not define ${HARNESS}_turn()." >&2; exit 1
  fi
fi
agent_turn() {
  local _mode="$1" _prompt="$2"
  if [ "$HARNESS" = "opencode" ]; then
    if [ "$_mode" = "cont" ]; then
      $TO opencode run $CONT_FLAG --agent "$AGENT" "$_prompt" 2>&1
    else
      $TO opencode run --agent "$AGENT" "$_prompt" 2>&1
    fi
  else
    "${HARNESS}_turn" "$_mode" "$_prompt"
  fi
}

# ---------------------------------------------------------------- AGENT CARD MUST EXIST
# A MISSING CARD IS FATAL. It must never fall back.
#
# When `opencode run --agent X` cannot find card X it prints
#   ! agent "X" not found. Falling back to default agent
# and silently runs its OWN built-in default -- which has been
# `google/gemini-3-pro-image-preview`, an IMAGE model with no tool support. Every turn then
# dies on "No endpoints found that support tool use", no candidate is ever written, and the
# orchestrator logs "nothing to score" forever.
#
# Measured on the civ fleet 2026-09-26: six of ten arms ran 25/25 turns this way. The cards
# existed on the host and the compose referenced them correctly -- they were written four hours
# AFTER the image was built and the image was never rebuilt, so they were absent inside the
# container. `docker compose config` validated, `docker ps` was healthy, exit codes were 0.
# Nothing anywhere warned, and the arms looked *faster* than the working ones because erroring
# out costs no tokens.
#
# Failing loudly here is the only honest option: a fallback of ANY model produces 25 turns of
# real-looking data attributed to a model that never ran. Pinning a sane default would hide the
# same bug rather than surface it.
if [ "${HARNESS:-opencode}" = "opencode" ] && [ "${REQUIRE_AGENT_CARD:-1}" = "1" ]; then
  _card_found=""
  for _d in "${OPENCODE_AGENT_DIR:-}" /work/.opencode/agent "$(pwd)/.opencode/agent" \
            "$HOME/.config/opencode/agent"; do
    [ -n "$_d" ] && [ -f "$_d/$AGENT.md" ] && { _card_found="$_d/$AGENT.md"; break; }
  done
  if [ -z "$_card_found" ]; then
    echo "FATAL: agent card '$AGENT.md' not found in any agent dir." | tee -a "$LOG"
    echo "       opencode would fall back to its built-in default model (an image model with" | tee -a "$LOG"
    echo "       no tool support) and every turn would be void while looking healthy." | tee -a "$LOG"
    echo "       The card most likely postdates the image: rebuild it, or bind-mount the card." | tee -a "$LOG"
    echo "       Set REQUIRE_AGENT_CARD=0 only if you intend to run the default agent." | tee -a "$LOG"
    exit 78   # EX_CONFIG
  fi
  echo "agent card: $_card_found" | tee -a "$LOG"
fi

echo "=== opencode TAS loop: up to $N iterations, harness=$HARNESS, agent=$AGENT, PLAN=$PLAN_MODE, NO_EMULATOR=$NO_EMULATOR, ORACLE_FEEDBACK=$ORACLE_FEEDBACK, EVAL_BUDGET=${EVAL_BUDGET:-none}, TURN_TIMEOUT=${TURN_TIMEOUT}s, $(date +%H:%M:%S) ===" | tee -a "$LOG"
# Anti-stuck watchdog: SIGKILL runaway `sleep` children (the agent's "wait for the
# scorer to recover" hang) so a turn can't stall forever — WITHOUT SIGTERM-ing opencode
# (which corrupts the -c session). Default on; WATCHDOG=0 disables. Backward compatible.
if [ "${WATCHDOG:-1}" = "1" ]; then
  WATCHDOG_MAX_SLEEP="${WATCHDOG_MAX_SLEEP:-900}" WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-30}" \
    bash "$(dirname "$0")/tas_sleep_watchdog.sh" >>"$LOG" 2>&1 &
  WATCHDOG_PID=$!
  trap 'kill "$WATCHDOG_PID" 2>/dev/null' EXIT
  echo "(anti-stuck sleep-watchdog started: pid $WATCHDOG_PID, max_sleep=${WATCHDOG_MAX_SLEEP:-900}s)" | tee -a "$LOG"
fi

for i in $ITERS; do
  echo "=== ITERATION $i/$N $(date +%H:%M:%S) ===" | tee -a "$LOG"
  # Per-turn budget reset. In single-turn mode the EXTERNAL orchestrator owns this (it holds the
  # secret, which is NOT present in this container), so skip it here.
  if [ -z "${TAS_TURN_INDEX:-}" ]; then
    : > "$EVAL_COUNT_FILE" 2>/dev/null || true   # reset per-turn: EVAL_BUDGET (if set) caps THIS turn's replays
    # Hardened-but-not-split mode: reset the metered eval-service counter (needs the secret, which
    # in that mode IS in this container). No-op when EVAL_SERVICE_URL is unset.
    if [ -n "${EVAL_SERVICE_URL:-}" ]; then
      curl -s -X POST -H "X-Eval-Secret: ${EVAL_RESET_SECRET:-}" "$EVAL_SERVICE_URL/reset_turn" >/dev/null 2>&1 || true
    fi
  fi
  EV_BEFORE=0
  # In oracle mode, prepend the previous turn's TRUE scored result so the agent edits against reality.
  PFX=""
  if [ "$ORACLE_FEEDBACK" = "1" ] && [ -n "$FEEDBACK" ]; then PFX="$FEEDBACK
"; fi
  # When a per-turn replay budget is set, tell the agent up front so it plans its sweeps
  # rather than getting cut off mid-search (the scorer hard-refuses past the cap).
  if [ -n "${EVAL_BUDGET:-}" ] && [ "${EVAL_BUDGET:-0}" -gt 0 ] 2>/dev/null \
     && [ "${EVAL_BUDGET_ADVISORY:-0}" = "1" ]; then
    # Games whose scorer neither bumps EVAL_COUNT_FILE nor hard-refuses past the cap declare
    # EVAL_BUDGET_ADVISORY=1 in their adapter vocab (wolf3d: a standalone Playwright script).
    # Say the budget is advisory rather than lying about it — the real backstop is TURN_TIMEOUT.
    PFX="${PFX}EVALUATION BUDGET: run at most $EVAL_BUDGET scorer calls THIS turn. Each call costs \
~6-10s of wall clock, the cap is on your honour (nothing will stop you), and the turn is killed on a \
wall-clock timeout — so plan your sweeps, keep each one small, and make sure you report your best \
VALIDATED trajectory before you run out of time. NEVER \`sleep\` waiting for the scorer to 'recover'.
"
  elif [ -n "${EVAL_BUDGET:-}" ] && [ "${EVAL_BUDGET:-0}" -gt 0 ] 2>/dev/null; then
    PFX="${PFX}REPLAY BUDGET: you may run at most $EVAL_BUDGET emulator replays (scorer calls) THIS \
turn. Past that the scorer hard-refuses and you are cut off, so spend the budget wisely and report \
your best VALIDATED trajectory before exhausting it. When the budget is spent, a scorer call returns \
{\"budget_exceeded\": true, ...} (or stops returning results). That means STOP: immediately end your \
reply with the STATUS line for the best VALIDATED trajectory you already have. Do NOT retry, and NEVER \
\`sleep\` or wait for the scorer to 'recover' — it is not down; the budget only resets on the NEXT turn, \
which cannot start until you return.
"
  fi
  # NO_SEED: from-scratch framing (the orchestrator deletes ALL seeds; here we just tell the agent
  # there is no human demo). OUTPUT_SCHEMA: require the written trajectory JSON to match a schema
  # (literal string, or @/path to a file). Both default-empty => prompts unchanged (backward compatible).
  if [ "${NO_SEED:-0}" = "1" ]; then
    PFX="${PFX}FROM SCRATCH: there is NO seed trajectory and NO human demo to copy. Author the $GAME_LABEL \
speedrun trajectory YOURSELF — build a minimal VALID trajectory, validate it with the \
scorer, then iteratively improve it. Save it under results/speedrun/best/.
"
  fi
  if [ -n "${OUTPUT_SCHEMA:-}" ]; then
    _SCHEMA="$OUTPUT_SCHEMA"; case "$_SCHEMA" in @*) _SCHEMA="$(cat "${_SCHEMA#@}" 2>/dev/null)";; esac
    PFX="${PFX}OUTPUT SCHEMA — the trajectory JSON you write MUST conform exactly to:
$_SCHEMA
"
  fi
  # Marker for the per-iteration /tmp snapshot below: only scratch files the agent touched
  # DURING this turn are archived, instead of re-copying its entire /tmp on every turn.
  TURN_START=$(date +%s)
  if [ "$i" -eq 1 ]; then
    if [ "$PLAN_MODE" = "1" ]; then
      OUT=$(agent_turn new "$PFX$PLAN_PROMPT")      # planning turn (no optimize)
    else
      OUT=$(agent_turn new "$PFX$FIRST")
    fi
  elif [ "$PLAN_MODE" = "1" ]; then
    if [ "$REPLAN_EVERY" -ge 1 ] 2>/dev/null && [ $(( (i - 1) % REPLAN_EVERY )) -eq 0 ]; then
      OUT=$(agent_turn cont "$PFX$EXEC_REPLAN_PROMPT")  # re-survey + execute
    else
      OUT=$(agent_turn cont "$PFX$EXEC_PROMPT")         # execute top plan item
    fi
  else
    OUT=$(agent_turn cont "$PFX$CONT")
  fi
  rc=$?   # 124 = `timeout` killed the turn mid-stream (which can break the -c continue-session)
  # If this turn was timeout-killed, flag it so the NEXT turn starts a fresh session (reset-after-kill).
  if [ "$rc" = 124 ]; then
    : > "$KILL_FLAG" 2>/dev/null || true
    echo "--- turn $i KILLED by ${TURN_TIMEOUT}s timeout (rc=124); next turn will reset the session" | tee -a "$LOG"
  fi
  echo "$OUT" | tee -a "$LOG"
  # RUNTIME BACKSTOP for the card check above. The preflight looks in the agent dirs we know
  # about; if opencode ever resolves cards from somewhere else, this catches the fallback from
  # opencode's own mouth. Either way the run must STOP rather than attribute another model's
  # (or a tool-less image model's) turns to $AGENT.
  if [ "${REQUIRE_AGENT_CARD:-1}" = "1" ] \
     && printf '%s' "$OUT" | grep -q 'not found. Falling back to default agent'; then
    echo "FATAL: opencode fell back to its default agent -- '$AGENT' was not resolvable at runtime." | tee -a "$LOG"
    echo "       Every turn from here would be attributed to $AGENT but produced by another model." | tee -a "$LOG"
    exit 78
  fi
  # Tripwire bookkeeping (no-op unless MAX_CONSECUTIVE_ERRORS>0). Classified HERE, from the raw
  # reply, but only ACTED ON at the very end of the iteration, so a dead turn is still fully
  # logged and exported before the loop gives up.
  classify_turn "$OUT" "$rc"
  if [ "${DEAD_TURN:-0}" = "1" ]; then
    DEAD_STREAK=$(( DEAD_STREAK + 1 ))
    echo "--- turn $i produced no agent output / a provider error (consecutive: $DEAD_STREAK/$MAX_CONSECUTIVE_ERRORS)" | tee -a "$LOG"
  else
    DEAD_STREAK=0
  fi
  # ---- ORACLE: score the agent's blind candidate out-of-band, gate it, prep next-turn feedback ----
  # GAME-AGNOSTIC. This used to be a ~470-line if/elif chain over $GAME. Everything that differs
  # between games — which evaluator to run, how to read its output, what its metric is called,
  # whether a promotion must be re-verified from disk, what extra bookkeeping a turn owes — now
  # lives behind scripts/scorers/$GAME.sh (protocol: scripts/scorers/_lib.sh). What is left here
  # is the part that was always the same: promote iff the oracle says this run reached the goal
  # in strictly fewer frames, and hand the TRUE result back to the agent next turn.
  ORACLE_STATUS=""; ORACLE_GF=""
  if [ "$ORACLE_FEEDBACK" = "1" ] && [ -f "$CAND" ]; then
    # The agent's reply, on disk, so an adapter can mine it (SMB records claimed-vs-measured)
    # without pushing a megabyte of prose through the environment.
    printf '%s' "$OUT" > "$SCRATCH_TMP/tas_turn_output.txt" 2>/dev/null || true
    SC=$(TAS_ITER="$i" TAS_TURN_OUT_FILE="$SCRATCH_TMP/tas_turn_output.txt" \
         LOG="$LOG" SCRATCH_TMP="$SCRATCH_TMP" RUN_ID="$RUN_ID" AGENT="$AGENT" \
         "$TAS_SCORER" score "$CAND")
    if [ "${ORACLE_SCORE_ONLY:-0}" = "1" ]; then
      # SCORE-ONLY games (pokemon_blue_offline). The candidate is scored and nothing else
      # happens: no promotion, no feedback, the candidate file is not even removed. That is not
      # a design decision, it is the behaviour that game has had since it was added, preserved
      # verbatim by this refactor — see the long note in scripts/scorers/pokemon_blue_offline.sh
      # before you change it, because arms are running under it right now.
      eval "$SC" 2>/dev/null
    else
      O_REACHED=0; O_GF=""; O_DIED=0; O_MP=""; O_ERR=""
      # Feedback fragments + per-turn scratch the adapter fills in. Reset EVERY turn: a value
      # left over from the previous turn would be reported as this turn's result.
      O_METRICS=""; O_FAIL_DETAIL=""; O_TAIL=""; O_LOG_EXTRA=""
      O_VERIFY_GF=""; O_CLAIMED=""; O_CAND_SHA=""; O_NOT_SCORED=0
      eval "$SC"
      if [ "$O_REACHED" = "1" ] && [ -n "$O_GF" ] && [ "$O_GF" -lt "$BEST_FRAME" ] 2>/dev/null; then
        mkdir -p results/speedrun/best
        O_TGT="results/speedrun/best/best_${BEST_PREFIX}_${O_GF}f.json"
        cp -f "$CAND" "$O_TGT"
        if [ "$ORACLE_REVERIFY" = "1" ]; then
          # RE-VERIFY BEFORE PROMOTING. The promote step further down ranks
          # results/speedrun/best/ by the frame count in the FILENAME, so without this the name
          # is taken on trust and a bad promotion is only detectable after the fact, never
          # prevented. Copy first (done above), then score the COPY exactly as it now sits on
          # disk, in a fresh scorer process, and keep it only if it reproduces the same number.
          # Costs one extra scorer call, and only on turns that actually improved.
          eval "$(TAS_ITER="$i" LOG="$LOG" SCRATCH_TMP="$SCRATCH_TMP" \
                  RUN_ID="$RUN_ID" AGENT="$AGENT" "$TAS_SCORER" verify "$O_TGT")"
          if [ -n "$O_VERIFY_GF" ] && [ "$O_VERIFY_GF" = "$O_GF" ]; then
            VERDICT="KEPT — new validated best ${O_GF}f (was ${BEST_FRAME}f), re-verified from disk"
            BEST_FRAME="$O_GF"; ORACLE_STATUS="STATUS: IMPROVED $O_GF"; ORACLE_GF="$O_GF"
          else
            rm -f "$O_TGT"
            VERDICT="REJECTED — scored ${O_GF}f but the saved artifact re-scored as '${O_VERIFY_GF:-no clear}'; NOT promoted"
            ORACLE_STATUS="STATUS: SEARCHING"
            echo "--- ${ORACLE_NAME} ORACLE: PROMOTION REFUSED, re-score mismatch (${O_GF} vs ${O_VERIFY_GF:-none})" | tee -a "$LOG"
          fi
        else
          VERDICT="KEPT — new validated best ${O_GF}f (was ${BEST_FRAME}f)"
          BEST_FRAME="$O_GF"; ORACLE_STATUS="STATUS: IMPROVED $O_GF"; ORACLE_GF="$O_GF"
        fi
      elif [ "$O_REACHED" = "1" ]; then
        VERDICT="REJECTED — ${ORACLE_REACH_VERB} at ${O_GF}f, not better than ${BEST_FRAME}f"; ORACLE_STATUS="STATUS: SEARCHING"
      elif [ "${O_NOT_SCORED:-0}" = "1" ]; then
        # A REFUSAL IS NOT A FAILURE. On EVAL_BUDGET=0 arms the in-loop scorer is 429'd by the
        # ban, so the adapter sees no result fields and O_REACHED is 0 -- indistinguishable, to
        # the branch below, from a candidate that genuinely missed the goal. Rendering it as
        # "REJECTED — did NOT finish the lap" tells the agent its trajectory FAILED when in fact
        # it was never run. Measured on stk-glm53 2026-09-17: 199 of 200 turns carried that
        # sentence while the arm was actually finishing laps at 164.5s, and the agent had to
        # navigate by the filenames in results/speedrun/best/ instead. Adapters signal the
        # distinction with O_NOT_SCORED=1.
        VERDICT="NOT SCORED this turn — ${O_FAIL_DETAIL:-the metered eval-service declined to run it}. This is NOT a result: your trajectory was never executed. The oracle scores it between turns; write your candidate and end the turn."
        ORACLE_STATUS="STATUS: SEARCHING"
      else
        VERDICT="REJECTED — ${ORACLE_GOAL_FAIL} (${O_FAIL_DETAIL})"; ORACLE_STATUS="STATUS: SEARCHING"
      fi
      # Post-verdict hook: bookkeeping a game owes once the outcome is known (SMB writes its
      # claimed-vs-measured probe row here, and renders its vision frames). May amend O_TAIL.
      eval "$(TAS_ITER="$i" TAS_VERDICT="$VERDICT" \
              TAS_PROMOTED="$([ -n "$ORACLE_GF" ] && echo 1 || echo 0)" \
              O_REACHED="$O_REACHED" O_GF="$O_GF" O_DIED="$O_DIED" O_MP="$O_MP" \
              O_IGN="${O_IGN:-}" O_CLAIMED="$O_CLAIMED" O_CAND_SHA="$O_CAND_SHA" \
              O_VERIFY_GF="$O_VERIFY_GF" O_TAIL="$O_TAIL" \
              LOG="$LOG" SCRATCH_TMP="$SCRATCH_TMP" RUN_ID="$RUN_ID" AGENT="$AGENT" \
              "$TAS_SCORER" post)"
      # HAND THE CANDIDATE TO AN OUT-OF-CONTAINER ORACLE BEFORE DROPPING IT.
      # ORACLE_BY_PATH arms score from the ORCHESTRATOR, which runs AFTER this loop exits, so a
      # candidate deleted here is gone before anyone can read it. Symptom: the agent genuinely
      # writes a tape and logs "candidate.json regenerated", the in-loop scorer is 429'd by the
      # ban, this line removes the file, and the orchestrator then reports "nothing to score" --
      # 105 consecutive turns on the tuxemon fleet with best stuck at the 999999 sentinel. It
      # looks exactly like an agent producing nothing, which is the opposite of the truth.
      # SAME-FILE GUARD. ORACLE_KEEP_CAND is derived from ORACLE_CAND_PATH, and a fleet is free to
      # point that at candidate.json ITSELF -- wolf3d's EC2 launcher does exactly that. Then the
      # cp below copies the file onto itself (a no-op at best) and the rm deletes the only copy,
      # so the orchestrator that was meant to read it logs "nothing to score" on a turn where the
      # agent genuinely wrote a tape. Measured on the wolf3d E3L9 fleet: six arms x 200 turns,
      # every candidate destroyed, best/ left holding a 2-byte `{}`, and the result
      # indistinguishable from six models that never produced anything. astray escaped only
      # because its path happens to be candidate_for_oracle.json.
      # -ef compares device+inode, so it is correct despite the relative/absolute mismatch
      # ($CAND is relative to /work; ORACLE_CAND_PATH is absolute).
      _keep_is_cand=0
      if [ -n "${ORACLE_KEEP_CAND:-}" ] && [ -f "$CAND" ]; then
        if [ "$CAND" -ef "${ORACLE_KEEP_CAND}" ]; then
          _keep_is_cand=1
          echo "--- oracle: KEEP_CAND *is* the candidate; leaving it for the orchestrator" | tee -a "$LOG"
        else
          cp -f "$CAND" "${ORACLE_KEEP_CAND}" 2>/dev/null || true
        fi
      fi
      # Drop so a stale candidate is never re-scored if the agent writes nothing next turn --
      # unless the preserved copy IS this file, where dropping it defeats the whole purpose.
      [ "$_keep_is_cand" = 1 ] || rm -f "$CAND"
      FEEDBACK="ORACLE RESULT of your last candidate (scored for you by ${ORACLE_FEEDBACK_BY} — you \
may NOT run it): reached_goal=${O_REACHED}, goal_frame=${O_GF:-none}, ${O_METRICS}Current VALIDATED \
best=${BEST_FRAME}f. Verdict: ${VERDICT}. Trust THIS over your own prediction; base your next edit on it.${O_TAIL}"
      echo "--- ORACLE${ORACLE_LOG_TAG}: ${VERDICT}${O_LOG_EXTRA} | best=${BEST_FRAME}f${O_ERR:+ | err=$O_ERR}" | tee -a "$LOG"
    fi
  fi
  # PROMOTE: deterministically sync results/speedrun/best/best.json to the TRUE best trajectory in
  # that dir — fixes the bug where a CLEARING run was left as a side file while best.json kept a
  # worse (non-cleared / higher-frame) one. Ranking: reached_goal beats non-cleared; among cleared
  # fewer goal_frame wins; else higher max_progress. Cached (each trajectory scored once) +
  # best-effort (skips on budget-exceeded). Skipped in the blind NO_EMULATOR path (no scorer).
  # PROMO_MEASURED marks whether the goal_frame in $PROMO came out of the REAL scorer (1) or was
  # merely read off a filename (0). Only a 1 may be reused as `measured_best` further down.
  # WHICH of the two promotion policies a game uses is declared by its adapter as PROMOTE_MODE:
  #   filename — rank best/ by the frame count in the file NAME (wolf3d, astray, SMB)
  #   rescore  — rank by re-scoring every artifact with scripts/promote_best.py (SML lineage)
  PROMO=""; PROMO_MEASURED=0
  if [ "${PROMOTE_MODE:-rescore}" = "filename" ]; then
    # The browser games (wolf3d, astray) cannot use scripts/promote_best.py: that ranks by
    # re-scoring `segments` trajectories through scripts/speedrun.py, which has no entry for
    # either (every file would be skipped), and a re-score here would cost another browser
    # launch per file per turn. A best/best_<prefix>_<gf>f.json is only ever written AFTER a
    # validated clear — and for BOTH browser games (wolf3d and astray) only after the saved
    # artifact was RE-SCORED from disk in a fresh scorer process and matched (see the re-verify
    # in each oracle block) — so promoting from the frame count in the filename is sound: the
    # name can no longer disagree with the file. best.json is written as a plain action list, so
    # it stays directly re-scorable. NOTE this only covers files THIS loop wrote; a filename
    # planted in best/ by hand or by a seed mount is still trusted, which is why the seed mounts
    # are read-only and the turn-0 assertions check them.
    PROMO=$(.venv/bin/python - <<'PY' 2>/dev/null
import glob, os, re, shutil
d = "results/speedrun/best"
best = None
for f in glob.glob(os.path.join(d, "*.json")):
    if os.path.basename(f) == "best.json":
        continue
    m = re.search(r'(\d+)f\.json$', os.path.basename(f))
    if not m:
        continue
    gf = int(m.group(1))
    if best is None or gf < best[0]:
        best = (gf, f)
if best:
    tgt = os.path.join(d, "best.json")
    if os.path.abspath(best[1]) != os.path.abspath(tgt):
        shutil.copyfile(best[1], tgt)
    print("PROMOTED_BEST reached=True goal_frame=%d from=%s" % (best[0], os.path.basename(best[1])))
PY
)
    [ -n "$PROMO" ] && echo "--- promote: $PROMO" | tee -a "$LOG"
  elif [ "${NO_EMULATOR:-0}" != "1" ] && [ -f scripts/promote_best.py ]; then
    # PYTHONPATH: /work is the repo root INSIDE the sandbox container; "." is the repo root when
    # the loop is run directly on the host (we cd'd there at the top). It used to be /work only,
    # so on the host promote_best.py died with ModuleNotFoundError: No module named 'scripts' —
    # silently, because stderr is discarded — and best.json was never promoted at all.
    PROMO=$(TAS_GAME="$GAME" PYTHONPATH=/work:. .venv/bin/python scripts/promote_best.py "$GAME" results/speedrun/best 2>/dev/null | grep '^PROMOTED_BEST' | tail -1)
    PROMO_MEASURED=1   # promote_best.py re-scores with the real emulator (cached), so trust it
    [ -n "$PROMO" ] && echo "--- promote: $PROMO" | tee -a "$LOG"
  fi

  # ---------------------------------------------------------------------------------------
  # PER-TURN ROW — written for EVERY iteration, whatever ORACLE_FEEDBACK / NO_EMULATOR are.
  # This deliberately runs BEFORE the artifact copies and is NOT guarded by `[ -d $EXPORT_DIR ]`
  # (the directory was created and write-checked at startup): a failed `cp` must never be able
  # to cost us the row. Columns:
  #   status / goal_frame  — the ORACLE's true verdict when the oracle ran, otherwise whatever
  #                          the agent SELF-REPORTED on its STATUS line (frequently missing, so
  #                          frequently empty). AGENT-REPORTED — treat as a claim, not a result.
  #   measured_best        — re-measured by the REAL scorer from the artifacts on disk. This is
  #                          the agent-independent number and the one to plot.
  # ---------------------------------------------------------------------------------------
  st=""; gf=""
  if [ "$ORACLE_FEEDBACK" = "1" ] && [ -n "$ORACLE_STATUS" ]; then
    st="$ORACLE_STATUS"; gf="$ORACLE_GF"
  else
    st=$(echo "$OUT" | grep -oiE "STATUS: (IMPROVED [0-9]+|CONVERGED|SEARCHING|PLANNED)" | tail -1)
    gf=$(echo "$st" | grep -oE "[0-9]+")
  fi
  # measured_best, in order of preference:
  #   1. the promote step already re-scored the best artifact with the real emulator this turn
  #      (free — promote_best.py caches, so this costs nothing extra);
  #   2. otherwise measure it ourselves with the real scorer via scripts/measure_best.py
  #      (SML/GB/NES/N64 -> safe_score_speedrun_ctx; wolf3d -> scripts/wolf3d_score.py). Results
  #      are cached by file CONTENT hash, so an unchanged best costs nothing on later turns, and
  #      --max-new bounds how many fresh scores a single turn can trigger;
  #   3. last resort, the old filename heuristic — kept only so a run never regresses to blank,
  #      but it is AGENT-NAMED and therefore untrustworthy (an agent saving `sml_1-1_best.json`
  #      yields nothing; an agent inventing `..._5212f.json` yields a fabricated number).
  # EVAL_BUDGET is cleared and EVAL_COUNT_FILE redirected so this harness-side measurement can
  # neither be refused by the agent's per-turn replay cap nor inflate that cap's accounting.
  MB=""
  if [ "$PROMO_MEASURED" = "1" ] && [ -n "$PROMO" ]; then
    case "$PROMO" in
      *reached=True*) MB=$(printf '%s' "$PROMO" | sed -nE 's/.*goal_frame=([0-9]+).*/\1/p') ;;
    esac
  fi
  if [ -z "$MB" ] && [ "${MEASURE_BEST:-1}" = "1" ] && [ -f scripts/measure_best.py ]; then
    MB=$(EVAL_BUDGET= EVAL_COUNT_FILE=/dev/null TAS_GAME="$GAME" PYTHONPATH=. \
         WOLF3D_PY="${WOLF3D_PY:-.venv/bin/python}" \
         WOLF3D_SCORER="${WOLF3D_SCORER:-scripts/wolf3d_score.py}" \
         WOLF3D_EPISODE="${WOLF3D_EPISODE:-0}" WOLF3D_LEVEL="${WOLF3D_LEVEL:-0}" \
         ASTRAY_PY="${ASTRAY_PY:-.venv/bin/python}" \
         ASTRAY_SCORER="${ASTRAY_SCORER:-scripts/astray_score.py}" \
         ASTRAY_LEVEL="${ASTRAY_LEVEL:-1}" \
         .venv/bin/python scripts/measure_best.py "$GAME" \
           --max-new "${MEASURE_MAX_NEW:-6}" 2>/dev/null \
         | sed -nE 's/^MEASURED_BEST=([0-9]+)$/\1/p' | tail -1)
  fi
  if [ -z "$MB" ]; then
    MB=$(ls results/speedrun/*.json results/speedrun/best/*.json 2>/dev/null \
         | grep -oE "[0-9]+f\\.json" | grep -oE "[0-9]+" | sort -n | head -1)
  fi
  # `st` is free text from the agent and HAS contained commas, which shifted every later
  # column and produced junk measured_best values (a two-digit number where a five-digit
  # frame count belonged). No literal frame count in this comment on purpose: this script
  # ships inside the agent containers.
  # Strip CR/LF and double-quotes, then RFC4180-quote the field.
  st_csv=$(printf '%s' "${st:-NONE}" | tr -d '\r\n"')
  echo "$(date +%s),$(date -u +%Y-%m-%dT%H:%M:%SZ),$RUN_ID,$AGENT,$i,\"$st_csv\",${gf:-},${MB:-}" >> "$RUNLOG"
  # Precise emulator evaluations this turn. Hardened mode: read the authoritative count from
  # the eval-service (the agent's local file counter is not bumped on the RPC path). Else the
  # size delta of the shared counter file.
  if [ -n "${EVAL_SERVICE_URL:-}" ]; then
    EV_AFTER=$(curl -s "$EVAL_SERVICE_URL/stats" 2>/dev/null | sed -nE 's/.*"count":[[:space:]]*([0-9]+).*/\1/p')
    EV_AFTER=${EV_AFTER:-0}
  else
    EV_AFTER=$(wc -c < "$EVAL_COUNT_FILE" 2>/dev/null || echo 0)
  fi
  EVALS=$(( EV_AFTER - ${EV_BEFORE:-0} ))
  # METERED FAST-EVAL SPEND (host-side, un-tamperable). $EVALS above is the delta of a counter
  # that lives in THIS container, so it is exactly as trustworthy as the agent; for any scorer
  # that never bumps it, it reads 0. These three columns come from the HOST meter, which the
  # container cannot write, so a run's real per-turn spend is auditable after the fact.
  # /stats is authenticated by this arm's token and returns ONLY this arm's line.
  if [ -n "${SMB_FAST_EVAL_URL:-}" ]; then
    FE_STATS=$(curl -s --noproxy '*' --max-time 15 \
                 -H "X-Eval-Token: ${SMB_FAST_EVAL_TOKEN:-}" \
                 "${SMB_FAST_EVAL_URL%/}/stats" 2>/dev/null)
    FE_USED=$(printf '%s' "$FE_STATS" | sed -nE 's/.*"used":[[:space:]]*([0-9]+).*/\1/p')
    FE_LIMIT=$(printf '%s' "$FE_STATS" | sed -nE 's/.*"limit":[[:space:]]*([0-9]+).*/\1/p')
    FE_TURN=$(printf '%s' "$FE_STATS" | sed -nE 's/.*"turn":[[:space:]]*([0-9]+).*/\1/p')
    echo "$(date +%s),$RUN_ID,$AGENT,$i,$EVALS,${st:-NONE},${gf:-},${FE_USED:-},${FE_LIMIT:-},${FE_TURN:-}" >> "$EVLOG"
    echo "--- turn $i: status=${st:-NONE} goal_frame=${gf:-none} measured_best=${MB:-none} evals=$EVALS fast_eval=${FE_USED:-?}/${FE_LIMIT:-?}" | tee -a "$LOG"
  else
    echo "$(date +%s),$RUN_ID,$AGENT,$i,$EVALS,${st:-NONE},${gf:-}" >> "$EVLOG"
    echo "--- turn $i: status=${st:-NONE} goal_frame=${gf:-none} measured_best=${MB:-none} evals=$EVALS" | tee -a "$LOG"
  fi

  # AUTO-EXPORT every saved improvement out of the sandbox: if an export dir is mounted
  # (docker-compose `volumes:` maps a host dir to /work/exported), copy all trajectory JSONs
  # there after every iteration, so each new best lands on the HOST immediately and survives
  # container shutdown/recreate.
  if [ -d "$EXPORT_DIR" ]; then
    cp -f results/speedrun/*.json "$EXPORT_DIR"/ 2>/dev/null || true
    cp -f results/speedrun/best/*.json "$EXPORT_DIR"/ 2>/dev/null || true
    # $SCRATCH_TMP, never a bare /tmp: on the host every arm shares /tmp, so a bare glob copied
    # OTHER arms' scratch bests into this arm's export dir (that is how one 9301f file ended up
    # byte-identical in three different wolf3d arms). Identical to the old behaviour in a
    # container, where SCRATCH_TMP is /tmp and /tmp is private to that container.
    cp -f "$SCRATCH_TMP"/*trimmed*.json "$SCRATCH_TMP"/*best*.json "$SCRATCH_TMP"/seed_*.json \
       "$EXPORT_DIR"/ 2>/dev/null || true
    cp -f PLAN.md "$EXPORT_DIR"/ 2>/dev/null || true   # the agent's running optimization log (latest)
    cp -f "$LOG" "$EXPORT_DIR/loop_log.txt" 2>/dev/null || true  # loop log lives with its run
    # FULL per-iteration archive: snapshot EVERY trajectory json present at the END of this
    # iteration — the kept best AND discarded / non-improving candidates the agent left in
    # results/speedrun or /tmp — namespaced by run-id + iteration so nothing clobbers across
    # iterations or restarts. The full agent turn output is saved alongside (it records what
    # each tried candidate scored, i.e. WHY a candidate was kept or discarded).
    ITER_DIR="$EXPORT_DIR/iters/$RUN_ID/iter_$(printf '%03d' "$i")"
    mkdir -p "$ITER_DIR"
    cp -f results/speedrun/*.json "$ITER_DIR"/ 2>/dev/null || true
    cp -f results/speedrun/best/*.json "$ITER_DIR"/ 2>/dev/null || true
    # /tmp scratch: only what the agent WROTE THIS TURN. The old blanket `cp /tmp/*.json` re-copied
    # the agent's whole accumulated scratch every iteration, so a 200-turn arm wrote 5.4 GB of
    # near-duplicates (6 arms = 33 GB, which is what filled the disk). The intent was always "the
    # candidates it left behind this iteration"; -newermt actually expresses that.
    # ITER_SNAPSHOT_ALL_TMP=1 restores the old unconditional copy.
    # Anchored to $SCRATCH_TMP for the same reason as the copy above: -newermt bounds this to
    # files written THIS TURN, but on a shared /tmp "this turn" still includes seven other arms'
    # concurrent writes, so the iteration archive silently mixed arms together.
    if [ "${ITER_SNAPSHOT_ALL_TMP:-0}" = "1" ]; then
      cp -f "$SCRATCH_TMP"/*.json "$ITER_DIR"/ 2>/dev/null || true
    else
      find "$SCRATCH_TMP" -maxdepth 1 -name '*.json' -newermt "@$TURN_START" \
        -exec cp -f {} "$ITER_DIR"/ \; 2>/dev/null || true
    fi
    cp -f PLAN.md "$ITER_DIR"/ 2>/dev/null || true   # per-iteration snapshot of the plan/log
    printf '%s\n' "$OUT" > "$ITER_DIR/turn_output.txt" 2>/dev/null || true
  fi
  # The loop always runs the full N iterations regardless of per-turn outcome (sweeps are
  # stochastic; a no-gain step can be followed by a winning one). The agent's verdict is
  # recorded in run_log.csv's status column — no separate convergence detection here.
  #
  # ...with ONE exception: the consecutive-error tripwire. This is not convergence detection —
  # it fires only on turns that produced no agent reply at all, which is an infrastructure
  # failure, never a negative result. Exit 3 so a supervisor can tell it apart from a clean
  # finish (0) and from a crash.
  if [ "${MAX_CONSECUTIVE_ERRORS:-0}" -gt 0 ] 2>/dev/null \
     && [ "$DEAD_STREAK" -ge "$MAX_CONSECUTIVE_ERRORS" ]; then
    echo "FATAL: $DEAD_STREAK consecutive turns produced no agent output / a provider error \
(MAX_CONSECUTIVE_ERRORS=$MAX_CONSECUTIVE_ERRORS). Aborting at iteration $i/$N rather than \
logging turns that did nothing. Check the provider credentials and the proxy allowlist." \
      | tee -a "$LOG"
    echo "aborted_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) reason=consecutive_agent_errors streak=$DEAD_STREAK iteration=$i" \
      >> "$EXPORT_DIR/run_meta.txt" 2>/dev/null || true
    cp -f "$LOG" "$EXPORT_DIR/loop_log.txt" 2>/dev/null || true
    exit 3
  fi
done
echo "=== TAS loop done $(date +%H:%M:%S). log: $LOG | run dir: $EXPORT_DIR ===" | tee -a "$LOG"
cp -f "$LOG" "$EXPORT_DIR/loop_log.txt" 2>/dev/null || true
echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$EXPORT_DIR/run_meta.txt" 2>/dev/null || true
