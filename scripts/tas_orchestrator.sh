#!/bin/bash
# EXTERNAL orchestrator for the hardened offline TAS run. Runs in its OWN container (NOT the
# agent's), holds EVAL_RESET_SECRET + a Docker socket, and drives the agent ONE turn per
# `docker exec`. Per turn it (1) resets the metered eval-service's per-turn budget using the
# secret, then (2) exec's a single agent turn (scripts/opencode_tas_loop.sh in TAS_TURN_INDEX
# mode). Because the secret + the turn-boundary control live HERE and never enter the agent
# container, the agent cannot refill its own budget via /reset_turn — closing the last gap in
# the eval-service hardening (the agent already has no PyBoy/ROM, so it can't score off-meter).
#
# Required env:
#   AGENT_CONTAINER    name of the hardened agent container to exec into
#   EVAL_SERVICE_URL   e.g. http://eval-service:8910   (reset target)
#   EVAL_RESET_SECRET  shared secret for POST /reset_turn   (NEVER set on the agent container)
#   SWEEPS             number of turns (N)
set -u
N="${SWEEPS:-100}"
AGENT_CONTAINER="${AGENT_CONTAINER:?set AGENT_CONTAINER}"
: "${EVAL_SERVICE_URL:?set EVAL_SERVICE_URL}"
: "${EVAL_RESET_SECRET:?set EVAL_RESET_SECRET}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)-orch}"

# ORACLE_KEEP_CAND DEFAULTS TO WHERE WE ACTUALLY LOOK. These two must name the same file: the
# agent's own loop 429s on the ban and then `rm -f "$CAND"`, so unless a copy is preserved first
# the orchestrator -- which runs after the loop exits -- finds nothing and logs "nothing to
# score" forever. That reads as an idle agent and is the exact opposite of the truth: astray's
# agents were writing good tapes (a real 1697->1648 edit) and having them deleted, 9 turns per
# arm, and tuxemon burned 105 consecutive turns the same way.
#
# Deriving it here instead of asking two services to agree removes the failure mode entirely.
# Anyone setting it explicitly still wins. It is passed to the agent via `docker exec` below,
# NOT via the actor's compose env, so turning it on never requires recreating the actor and
# discarding its accumulated PLAN.md and notes.
if [ "${ORACLE_BY_PATH:-0}" = "1" ] || [ "${TUX_ORACLE_BY_PATH:-0}" = "1" ]; then
  : "${ORACLE_KEEP_CAND:=${ORACLE_CAND_PATH:-${TUX_CAND_PATH:-}}}"
  export ORACLE_KEEP_CAND
fi

log() { echo "[orchestrator $(date +%H:%M:%S)] $*"; }

reset_budget() {
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "X-Eval-Secret: $EVAL_RESET_SECRET" "$EVAL_SERVICE_URL/reset_turn"
}

# --- wait for the eval-service and the agent container to be ready ---
log "waiting for eval-service at $EVAL_SERVICE_URL ..."
for _ in $(seq 1 60); do
  curl -sf "$EVAL_SERVICE_URL/stats" >/dev/null 2>&1 && break; sleep 2
done
log "waiting for agent container '$AGENT_CONTAINER' ..."
for _ in $(seq 1 60); do
  docker exec "$AGENT_CONTAINER" true >/dev/null 2>&1 && break; sleep 2
done

# --- one-time seed reset in the AGENT container (was the agent command's prefix) ---
# SEED_MODE=human (default): keep the human-gold trajectory, drop other seeds -> agent starts from it.
# SEED_MODE=scratch: delete ALL trajectories (incl. human) -> agent authors one FROM SCRATCH.
# SEED_MODE=continue|keep: keep ALL existing trajectories -> RESUME a prior run from its current best.
# TRAJECTORY EXTENSIONS, plural. Pokemon/SMB/Tuxemon tapes are .json, but
# SuperTuxKart's DSL is .traj -- so a .json-only sweep silently deleted NOTHING
# for STK and every stale trajectory from a previous run survived the reset. The
# agent then started from whatever was lying around rather than from the seed,
# and the run looked seeded when it was not. Measured 2026-09-16.
# ARCHIVE exported/ FOR EVERY FRESH RUN, NOT JUST SCRATCH ONES.
# This block used to live inside the `scratch` branch, on the assumption that only a
# from-nothing arm is compromised by the previous run's notes. That is wrong: a SEEDED arm
# reads the same PLAN.md and the same turn_output.txt. Measured 2026-09-24 on mk64c -- after a
# clean relaunch (hardened image, no ROM, no cores) dspro was caught running
#   cat exported/iters/.../iter_048/turn_output.txt
# and reading back "baseline (11791): goal_frame=11791 maxr=1401" -- ground truth it had
# measured in the PREVIOUS run by driving the emulator it no longer has. Hardening removed the
# tool and left the tool's OUTPUT sitting in the bind mount. Seven arms cleared the bar inside
# nine turns on a fleet where seven had failed for a hundred, and the run had to be voided.
# `continue`/`keep` is exempt: resuming a run is the one case where the history is meant to survive.
_archive_exported() {
  [ "${SEED_MODE:-human}" = "continue" ] && return 0
  [ "${SEED_MODE:-human}" = "keep" ] && return 0
  if [ -z "${EXPORT_DIR_HOST:-}" ]; then
    log "seeding: WARNING — EXPORT_DIR_HOST unset; cannot verify exported/ is clean"
    return 0
  fi
  [ -d "$EXPORT_DIR_HOST" ] || return 0
  [ -n "$(ls -A "$EXPORT_DIR_HOST" 2>/dev/null)" ] || return 0
  _arch="${EXPORT_DIR_HOST%/}.prev-$(date -u +%Y%m%dT%H%M%SZ)"
  if mv "$EXPORT_DIR_HOST" "$_arch" 2>/dev/null; then
    mkdir -p "$EXPORT_DIR_HOST"
    log "seeding: archived prior exported/ to $(basename "$_arch")"
  else
    log "seeding: WARNING — could not archive $EXPORT_DIR_HOST; the prior run's PLAN.md and turn outputs are STILL VISIBLE to the agent"
  fi
}
_archive_exported

if [ "${SEED_MODE:-human}" = "scratch" ]; then
  log "seeding: SCRATCH — removing ALL trajectories (no seed)"
  docker exec "$AGENT_CONTAINER" bash -lc "find results/speedrun \( -name '*.json' -o -name '*.traj' \) -delete" || true
  # (exported/ already archived above, for every mode.)
  # HISTORICAL NOTE — why this matters at all:
  # /work/exported is a BIND MOUNT to out/exported/<arm> on the host, so wiping
  # results/speedrun inside the container leaves the PREVIOUS run's artefacts fully visible:
  # its PLAN.md, its trajectories, its notes. Measured 2026-09-23 on smlmet: after a recreate,
  # the agent read a 418KB PLAN.md from its own prior run and said so --
  #   "there's a long history of 85 turns with zero evaluations, and the plan describes a
  #    'jump-every-16-frames forever' tape that was never actually measured"
  # -- before writing its first candidate. The arm was reported as "from scratch" and was not.
  # ARCHIVE rather than delete: exported/ is also where results land for analysis, so a wipe
  # would destroy the record. Moving it aside keeps the data and gives the new run a clean dir.
  if false; then :
  elif [ -z "${EXPORT_DIR_HOST:-}" ]; then
    log "seeding: WARNING — EXPORT_DIR_HOST unset; cannot verify exported/ is clean for a scratch run"
  fi
