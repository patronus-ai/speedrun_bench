#!/usr/bin/env python3
"""Generate the SuperTux compose files (scratch + seeded) in the ORCHESTRATOR topology.

    python3 sandbox/gen_supertux_compose.py      # writes sandbox/docker-compose.supertux-{scratch,seeded}.yml

WHY A GENERATOR. The original SuperTux fleets ran the TAS loop as PID 1 INSIDE the agent container,
so the agent container had to hold EVAL_RESET_SECRET to score between turns -- and an agent that can
run shell commands can read its own environment and make unmetered, privileged scoring calls. That
made the SuperTux ban bypassable. Tuxemon and SuperTuxKart already used the fix, reproduced here:

  eval-service-stx-<cond>-<m>   owns the scorer + WASM build; holds the secret; reads candidates
                                from a READ-ONLY mount of the agent's exported dir.
  stx-<cond>-<m>                the agent. `sleep infinity`; NO secret; no scorer, no build.
  orchestrator-stx-<cond>-<m>   the only other holder of the secret. Drives each turn with
                                `docker exec` and scores the candidate BY PATH (privileged-only).

Everything else -- models, cards, provider routing, limits -- is taken from the compose files the
experiments ran with. The turn budget matches: the original loop ran STX_ITERATIONS=200 iterations;
the orchestrator runs SWEEPS=200 single-iteration turns.
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))

# Per-model agent card + provider routing, copied from the compose files the runs used.
MODELS = json.loads(r"""{
  "scratch": {
    "deepseek": {
      "agent": "supertux-tas-deepseek-v4",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "SWEEP_API_BASE": "${BASETEN_API_BASE:-https://inference.baseten.co/v1}",
        "SWEEP_API_KEY": "${BASETEN_API_KEY:?set BASETEN_API_KEY in sandbox/.env}"
      }
    },
    "dspro": {
      "agent": "supertux-tas-deepseek-pro",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "SWEEP_API_BASE": "${BASETEN_API_BASE:-https://inference.baseten.co/v1}",
        "SWEEP_API_KEY": "${BASETEN_API_KEY:?set BASETEN_API_KEY in sandbox/.env}"
      }
    },
    "gemini": {
      "agent": "supertux-tas-gemini",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "GEMINI_API_KEY": "${GEMINI_API_KEY:?set GEMINI_API_KEY in sandbox/.env}",
        "SWEEP_API_BASE": "http://host.docker.internal:8790/v1",
        "SWEEP_API_KEY": "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY in sandbox/.env}"
      }
    },
    "glm": {
      "agent": "supertux-tas-glm",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "SWEEP_API_BASE": "${BASETEN_API_BASE:-https://inference.baseten.co/v1}",
        "SWEEP_API_KEY": "${BASETEN_API_KEY:?set BASETEN_API_KEY in sandbox/.env}"
      }
    },
    "glm53": {
      "agent": "supertux-tas-glm53",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "OPENROUTER_API_KEY": "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY in sandbox/.env}",
        "SWEEP_API_BASE": "${OPENROUTER_API_BASE:-https://openrouter.ai/api/v1}",
        "SWEEP_API_KEY": "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY in sandbox/.env}"
      }
    },
    "grok": {
      "agent": "supertux-tas-grok",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "OPENROUTER_API_KEY": "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY in sandbox/.env}",
        "SWEEP_API_BASE": "${OPENROUTER_API_BASE:-https://openrouter.ai/api/v1}",
        "SWEEP_API_KEY": "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY in sandbox/.env}"
      }
    },
    "inkling": {
      "agent": "supertux-tas-inkling-small",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "BASETEN_API_KEY": "${BASETEN_API_KEY:?set BASETEN_API_KEY in sandbox/.env}",
        "SWEEP_API_BASE": "${BASETEN_API_BASE:-https://inference.baseten.co/v1}",
        "SWEEP_API_KEY": "${BASETEN_API_KEY:?set BASETEN_API_KEY in sandbox/.env}"
      }
    },
    "kimi": {
      "agent": "supertux-tas-kimi-k3",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "SWEEP_API_BASE": "${BASETEN_API_BASE:-https://inference.baseten.co/v1}",
        "SWEEP_API_KEY": "${BASETEN_API_KEY:?set BASETEN_API_KEY in sandbox/.env}"
      }
    },
    "opus": {
      "agent": "supertux-tas-opus",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "OPENROUTER_API_KEY": "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY in sandbox/.env}",
        "SWEEP_API_BASE": "${OPENROUTER_API_BASE:-https://openrouter.ai/api/v1}",
        "SWEEP_API_KEY": "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY in sandbox/.env}"
      }
    },
    "sol": {
      "agent": "supertux-tas-sol",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "OPENAI_API_KEY": "${OPENAI_API_KEY:?set OPENAI_API_KEY in sandbox/.env}",
        "SWEEP_API_BASE": "${OPENAI_API_BASE:-https://api.openai.com/v1}",
        "SWEEP_API_KEY": "${OPENAI_API_KEY:?set OPENAI_API_KEY in sandbox/.env}"
      }
    }
  },
  "seeded": {
    "deepseek": {
      "agent": "supertux-tas-deepseek-v4",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "SWEEP_API_BASE": "${BASETEN_API_BASE:-https://inference.baseten.co/v1}",
        "SWEEP_API_KEY": "${BASETEN_API_KEY:?set BASETEN_API_KEY in sandbox/.env}"
      }
    },
    "dspro": {
      "agent": "supertux-tas-deepseek-pro",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "SWEEP_API_BASE": "${BASETEN_API_BASE:-https://inference.baseten.co/v1}",
        "SWEEP_API_KEY": "${BASETEN_API_KEY:?set BASETEN_API_KEY in sandbox/.env}"
      }
    },
    "gemini": {
      "agent": "supertux-tas-gemini",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "GEMINI_API_KEY": "${GEMINI_API_KEY:?set GEMINI_API_KEY in sandbox/.env}",
        "SWEEP_API_BASE": "http://host.docker.internal:8790/v1",
        "SWEEP_API_KEY": "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY in sandbox/.env}"
      }
    },
    "glm": {
      "agent": "supertux-tas-glm",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "SWEEP_API_BASE": "${BASETEN_API_BASE:-https://inference.baseten.co/v1}",
        "SWEEP_API_KEY": "${BASETEN_API_KEY:?set BASETEN_API_KEY in sandbox/.env}"
      }
    },
    "grok": {
      "agent": "supertux-tas-grok",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "OPENROUTER_API_KEY": "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY in sandbox/.env}",
        "SWEEP_API_BASE": "${OPENROUTER_API_BASE:-https://openrouter.ai/api/v1}",
        "SWEEP_API_KEY": "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY in sandbox/.env}"
      }
    },
    "kimi": {
      "agent": "supertux-tas-kimi-k3",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "SWEEP_API_BASE": "${BASETEN_API_BASE:-https://inference.baseten.co/v1}",
        "SWEEP_API_KEY": "${BASETEN_API_KEY:?set BASETEN_API_KEY in sandbox/.env}"
      }
    },
    "opus": {
      "agent": "supertux-tas-opus",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "OPENROUTER_API_KEY": "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY in sandbox/.env}",
        "SWEEP_API_BASE": "${OPENROUTER_API_BASE:-https://openrouter.ai/api/v1}",
        "SWEEP_API_KEY": "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY in sandbox/.env}"
      }
    },
    "sol": {
      "agent": "supertux-tas-sol",
      "extra_hosts": [
        "host.docker.internal:172.18.0.1"
      ],
      "provider": {
        "OPENAI_API_KEY": "${OPENAI_API_KEY:?set OPENAI_API_KEY in sandbox/.env}",
        "SWEEP_API_BASE": "${OPENAI_API_BASE:-https://api.openai.com/v1}",
        "SWEEP_API_KEY": "${OPENAI_API_KEY:?set OPENAI_API_KEY in sandbox/.env}"
      }
    }
  }
}""")

ENV_COMMON = {
    "HTTP_PROXY": "http://proxy:8888", "HTTPS_PROXY": "http://proxy:8888",
    "http_proxy": "http://proxy:8888", "https_proxy": "http://proxy:8888",
    "GAME": "supertux", "BEST_PREFIX": "supertux",
    "STX_MAX_STEPS": "15000", "PLAN": "1", "REPLAN_EVERY": "5",
    "ORACLE_FEEDBACK": "1", "MEASURE_BEST": "0", "TURN_TIMEOUT": "1800",
    "NO_EMULATOR": "1", "EXPORT_DIR": "/export",
    # Candidate files live in the exported dir, the SAME host dir the eval-service mounts
    # read-only at /work/candidates, so the orchestrator can have it scored without the agent
    # ever holding a way to score.
    "CAND": "/export/candidate.json",
    "ORACLE_KEEP_CAND": "/export/candidate_for_oracle.json",
    "EVAL_BUDGET": "${EVAL_BUDGET:-0}",
}

def q(v):
    return json.dumps(v)

def env_block(d, indent):
    pad = " " * indent
    return "\n".join(f"{pad}{k}: {q(str(v))}" for k, v in d.items())

def arm(cond, m, spec):
    name = f"stx-{cond}-{m}"
    ev = f"eval-service-{name}"
    tmp = f"/tmp/{name}"
    agent_env = dict(ENV_COMMON)
    agent_env.update({
        "NO_SEED": "1" if cond == "scratch" else "0",
        "AGENT": spec["agent"],
        "LOG": f"{tmp}/loop.log", "EVAL_COUNT_FILE": f"{tmp}/eval_count",
        "KILL_FLAG": f"{tmp}/killed_last_turn", "TMPDIR": tmp,
        "XDG_DATA_HOME": f"/root/.state/{name}/data",
        # The in-loop scorer still calls the service; banned, it is refused (429) and the adapter
        # reports NOT SCORED rather than a failed run. The orchestrator does the real scoring.
        "STX_EVAL_URL": f"http://{ev}:8920",
        "NO_PROXY": f"localhost,127.0.0.1,proxy,{ev}", "no_proxy": f"localhost,127.0.0.1,proxy,{ev}",
    })
    agent_env.update(spec["provider"])
    seed_cp = ("cp /seed/seed.json results/speedrun/best/best_supertux_seed_9498f.json\n"
               if cond == "seeded" else "")
    seed_vol = ("\n      - ../seeds/supertux/welcome_seed_9498f.json:/seed/seed.json:ro"
                if cond == "seeded" else "")
    return f"""
  {ev}:
    <<: *stx_eval
    container_name: sb-{ev}
    volumes:
      - ${{STX_BUILD_DIR:?set STX_BUILD_DIR in sandbox/.env}}:${{STX_BUILD_DIR}}:ro
      - ${{STX_REPO:?set STX_REPO in sandbox/.env}}/tools:${{STX_REPO}}/tools:ro
      - ../out/exported/{name}:/work/candidates:ro

  {name}:
    <<: *stx_actor
    container_name: sb-{name}
    depends_on: [{ev}]
    volumes:
      - ../out/exported/{name}:/export{seed_vol}
    command:
      - bash
      - -lc
      - |
        set -e
        mkdir -p results/speedrun/best "$$TMPDIR" "$$XDG_DATA_HOME"
        find results/speedrun -type f -delete
        {seed_cp.strip()}
        exec sleep infinity
    environment:
{env_block(agent_env, 6)}

  orchestrator-{name}:
    <<: *stx_orch
    container_name: sb-orchestrator-{name}
    depends_on: [{ev}, {name}]
    environment:
      AGENT_CONTAINER: {q("sb-" + name)}
      EVAL_SERVICE_URL: {q(f"http://{ev}:8920")}
      EVAL_RESET_SECRET: "${{EVAL_RESET_SECRET:?set EVAL_RESET_SECRET in sandbox/.env}}"
      SWEEPS: "${{STX_SWEEPS:-200}}"
      SEED_MODE: {q("scratch" if cond == "scratch" else "continue")}
      # SuperTux has no vision channel. Unset, the orchestrator waits 300 s per turn for
      # frames that never arrive (the Tuxemon and SuperTuxKart orchestrators set this too).
      VISION_WAIT: "0"
      ORACLE_BY_PATH: "1"
      # Two namespaces, one file: the eval-service reads it at /work/candidates, the agent writes it
      # at /export. ORACLE_KEEP_CAND is set EXPLICITLY to the agent-side path -- left unset, the
      # orchestrator derives it from ORACLE_CAND_PATH and hands the agent a path that does not
      # exist in its container, so no candidate would ever reach the scorer.
      ORACLE_CAND_PATH: "/work/candidates/candidate_for_oracle.json"
      ORACLE_KEEP_CAND: "/export/candidate_for_oracle.json"
