# speedrun_bench

How to reproduce the LLM speedrun experiments on **SuperTux**, **Tuxemon** and **SuperTuxKart**.

An agent (an LLM driving the opencode CLI) is given a level and a budget of turns, writes an
input tape each turn, and is told how that tape scored. It never runs the game itself: scoring
happens in a separate container it cannot reach except through a metered HTTP endpoint, and
that endpoint refuses it outright. The metric is how fast the finished run is.

This repo holds only the experiment: the harness, the containers, the agent prompts, the seeds
and the configuration. **Each game lives in its own repo** and is pinned here by commit:

| game | repo | pinned commit | what it contains |
|---|---|---|---|
| SuperTux | [patronus-ai/supertux-speedrun](https://github.com/patronus-ai/supertux-speedrun) | `355af693` | deterministic engine fork (WASM) + scorer |
| Tuxemon | [patronus-ai/tuxemon-speedrun](https://github.com/patronus-ai/tuxemon-speedrun) | `7eec88e9` | deterministic engine fork + agent env + scorer |
| SuperTuxKart | [patronus-ai/stk-ghosts](https://github.com/patronus-ai/stk-ghosts) | `339cfeb6` | engine + determinism patches + headless build |

Full SHAs are in [`games.lock`](games.lock).

## Quick start

Requirements: Docker with Compose ≥ 2.20, `git`, [`uv`](https://docs.astral.sh/uv/), and for
SuperTux, emsdk 6.0.8. Allow roughly 15 GB of disk for the game checkouts and builds.

```bash
cp sandbox/.env.example sandbox/.env          # add your API keys and a random EVAL_RESET_SECRET
scripts/setup_games.sh                        # clone the pinned games, build them, write paths into sandbox/.env
python3 tools/gemini_schema_proxy.py &        # only if you run Gemini arms (listens on :8790)

# one fleet = one game x one condition, every model
docker compose -f sandbox/docker-compose.tuxemon-scratch.yml up -d --build

# or a single arm: its eval-service, agent and orchestrator, plus the egress proxy
docker compose -f sandbox/docker-compose.supertux-scratch.yml up -d --build \
    proxy eval-service-stx-scratch-opus stx-scratch-opus orchestrator-stx-scratch-opus
```

Fleets: `docker-compose.{supertux,tuxemon,stk}-{scratch,seeded}.yml` in `sandbox/`. The SuperTux
files are generated; edit `sandbox/gen_supertux_compose.py` instead.

**Results** are in each orchestrator's log. A verified improvement is logged as
`COPY-BACK <n>f -> best/`, and it is written only after the scorer confirmed the run reached the
goal. The tapes themselves land in `out/exported/<arm>/`. Filenames that agents write are claims,
not results. If you report a number, re-score its tape.

## How an arm works

Each model × condition is three containers on an internal network (`agentnet`) whose only route
out is an allowlisting proxy to the inference hosts:

| container | holds | does |
|---|---|---|
| `eval-service-…` | the game build + scorer, `EVAL_RESET_SECRET` | scores tapes. Unprivileged requests get `429`. |
| agent | the opencode agent, its card, `best/` | `sleep infinity`. Has **no** secret, scorer or game. |
| `orchestrator-…` | `EVAL_RESET_SECRET`, the Docker socket | runs each turn via `docker exec`, then scores the candidate |

The orchestrator scores the agent's candidate **by path**: the eval-service reads it from a
read-only mount of the agent's export directory. Path scoring is itself privileged, so an agent
cannot write a tape and ask for it by name.

A scoring ban counts as real only when both halves hold. The **means** are gone (no scorer,
build or ROM in the agent image), and the **boundary** refuses (`POST /score` from the agent returns
`429`). Check a running arm with `scripts/preflight_ban.sh`.

## Conditions and seeds

- **scratch**: `best/` starts empty.
- **seeded**: `best/` starts with one finishing tape, copied in at start-up from `seeds/`. Seeds
  are mounted at runtime and **never baked into the image**, since every arm, scratch included,
  runs from the same image.

The seeds are not human play:

| seed | what it actually is |
|---|---|
| `seeds/supertux/welcome_seed_9498f.json` | a GPT-5.6-sol online playthrough, converted to a tape |
| `seeds/tuxemon/best_tuxemon_seed_105400f.json` | the scripted `gymwalk` driver's tape (`tools/tux_seed_clipped.py`), clipped to the scoring window |
| `seeds/stk/stk_seed_ainative_168s.tape` | a capture of SuperTuxKart's built-in AI driver |

## Differences from the runs as originally executed

This repo is the **corrected** harness. The following problems existed in the original runs and are
fixed here. Results produced before these fixes were run under the older conditions.

1. **SuperTux's ban was bypassable.** The loop ran inside the agent container and needed
   `EVAL_RESET_SECRET` to score, so the agent could read the secret from its own environment and
   make unmetered calls. SuperTux now uses the same agent / eval-service / orchestrator layout as
   the other two games, and the agent holds no secret.
2. **SuperTuxKart's scratch arms could see seed facts.** The seed's time, distance and event
   counts were in the adapter's default prompt text and in comments shipped in the agent image.
   Seed facts now reach seeded agents only, through their compose environment.
3. **SuperTuxKart cards disagreed with the prompt.** Nine of ten cards still taught the retired
   trajectory DSL while the per-turn prompt asked for a tape. All ten now teach the tape format.
4. **Banned Tuxemon and SuperTux arms were told their tapes failed.** A ban refusal (`429`) was
   reported to the agent as "REJECTED", when the tape had not been run at all. It is now
   reported as *NOT SCORED this turn* (SuperTuxKart already did this).
5. **Candidate hand-off path.** The orchestrator derived the agent-side candidate path from the
   eval-service-side one, which pointed the agent at a directory that does not exist in its
   container. Each orchestrator now sets `ORACLE_KEEP_CAND` explicitly.
6. **Seeding was partly manual.** Six of ten SuperTuxKart seeded arms and every Tuxemon seeded
   arm got their seed from a separate `docker cp` step. Every seeded arm now copies its seed in
   from its own compose command.
7. **The Tuxemon seed was named "human".** The name was needed only to survive the
   orchestrator's reset. It is now named `*seed*`, which the reset also keeps.
8. **Host paths.** Every `/home/ubuntu/…` path is now a variable (`STX_REPO`, `STX_BUILD_DIR`,
   `TUX_DIR`, `STK_DIR`) written by `scripts/setup_games.sh`.
9. **Resource limits.** The original arms had no CPU or memory limits, so an agent that forked
   many search processes simply got more compute. Every agent is now capped at 2 CPUs / 8 GB.
10. **Irreproducible image step removed.** The image no longer downloads an unpinned nightly N64
    emulator core, which none of these games uses.

## Provenance of the pins

Each game commit was checked against a known result before it was pinned:

- **Tuxemon**: from a fresh clone of the pin, scoring the seed gives `engine_steps=105400`,
  `maps_reached=11`, `final_map=spyder_leather_gym.tmx`, its known result.
- **SuperTux**: the scorer in the pinned repo and the original scorer both give
  `reached_goal=True, goal_frame=9498` on the seed. The pin sits on engine commit `25821737`, the
  commit the WASM build was made from, **not** the `speedrun-benchmark` branch tip, which is 18
  commits ahead and changes game code.
- **SuperTuxKart**: the headless build leaves a content-addressed stamp for every patch it
  applies, and all 40 patches in the pin match the stamps of the build that produced the results.

## Verification of this repo

Tested on the machine that ran the original experiments, from this repo's own files:

| check | result |
|---|---|
| `scripts/setup_games.sh tuxemon`: fresh clone of the pin, Python 3.12.13 venv **inside** the checkout | seed scores `engine_steps=105400, maps_reached=11`, gym reached |
| Tuxemon seeded eval-service (`docker-compose.tuxemon-seeded.yml`), privileged path scoring | seed → `105400 / 11 maps / gym` |
| SuperTuxKart seeded eval-service (`docker-compose.stk-seeded.yml`), privileged source POST | seed → `finished=True, total_time=168.029526, max_distance=2613.500244` |
| SuperTux scratch arm (`docker-compose.supertux-scratch.yml`, 2 turns) | agent holds no secret; agent `POST /score` → `429`; path scoring without the secret → `403`; in-loop verdict reads *NOT SCORED*; orchestrator scored the agent's own tape by path with the real scorer |
| agent image built from this repo | contains no seeds, `.env`, compose files or game code, and no seed or target numbers anywhere in `scripts/` or `.opencode/` |
| every compose file | validates with `docker compose config`; no agent container holds `EVAL_RESET_SECRET`; every agent capped at 2 CPUs / 8 GB |

**Not yet verified:** building SuperTux's WASM (`tools/stx_build_wasm.sh`, emsdk 6.0.8) and
SuperTuxKart's native binary (`docker/build-native.sh`) from scratch on a clean machine. The tests
above used the existing builds, which are tied to the pinned commits by the provenance checks. A
full fleet run from this repo has not been done either; the tests cover one arm per game.

## Known limitations

- **Inkling-Small is retired on Baseten.** Calls return `Gone: the model version … has been
  deprecated`, so its arms cannot run until another deployment is configured.
- **Baseten rate-limits some models under load.** DeepSeek arms in particular lost many turns to
  `Too Many Requests` when many arms ran at once. The orchestrator's dead-arm detector aborts an
  arm after 8 consecutive provider errors. Watch for it, or run fewer Baseten arms at once.
- `AGENTNET_SUBNET` defaults to `172.18.0.0/16`. Change it in `sandbox/.env` if that range is
  already in use on your host.

## Layout

```
games.lock                       pinned game repos
scripts/setup_games.sh           fetch + build the games, write sandbox/.env paths
scripts/opencode_tas_loop.sh     one agent turn (run by the orchestrator via docker exec)
scripts/tas_orchestrator.sh      drives turns, scores candidates, banks improvements
scripts/scorers/<game>.sh        per-game adapter: prompt vocabulary + how to score
scripts/{stx,tux,stk}_eval_service.py   metered scorer services
sandbox/Dockerfile               agent / orchestrator / eval-service image
sandbox/Dockerfile.stk-eval      SuperTuxKart eval-service image
sandbox/docker-compose.*.yml     fleets; base.yml holds the proxy and networks
.opencode/agent/*.md             agent cards (the system prompt per model and game)
seeds/                           seed tapes for the seeded condition
tools/gemini_schema_proxy.py     host-side proxy for Gemini's tool-schema restrictions
```
