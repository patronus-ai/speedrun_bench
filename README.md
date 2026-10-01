# speedrun_bench

Reproduce the LLM speedrun experiments on **SuperTux**, **Tuxemon** and **SuperTuxKart**.

Each turn, an agent (an LLM driving the opencode CLI) writes an input tape for a level and is told
how that tape scored. The agent never runs the game. Scoring happens in a separate container, and
the agent's own requests to it are refused. The score is how fast the finished run is.

This repo contains the experiment only: harness, containers, agent prompts, seeds and
configuration. Each game lives in its own repo, pinned by commit in [`games.lock`](games.lock):

| game | repo |
|---|---|
| SuperTux | [patronus-ai/supertux-speedrun](https://github.com/patronus-ai/supertux-speedrun) |
| Tuxemon | [patronus-ai/tuxemon-speedrun](https://github.com/patronus-ai/tuxemon-speedrun) |
| SuperTuxKart | [patronus-ai/stk-ghosts](https://github.com/patronus-ai/stk-ghosts) |

## Requirements

- Docker with Compose ≥ 2.20
- `git` and [`uv`](https://docs.astral.sh/uv/)
- emsdk 6.0.8, to build SuperTux
- about 15 GB of disk for the game checkouts and builds

## Quick start

```bash
cp sandbox/.env.example sandbox/.env      # add API keys and a random EVAL_RESET_SECRET
scripts/setup_games.sh                    # fetch + build the pinned games; writes their paths to sandbox/.env
python3 tools/gemini_schema_proxy.py &    # only for Gemini arms (listens on :8790)

# a whole fleet: one game, one condition, every model
docker compose -f sandbox/docker-compose.tuxemon-scratch.yml up -d --build

# a single arm, plus the egress proxy
docker compose -f sandbox/docker-compose.supertux-scratch.yml up -d --build \
    proxy eval-service-stx-scratch-opus stx-scratch-opus orchestrator-stx-scratch-opus
```

To set up only some games, name them: `scripts/setup_games.sh tuxemon stk`.

## Fleets

Six compose files in `sandbox/`, one per game and condition:

```
docker-compose.supertux-scratch.yml   docker-compose.supertux-seeded.yml
docker-compose.tuxemon-scratch.yml    docker-compose.tuxemon-seeded.yml
docker-compose.stk-scratch.yml        docker-compose.stk-seeded.yml
```

Each file defines one arm per model: Claude Opus 5, GPT-5.6 Sol, Kimi-K3, GLM 5.2 / 5.3, Grok 4.6,
Gemini 3.7 Flash, DeepSeek V4 Flash / Pro and Inkling. The exact set differs by file. The
SuperTux files are generated, so edit `sandbox/gen_supertux_compose.py` and re-run it.

All files share one Compose project (`speedrun-bench`) and one internal network. Container names
start with `sb-`, so the fleets can run alongside other containers on the same host.

## How an arm works

Each arm is three containers on an internal network (`agentnet`). Their only route out is a
proxy that allows the inference hosts and nothing else.

| container | holds | role |
|---|---|---|
| eval-service | game build, scorer, `EVAL_RESET_SECRET` | scores tapes; unprivileged requests get `429` |
| agent | opencode, its agent card, `best/` | idles (`sleep infinity`); holds no secret, scorer, game or browser |
| orchestrator | `EVAL_RESET_SECRET`, Docker socket | runs each turn with `docker exec`, then scores the candidate |

The orchestrator has the candidate scored **by path**: the eval-service reads it from a read-only
mount of the agent's export directory. Path scoring also needs the secret, so an agent cannot
write a tape and then ask for it to be scored by name.

A scoring ban holds only if both of these are true:

- **The scorer is out of reach.** The agent image has no scorer, build or ROM.
- **The eval-service refuses the agent.** An unprivileged `POST /score` returns `429`.

`scripts/preflight_ban.sh` checks both on a running arm.

## Conditions and seeds

- **scratch**: `best/` starts empty.
- **seeded**: `best/` starts with one finishing tape from `seeds/`, copied in when the agent starts.

Seeds are mounted at runtime and are never built into the image. Every arm, scratch included,
runs from the same image, so a seed inside it would be readable by the scratch arms.

The seeds are not human play:

| seed | origin |
|---|---|
| `seeds/supertux/welcome_seed_9498f.json` | an LLM (GPT-5.6-sol) playthrough, converted to a tape |
| `seeds/tuxemon/best_tuxemon_seed_105400f.json` | a scripted driver's tape, clipped to the scoring window |
| `seeds/stk/stk_seed_ainative_168s.tape` | bot driver |

## Outputs

- **Orchestrator log:** each turn's verdict. A verified improvement appears as
  `COPY-BACK <n>f -> best/`, written only after the scorer confirms the run reached the goal.
- **`out/exported/<arm>/`:** the agent's tapes, plan and per-turn logs.

Filenames the agent writes are claims. Re-score a tape before reporting its number.

## Configuration

`sandbox/.env` (template: `sandbox/.env.example`):

| variable | meaning |
|---|---|
| `OPENROUTER_API_KEY`, `BASETEN_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY` | provider keys; only the ones your models use |
| `EVAL_RESET_SECRET` | shared by each orchestrator and its eval-service; agents never receive it |
| `STX_REPO`, `STX_BUILD_DIR`, `TUX_DIR`, `STK_DIR` | game paths, written by `scripts/setup_games.sh` |
| `AGENTNET_SUBNET`, `AGENTNET_GATEWAY` | agent network; change if `172.18.0.0/16` is in use on your host |

Game paths must be absolute. Each game is mounted into the containers at the same absolute path as
on the host, so builds cannot be moved after they are made. The SuperTux build embeds its build
directory, and the Tuxemon venv points into its own tree.

## Changes from the original harness

This is a corrected version of the harness the experiments first ran on:

- **SuperTux uses the same three-container arm as the other games.** Previously its agent held the
  scoring secret, which made its ban bypassable.
- **SuperTuxKart seed details reach seeded arms only.** They used to be in text shipped inside
  every agent's image, scratch arms included.
- **All SuperTuxKart agent cards describe the same tape format as the per-turn prompt.**
- **A ban refusal is reported to the agent as "NOT SCORED".** Previously it read "REJECTED", as
  if the tape had run and failed.
- **Every orchestrator sets the agent-side candidate path explicitly**, and every seeded arm copies
  in its own seed. Previously some arms needed manual steps.
- **No host-specific paths**; every agent is limited to 2 CPUs and 8 GB; and the image no longer
  downloads an unpinned nightly N64 emulator core.

## Known limitations

- Inkling-Small is no longer served by Baseten, so its arms need another deployment.
- Under heavy parallel load, some providers rate-limit requests. The orchestrator aborts an arm
  after 8 consecutive provider errors. Run fewer arms on the same provider at once if you see
  aborts.
- The from-scratch builds of the SuperTux WASM and the SuperTuxKart native binary follow each
  game repo's own build script (`tools/stx_build_wasm.sh`, `docker/build-native.sh`).

## Layout

```
games.lock                             pinned game repos
scripts/setup_games.sh                 fetch + build the games, write paths to sandbox/.env
scripts/opencode_tas_loop.sh           one agent turn (run by the orchestrator)
scripts/tas_orchestrator.sh            drives turns, scores candidates, keeps improvements
scripts/scorers/<game>.sh              per-game adapter: prompt vocabulary + how to score
scripts/{stx,tux,stk}_eval_service.py  metered scorer services
sandbox/Dockerfile                     agent / orchestrator / eval-service image
sandbox/Dockerfile.stk-eval            SuperTuxKart eval-service image
sandbox/docker-compose.*.yml           fleets; base.yml holds the proxy and networks
.opencode/agent/*.md                   agent cards (the prompt for each model and game)
seeds/                                 seed tapes for the seeded condition
tools/gemini_schema_proxy.py           host-side proxy for Gemini's tool-schema limits
```
