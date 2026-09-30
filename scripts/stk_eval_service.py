#!/usr/bin/env python3
"""Scoring service for SuperTuxKart (stk-ghosts), with an ENFORCEABLE agent ban.

TOPOLOGY. The actor writes a trajectory and cannot run the engine: the native binary and the
1.5GB stk-assets checkout live only here. The only scoring path is this HTTP service, so
EVAL_BUDGET=0 is a control rather than a request.

THE PRIVILEGED-ORACLE GATE IS NOT OPTIONAL, AND THIS FILE EXISTS BECAUSE OF WHAT HAPPENED
WITHOUT IT. pk_eval_service.py was the one service of four that lacked it; when EVAL_BUDGET=0
started meaning BANNED, the gate refused the HARNESS as well as the agent and an arm ran 186
turns scoring absolutely nothing -- every archived verdict the same 429, `best` frozen on the
seed, the model writing 3,000-line routes into a void. The rule that falls out of it:

    the privilege boundary is the CONTAINER boundary.

EVAL_RESET_SECRET belongs in the orchestrator and NEVER in the actor. An oracle running inside
the actor is unprivileged and 429s alongside it, which is the property that makes the ban real.
SuperTux put the secret in the agent container and its ban is bypassable; do not copy that.

SCORING IS episode.py's, NOT A NEW ONE. tools/ghosts/episode.py:score_key ranks
    finished    -> (1, 1.0,   -total_time)
    unfinished  -> (0, alive,  max_distance)
    timeout     -> below everything
so an unfinished run still carries a gradient (distance) and any finish beats every non-finish.
That matters here: nothing finishes a lap yet -- the human tape re-drives only 369.88m of ~2614m
and the re-derived line dies at pad 3 -- so early fleets live entirely in the `unfinished` branch.
Re-deriving the ranking here would risk disagreeing with the repo that owns it, so this shells
out to the same `tools.ghosts drive` the project uses and reports its fields verbatim.

    EVAL_BUDGET=0 EVAL_RESET_SECRET=... python3 scripts/stk_eval_service.py --port 8940
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# Popped so a subprocess -- notably the drive itself -- cannot read it out of the environment.
_SECRET = os.environ.pop("EVAL_RESET_SECRET", None)
_BUDGET = os.environ.get("EVAL_BUDGET")
REPO = Path(os.environ.get("STK_REPO", "/src"))
BINARY = REPO / "build" / "native" / "bin" / "supertuxkart"
TIMEOUT = int(os.environ.get("STK_TIMEOUT", "900"))

_lock = threading.Lock()
_count = 0
_total = 0


def _budget():
    """Per-turn cap. None = unlimited, 0 = BANNED, n>0 = n drives.

    Distinguish UNSET from 0 -- and note that `if cap` is the bug this shape exists to avoid:
    0 is falsy, so a truthiness test silently means "uncapped" and the ban never fires. Equally,
    a compose that WANTS uncapped must pass empty, not 0; pkblueun passed 0 for exactly that and
    inverted when the semantics were fixed.
    """
    if _BUDGET is None or str(_BUDGET).strip() == "":
        return None
    try:
        v = int(_BUDGET)
    except ValueError:
        return None
    return max(0, v)


# PlayerAction 6. `LinearWorld::getRescueTransform` drops the kart at the centre of its current
# quad facing down the driveline, so a rescue pulse train completes a lap WITHOUT STEERING -- a
# pure warp exploit. The DSL closes this by omission (tools/ghosts/trajectory.py:47 documents it,
# and decompile_from_history refuses code 6), so a `.traj` submission cannot express it.
#
# A RAW history.dat CAN. Patch 0020 gates only AGENT_UNWEDGE_CODE (20) on agentIsWedged(); every
# other code falls through the `else` to `kart->getController()->action(ie.m_action, ie.m_value)`,
# so a hand-edited tape carrying action 6 gets a real, ungated PA_RESCUE -- and it does NOT appear
# in unwedge_granted, which counts code 20 only. Verified against the patch, 2026-09-17.
#
# This check therefore exists for the moment the service starts accepting tapes as well as
# trajectories. It is cheap enough to run unconditionally: a submission that mentions the rescue
# code anywhere is refused before the engine ever sees it.
_RESCUE_ACTION = 6

# THE HEADER IS THE REAL REWARD-HACK SURFACE, not the input body.
#
# The body of a submission is input-only -- steer/accel/brake/nitro/drift/fire, no position
# channel, and rescue is refused above -- so a candidate cannot teleport. The HEADER, however,
# configures the race itself, and trajectory.py only range-checks it: `laps` is floored at
# _MIN_LAPS and `difficulty` is bounded, but `track` and `kart` are merely REQUIRED (no
# whitelist) and `sim_cap` has minimum=0.0 with no ceiling. So a candidate could legally ask for
# a different, shorter TRACK, a faster KART, or a much larger SIM_CAP that lets a slow line
# finish where it should have timed out -- and score brilliantly at a task nobody set.
#
# This pins the race to the one being benchmarked. Anything the agent is not entitled to choose
# is compared against the expected value and refused on mismatch, with the offending field named
# so the refusal is legible rather than mysterious.
#
# NOTE THIS IS FORMAT-INDEPENDENT. history.dat carries the same fields (track/numkarts/
# difficulty/reverse/laps/sim_cap), so switching the service to accept raw tapes would not close
# this; the check belongs here either way.
_PINNED = {
    "track":      os.environ.get("STK_PIN_TRACK",      "black_forest"),
    "kart":       os.environ.get("STK_PIN_KART",       "tux"),
    "laps":       os.environ.get("STK_PIN_LAPS",       "1"),
    "difficulty": os.environ.get("STK_PIN_DIFFICULTY", "0"),
    "reverse":    os.environ.get("STK_PIN_REVERSE",    "no"),
}
_SIM_CAP_MAX = float(os.environ.get("STK_SIM_CAP_MAX", "300"))


def _reject_header(src: str) -> str | None:
    """Refuse a submission whose header asks for a different race than the one benchmarked."""
    seen = {}
    for line in src.splitlines():
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        key, val = key.strip().lower(), val.strip()
        if key in _PINNED or key == "sim_cap" or key == "model 0":
            seen.setdefault(key, val)
    # COMPARE CANONICALLY. The two submission formats spell the same values
    # differently: the agent DSL writes `reverse: no`, while compile_to_history
    # writes `reverse: y|n` (trajectory.py) and names the kart on a `model 0:`
    # line rather than `kart:`. A literal != therefore refused a tape whose race
    # config was IDENTICAL to the pinned one -- "REFUSED: header `reverse: n`
    # -- pinned to `reverse: no`" -- which is a format complaint dressed up as a
    # cheating complaint, and it blocked the only artifact that finishes a lap.
    def _canon(key: str, val: str) -> str:
        v = val.strip().lower()
        if key == "reverse":
            return "yes" if v.startswith("y") else "no"
        return v

    for key, expected in _PINNED.items():
        got = seen.get(key)
        # A tape names the kart as `model 0: <kart>`; the DSL uses `kart:`.
        if got is None and key == "kart":
            got = seen.get("model 0")
        if got is not None and _canon(key, got) != _canon(key, expected):
            return (f"REFUSED: header `{key}: {got}` -- this benchmark is pinned to "
                    f"`{key}: {expected}`. The race configuration is not yours to choose; "
                    "optimise the driving inputs instead.")
    cap = seen.get("sim_cap")
    if cap is not None:
        try:
            if float(cap) > _SIM_CAP_MAX:
                return (f"REFUSED: sim_cap {cap} exceeds the {_SIM_CAP_MAX}s ceiling. A larger "
                        "cap lets a slow line finish where it should have timed out.")
        except ValueError:
            return f"REFUSED: sim_cap {cap!r} is not a number."
    return None


def _reject_warps(src: str) -> str | None:
    """Return a refusal reason if `src` looks like a history.dat carrying a rescue event.

    history.dat's body is one input event per line: `<world_tick> <kart_index> <action> <value>`.
    Only 4-integer lines are considered, so the DSL (which is `<time> <channel> <value>`, i.e.
    non-integer time and an alphabetic channel) is unaffected and passes straight through.
    """
    for lineno, line in enumerate(src.splitlines(), 1):
        parts = line.split()
        if len(parts) != 4:
            continue
        try:
            _tick, _kart, action, _value = (int(p) for p in parts)
        except ValueError:
            continue            # not an event line -- header, DSL, or comment
        if action == _RESCUE_ACTION:
            return (f"REFUSED: line {lineno} carries PlayerAction {_RESCUE_ACTION} (rescue). "
                    "Rescue teleports the kart to the centre of its quad facing down the "
                    "driveline, which completes a lap without steering. Use the unwedge action, "
                    "which is granted only when the kart is genuinely wedged.")
    return None


def _drive(src: str) -> dict:
    """Run one trajectory through the engine and return the result JSON verbatim."""
    if not BINARY.is_file():
        return {"error": f"no native binary at {BINARY}; build it with docker/build-native.sh"}
    warp = _reject_warps(src)
    if warp:
        return {"error": warp, "reason": "rejected_warp"}
    bad_header = _reject_header(src)
    if bad_header:
        return {"error": bad_header, "reason": "rejected_header"}
    with tempfile.TemporaryDirectory() as td:
        traj = Path(td) / "candidate.traj"
        out = Path(td) / "result.json"
        traj.write_text(src)
        # --full-assets IS REQUIRED, and is not a performance choice.
        #
        # Without it, cli.py:1171 calls build_campaign_assets_dir(), which
        # creates a symlink farm at <repo>/stk-assets-campaign -- a directory
        # INSIDE the checkout. docker-compose.stk.yml mounts that checkout
        # read-only, deliberately: the engine and the 1.5GB asset tree live
        # where the actor cannot reach them. So every candidate fails with
        #
        #     INVALID: [Errno 30] Read-only file system: 'sfx'
        #
        # 'sfx' being the first shared directory the farm tries to link. The
        # compose comment says the drive "writes its trajectory and result into
        # a tempdir, never into the checkout" -- true of those two, but the
        # asset farm is a third write nobody accounted for. Measured 2026-09-16:
        # :ro fails as above; rw scores the seed correctly.
        #
        # The farm exists to trim tracks/ from 44 entries to black_forest alone
        # so the engine scans less at startup. Skipping it costs LOAD TIME per
        # drive and nothing else -- it does not touch physics, and the seed
        # scores identically either way. That is the right trade for
        # keeping the mount read-only.
        # ROUTE A TAPE TO --tape, A DSL TO --trajectory.
        #
        # This hardcoded --trajectory, so a compiled history.dat posted to /score was
        # parsed as agent DSL and refused. That mattered once a tape became the only
        # artifact that finishes: the benchmark seed (a captured history.dat) re-drives to a
        # finished lap on this binary, while no DSL trajectory has ever completed one.
        # Without this branch the seed could be driven from the CLI and NOT through the
        # service the arm actually scores against.
        #
        # Detected by HEADER, not by filename or a flag: compile_to_history writes
        # `History-version:` and `model <n>:`, neither of which the DSL has (its header
        # is track/kart/laps/difficulty/reverse/sim_cap only). A DSL that happened to
        # contain the words would still need them as `key: value` header lines.
        # DETECT BY BODY SHAPE, NOT JUST THE HEADER.
        #
        # This looked for `History-version:` in the first 20 lines only. Measured on
        # stk-glm53: the agent wrote a CORRECT tape body and the header was either
        # absent or appended at the end, so the tape was routed to the DSL parser and
        # refused -- "line 12: expected '<time> <action> <value>', got '0 0 0 0'"
        # (a valid tape line) and "line 10111: 'History' is not a time". It then
        # retreated to hybrids that merely scored badly (38-40m) instead of erroring,
        # which is worse: a silent bad score reads as a bad driver.
        #
        # A tape body line is FOUR whitespace-separated integers-ish fields
        # (<world_tick> <kart_index> <action> <value>); a DSL body line is THREE with
        # an alphabetic channel (`0.00833 steer 0.00000`). Sampling the body is
        # therefore decisive and does not care where the header sits, or whether the
        # agent wrote one at all.
        _lines = src.splitlines()
        _hdr = any(ln.split(":", 1)[0].strip().lower() == "history-version"
                   for ln in _lines if ":" in ln)
        _four = _three = 0
        for ln in _lines:
            parts = ln.split()
            if len(parts) == 4 and parts[0].lstrip("-").isdigit() and parts[1].lstrip("-").isdigit():
                _four += 1
            elif len(parts) == 3 and parts[1][:1].isalpha():
                _three += 1
        _is_tape = _hdr or (_four > _three and _four > 10)
        cmd = ["python3", "-m", "tools.ghosts", "drive", "--full-assets",
               "--tape" if _is_tape else "--trajectory", str(traj),
               "--output", str(out), "--timeout", str(TIMEOUT)]
        try:
            p = subprocess.run(cmd, cwd=str(REPO), capture_output=True, text=True,
                               timeout=TIMEOUT + 60)
        except subprocess.TimeoutExpired:
            # Deliberately NOT scored zero: episode.py sorts a timeout below everything precisely
            # so a hung candidate cannot win, and a zero would be a number the search could climb.
            return {"error": f"drive exceeded {TIMEOUT + 60}s", "reason": "timeout"}
        if not out.is_file():
            tail = (p.stderr or p.stdout or "")[-600:]
            return {"error": f"drive produced no result (rc={p.returncode}): {tail}"}
        try:
            return json.loads(out.read_text())
        except Exception as e:
            return {"error": f"unreadable result: {e!r}"}


def _verdict(res: dict) -> dict:
    """Add the ranking fields the loop reads, without re-implementing the ranking."""
    if res.get("error"):
        return res
    finished = bool(res.get("finished"))
    reach = res.get("max_distance")
    res["REACHED"] = finished
    res["GOAL"] = res.get("total_time") if finished else None
    # The agent's steering signal when nothing finishes. Named separately from GOAL so a
    # distance can never be mistaken for a lap time by anything downstream.
    res["PROGRESS_M"] = reach
    return res


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/stats":
            # `total` is the LIFETIME count of drives actually executed and includes oracle
            # calls. It is the cheap detector for a dead loop: total==0 after turn 1 means the
            # arm is measuring nothing. Checking it would have caught the pk failure at turn 1
            # instead of turn 186.
            return self._send(200, {"count": _count, "budget": _budget(), "total": _total})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        global _count, _total
        if self.path == "/reset_turn":
            if _SECRET and self.headers.get("X-Eval-Secret") != _SECRET:
                return self._send(403, {"error": "bad secret"})
            with _lock:
                _count = 0
            return self._send(200, {"ok": True})
        if self.path != "/score":
            return self._send(404, {"error": "not found"})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        except Exception as e:
            return self._send(400, {"error": f"bad json: {e!r}"})
        src = req.get("src") or ""
        if not src.strip():
            return self._send(400, {"error": "empty trajectory"})

        privileged = bool(_SECRET) and self.headers.get("X-Eval-Secret") == _SECRET
        cap = None if privileged else _budget()
        with _lock:
            if cap == 0:
                return self._send(429, {"error": (
                    "scoring is DISABLED for the agent this turn (EVAL_BUDGET=0). The oracle "
                    "scores your trajectory between turns; write it and end the turn.")})
            if cap is not None and _count >= cap:
                return self._send(429, {"error": (
                    f"EVAL_BUDGET exceeded: {_count} drives this turn (cap={cap}). STOP "
                    "scoring and report your best VERIFIED result.")})
            if not privileged:
                _count += 1
            _total += 1
        self._send(200, _verdict(_drive(src)))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8940)
    a = ap.parse_args()
    b = _budget()
    print(f"stk eval service on :{a.port} | repo={REPO} | binary={'ok' if BINARY.is_file() else 'MISSING'}"
          f" | budget={'BANNED(0)' if b == 0 else (b if b is not None else 'uncapped')}"
          f" | secret={'set' if _SECRET else 'UNSET(open)'}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
