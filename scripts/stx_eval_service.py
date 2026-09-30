#!/usr/bin/env python3
"""Metered HTTP scorer for SuperTux -- the eval-service the SuperTux arms never had.

WHY THIS EXISTS
---------------
SuperTux was the ONLY game whose scorer ran inside the agent's own container: 11 arm containers
and 0 eval-services, while Pokemon and SMB each have one per arm. `scripts/scorers/supertux.sh`
invoked `/home/ubuntu/stx_score.py` locally, which meant the scorer, playwright and the WASM build
all had to be mounted next to the agent. A read-only mount stops the agent MODIFYING the scorer;
it does nothing to stop it RUNNING it.

The harness told each agent every turn, "scored for you by the oracle -- you may NOT run it"
(opencode_tas_loop.sh:799). GLM acknowledged that sentence in its own log and then invoked
stx_score.py 235 more times (244 total). So the rule was unenforceable, EVAL_BUDGET=none was
honest about being unenforceable, and every arm's search was guided by however many unmetered
self-scorings it happened to run -- an unmeasured confound between arms, not a property of the
models.

This service makes the budget real the same way eval_service.py does for the emulator games: the
scorer lives HERE, in a container the agent cannot exec into, and the only path to a score is a
metered HTTP endpoint.

    POST /score       {tape: {...}}                      -> the stx_score.py result dict
    POST /reset_turn  (X-Eval-Secret: $EVAL_RESET_SECRET) -> {"ok": true}; zeroes the turn meter
    GET  /health                                          -> {"ok": true, "count": n}

Deliberately NOT reusing scripts/eval_service.py: that one dispatches to speedrun._safe_score,
which owns a PyBoy/nes-py emulator and knows nothing about the browser harness. Extending it would
also put 11 live Pokemon arms and the SMB arms at risk on the next rebuild for no benefit.
"""
import json, os, subprocess, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("STX_EVAL_PORT", "8920"))
# EVAL_BUDGET semantics, deliberately explicit because "0" is ambiguous:
#   unset / negative -> UNLIMITED
#   0                -> BANNED: the agent may not score at all this turn
#   N > 0            -> N scored evaluations per turn
# The first version treated 0 as unlimited, which is the exact opposite of what someone setting
# it to zero intends.
# Default 0 = BANNED. Fail closed: an unset budget must not silently grant
# unlimited scoring, which is the state that produced the original confound.
# Unset AND set-but-empty both mean BANNED. `export EVAL_BUDGET=` in a shell script yields "",
# and treating that as unlimited would hand out the exact opposite of the default. Only an
# explicit negative asks for unlimited.
_raw = ((os.environ.get("EVAL_BUDGET") or "").strip() or "0")
BUDGET = None if int(_raw) < 0 else int(_raw)
SECRET = os.environ.get("EVAL_RESET_SECRET", "")
# No host-path defaults: the scorer ships in the pinned supertux-speedrun checkout (tools/stx_score.py)
# and the WASM build must be mounted at the ABSOLUTE path it was compiled at (emscripten preloads
# data under that directory). An unset value fails here, loudly, instead of scoring against a path
# that only existed on the original machine.
SCORER = os.environ["STX_SCORER"]
BUILD = os.environ["STX_BUILD"]
PY = os.environ.get("STX_PY", "/work/.venv/bin/python")
LEVEL = os.environ.get("STX_LEVEL", os.path.join(BUILD, "data/levels/world1/welcome_antarctica.stl"))
# Root the orchestrator may name candidates under: the agent's exported dir, mounted READ-ONLY.
CAND_ROOT = os.environ.get("STX_CAND_ROOT", "/work/candidates")
MAX_STEPS = os.environ.get("STX_MAX_STEPS", "15000")
TIMEOUT = int(os.environ.get("STX_TIMEOUT", "900"))


class _State:
    def __init__(self):
        # Serialise scoring: one browser at a time makes the meter exact, and it also removes the
        # concurrent-run port collision that used to kill runs with EADDRINUSE on the fixed 8847.
        self.lock = threading.Lock()
        self.count = 0        # evaluations THIS turn
        self.total = 0        # since service start


S = _State()