"""

HEADER = """# GENERATED by sandbox/gen_supertux_compose.py -- edit the generator, not this file.
# SuperTux {cond} fleet, orchestrator topology. See the generator's docstring for why.
# Container names carry an sb- prefix so this repo can run beside other fleets on one host.
#   docker compose -f sandbox/docker-compose.supertux-{cond}.yml up -d --build
name: speedrun-bench   # one project for every game file, so they share one agentnet
include:
  - docker-compose.base.yml

x-stx-eval: &stx_eval
  build:
    context: ..
    dockerfile: sandbox/Dockerfile
    args: {{WITH_PLAYWRIGHT: "1"}}
  command: [bash, -lc, "PYTHONPATH=/work .venv/bin/python scripts/stx_eval_service.py"]
  networks: [agentnet]
  environment:
    EVAL_BUDGET: "${{EVAL_BUDGET:-0}}"
    EVAL_RESET_SECRET: "${{EVAL_RESET_SECRET:?set EVAL_RESET_SECRET in sandbox/.env}}"
    STX_EVAL_PORT: "8920"
    STX_SCORER: "${{STX_REPO}}/tools/stx_score.py"
    STX_BUILD: "${{STX_BUILD_DIR}}"
    STX_MAX_STEPS: "15000"
    STX_CAND_ROOT: /work/candidates

