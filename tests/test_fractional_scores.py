"""Keep saved lap times intact across the real harness scripts without running models."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash") or "/bin/bash"


# --- Fixture helpers ---
class HarnessFixture:
    """Replace container and provider boundaries while exercising production shell logic."""

    def __init__(self, directory):
        self.root = Path(directory)
        self.bin = self.root / "bin"
        self.best = self.root / "results/speedrun/best"
        self.bin.mkdir()
        self.best.mkdir(parents=True)
        (self.root / "exported").mkdir()
        (self.root / "tmp").mkdir()
        (self.root / ".venv/bin").mkdir(parents=True)
        (self.root / ".venv/bin/python").symlink_to(sys.executable)
        shutil.copytree(ROOT / "scripts", self.root / "scripts")
        # The orchestrator uses literal host scratch paths. Keep each test's files isolated.
        for script in (self.root / "scripts").glob("*.sh"):
            script.write_text(script.read_text().replace("/tmp/", f"{self.root}/tmp/"))
        self._write_stub("docker", DOCKER_STUB)
        self._write_stub("curl", CURL_STUB)
        self._write_stub("opencode", "print('STATUS: SEARCHING')\n")
        (self.bin / "bash").symlink_to(BASH)
        (self.bin / "python3").symlink_to(sys.executable)

    def _write_stub(self, name, content):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + textwrap.dedent(content))
        path.chmod(0o755)

    def seed(self, score, marker="seed"):
        path = self.best / f"seed_{score}f.json"
        path.write_text(json.dumps({"marker": marker}))

    def run(self, script, **settings):
        env = {key: os.environ[key] for key in ("HOME", "LANG") if key in os.environ}
        env.update(
            PATH=f"{self.bin}:/usr/bin:/bin",
            FIXTURE_ROOT=str(self.root),
            TMPDIR=str(self.root / "tmp"),
            SCRATCH_TMP=str(self.root / "tmp"),
            EXPORT_DIR=str(self.root / "exported"),
            RUNS_ROOT=str(self.root / "runs"),
            GAME="supertuxkart",
            RUN_ID="fractional-score-test",
            SWEEPS="1",
            SEED_MODE="continue",
            PHASE_GATE="0",
            VISION_WAIT="0",
            AGENT_CONTAINER="fixture-agent",
            EVAL_SERVICE_URL="http://fixture.invalid",
            EVAL_RESET_SECRET="fixture-value",
            ORACLE_BY_PATH="1",
            ORACLE_CAND_PATH="/work/candidates/candidate.json",
            ORACLE_KEEP_CAND="/work/exported/candidate.json",
            SWEEP_API_BASE="http://fixture.invalid",
            SWEEP_API_KEY="fixture-value",
            REQUIRE_AGENT_CARD="0",
            NO_EMULATOR="1",
            ORACLE_FEEDBACK="0",
            MEASURE_BEST="0",
            TURN_TIMEOUT="0",
            WATCHDOG="0",
            TAS_TURN_INDEX="1",
            TAS_NUM_TURNS="1",
        )
        env.update(settings)
        completed = subprocess.run(
            [BASH, str(self.root / script), "1"],
            cwd=self.root,
            env=env,
            text=True,
            capture_output=True,
            timeout=20,
        )
        if completed.returncode:
            raise AssertionError(completed.stdout + completed.stderr)
        return completed.stdout + completed.stderr

    def score_turn(self, value, reached=True):
        (self.root / "exported/candidate.json").write_text('{"marker":"candidate"}')
        (self.root / "verdict.json").write_text(
            json.dumps({"result": {"reached_goal": reached, "goal_frame": value}})
        )
        return self.run("scripts/tas_orchestrator.sh")

    def source_turn(self, value, finished=True):
        (self.root / "candidates").mkdir()
        (self.root / "candidates/candidate.py").write_text("# candidate program\n")
        (self.root / "verdict.json").write_text(json.dumps({
            "finished": finished, "total_time": value, "max_distance": 1000,
        }))
        return self.run(
            "scripts/tas_orchestrator.sh", ORACLE_SRC_POST="1",
            ORACLE_CAND_PATH="/work/candidates/candidate.py",
            ORACLE_FEEDBACK_FILE="/work/results/speedrun/oracle_feedback.txt",
            BEST_FRAME_INIT="168",
        )

    def agent_baseline(self):
        self.run("scripts/opencode_tas_loop.sh")
        metadata = next(self.root.glob("exported/**/run_meta.txt")).read_text()
        return dict(line.split("=", 1) for line in metadata.splitlines() if "=" in line)[
            "best_frame_init"
        ]

    def copied_candidates(self):
        return [path for path in self.best.glob("*.json")
                if json.loads(path.read_text()).get("marker") == "candidate"]


DOCKER_STUB = r'''
import os
from pathlib import Path
import shlex
import shutil
import sys

root = Path(os.environ["FIXTURE_ROOT"])
args = sys.argv[1:]
if not args or args.pop(0) != "exec":
    raise SystemExit("Unexpected docker operation")
while args and args[0].startswith("-"):
    option = args.pop(0)
    if option == "-e":
        args.pop(0)
if not args or args.pop(0) != "fixture-agent":
    raise SystemExit("Unexpected container")
if args == ["true"]:
    raise SystemExit(0)
def local_path(name):
    return root / name.removeprefix("/work/")

command = args[-1] if args and args[0] in ("sh", "bash") else ""
if "scripts/opencode_tas_loop.sh" == command:
    print("STATUS: SEARCHING")
elif command.startswith("ls /work/results/speedrun/best/"):
    print("\n".join(path.name for path in (root / "results/speedrun/best").iterdir()))
elif command.startswith("cp "):
    words = shlex.split(command)
    source, target = map(local_path, words[1:])
    shutil.copyfile(source, target)
elif args and args[0] == "cat":
    print(local_path(args[1]).read_text(), end="")
elif command.startswith("mkdir -p results/speedrun/best && cp -f "):
    words = shlex.split(command)
    source, target = map(local_path, words[-2:])
    shutil.copyfile(source, target)
elif command.startswith("cat > "):
    local_path(shlex.split(command)[2]).write_text(sys.stdin.read())
else:
    raise SystemExit("Unexpected docker exec: " + repr(args))
'''


CURL_STUB = r'''
import os
from pathlib import Path
import sys

args = sys.argv[1:]
url = next((arg for arg in args if arg.startswith("http://")), "")
if url.endswith("/score"):
    print((Path(os.environ["FIXTURE_ROOT"]) / "verdict.json").read_text())
elif url.endswith("/reset_turn"):
    print("200", end="")
elif url.endswith("/stats"):
    print('{"count":0}')
else:
    raise SystemExit("Unexpected curl request")
'''
# --- End fixture helpers ---


class FractionalScoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="speedrun-scores-", dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        self.harness = HarnessFixture(self.directory.name)

    def test_faster_fractional_lap_is_retained(self):
        self.harness.seed("168.03")
        self.harness.score_turn(167.73)
        self.assertEqual(len(self.harness.copied_candidates()), 1)

    def test_slower_fractional_lap_is_not_retained(self):
        self.harness.seed("176.591034")
        self.harness.score_turn(200.0)
        self.assertEqual(self.harness.copied_candidates(), [])

    def test_saved_score_preserves_the_scorers_precision(self):
        self.harness.score_turn(176.591034)
        self.assertEqual(
            [path.name for path in self.harness.copied_candidates()],
            ["agent_supertuxkart_176.591034f.json"],
        )

    def test_faster_integer_frame_count_is_retained(self):
        self.harness.seed("9498")
        self.harness.score_turn(5127)
        self.assertEqual(len(self.harness.copied_candidates()), 1)

    def test_large_integer_score_keeps_its_full_value(self):
        self.harness.score_turn(1000000)
        self.assertEqual(
            [path.name for path in self.harness.copied_candidates()],
            ["agent_supertuxkart_1000000f.json"],
        )

    def test_integral_float_keeps_integer_compatible_filename(self):
        self.harness.score_turn(5127.0)
        self.assertEqual(
            [path.name for path in self.harness.copied_candidates()],
            ["agent_supertuxkart_5127f.json"],
        )

    def test_integral_float_preserves_filename_promotion(self):
        self.harness.seed("9498")
        self.harness.score_turn(5127.0)
        output = self.harness.run("scripts/opencode_tas_loop.sh", GAME="supertux")
        self.assertIn("PROMOTED_BEST reached=True goal_frame=5127 ", output)
        self.assertEqual(
            json.loads((self.harness.best / "best.json").read_text())["marker"], "candidate"
        )

    def test_equal_score_is_not_retained(self):
        self.harness.seed("9498")
        self.harness.score_turn(9498)
        self.assertEqual(self.harness.copied_candidates(), [])

    def test_unfinished_run_is_not_retained(self):
        self.harness.seed("9498")
        self.harness.score_turn(5127, reached=False)
        self.assertEqual(self.harness.copied_candidates(), [])

    def test_boolean_is_not_a_numeric_score(self):
        self.harness.score_turn(True)
        self.assertEqual(self.harness.copied_candidates(), [])

    def test_scientific_notation_survives_copyback_and_baseline(self):
        self.harness.seed("1e-06")
        self.harness.score_turn(1e-07)
        self.assertEqual(
            [path.name for path in self.harness.copied_candidates()],
            ["agent_supertuxkart_1e-07f.json"],
        )
        self.assertEqual(self.harness.agent_baseline(), "1e-07")

    def test_agent_ranks_mixed_saved_scores_numerically(self):
        self.harness.seed("169.01")
        self.harness.seed("168.03")
        (self.harness.best / "best_pk_167.73f.py").write_text("# program\n")
        self.assertEqual(self.harness.agent_baseline(), "167.73")

    def test_agent_reads_fractional_baseline(self):
        self.harness.seed("168.03")
        self.assertEqual(self.harness.agent_baseline(), "168.03")

    def test_agent_reads_integer_baseline(self):
        self.harness.seed("9498")
        self.assertEqual(self.harness.agent_baseline(), "9498")

    def test_agent_records_fractional_filename_fallback(self):
        self.harness.seed("168.03")
        output = self.harness.run("scripts/opencode_tas_loop.sh")
        self.assertIn("measured_best=168.03", output)

    def test_source_post_preserves_finished_lap(self):
        self.harness.source_turn(167.73)
        self.assertEqual(
            (self.harness.best / "best_pk_167.73f.py").read_text(),
            "# candidate program\n",
        )

    def test_agent_reads_source_post_lap_baseline(self):
        self.harness.source_turn(167.73)
        self.assertEqual(self.harness.agent_baseline(), "167.73")

    def test_agent_records_source_post_lap_filename_fallback(self):
        self.harness.source_turn(167.73)
        output = self.harness.run("scripts/opencode_tas_loop.sh")
        self.assertIn("measured_best=167.73", output)

    def test_source_post_does_not_promote_unfinished_lap(self):
        self.harness.source_turn(167.73, finished=False)
        self.assertEqual(list(self.harness.best.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