def _score(tape_obj):
    d = Path(tempfile.mkdtemp(prefix="stxeval_"))
    cand, out = d / "cand.json", d / "res.json"
    cand.write_text(json.dumps(tape_obj))
    cmd = [PY, SCORER, str(cand), "--out", str(out), "--build", BUILD,
           "--level", LEVEL, "--max-steps", str(MAX_STEPS), "--quiet"]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)
    if out.exists():
        return json.loads(out.read_text())
    return {"error": "scorer produced no result",
            "stderr": (p.stderr or "")[-600:], "returncode": p.returncode}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send(200, {"ok": True, "count": S.count, "total": S.total, "budget": BUDGET})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._send(400, {"error": "bad JSON"})

        if self.path == "/reset_turn":
            if not SECRET or self.headers.get("X-Eval-Secret") != SECRET:
                return self._send(403, {"error": "bad or missing X-Eval-Secret"})
            with S.lock:
                S.count = 0
            return self._send(200, {"ok": True})

        if self.path != "/score":
            return self._send(404, {"error": "unknown path"})

        # PATH SCORING, PRIVILEGED ONLY. The orchestrator -- the only holder of EVAL_RESET_SECRET --
        # names the candidate the agent left in its exported dir, and this service reads it from its
        # own read-only mount. That is what lets the AGENT container carry no secret at all: before
        # this, the SuperTux loop ran inside the agent container and needed the secret to score,
        # so the agent could read it from its environment and bypass the ban. An unprivileged caller
        # may not name a path either, or it could write a tape and ask for it by name.
        if isinstance(body, dict) and body.get("path") is not None:
            if not (SECRET and self.headers.get("X-Eval-Secret") == SECRET):
                return self._send(403, {"error": "path scoring requires X-Eval-Secret"})
            cp = Path(body["path"])
            try:
                cp.resolve().relative_to(Path(CAND_ROOT).resolve())
            except Exception:
                return self._send(400, {"error": f"path must live under {CAND_ROOT}"})
            if not cp.is_file():
                return self._send(404, {"error": f"no candidate at {cp}"})
            try:
                body = {"tape": json.loads(cp.read_text())}
            except Exception as e:
                return self._send(400, {"error": f"unreadable candidate {cp}: {e!r}"})

        # THE ORACLE IS PRIVILEGED. The harness scores every candidate through this same
        # endpoint, so a hard ban (EVAL_BUDGET=0) would block the harness as well as the agent.
        # The oracle already holds EVAL_RESET_SECRET; the agent does not. Privileged calls bypass
        # the meter AND are not counted, so oracle scoring never consumes the agent's budget.
        privileged = bool(SECRET) and self.headers.get("X-Eval-Secret") == SECRET

        with S.lock:
            # Refuse at the HTTP boundary. This is the whole point: an in-scorer counter can be
            # bypassed by running the scorer directly, an HTTP 429 cannot be.
            if not privileged and BUDGET == 0:
                return self._send(429, {"error": "scoring is DISABLED for the agent this turn "
                                                 "(EVAL_BUDGET=0). The oracle scores your "
                                                 "candidate between turns; write your trajectory "
                                                 "and end the turn.", "count": S.count})
            if not privileged and BUDGET is not None and S.count >= BUDGET:
                return self._send(429, {"error": f"EVAL_BUDGET exceeded: {S.count} evaluations "
                                                 f"this turn (cap={BUDGET}). Keep the best "
                                                 f"VALIDATED trajectory you already have.",
                                        "count": S.count})
            if not privileged:
                S.count += 1
            S.total += 1
            count_now = S.count
            try:
                res = _score(body.get("tape") or body)
            except subprocess.TimeoutExpired:
                return self._send(504, {"error": f"scorer timed out after {TIMEOUT}s",
                                        "count": count_now})
            except Exception as e:
                return self._send(500, {"error": f"scorer crashed: {e!r}", "count": count_now})
        res["_eval_count"] = count_now
        return self._send(200, res)


print(f"stx eval-service on :{PORT}  "
      f"budget={'unlimited' if BUDGET is None else ('BANNED (0)' if BUDGET == 0 else BUDGET)}  "
      f"level={Path(LEVEL).name}",
      flush=True)
ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