x-stx-actor: &stx_actor
  build:
    context: ..
    dockerfile: sandbox/Dockerfile
    # No browser in the agent: scoring runs in the eval-service, and a browser plus any game assets
    # would let an agent build its own scorer.
    args: {{STRIP_SEEDS: "1"}}
  networks: [agentnet]
  extra_hosts: ["host.docker.internal:${{AGENTNET_GATEWAY:-172.18.0.1}}"]
  cpus: 2
  mem_limit: 8g
  restart: "no"

x-stx-orch: &stx_orch
  build:
    context: ..
    dockerfile: sandbox/Dockerfile
    args: {{WITH_DOCKER_CLI: "1"}}
  command: [bash, -lc, scripts/tas_orchestrator.sh]
  volumes: [/var/run/docker.sock:/var/run/docker.sock]
  networks: [agentnet]
  restart: "no"

services:"""

def main():
    for cond in ("scratch", "seeded"):
        body = HEADER.format(cond=cond)
        for m in sorted(MODELS[cond]):
            body += arm(cond, m, MODELS[cond][m])
        out = os.path.join(HERE, f"docker-compose.supertux-{cond}.yml")
        open(out, "w").write(body.rstrip() + "\n")
        print("wrote", os.path.relpath(out), f"({len(MODELS[cond])} models)")

if __name__ == "__main__":
    main()
