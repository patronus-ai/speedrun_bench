#!/usr/bin/env python3
"""Tuxemon eval service: the ONLY way an agent may score a tape.

WHY A SERVICE AND NOT A SCORER IN THE AGENT CONTAINER.
This is the same lesson SuperTux paid for. Its unmetered arms shipped stx_score.py, playwright and
the game build inside the agent container and merely TOLD the agent not to run the scorer; GLM ran
it 244 times. An in-process counter cannot be enforced by the thing it is counting. Here the agent
container gets no Tuxemon and no scorer, and the only scoring path is an HTTP 429 it cannot argue
with.

Directly modelled on scripts/stx_eval_service.py -- same budget semantics, same privileged-oracle
carve-out, same one-at-a-time lock. Divergences from that file are Tuxemon-specific and noted
inline.

    POST /score      {"tape": [["UP",4],["INTERACT",1], ...]}  -> tux_score.py result dict
    POST /reset_turn  (X-Eval-Secret)                          -> zero the per-turn meter
    GET  /                                                     -> meter state

ONE SCORE AT A TIME. Tuxemon's client binds a TCP port and keeps the player on a module-global
session, so two concurrent scorers in one container collide with OSError 98 and the second silently
runs against the first one's game. The lock is not just for an exact meter here; it is correctness.
"""
import json
import os
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("TUX_EVAL_PORT", "8930"))

# EVAL_BUDGET semantics, copied deliberately from stx_eval_service so the two games mean the same
# thing by the same number:
#   negative -> unlimited
#   0        -> BANNED for the agent (the oracle still scores, via the secret)
#   n>0      -> n agent evaluations per turn
# Unset AND set-but-empty both mean BANNED: `export EVAL_BUDGET=` yields "", and treating that as
# "unlimited" would silently un-ban a metered arm.
_raw = ((os.environ.get("EVAL_BUDGET") or "").strip() or "0")
BUDGET = None if int(_raw) < 0 else int(_raw)
SECRET = os.environ.get("EVAL_RESET_SECRET", "")

# No host-path defaults. The scorer ships in the pinned tuxemon-speedrun checkout (tools/tux_score.py).
TUX_DIR = os.environ["TUX_DIR"]
SCORER = os.environ.get("TUX_SCORER", os.path.join(TUX_DIR, "tools", "tux_score.py"))
# Tuxemon runs on its OWN interpreter, not /work/.venv: the game needs pygame-ce 2.5.7 and
# pygame-menu-ce, which the videogamebench venv does not carry.
PY = os.environ.get("TUX_PY", os.path.join(TUX_DIR, ".venv312", "bin", "python"))
TARGET = os.environ.get("TUX_TARGET", "spyder_leather_gym.tmx")
MAX_STEPS = os.environ.get("TUX_MAX_STEPS", "200000")
TIMEOUT = int(os.environ.get("TUX_TIMEOUT", "1800"))
# Root the orchestrator may ask this service to read candidates from. It is the agent's exported
# dir, mounted here READ-ONLY: the agent writes candidate.json, the orchestrator names it, and the
# tape never has to travel over the wire. Requests are confined to this tree.
CAND_ROOT = os.environ.get("TUX_CAND_ROOT", "/work/candidates")


class _State:
    def __init__(self):
        self.lock = threading.Lock()
        self.count = 0        # evaluations THIS turn
        self.total = 0        # since service start


S = _State()


