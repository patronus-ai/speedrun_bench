#!/bin/bash
# Shared helpers for the per-game GAME ADAPTERS in this directory.
#
# WHAT AN ADAPTER IS. scripts/opencode_tas_loop.sh is game-agnostic; everything that is true of
# ONE game lives in scripts/scorers/<GAME>.sh. The loop looks the file up by $GAME and talks to
# it over a four-verb stdout protocol, so the loop never grows another `if [ "$GAME" = ... ]`.
#
#   <GAME>.sh vocab            -> KEY=value lines: the game's labels, prompt nouns, oracle
#                                 vocabulary and evaluator settings. Evaluated ONCE, near the
#                                 top of the loop, before any prompt string is built.
#   <GAME>.sh score <cand>     -> KEY=value lines describing the oracle's verdict on <cand>:
#                                 O_REACHED / O_GF / O_DIED / O_MP / O_EXTRA / O_ERR plus the
#                                 pre-rendered feedback fragments (see below).
#   <GAME>.sh verify <path>    -> O_VERIFY_GF=<frames|''>. Only called when the adapter asked
#                                 for it with ORACLE_REVERIFY=1. Re-scores the artifact AS IT
#                                 SITS ON DISK, in a fresh scorer process, so a promotion is
#                                 never made on the strength of an in-loop number.
#   <GAME>.sh post             -> optional; runs AFTER the promotion decision, may emit more
#                                 KEY=value lines (e.g. an amended O_TAIL). No-op by default.
#
# EVERY LINE AN ADAPTER PRINTS ON STDOUT IS `eval`d BY THE LOOP. Emit with `emit`/`emit_val`
# (which shell-quote with printf %q) or from a python heredoc that quotes its own output.
# Anything you want a human to read goes through `olog`, never to stdout.
#
# THE FEEDBACK FRAGMENTS. The loop assembles one generic sentence:
#
#   ORACLE RESULT of your last candidate (scored for you by <ORACLE_FEEDBACK_BY> - you may NOT
#   run it): reached_goal=<O_REACHED>, goal_frame=<O_GF|none>, <O_METRICS>Current VALIDATED
#   best=<n>f. Verdict: <VERDICT>. Trust THIS over your own prediction; base your next edit on
#   it.<O_TAIL>
#
# so a game controls its own wording through four strings it emits from `score`:
#   O_METRICS      the game's own metric clause. MUST end with ". " if non-empty.
#   O_FAIL_DETAIL  what goes in the parentheses of "REJECTED - <ORACLE_GOAL_FAIL> (<detail>)".
#   O_TAIL         anything appended after the closing sentence (error notes, etc).
#   O_LOG_EXTRA    extra text for the console line, between the verdict and " | best=".
#
# and four strings it emits from `vocab`:
#   ORACLE_FEEDBACK_BY  who scored it, as named to the agent.
#   ORACLE_REACH_VERB   "reached goal" / "completed 8-4" / ... used in the not-better verdict.
#   ORACLE_GOAL_FAIL    "did NOT reach the exit" / ... used in the failed verdict.
#   ORACLE_NAME         short tag for this game's console lines ("wolf3d", "SMB", ...).
set -u

# emit VAR            -> VAR=<current value, shell-quoted>
emit() { printf '%s=%q\n' "$1" "${!1-}"; }
# emit_val KEY VALUE  -> KEY=<value, shell-quoted>
emit_val() { printf '%s=%q\n' "$1" "$2"; }
# dflt VAR TEXT       -> set VAR to TEXT unless it is already set and non-empty.
# Exactly the semantics of the old `VAR=${VAR:-TEXT}` lines, but it parses correctly when TEXT
# contains an ODD number of apostrophes (bash treats a ' inside ${...} as opening a quote, which
# silently left the variable EMPTY and let another game's defaults win - see the wolf3d block's
# history). Never write ${VAR:-...} with prose defaults in an adapter; always use dflt.
dflt() { [ -n "${!1:-}" ] || printf -v "$1" '%s' "$2"; }

# olog MSG -> the human-readable channel. Goes to STDERR (stdout is the KEY=value protocol) and,
# when the loop passed one in, is appended to the loop's own log file. Both streams of the loop
# land in the same place in every deployment (docker logs / `>file 2>&1`), so this is the same
# console text the pre-adapter code produced with `| tee -a "$LOG"`.
olog() {
  printf '%s\n' "$*" >&2
  [ -n "${LOG:-}" ] && printf '%s\n' "$*" >> "$LOG" 2>/dev/null
  return 0
}

# The python the harness scripts use. Adapters run INSIDE the agent container, where the repo
# venv is at .venv - identical to the hard-coded `.venv/bin/python` the loop used before.
TAS_PY="${TAS_PY:-.venv/bin/python}"