elif [ "${SEED_MODE:-human}" = "continue" ] || [ "${SEED_MODE:-human}" = "keep" ]; then
  log "seeding: CONTINUE — keeping ALL existing trajectories (resume from current best)"
else
  # KEEP *human* OR *seed*. The pattern used to be *human* alone, which encoded
  # an assumption that a seed is always a human recording. That is false for
  # SuperTuxKart: rendering makes the engine non-deterministic, so a lap a human
  # can SEE cannot be re-driven, and the only re-drivable seed is a headless
  # SkiddingAI capture (verified bit-exact on re-drive). Naming that file *human* to survive the reset would be a
  # lie in the artefact; widening the pattern keeps the name honest.
  log "seeding: from GOLD seed (removing non-seed trajectories)"
  docker exec "$AGENT_CONTAINER" bash -lc "find results/speedrun \( -name '*.json' -o -name '*.traj' \) ! -name '*human*' ! -name '*seed*' -delete" || true
fi

log "starting $N turns; run_id=$RUN_ID; agent=$AGENT_CONTAINER"
for i in $(seq 1 "$N"); do
  code=$(reset_budget)
  if [ "$code" != "200" ]; then
    log "WARN: budget reset returned HTTP $code (turn $i) — continuing"
  fi
  log "=== TURN $i/$N (budget reset ok) ==="
  # --- WAIT FOR FRESH VISION FEEDBACK -------------------------------------------------
  # An external pass renders the PREVIOUS turn's attempts and writes
  # /work/gemini_suggestions.txt. It is triggered by the TURN line above, so wait for the file
  # to actually refresh before dispatching the agent - otherwise the agent reads stale advice
  # about attempts from two turns ago. Bounded, and skipped on turn 1 (nothing to analyse yet).
  if [ "${VISION_WAIT:-1}" = "1" ] && [ "$i" -gt 1 ]; then
    _t0=$(date +%s); _deadline=$(( _t0 + ${VISION_WAIT_SECS:-300} ))
    _before=$(docker exec "$AGENT_CONTAINER" sh -c 'stat -c %Y /work/gemini_suggestions.txt 2>/dev/null || echo 0')
    while [ "$(date +%s)" -lt "$_deadline" ]; do
      _now=$(docker exec "$AGENT_CONTAINER" sh -c 'stat -c %Y /work/gemini_suggestions.txt 2>/dev/null || echo 0')
      if [ "$_now" -gt "$_before" ]; then
        log "vision feedback refreshed after $(( $(date +%s) - _t0 ))s — dispatching turn $i"
        break
      fi
      sleep 10
    done
    if [ "$(date +%s)" -ge "$_deadline" ]; then
      log "WARN: vision feedback did not refresh within ${VISION_WAIT_SECS:-300}s — dispatching anyway"
    fi
  fi
  # --- PHASE GATE (objective, not self-reported) --------------------------------------
  # PHASE 1 = discovery (nothing finishes yet), PHASE 2 = optimise the thing that finishes. The
  # agent cannot be trusted to judge its own phase: it has saved a frontier.json carrying NO
  # goal_frame and then reported CONVERGED while nothing actually finished. So decide it here,
  # from the artifact.
  #
  # THE GATE IS OPT-IN PER GAME, AND THAT IS DELIBERATE. The IDEA is generic; the IMPLEMENTATION
  # is not, and cannot cheaply be made so. scripts/phase_gate.sh replays candidates through
  # scripts/phase_probe.py with MK64_GOAL_LAP, and thresholds them against SHORTCUT_MIN /
  # RECOVERY_MIN which are calibrated in Mario Kart 64 route units. There is no per-game probe
  # to swap in. Run unconditionally (which is what this did) it fails on every other game and
  # falls through to PHASE 1 by the `case` default — i.e. it wasted a replay attempt per turn and
  # then applied MK64 staging vocabulary to, say, a Game Boy run. Rather than pretend the
  # mechanism is generic, ask the AGENT CONTAINER what game it is running and only consult the
  # gate for games that actually have a probe.
  #
  #   PHASE_GATE=auto (default) — consult the gate iff the agent's $GAME is in $PHASE_GATE_GAMES
  #   PHASE_GATE=1              — always consult it
  #   PHASE_GATE=0              — never consult it
  #
  # DOCUMENTED DEFAULT WHEN THE GATE DOES NOT RUN: TAS_PHASE=1. It is still passed to the agent,
  # exactly as before, so no arm's environment changes; the only thing that goes away is a replay
  # that could never have produced a 2.
  PHASE_GATE="${PHASE_GATE:-auto}"
  PHASE_GATE_GAMES="${PHASE_GATE_GAMES:-mario_kart_64}"
  _use_gate=0
  case "$PHASE_GATE" in
    1) _use_gate=1 ;;
    0) _use_gate=0 ;;
    *) _agent_game=$(docker exec "$AGENT_CONTAINER" printenv GAME 2>/dev/null | tr -d '\r\n')
       case " $PHASE_GATE_GAMES " in *" ${_agent_game:-none} "*) _use_gate=1 ;; esac ;;
  esac
  TAS_PHASE=1
  if [ "$_use_gate" = 1 ]; then
    # phase_gate.sh REPLAYS the frontier here in the orchestrator (own ROM/core, so the agent's
    # metered budget is untouched) and caches by file hash. Reading the agent's `goal_frame`
    # field instead made the phase depend on a bookkeeping act: a genuinely finishing lap sat
    # unstamped and the gate never fired.
    TAS_PHASE=$(bash scripts/phase_gate.sh "$AGENT_CONTAINER" 2>/dev/null | tail -1 | tr -d '\r\n')
    case "$TAS_PHASE" in 1|2) ;; *) TAS_PHASE=1 ;; esac
    if [ "$TAS_PHASE" = 2 ]; then
      log "phase gate: PHASE 2 — a candidate finishes; optimising it"
    else
      log "phase gate: PHASE 1 — nothing finishes yet (discovery)"
    fi
  else
    log "phase gate: not applicable to game '${_agent_game:-unset}' (PHASE_GATE=$PHASE_GATE, probes exist for: $PHASE_GATE_GAMES) — dispatching PHASE 1"
  fi

  # ------------------------------------------------------------------------------------
  # Drive exactly one agent turn. The agent container already carries AGENT/PLAN/SWEEP_*/
  # EVAL_SERVICE_URL/EVAL_BUDGET in its env (compose); we add only the per-turn coordinates.
  # ORACLE_KEEP_CAND is forwarded because the loop DELETES the candidate at end of turn
  # (opencode_tas_loop.sh:807, `rm -f "$CAND"`, so a stale candidate is never re-scored) and only
  # preserves a copy when this is set. Without it the orchestrator arrives after the delete and
  # logs "nothing to score" for a turn the agent completed -- indistinguishable from an agent that
  # wrote nothing. Measured on pkblueun/glm53: an 18KB route program written at 01:44 was gone by
  # the time the oracle looked at 01:45:17. Passing it HERE rather than in the agent's compose env
  # means enabling it does not require recreating the actor and discarding its accumulated notes.
  _turn_out="${SCRATCH_TMP:-/tmp}/turn_$i.out"
  docker exec \
    -e TAS_TURN_INDEX="$i" -e TAS_NUM_TURNS="$N" -e RUN_ID="$RUN_ID" -e TAS_PHASE="$TAS_PHASE" \
    ${ORACLE_KEEP_CAND:+-e ORACLE_KEEP_CAND="$ORACLE_KEEP_CAND"} \
    ${ORACLE_FEEDBACK_FILE:+-e ORACLE_FEEDBACK_FILE="$ORACLE_FEEDBACK_FILE"} \
    "$AGENT_CONTAINER" bash -lc 'scripts/opencode_tas_loop.sh' 2>&1 | tee "$_turn_out"
  # PIPESTATUS, not `|| log`: through the pipe `||` would test tee's status, which is always 0,
  # and a failed turn would silently stop being reported.
  [ "${PIPESTATUS[0]}" -eq 0 ] || log "WARN: agent turn $i exited non-zero"

  # ---- DEAD-ARM DETECTOR --------------------------------------------------------------------
  # An arm whose PROVIDER has failed keeps running, keeps printing banners, keeps re-promoting
  # its seed as "PROMOTED_BEST reached=True", and keeps reporting "Up" to docker ps. It looks
  # healthy from every angle while measuring nothing. Not hypothetical: an OpenRouter credit
  # lapse on 2026-09-25/26 killed six arms across FOUR games and went unnoticed for two days --
  # astray opus burned 193 of 200 turns, supertux opus its last 36, SMB kimi all 200 (its
  # "2520f" was simply the untouched seed). A LAUNCH-TIME preflight would have caught NONE of
  # them: every one started healthy and died mid-run. Hence a per-turn check, here.
  #
  # TRANSPORT FAILURES ONLY. An eval-service 429 is the BAN WORKING AS DESIGNED and must never
  # match -- counting it would abort every correctly-banned arm on turn 1. That distinction is
  # exactly what made a naive grep useless during the fleet scan: it scored two healthy arms at
  # ~1000 "errors" each purely from their ban refusals.
  #
  # The phrase list alone is NOT enough to keep that promise: "Too Many Requests" is also the
  # HTTP reason phrase for 429, so an agent that pokes the banned scorer and echoes e.g.
  # `429 Client Error: Too Many Requests for url: http://eval-service-.../score` would match.
  # RETIRED MODELS count too. Baseten withdrew inkling-small and every call returned
  # `Error: Gone: the model version you are trying to access has been deprecated.` -- the
  # wolf3d e3l9 inkling arms burned 166 turns in 15 minutes on that line while this detector,
  # which did not know the phrase, stayed at zero.
  # Eight such turns would abort a healthy banned arm. So any line that names the eval-service,
  # the /score route or the budget is dropped BEFORE matching.
  _prov_err=$(grep -iE 'Insufficient credits|No endpoints found|Cannot connect to API|Too Many Requests|Provider returned error|AI_APICallError|Unauthorized|invalid api key|has been deprecated|model_not_found|The model .* does not exist' "$_turn_out" 2>/dev/null \
              | grep -viE 'eval-service|/score|EVAL_BUDGET|scoring is DISABLED' | head -1)
  if [ -n "$_prov_err" ]; then
    _deadstreak=$(( ${_deadstreak:-0} + 1 ))
    log "PROVIDER ERROR turn $i (consecutive ${_deadstreak}/${DEAD_ARM_LIMIT:-8}): $(printf '%s' "$_prov_err" | cut -c1-160)"
  else
    _deadstreak=0
  fi
  rm -f "$_turn_out"
  if [ "${_deadstreak:-0}" -ge "${DEAD_ARM_LIMIT:-8}" ]; then
    log "ABORTING: ${_deadstreak} consecutive turns failed at the PROVIDER, not the model."
    log "  The remaining $(( N - i )) turns would measure nothing but still cost money."
    log "  This arm is VOID from turn $(( i - _deadstreak + 1 )); fix the provider and relaunch."
    exit 75   # EX_TEMPFAIL -- transient upstream failure, not a bad configuration
  fi

  # ---- ORACLE SCORING FROM OUTSIDE THE AGENT (opt-in: ORACLE_BY_PATH=1) ------------------
  # GAME-AGNOSTIC. Was TUX_ORACLE_BY_PATH; SMB needs the identical topology, and a
  # per-game name would have meant a second copy of this block. TUX_* is still honoured
  # so the running tuxemon arms keep working without a recreate.
  # Gated, so no existing arm changes behaviour. Every other game runs its oracle INSIDE the
  # agent container, which forces a choice between two broken options:
  #   * give the agent EVAL_RESET_SECRET so the oracle can bypass the meter -- then the AGENT
  #     holds the key and EVAL_BUDGET=0 is a request, not a control. That is SuperTux today: its
  #     agent containers carry the secret, so agent scoring is privileged and uncounted.
  #   * withhold the secret -- then the harness's OWN scoring is metered too, EVAL_BUDGET=0 429s
  #     every candidate, and nothing is promoted across 200 turns.
  # Neither is a real "scorer banned" condition.
  #
  # Here the orchestrator scores instead: it holds the secret, the agent does not, and the tape
  # never crosses the wire -- the eval-service reads the candidate from its own READ-ONLY mount
  # of that arm's exported dir. The agent has no scorer and no key, so the ban is enforced.
  if { [ "${ORACLE_BY_PATH:-0}" = "1" ] || [ "${TUX_ORACLE_BY_PATH:-0}" = "1" ]; } \
     && [ -n "${EVAL_SERVICE_URL:-}" ]; then
    _cand="${ORACLE_CAND_PATH:-${TUX_CAND_PATH:-/work/candidates/candidate.json}}"
    # LOCAL SCORER PATH (ORACLE_LOCAL_SCORER). Some games' candidates are NOT scoreable by the
    # eval-service's generic entrypoint. SMB tapes are smb_fm2_rle_v1 -- "segments" of
    # [frame_count, "RLDUTSBA"] pairs -- which scripts/smb_tas_score.py understands and
    # score_speedrun_ctx does not: handed one it dies with
    #   TypeError: list indices must be integers or slices, not str
    # surfacing as "scorer returned None (native crash/timeout)", i.e. it looks like a flaky
    # emulator rather than the wrong scorer. The AGENT was following its ORACLE_ARTIFACT spec
    # exactly; the routing was wrong.
    #
    # This orchestrator image is not HARDENED, so it has the repo, the ROM and the venv. Pull the
    # candidate out of the agent and score it here. The agent still cannot score: it has no ROM and
    # the eval-service refuses it.
    if [ -n "${ORACLE_LOCAL_SCORER:-}" ]; then
      _lc=/tmp/oracle_cand_$i.json; _lo=/tmp/oracle_out_$i.json
      docker exec "$AGENT_CONTAINER" cat "$_cand" > "$_lc" 2>/dev/null || true
      if [ -s "$_lc" ]; then
        # CONSUME IT. The loop only deletes its candidate when the preserved copy is a DIFFERENT
        # file; when ORACLE_CAND_PATH points at candidate.json itself it now deliberately leaves
        # the file in place so we can read it here. Something must still clear it, or a turn
        # where the agent writes nothing re-scores the previous turn's tape and reports it as a
        # fresh result -- silently flat-lining a fleet at whatever it last achieved. We have the
        # bytes in $_lc, so removing the remote copy now is safe in both wirings.
        docker exec "$AGENT_CONTAINER" rm -f "$_cand" 2>/dev/null || true
        ${ORACLE_LOCAL_SCORER} "$_lc" --out "$_lo" >/dev/null 2>&1 || true
        if [ -s "$_lo" ]; then
          log "oracle turn $i (local): $(head -c 300 "$_lo")"
          # FEEDBACK + COPY-BACK. This branch used to log the verdict and `continue`, exactly
          # the defect documented on DATA_POST below -- scored, printed, discarded. The agent
          # never learned the result, so it re-proposed blind for its whole budget and best/
          # stayed empty however good the tape was. Both halves are required: feedback closes
          # the loop, copy-back banks the frontier.
          _verdict=$(cat "$_lo")
          if [ -n "${ORACLE_FEEDBACK_FILE:-}" ]; then
            printf '%s' "$_verdict" | "${TAS_PY:-python3}" /work/scripts/oracle_data_feedback.py \
              "${BEST_FRAME_INIT:-0}" "${ORACLE_GOAL_LABEL:-the goal}" > /tmp/oracle_fb_$i.txt 2>/dev/null || true
            if [ -s /tmp/oracle_fb_$i.txt ]; then
              docker exec -i "$AGENT_CONTAINER" sh -c "cat > '$ORACLE_FEEDBACK_FILE'" \
                < /tmp/oracle_fb_$i.txt 2>/dev/null || true
            fi
            rm -f /tmp/oracle_fb_$i.txt
          fi
          _new=$(printf '%s' "$_verdict" | "${TAS_PY:-python3}" -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
r=(d.get("result") or d)
v=r.get("goal_frame")
print(v if (r.get("reached_goal") and isinstance(v,(int,float)) and not isinstance(v,bool)) else "")' 2>/dev/null)
          # Progress frontier for a run that has not cleared yet -- same ratchet as DATA_POST,
          # without which an un-cleared arm is told "best=0f" every turn and regresses freely.
          _newp=$(printf '%s' "$_verdict" | "${TAS_PY:-python3}" -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
r=(d.get("result") or d)
p=r.get("max_progress")
print(p if (not r.get("reached_goal") and isinstance(p,(int,float)) and not isinstance(p,bool)) else "")' 2>/dev/null)
          _lgame="${ORACLE_DATA_GAME:-${GAME:-run}}"
          if [ -n "$_new" ]; then
            _bar=$(docker exec "$AGENT_CONTAINER" sh -c 'ls /work/results/speedrun/best/ 2>/dev/null' \
                   | grep -oE '[0-9.]+f\.json' | sed 's/f\.json$//' | sort -g | head -1)
            _bar="${_bar:-${BEST_FRAME_INIT:-}}"
            if [ -z "$_bar" ] || awk -v a="$_new" -v b="$_bar" 'BEGIN{exit !(a+0 < b+0)}'; then
              # Bank the bytes WE SCORED ($_lc), not '$_cand': the consume step above has already
              # deleted the agent's copy, so `cp '$_cand'` fails on every improvement. It shipped
              # that way and turned astray glm53-scratch's verified 321f into "copy-back FAILED".
              # Writing $_lc is also the stronger guarantee -- best/ gets exactly the tape that
              # earned the verdict, never something the agent rewrote in between.
              docker exec -i "$AGENT_CONTAINER" sh -c "cat > '/work/results/speedrun/best/agent_${_lgame}_${_new}f.json'" < "$_lc" 2>/dev/null \
                && log "oracle turn $i (local): COPY-BACK ${_new}f -> best/ (previous bar ${_bar:-none})" \
                || log "oracle turn $i (local): copy-back FAILED for ${_new}f"
            fi
          elif [ -n "$_newp" ]; then
            _pbar=$(docker exec "$AGENT_CONTAINER" sh -c 'ls /work/results/speedrun/best/ 2>/dev/null' \
                    | grep -oE '_p[0-9]+\.json' | sed 's/^.*_p//; s/\.json$//' | sort -g | tail -1)
            if [ -z "$_pbar" ] || awk -v a="$_newp" -v b="$_pbar" 'BEGIN{exit !(a+0 > b+0)}'; then
              docker exec -i "$AGENT_CONTAINER" sh -c "cat > '/work/results/speedrun/best/agent_${_lgame}_p${_newp}.json'" < "$_lc" 2>/dev/null \
                && log "oracle turn $i (local): COPY-BACK progress ${_newp} -> best/ (previous bar ${_pbar:-none})" \
                || log "oracle turn $i (local): progress copy-back FAILED for ${_newp}"
            fi
          fi
        else
          log "oracle turn $i (local): scorer produced no result"
        fi
      else
        log "oracle turn $i (local): nothing to score (no candidate written this turn)"
      fi
      rm -f "$_lc" "$_lo"
      continue
    fi
    # INLINE-SOURCE PATH (ORACLE_SRC_POST). Path scoring needs a directory BOTH the actor and the
    # eval-service can see. Pokemon deliberately has none: mounting the arm's results dir let one
    # arm read its own scored results and reconstruct the feedback the oracle withheld, so the
    # leaderboard measured who noticed the directory -- and `:ro` does not fix that, because
    # reading IS the leak. A Pokemon candidate is a text route program, so pull it out of the
    # agent and post the SOURCE, keeping the ban intact with no shared mount.
    # ---- TAPE POST (ORACLE_TAPE_POST) --------------------------------------------------------
    # The tape-only Pokemon condition. Same shape as ORACLE_SRC_POST below, but the candidate is
    # INERT DATA -- a frame-keyed tail -- posted to /score_tape instead of source posted to
    # /score. That is the entire condition: no agent Python ever executes beside the ROM, so the
    # WRAM channel (`self.m`), the readable ROM (open() is not banned) and the AST gate the
    # service itself calls "a speed bump, not a sandbox" all stop applying.
    #
    # The candidate file is JSON: {"boundary": N, "tail": [[start,count,"KEYS"], ...]}. It is
    # posted verbatim rather than rebuilt, so a malformed tail reaches the service's own
    # validator and comes back as an actionable message ("record 3 starts at frame X but the
    # previous record ends at Y") instead of being silently reshaped here.
    # ---- DATA POST (ORACLE_DATA_POST) --------------------------------------------------------
    # For an eval-service speaking the GENERIC protocol -- {fn, game, data, kw}, trajectory as
    # PARSED JSON under `data`. MK64 is one. ORACLE_SRC_POST below sends {"name","src"}, the
    # shape pk_eval_service.py and stk_eval_service.py accept because THEIR candidates are text,
    # so a JSON trajectory arrived as a string under the wrong key, the scorer was handed
    # nothing, and it surfaced as "scorer returned None (native crash/timeout)" -- which reads
    # as a flaky emulator rather than a wrong envelope.
    #
    # ORACLE_LOCAL_SCORER is not an alternative here either: scripts/speedrun.py routes through
    # _rpc_score, so the "local" scorer is an RPC CLIENT that hits the same eval-service without
    # a secret and is refused by the very EVAL_BUDGET=0 ban it is meant to be exempt from
    # (speedrun.py:118). Both were tried on MK64; this is the one that returns a measurement.
    #
    # X-Eval-Secret makes THIS call privileged while the agent stays banned: the orchestrator
    # holds the key, the agent never sees it, so EVAL_BUDGET=0 remains a control not a request.
    #
    # Verified against the live service BEFORE this branch was written:
    #   {fn:plain, game:mario_kart_64, data:{...}} -> max_progress=2000809
    #   (lap 0, ckpt 1, route 809 -- past the half-lap plane, lap not finished)
    if [ "${ORACLE_DATA_POST:-0}" = "1" ]; then
      _dc=/tmp/oracle_data_$i.json
      docker exec "$AGENT_CONTAINER" cat "$_cand" > "$_dc" 2>/dev/null || true
      if [ ! -s "$_dc" ]; then
        log "oracle turn $i: nothing to score (no candidate written this turn)"
        rm -f "$_dc"; continue
      fi
      _verdict=$("${TAS_PY:-python3}" /work/scripts/oracle_data_post.py \
                   "$_dc" "${EVAL_SERVICE_URL%/}/score" "$EVAL_RESET_SECRET" \
                   "${ORACLE_DATA_GAME:-${GAME:-}}" 2>/dev/null)
      rm -f "$_dc"
      log "oracle turn $i: $(printf '%s' "$_verdict" | head -c 300)"
      # FEEDBACK + COPY-BACK. Every transport block owns these; DATA_POST logged the
      # verdict and `continue`d without them, so a WINNING lap was measured, printed,
      # and thrown away. Measured on mk64wariofrontier: turn 3 returned
      # reached_goal=true goal_frame=7719 against a 7741 bar -- 22 frames under, a real
      # win -- and best/ stayed empty because nothing copied it back.
      if [ -n "${ORACLE_FEEDBACK_FILE:-}" ]; then
        printf '%s' "$_verdict" | "${TAS_PY:-python3}" /work/scripts/oracle_data_feedback.py \
          "${BEST_FRAME_INIT:-0}" "${ORACLE_GOAL_LABEL:-the goal}" > /tmp/oracle_fb_$i.txt 2>/dev/null || true
        if [ -s /tmp/oracle_fb_$i.txt ]; then
          docker exec -i "$AGENT_CONTAINER" sh -c "cat > '$ORACLE_FEEDBACK_FILE'" \
            < /tmp/oracle_fb_$i.txt 2>/dev/null || true
        fi
        rm -f /tmp/oracle_fb_$i.txt
      fi
      _new=$(printf '%s' "$_verdict" | "${TAS_PY:-python3}" -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
r=(d.get("result") or d)
v=r.get("goal_frame")
print(v if (r.get("reached_goal") and isinstance(v,(int,float)) and not isinstance(v,bool)) else "")' 2>/dev/null)
      # PROGRESS FRONTIER, banked even when the run did NOT clear.
      # Until 2026-09-23 the copy-back above fired ONLY on reached_goal, so an arm that had
      # not yet cleared banked nothing and was told "Current validated best=0f" every turn --
      # measured on smlmet GLM 5.2: 0f on all 143 verdicts, so the standing instruction
      # "start from the current VALIDATED best" was never once satisfiable. With no ratchet,
      # 54% of its submissions came in BELOW its own running best, and after first reaching
      # max_progress 2224 it produced 82 further verdicts and never beat it again. The two
      # arms that DID clear got a banked best immediately (Opus on verdict 1) and did not
      # regress. Banking the progress frontier gives an un-cleared arm the same ratchet.
      _newp=$(printf '%s' "$_verdict" | "${TAS_PY:-python3}" -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit()
r=(d.get("result") or d)
p=r.get("max_progress")
print(p if (not r.get("reached_goal") and isinstance(p,(int,float)) and not isinstance(p,bool)) else "")' 2>/dev/null)
      if [ -n "$_new" ]; then
        _bar=$(docker exec "$AGENT_CONTAINER" sh -c 'ls /work/results/speedrun/best/ 2>/dev/null' \
               | grep -oE '[0-9.]+f\.json' | sed 's/f\.json$//' | sort -g | head -1)
        _bar="${_bar:-${BEST_FRAME_INIT:-}}"
        if [ -z "$_bar" ] || awk -v a="$_new" -v b="$_bar" 'BEGIN{exit !(a+0 < b+0)}'; then
          _dst="/work/results/speedrun/best/agent_${ORACLE_DATA_GAME:-run}_${_new}f.json"
          docker exec "$AGENT_CONTAINER" sh -c "cp '$_cand' '$_dst'" 2>/dev/null \
            && log "oracle turn $i: COPY-BACK ${_new}f -> best/ (previous bar ${_bar:-none})" \
            || log "oracle turn $i: copy-back FAILED for ${_new}f"
        fi
      elif [ -n "$_newp" ]; then
        # Distinct `_p<n>.json` suffix so it can never be parsed as a goal_frame by the
        # `[0-9.]+f\.json` bar above, and so promote_best.py's rank() -- which already scores
        # an un-cleared run as (0, max_progress) -- picks the furthest one. HIGHER is better
        # here, the opposite of the frame bar.
        _pbar=$(docker exec "$AGENT_CONTAINER" sh -c 'ls /work/results/speedrun/best/ 2>/dev/null' \
                | grep -oE '_p[0-9]+\.json' | sed 's/^_p//; s/\.json$//' | sort -g | tail -1)
        if [ -z "$_pbar" ] || awk -v a="$_newp" -v b="$_pbar" 'BEGIN{exit !(a+0 > b+0)}'; then
          _dstp="/work/results/speedrun/best/agent_${ORACLE_DATA_GAME:-run}_p${_newp}.json"
          docker exec "$AGENT_CONTAINER" sh -c "cp '$_cand' '$_dstp'" 2>/dev/null \
            && log "oracle turn $i: COPY-BACK progress ${_newp} -> best/ (previous bar ${_pbar:-none})" \
            || log "oracle turn $i: progress copy-back FAILED for ${_newp}"
        fi
      fi
      # DO NOT FALL THROUGH. The path-scoring block below runs next and posts a
      # request eval_service.py must refuse -- "path must live under
      # /work/candidates" -- landing in the log immediately AFTER a successful
      # verdict. Two contradictory lines for one turn is how a working oracle gets
      # read as a broken one, and that misreading has cost real time today. Path
      # scoring is precisely what is unavailable on this arm.
      continue
    fi

    if [ "${ORACLE_TAPE_POST:-0}" = "1" ]; then
      _tp=/tmp/oracle_tape_$i.json
      docker exec "$AGENT_CONTAINER" cat "$_cand" > "$_tp" 2>/dev/null || true
      if [ ! -s "$_tp" ]; then
        log "oracle turn $i: nothing to score (no candidate written this turn)"
        rm -f "$_tp"; continue
      fi
      if ! "${TAS_PY:-python3}" -c 'import json,sys; json.load(open(sys.argv[1]))' "$_tp" 2>/dev/null; then
        log "oracle turn $i: candidate is not valid JSON (tape mode expects {\"boundary\":N,\"tail\":[...]})"
        rm -f "$_tp"; continue
      fi
      _verdict=$(curl -s -m 2400 -X POST "${EVAL_SERVICE_URL%/}/score_tape" \
                   -H 'Content-Type: application/json' \
                   -H "X-Eval-Secret: $EVAL_RESET_SECRET" \
                   --data-binary @"$_tp" || true)
      rm -f "$_tp"
      log "oracle turn $i: $(printf '%s' "$_verdict" | head -c 300)"
      # /score_tape returns a FLAT dict (ok/reached_badge/badge_frame/diagnosis), not the
      # {"result":{...}} envelope, so the generic feedback+copy-back path below would not parse
      # it. Handle both here and fall through to the next turn.
      "${TAS_PY:-python3}" - "$_verdict" "${BEST_FRAME_INIT:-0}" <<'PY' > /tmp/oracle_fb_$i.txt 2>/dev/null || true
import json, sys
try: d = json.loads(sys.argv[1] or "{}")
except Exception: d = {}
ok  = bool(d.get("reached_badge"))
gf  = d.get("badge_frame")
diag = d.get("diagnosis") or {}
bits = [f"{k}={v}" for k, v in diag.items() if v not in (None, "")]
if d.get("error"):
    bits.append("error=" + str(d["error"])[:300])
print("ORACLE RESULT of your last tape (verified from POWER-ON by the eval-service -- you may "
      "NOT run it): reached=%d, badge_frame=%s. %s Trust THIS over your own prediction; base "
      "your next tail on it." % (int(ok), gf if gf is not None else "none", " ".join(bits)))
PY
      if [ -n "${ORACLE_FEEDBACK_FILE:-}" ] && [ -s /tmp/oracle_fb_$i.txt ]; then
        docker exec -i "$AGENT_CONTAINER" sh -c "cat > '$ORACLE_FEEDBACK_FILE'" \
          < /tmp/oracle_fb_$i.txt 2>/dev/null || true
      fi
      # COPY-BACK on a verified improvement, same rule as the program path.
      _new=$(printf '%s' "$_verdict" | "${TAS_PY:-python3}" -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
print(d["badge_frame"] if (d.get("reached_badge") and isinstance(d.get("badge_frame"),int)) else "")' 2>/dev/null)
      if [ -n "$_new" ]; then
        _bar=$(docker exec "$AGENT_CONTAINER" sh -c 'ls /work/results/speedrun/best/ 2>/dev/null' \
               | grep -oE '[0-9]+f\.json' | grep -oE '[0-9]+' | sort -n | head -1)
        # FLOAT-SAFE. `-lt` is integer-only and STK's bar is a lap TIME (176.591), so
      # the comparison errored and no copy-back happened even once the value survived
      # the type check above. Same defect already fixed twice in this file's sibling
      # paths; awk keeps integer games ranking identically.
      if [ -z "$_bar" ] || awk -v a="$_new" -v b="$_bar" 'BEGIN{exit !(a+0 < b+0)}'; then
          _dst="/work/results/speedrun/best/agent_${GAME:-run}_${_new}f.json"
          docker exec "$AGENT_CONTAINER" sh -c "cp '$_cand' '$_dst'" 2>/dev/null \
            && log "oracle turn $i: COPY-BACK ${_new}f -> best/ (previous bar ${_bar:-none})" \
            || log "oracle turn $i: copy-back FAILED for ${_new}f"
        fi
      fi
      rm -f /tmp/oracle_fb_$i.txt
      continue
    fi

    if [ "${ORACLE_SRC_POST:-0}" = "1" ]; then
      _sc=/tmp/oracle_src_$i.txt
      docker exec "$AGENT_CONTAINER" cat "$_cand" > "$_sc" 2>/dev/null || true
      if [ ! -s "$_sc" ]; then
        log "oracle turn $i: nothing to score (no candidate written this turn)"
        rm -f "$_sc"; continue
      fi
      # Build the body with json.dumps -- a route program contains quotes, backslashes and
      # newlines, so shell interpolation would produce invalid JSON and read as a scorer failure.
      "${TAS_PY:-python3}" - "$_sc" > /tmp/oracle_req_$i.json <<'PY'
import json, sys
print(json.dumps({"name": "candidate", "src": open(sys.argv[1]).read()}))
PY
      _verdict=$(curl -s -m 2400 -X POST "${EVAL_SERVICE_URL%/}/score" \
                   -H 'Content-Type: application/json' \
                   -H "X-Eval-Secret: $EVAL_RESET_SECRET" \
                   --data-binary @/tmp/oracle_req_$i.json || true)
      rm -f "$_sc" /tmp/oracle_req_$i.json

      # CLOSE THE LOOP. Scoring the candidate is only half the job: the verdict has to reach the
      # agent's NEXT turn or it optimises blind. This response is FLAT ({"boundary":..,"error":..})
      # -- not the {"result":{...}} envelope the generic path below expects -- so it is parsed and
      # rendered here, in the same wording the in-loop scorer uses, and written into the agent
      # container for opencode_tas_loop.sh to pick up via ORACLE_FEEDBACK_FILE.
      if [ -n "${ORACLE_FEEDBACK_FILE:-}" ] && [ -n "$_verdict" ]; then
        _fb=$(printf '%s' "$_verdict" | "${TAS_PY:-python3}" -c '
import json, sys
try:
    d = json.load(sys.stdin) or {}
except Exception:
    sys.exit()
# Only a fresh-process REPRODUCED verdict counts as a score; an in-process number does not.
# SHAPE DETECTION. This parser was written for Pokemon and reads verified_badge_frame /
# VERDICT=="REPRODUCED" / boundary / end_map. A verdict from ANOTHER game contains none of
# those, so every field comes back empty and the agent is told
#     "reached_goal=0, goal_frame=none, Verdict: REJECTED -- did NOT reach BADGE_1 ()"
# no matter what actually happened. Measured on SuperTuxKart 2026-09-17: the kart drove
# progressively shorter distances on a lap it had previously been finishing, and every
# one of those turns produced that identical badge sentence with empty parentheses. The agent
# had no way to tell a small regression from a catastrophic one, so it could not do the revert-on-
# regression its own plan called for.
#
# The eval-service ALREADY returns what is needed (finished / max_distance / total_time), and
# the game adapter already formats it (O_METRICS="max_distance=...m"). Only this parser was
# blind to it. Detect the shape rather than adding a game flag: a payload carrying
# "max_distance" is a distance-scored game, and one carrying badge fields is Pokemon.
_distance_shape = "max_distance" in d or "finished" in d
gf = d.get("verified_badge_frame") or (d.get("verify") or {}).get("badge_frame")
ok = d.get("VERDICT") == "REPRODUCED" and gf is not None
err = (d.get("error") or "").replace("\n", " ")[:600]
bits = []
if _distance_shape:
    _fin = bool(d.get("finished"))
    _md  = d.get("max_distance")
    _tt  = d.get("total_time") or d.get("lap_time")
    ok = _fin and isinstance(_tt, (int, float))
    gf = _tt if ok else None
    if isinstance(_md, (int, float)):
        bits.append("max_distance=%.2fm" % _md)
    if d.get("laps_done") is not None:
        bits.append("laps_done=%s" % d["laps_done"])
    if not _fin:
        bits.append("did NOT finish the lap")
if d.get("boundary") is not None: bits.append("boundary=%s" % d["boundary"])
if d.get("end_map") is not None:  bits.append("end_map=%s at %s" % (d["end_map"], d.get("end_pos")))
if d.get("inproc_badge_frame") is not None:
    bits.append("in-process badge_frame=%s (NOT a score)" % d["inproc_badge_frame"])
print("REACHED" if ok else "FAILED")
print(gf if ok else "")
# The RouteError is the single most useful line the agent gets -- BRIEF.md calls it the main
# signal. Surfacing it verbatim is the entire point of this block.
print("; ".join(bits) + ("; RouteError: " + err if err else ""))
' 2>/dev/null)
        _fb_ok=$(printf '%s' "$_fb"  | sed -n 1p)
        _fb_gf=$(printf '%s' "$_fb"  | sed -n 2p)
        _fb_det=$(printf '%s' "$_fb" | sed -n 3p)
        if [ -n "$_fb_ok" ]; then
          # Track the bar here: pk has no frame-keyed <n>f.json for promote_best to rank, so the
          # orchestrator is the only thing that can carry "current best" across turns.
          _bar="${_PK_BEST:-${BEST_FRAME_INIT:-0}}"
          # NUMERIC, NOT INTEGER. `[ x -lt y ]` is integer-only, and SuperTuxKart scores a lap in
          # SECONDS to six decimals (164.514267), not frames. Every STK turn therefore died on
          #     tas_orchestrator.sh: line 361: [: 164.514267: integer expression expected
          # so this branch never ran, _PK_BEST never advanced, and the agent was told
          # "Current VALIDATED best=999999f" for all 200 turns while actually improving.
          # awk compares as floats and is byte-identical for integers.
          if [ "$_fb_ok" = "REACHED" ] && [ -n "$_fb_gf" ] \
             && { [ "$_bar" = "0" ] || awk -v a="$_fb_gf" -v b="$_bar" 'BEGIN{exit !(a+0 < b+0)}'; }; then
            _PK_BEST="$_fb_gf"
            docker exec "$AGENT_CONTAINER" sh -c \
              "mkdir -p results/speedrun/best && cp -f '$_cand' 'results/speedrun/best/best_pk_${_fb_gf}f.py'" \
              2>/dev/null && log "PROMOTED: badge_frame=$_fb_gf (was $_bar)"
          fi
          # The goal NOUN is per-game. Default keeps every Pokemon arm's wording byte-identical.
          _goal="${ORACLE_GOAL_LABEL:-BADGE_1}"
          _verd_txt="REJECTED — did NOT reach ${_goal}"
          [ "$_fb_ok" = "REACHED" ] && _verd_txt="REPRODUCED — reached ${_goal} at ${_fb_gf}f"
          printf 'ORACLE RESULT of your last candidate (scored for you by the metered eval-service — you may NOT run it): reached_goal=%s, goal_frame=%s, Current VALIDATED best=%sf. Verdict: %s (%s). Trust THIS over your own prediction; base your next edit on it.\n' \
            "$([ "$_fb_ok" = REACHED ] && echo 1 || echo 0)" "${_fb_gf:-none}" \
            "${_PK_BEST:-${BEST_FRAME_INIT:-0}}" "$_verd_txt" "$_fb_det" \
            | docker exec -i "$AGENT_CONTAINER" sh -c "cat > '$ORACLE_FEEDBACK_FILE'" 2>/dev/null
          log "oracle turn $i: $_fb_ok ${_fb_gf:+goal_frame=$_fb_gf }| $_fb_det"
          continue
        fi
      fi
    else
    # `|| true`: a curl failure must not kill the orchestrator mid-run under set -e.
    _verdict=$(curl -s -m 2400 -X POST "${EVAL_SERVICE_URL%/}/score" \
                 -H 'Content-Type: application/json' \
                 -H "X-Eval-Secret: $EVAL_RESET_SECRET" \
                 -d "{\"path\":\"$_cand\"}" || true)
    fi
    case "$_verdict" in
      "")             log "oracle turn $i: no response from $EVAL_SERVICE_URL" ;;
      *'"result"'*)   log "oracle turn $i: $(printf '%s' "$_verdict" | head -c 300)" ;;
      *'no candidate'*)
        # EXPECTED, NOT AN ERROR. PLAN turns (and any turn the agent ends without writing) leave
        # nothing to score. Logging this as REFUSED made turn 1 look like the ban was blocking the
        # harness -- the exact failure this topology exists to avoid -- when the agent had simply
        # not produced a tape yet. Distinguish the two, or the real failure hides in the noise.
        log "oracle turn $i: nothing to score (no candidate written this turn)" ;;
      *)              log "oracle turn $i: REFUSED -- $(printf '%s' "$_verdict" | head -c 200)" ;;
    esac

    # ---- COPY-BACK: a WINNING candidate has to LAND in the agent's best/ ---------------------
    # NOBODY OWNED THIS, AND IT SILENTLY CAPPED EVERY SEEDED ARM. promote_best only ranks files
    # that are ALREADY in results/speedrun/best/. In the normal topology the AGENT saves its own
    # best -- but here the agent cannot score (that is the entire point of the ban), so it has no
    # idea which of its tapes is good, and nothing else wrote there. best/ therefore held only the
    # seed, the promoter re-promoted the seed every turn, and every real improvement was logged
    # and then overwritten. Measured: Tuxemon/grok found -738 engine_steps and SMB/kimi -82
    # frames; both were discarded. Worse than losing them, each arm was told its best was still
    # the seed, so it restarted from the seed every turn and could never COMPOUND an improvement
    # -- kimi re-derived the identical 2438 three turns running.
    #
    # The score field differs by game (SMB reached_goal/goal_frame, Tuxemon
    # reached_target/engine_steps) and the filename MUST end <N>f.json, because the baseline is
    # recovered by regexing the number back out of it (opencode_tas_loop.sh).
    _new=$(printf '%s' "$_verdict" | .venv/bin/python -c '
import json,sys
try: d=(json.load(sys.stdin) or {}).get("result") or {}
except Exception: sys.exit()
ok = d.get("reached_goal") or d.get("reached_target")
v  = d.get("goal_frame") if d.get("goal_frame") is not None else d.get("engine_steps")
# FLOAT GOAL VALUES ARE REAL. MK64 and SMB report an integer FRAME count, so
# `isinstance(v, int)` held for every game until STK, which reports SECONDS:
# goal_frame=176.591034. A genuine finished lap -- reached_goal=True, laps_done=1 --
# was therefore discarded on a type check and never copied back into best/, so the
# agent kept being told best=999999f with a finishing tape already in hand.
# Formatted with %g so an integer frame count still renders as "7741" and lands in
# the <N>f.json filename promote_best ranks on, while 176.591034 survives intact.
print(("%g" % v) if (ok and isinstance(v, (int, float)) and not isinstance(v, bool)) else "")' 2>/dev/null)
    if [ -n "$_new" ]; then
      # The candidate path above is in the EVAL-SERVICE namespace (/work/candidates/...); the
      # agent mounts that same host dir at /work/exported. Copying $_cand verbatim inside the
      # agent would fail on a path that does not exist there.
      _agent_cand="/work/exported/$(basename "$_cand")"
      _bar=$(docker exec "$AGENT_CONTAINER" sh -c 'ls /work/results/speedrun/best/ 2>/dev/null' \
             | grep -oE '[0-9]+f\.json' | grep -oE '[0-9]+' | sort -n | head -1)
      # FLOAT-SAFE. `-lt` is integer-only and STK's bar is a lap TIME (176.591), so
      # the comparison errored and no copy-back happened even once the value survived
      # the type check above. Same defect already fixed twice in this file's sibling
      # paths; awk keeps integer games ranking identically.
      if [ -z "$_bar" ] || awk -v a="$_new" -v b="$_bar" 'BEGIN{exit !(a+0 < b+0)}'; then
        # GAME IS NOT SET IN THE ORCHESTRATOR -- it lives on the AGENT container (the compose game
        # anchors). Referencing it bare under `set -u` aborted the orchestrator with "GAME:
        # unbound variable" one line after the first winning verdict, killing the arm. The prefix
        # is cosmetic; only the trailing <N>f.json is load-bearing.
        # And do NOT put comments between `sh -c \` and its argument: the backslash joins the
        # lines, the `#` then swallows the rest, and `sh -c` runs with NO command -- which exits
        # non-zero and reports as "copy-back FAILED" against a cp that is actually fine.
        _dst="/work/results/speedrun/best/agent_${GAME:-run}_${_new}f.json"
        if docker exec "$AGENT_CONTAINER" sh -c "cp '$_agent_cand' '$_dst'" 2>/dev/null; then
          log "oracle turn $i: COPY-BACK ${_new}f -> best/ (previous bar ${_bar:-none})"
        else
          log "oracle turn $i: copy-back FAILED for ${_new}f from $_agent_cand"
        fi
      fi
    fi

    # ---- FEEDBACK DELIVERY (generic) ---------------------------------------------------------
    # WITHOUT THIS THE AGENT OPTIMISES BLIND, AND IT LOOKS LIKE A MODEL FAILURE.
    # Each turn is a fresh process, so opencode_tas_loop.sh:218 reads FEEDBACK from
    # $ORACLE_FEEDBACK_FILE *inside the agent* or starts with nothing. The Pokemon branch above
    # writes that file; this generic branch never did. Consequence, measured 2026-09-07: every
    # Tuxemon arm in BOTH the seeded and +trail fleets ran 200 turns without ever seeing an oracle
    # verdict -- and the whole point of the +trail condition (return `map_trail` so the agent can
    # see WHERE its route spends steps) was computed by the eval-service, logged here truncated to
    # 300 chars, and then discarded. The condition was never actually delivered.
    #
    # Game-agnostic on purpose: reached_goal/goal_frame (SMB, pk) and reached_target/engine_steps
    # (Tuxemon) are both handled, and map_trail is appended when the service returns it.
    if [ -n "${ORACLE_FEEDBACK_FILE:-}" ] && [ -n "$_verdict" ]; then
      # NO BACKSLASHES INSIDE f-STRING EXPRESSIONS, and NO 2>/dev/null on the python.
      # v1 of this block used f"...{val if val is not None else \"none\"}..." which is a
      # SyntaxError before Python 3.12, and stderr was suppressed -- so it failed silently and
      # wrote an empty file. The orchestrator logged healthy "oracle turn N" lines the whole time
      # while the agent received nothing, which is indistinguishable from the ORIGINAL bug this
      # code exists to fix. Any formatter error must now be visible in the orchestrator log.
      _fbtxt=$(printf '%s' "$_verdict" | .venv/bin/python -c '
import json,sys
try: d=(json.load(sys.stdin) or {}).get("result") or {}
except Exception: sys.exit(0)
ok    = bool(d.get("reached_goal") or d.get("reached_target"))
val   = d.get("goal_frame") if d.get("goal_frame") is not None else d.get("engine_steps")
score = str(val) if val is not None else "none"
bits  = []
for k in ("maps_reached","final_map","agent_steps","error"):
    if d.get(k) not in (None,""):
        bits.append("%s=%s" % (k, d[k]))
trail = d.get("map_trail")
if trail:
    # Collapse the per-action sequence to visit COUNTS per map: repeats ARE the redundant laps,
    # and the raw ~47-entry list would dominate the feedback string.
    from collections import Counter
    c = Counter(m for _i, m in trail if m)
    bits.append("map visit counts (a map appearing N>1 times means the route re-entered it): "
                + ", ".join("%s x%d" % (m, n) for m, n in c.most_common()))
print("ORACLE RESULT of your last candidate (scored for you by the metered eval-service -- you "
      "may NOT run it): reached=%d, score=%s. %s "
      "Trust THIS over your own prediction; base your next edit on it."
      % (int(ok), score, " ".join(bits)))') || _fbtxt=""
      if [ -n "$_fbtxt" ]; then
        printf '%s\n' "$_fbtxt" \
          | docker exec -i "$AGENT_CONTAINER" sh -c "cat > '$ORACLE_FEEDBACK_FILE'" || true
      else
        log "oracle turn $i: WARNING feedback formatter produced nothing (agent will run blind)"
      fi
    fi

    printf '%s\n' "$_verdict" > "/tmp/oracle_turn_${i}.json" 2>/dev/null || true
  fi
done
log "=== orchestrator done: $N turns ==="