def _score(tape_obj):
    d = Path(tempfile.mkdtemp(prefix="tuxeval_"))
    cand, out = d / "tape.json", d / "res.json"
    cand.write_text(json.dumps(tape_obj))
    env = dict(os.environ)
    # tux_score.py refuses to run without this, and TuxemonEnv refuses to construct without it.
    # Note the near-miss TUXEMON_DETERMINISTIC_DRAW, which only forces drawing: setting that alone
    # leaves determinism OFF and identical tapes then score differently, which reads as an engine
    # bug rather than a config error. Set the real one explicitly here.
    env["TUXEMON_DETERMINISTIC"] = "1"
    cmd = [PY, SCORER, "--tape", str(cand), "--out", str(out),
           "--target", TARGET, "--max-steps", str(MAX_STEPS)]
    # SEEDED ARMS MUST SCORE UNDER THE SEED'S OWN REPLAY CONDITIONS. scripts/scorers/tuxemon.sh
    # gained these knobs, but seeded arms score through THIS service rather than that local
    # branch, so wiring them there alone would silently leave this path on the defaults -- and a
    # driver-derived seed then scores maps_reached=5 instead of clearing the gym, which reads as
    # a bad seed rather than a missing flag. Unset for the from-scratch fleet: unchanged.
    if os.environ.get("TUX_NO_AUTO_COMBAT"):
        cmd.append("--no-auto-combat")
    if os.environ.get("TUX_INTRO_ROUTE"):
        cmd += ["--intro-route", os.environ["TUX_INTRO_ROUTE"]]
    if os.environ.get("TUX_HANDOFF_STEP"):
        cmd += ["--handoff-step", os.environ["TUX_HANDOFF_STEP"]]
    # OPT-IN MAP TRAIL. Off by default so existing arms are unaffected.
    #
    # WHY IT EXISTS. A Tuxemon agent edits a 1082-entry tape with no state channel at all: the
    # verdict gives final_map/maps_reached and nothing else, so it cannot tell WHICH entries
    # correspond to which part of the route. Every arm therefore trimmed idle *inside* the seed's
    # four redundant whiteout laps, and none attempted to delete a lap -- you cannot delete a lap
    # you cannot locate. The trail is (action_index -> map) at each transition, which is precisely
    # the information needed to bound a lap. ~47 records for 1082 actions, so it is cheap.
    trail = d / "trail.json"
    if os.environ.get("TUX_MAP_TRAIL"):
        cmd += ["--trail", str(trail)]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT, env=env,
                       cwd=TUX_DIR)
    if out.exists():
        res = json.loads(out.read_text())
        if os.environ.get("TUX_MAP_TRAIL") and trail.exists():
            try:
                # Compact to [action_index, map] pairs: the agent needs the boundaries, not the
                # engine_step of every record, and the feedback string is prompt-budgeted.
                res["map_trail"] = [[e.get("action_index"), e.get("map")]
                                    for e in json.loads(trail.read_text())]
            except Exception as exc:
                res["map_trail_error"] = repr(exc)[:200]
        return res
    return {"error": "scorer produced no result",
            "stderr": (p.stderr or "")[-600:], "returncode": p.returncode}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send(200, {"ok": True, "count": S.count, "total": S.total,
                         "budget": BUDGET, "target": TARGET})

    def do_POST(self):
        if self.path == "/reset_turn":
            if not SECRET or self.headers.get("X-Eval-Secret") != SECRET:
                return self._send(403, {"error": "forbidden"})
            with S.lock:
                S.count = 0
            return self._send(200, {"ok": True})

        if self.path != "/score":
            return self._send(404, {"error": "unknown path"})

        # THE ORACLE IS PRIVILEGED, AND IT IS NOT THE AGENT.
        #
        # This is where the other two games get it wrong, in opposite directions:
        #   * SuperTux puts EVAL_RESET_SECRET in the AGENT container, because its oracle
        #     (scorers/supertux.sh) runs there. So the agent holds the key: with EVAL_BUDGET=0 its
        #     own calls are privileged, uncounted and unlimited. Live meters read count=0 total=291
        #     -- consistent with harness-only use, but the counters CANNOT distinguish agent from
        #     harness, so "scoring is disabled" is a request, not a control.
        #   * Pokemon's pk_eval_service treats 0 as FALSY, i.e. UNCAPPED. Its "EVAL_BUDGET=0" arms
        #     were never metered at all.
        #
        # Here the agent gets no secret and no scorer. The orchestrator -- which has the secret and
        # is a separate container the agent cannot exec into -- asks for a candidate BY PATH, and
        # this service reads it from its own read-only mount of the agent's exported dir. Nothing
        # the agent can reach will score a tape, so a ban is a ban.
        privileged = bool(SECRET) and self.headers.get("X-Eval-Secret") == SECRET

        try:
            n = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception as e:
            return self._send(400, {"error": f"bad json: {e!r}"})

        tape = req.get("tape")
        path = req.get("path")
        if path is not None:
            # PATH SCORING IS PRIVILEGED-ONLY. If the agent could name a path it would simply
            # write a tape and ask for it by name, which is the ban with extra steps.
            if not privileged:
                return self._send(403, {"error": "path scoring requires X-Eval-Secret"})
            p = Path(path)
            # Confine to the mounted candidate root so a stray path cannot read the filesystem.
            try:
                p.resolve().relative_to(Path(CAND_ROOT).resolve())
            except Exception:
                return self._send(400, {"error": f"path must live under {CAND_ROOT}"})
            if not p.is_file():
                return self._send(404, {"error": f"no candidate at {path}"})
            try:
                tape = json.loads(p.read_text())
            except Exception as e:
                return self._send(400, {"error": f"unreadable candidate {path}: {e!r}"})
        if tape is None:
            return self._send(400, {"error": "missing 'tape' or 'path'"})

        with S.lock:
            # Refuse at the HTTP boundary. An in-scorer counter can be bypassed by running the
            # scorer directly; a 429 cannot.
            if not privileged and BUDGET == 0:
                return self._send(429, {"error": "scoring is DISABLED for the agent this turn "
                                                 "(EVAL_BUDGET=0). The oracle scores your "
                                                 "candidate between turns; write your tape and "
                                                 "end the turn.", "count": S.count})
            if not privileged and BUDGET is not None and S.count >= BUDGET:
                return self._send(429, {"error": f"EVAL_BUDGET exceeded: {S.count} evaluations "
                                                 f"this turn (cap={BUDGET}). Keep the best "
                                                 f"VALIDATED tape you already have.",
                                        "count": S.count})
            if not privileged:
                S.count += 1
            S.total += 1
            count_now = S.count
            try:
                result = _score(tape)
            except subprocess.TimeoutExpired:
                return self._send(504, {"error": f"scorer timed out after {TIMEOUT}s",
                                        "count": count_now})
            except Exception as e:
                return self._send(500, {"error": f"scorer crashed: {e!r}", "count": count_now})

        return self._send(200, {"result": result, "count": count_now})


def main():
    print(f"tux eval service on :{PORT} budget={BUDGET} target={TARGET} scorer={SCORER}",
          flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
