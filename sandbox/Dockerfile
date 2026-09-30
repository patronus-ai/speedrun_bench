# Agent container: runs the OpenCode sml-tas loop with NO direct internet.
# Its only egress route at runtime is the proxy service (see docker-compose.yml),
# which allowlists just the vLLM host. So everything the agent needs from the
# network — the opencode CLI, the openai-compatible provider package, and the
# python deps — is installed HERE at build time (build has full internet).
FROM python:3.10-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates git unzip libsdl2-2.0-0 nodejs npm ripgrep \
      build-essential python3-dev libmgba0.10t64 \
      libgl1 libgl1-mesa-dri libglib2.0-0 libgomp1 \
      xvfb \
    && rm -rf /var/lib/apt/lists/*
# xvfb: BizHawk is a GUI app even when driven headlessly, so replay_smb_core_tas.py shells out
# through xvfb-run. Without it an RLE (smb_fm2_rle_v1) tape fails with
#   "DISPLAY is unset and xvfb-run is unavailable"
# which surfaces to the agent as a plain oracle refusal -- indistinguishable from a tape that
# does not clear. It cannot be installed after the fact: these containers sit on an egress-locked
# network, so apt-get inside a running container reaches nothing. It has to be in the image.
# build-essential + python3-dev: needed to compile nes-py (the optional NES emulator dep).
# libmgba0.10t64: native mGBA library (provides libmgba.so.0.10) that the `mgba`/`pygba`
# Python bindings load — the real Game Boy Advance backend (src/emulators/mgba/interface.py),
# for GBA-only titles (Advance Wars, Fire Emblem GBA). Distinct from PyBoy (GB/GBC).
# libgl1/mesa-dri/glib/gomp: needed just to dlopen the N64 libretro core
# (src/emulators/n64/interface.py drives parallel_n64 via ctypes). The angrylion SOFTWARE
# renderer means no GPU/Vulkan context is needed at run time — headless.
# ripgrep is REQUIRED by opencode's glob/grep/skill tools — without it those
# tools fail ("ripgrep execution failed") and skills never load.

# (The N64 libretro core fetch was removed: no game in this benchmark uses it, and it pulled an
# UNPINNED nightly build, so it made the image irreproducible.)

# OpenCode CLI (build-time network).
RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/root/.opencode/bin:${PATH}"

# Pre-install the openai-compatible provider so opencode never reaches the npm
# registry at runtime (the egress proxy only allows the vLLM host).
RUN mkdir -p /root/.config/opencode \
    && cd /root/.config/opencode \
    && npm init -y >/dev/null 2>&1 \
    && npm install @ai-sdk/openai-compatible >/dev/null 2>&1
# Global opencode config: kimi provider; baseURL/apiKey from env; instant mode on.
COPY sandbox/opencode.container.json /root/.config/opencode/opencode.json

WORKDIR /work
# The agent sometimes runs `python3` (system) instead of `.venv/bin/python` for ad-hoc
# scoring snippets; PYTHONPATH=/work (below) makes `import scripts.*` work there, but the
# result objects carry PIL screenshots, so the system python needs Pillow too — otherwise
# those snippets crash with ModuleNotFoundError: No module named 'PIL'.
RUN pip install --no-cache-dir Pillow
# Python deps into an in-image venv at /work/.venv (matches the scripts' .venv/bin/python).
COPY requirements.txt ./requirements.txt
# Install CORE deps (required — Game Boy TAS + online loop) separately from the NES extras, so a
# failure of the optional NES packages (gym-super-mario-bros / nes-py) can never break the image
# the GBA agents actually use. NES is attempted best-effort and skipped if it won't build.
RUN python -m venv /work/.venv \
    && /work/.venv/bin/pip install --no-cache-dir -U pip \
    && grep -vE '^[[:space:]]*(gym-super-mario-bros|nes-py)([[:space:]]|>|=|<|$)' requirements.txt > /tmp/req-core.txt \
    && /work/.venv/bin/pip install --no-cache-dir -r /tmp/req-core.txt \
    && (/work/.venv/bin/pip install --no-cache-dir 'gym-super-mario-bros>=7.4.0' 'nes-py>=8.2.1' \
        || echo "WARN: optional NES deps skipped (compile failed); --emulator nes unavailable")

# Optional: PLAYWRIGHT CHROMIUM, for the browser-based (non-emulator) games. wolf3d is the
# GameWorld browser port of Wolfenstein 3D: scripts/wolf3d_env.py drives it with Playwright and
# scripts/wolf3d_score.py is its ONLY evaluator (there is no libretro/PyBoy path). requirements.txt
# already installs the playwright PYTHON package above, but that ships no browser — the binary is
# a separate download, so without this step every scorer call dies with "Executable doesn't exist".
# Pinned to a fixed root-owned path instead of the per-HOME default cache, so it resolves for any
# process in the container whatever HOME is. Build-time network only.
# ARG-guarded so the emulator images (sml/mk64/nes) are not grown by ~700MB for a browser they
# never launch: build the wolf3d image with --build-arg WITH_PLAYWRIGHT=1.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ARG WITH_PLAYWRIGHT=
# RETRY THE CHROMIUM DOWNLOAD. This is a fetch from Playwright's CDN and it is the single most
# failure-prone step in the image. On 2026-09-26 all 10 EC2 instances died here with
# "Error: Download failure, code=1" -- Docker Hub had worked moments earlier, so egress existed
# and the CDN specifically refused/timed out. Because the failure is upstream of every gate in
# the launcher (ban preflight, generating check, self-terminate), the instances sat idle and
# billing for ~4 hours with no log in S3. Three attempts with backoff turns a transient CDN
# blip into a slow build instead of a dead fleet.
RUN if [ -n "$WITH_PLAYWRIGHT" ]; then \
      for i in 1 2 3; do \
        /work/.venv/bin/python -m playwright install --with-deps chromium && break; \
        echo "playwright install attempt $i failed; retrying in $((i*20))s"; sleep $((i*20)); \
      done; \
      ls -d /ms-playwright/chromium-* || { echo "FATAL: chromium not installed after 3 attempts"; exit 1; }; \
      rm -rf /var/lib/apt/lists/*; \
    fi

# TUXEMON RUNTIME, for the tuxemon EVAL-SERVICE image only (--build-arg WITH_TUXEMON=1).
#
# The game is bind-mounted from the host at $TUX_DIR, but a mount carries FILES,
# not an interpreter: that tree's .venv312/bin/python is a symlink to python3.12, which does not
# exist in this image. Exec'ing it fails with a bare
#     FileNotFoundError(2, 'No such file or directory')
# which reads like a missing SCRIPT rather than a missing interpreter -- it cost a full debugging
# pass. Install the deps into the image's own 3.10 venv and point TUX_PY at that instead.
#
# ARG-guarded so the emulator and browser images are not grown by packages they never import.
# THE LIST IS tuxemon-src/requirements.txt, NOT A HAND-PICKED SUBSET. Picking what looked
# necessary (pygame_menu, pyscroll, pytmx, natsort, cbor, babel, prompt_toolkit) got through the
# import of pygame_menu and then died on `websockets`, which tuxemon/network/websocket_client.py
# imports at module load. Each omission costs a full rebuild to discover, so install the whole
# file. pygame-ce arrives regardless as a pygame-menu-ce dependency (2.5.8), which is fine --
# it is a drop-in for the mainline pygame already in this venv.
ARG WITH_TUXEMON=
RUN if [ -n "$WITH_TUXEMON" ]; then \
      /work/.venv/bin/pip install --no-cache-dir \
        babel cbor websockets pillow packaging 'pyscroll>=2.31' pytmx==3.32 requests \
        natsort 'PyYAML>=6.0.2' prompt_toolkit pygame-menu-ce==4.5.2 'pydantic>=2.10.6' \
      && /work/.venv/bin/python -c "import pygame_menu, pyscroll, pytmx; print('tuxemon deps OK')"; \
    fi

# Project files (the repo-root .dockerignore keeps the host .venv / media / git out).
COPY . /work

# Optional HARDENED build (offline eval-service hardening). When --build-arg HARDENED=1,
# WHY pokemon_calib_env.py IS STRIPPED HERE AND NOT VIA .dockerignore: the EVAL-SERVICE needs it
# (pokemon_offline/pk_tape.py, pk_route.py and render_tape.py all import PRESS/REL/TILEMAP/
# DEFAULT_ROM from it), so excluding it from the build context would break scoring. Only the
# HARDENED actor image can lose it -- and the actor never uses it: the agent view has zero
# references and the import would fail anyway once PyBoy is gone.
#
# It is a MEASURED-FACTS SHEET for exactly what the task asks agents to discover: "16-17 frames per
# tile", "a press must be held >= 2 frames or it is dropped", "the move completes ~13 frames after
# release", "8 frames is plenty" for a text box, plus the text-box corner tiles. In program mode
# that shortens discovery; in TAPE mode it is close to the whole task, because a tape must hardcode
# frame counts where a route could just poll textbox().
#
# It was readable by every arm of every prior run, and usage was UNEVEN -- DeepSeek cited its
# tilemap in 29 files, gpt-sol never opened it -- so "who grepped the repo" was a hidden variable
# in the model comparison. Removing it makes the discovery requirement uniform. Note this DOES
# make future actor images differ from the pkblueun/pknostate runs, which had it; that difference
# belongs in the writeup rather than being silently carried forward.
#
# THE SHEET IS NOT THE ONLY COPY. Deleting pokemon_calib_env.py alone left the headline fact
# ("Walking is 17 frames per tile with a direction held") in pokemon_sol_run.py:70 and
# pokemon_online_calib.py:38, which paste it into an ONLINE agent prompt. So the whole
# calibration/online family goes: sol_run, online_calib, sol_replay, calib_measure. All four are
# host-side tooling for the online + replay paths; the eval-service imports NONE of them (it
# reaches calib_env only through pokemon_offline/pk_route.py and pk_tape.py, and that copy stays).
# Re-grep after touching this list:
#   docker exec <actor> grep -rl "frames per tile\|8 frames is plenty" /work --exclude-dir=.venv
#
# strip PyBoy + the ROMs so the agent has NO way to score locally: `from pyboy import ...`
# fails (scripts/speedrun.py guards the import) and there is no ROM to load. The only scoring
# path is then the metered eval-service via EVAL_SERVICE_URL, which makes the per-turn replay
# budget UN-bypassable (the `fast_eval` trick has nothing to import). Unset => normal image,
# fully backward compatible.
#
# /work/cores GOES TOO, and that is not belt-and-braces. Game Boy emulation dies with PyBoy, but
# N64 does not: the libretro core is a plain .so loaded through ctypes, so an MK64 actor keeping
# cores/ could still drive the emulator even with pyboy uninstalled. An audit of the mk64c fleet
# found the actor holding mario_kart_64.z64, parallel_n64_libretro.so and an importable
# N64Interface while its prompt read "you may NOT run the emulator" -- the ban was a request.
# The EVAL-SERVICE needs both roms/ and cores/, so it must be built from the UNHARDENED image;
# hardening is for the actor only. Build them as separate tags, never share one.
ARG HARDENED=
RUN if [ -n "$HARDENED" ]; then \
      /work/.venv/bin/pip uninstall -y pyboy gym-super-mario-bros nes-py >/dev/null 2>&1 || true; \
      rm -rf /work/roms /work/cores; \
      rm -f /work/scripts/smb_nespy_score.py /work/scripts/smb_tas_score.py; \
      : "SMB scorers go too. Uninstalling nes-py already stops them RUNNING, but leaving the \
files behind means preflight_ban.sh reports a local scorer and an auditor cannot tell an \
enforced ban from a lucky one. 'Means removed' should be literally true."; \
      rm -f /work/scripts/pokemon_calib_env.py /work/scripts/pokemon_calib_measure.py \
            /work/scripts/pokemon_sol_run.py /work/scripts/pokemon_online_calib.py \
            /work/scripts/pokemon_sol_replay.py; \
      echo "HARDENED image: PyBoy + ROMs + libretro cores + Pokemon calibration sheet removed"; \
    fi

# Optional HARDENED build for the BROWSER games (wolf3d, astray). HARDENED above strips the
# emulator+ROMs, which is the right control for the emulator games; it does nothing for these,
# because their "emulator" is Playwright Chromium driving a local HTML build and their scorer is
# a plain Python file sitting in /work/scripts.
#
# THAT IS WHY BOTH GAMES RAN UNCAPPED. Their composes set no EVAL_BUDGET and said so honestly:
# the scorer does not bump EVAL_COUNT_FILE, so a per-turn cap would be unenforceable. An
# in-process counter is not a control -- an agent invokes the scorer directly and never touches
# it (measured on SuperTux: 235 extra scorer runs after being told it may not). Mounting the
# scorer :ro does not help either: read-only prevents modification, not execution.
#
# With the scorer removed, the ONLY scoring path is the eval-service over HTTP
# (scripts/w3d_eval_service.py / scripts/astray_eval_service.py), which refuses with 429 at the
# boundary. The route GENERATORS go too: wolf3d_route.py and astray_route.py emit a finished
# route from the level geometry, which is the answer, not a scorer.
# The EVAL-SERVICE image must NOT set this -- it needs the scorer and its *_env module.
ARG HARDEN_BROWSER=
RUN if [ -n "$HARDEN_BROWSER" ]; then \
      rm -f /work/scripts/wolf3d_score.py /work/scripts/wolf3d_boss_score.py \
            /work/scripts/wolf3d_env.py /work/scripts/wolf3d_boss_env.py \
            /work/scripts/wolf3d_route.py /work/scripts/wolf3d_determinism.py \
            /work/scripts/wolf3d_boss_render.py /work/scripts/wolf3d_overlay_video.py \
            /work/scripts/astray_score.py /work/scripts/astray_env.py \
            /work/scripts/astray_route.py /work/scripts/astray_determinism.py; \
      echo "HARDEN_BROWSER: wolf3d + astray scorers, env modules and route generators removed"; \
    fi

# Optional: install the Docker CLI (client only). Used by the TRUSTED orchestrator image
# (scripts/tas_orchestrator.sh), which drives the agent container via `docker exec`. The
# untrusted agent image is NEVER built with this and never gets the Docker socket.
ARG WITH_DOCKER_CLI=
RUN if [ -n "$WITH_DOCKER_CLI" ]; then \
      curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-27.3.1.tgz \
        | tar -xz -C /usr/local/bin --strip-components=1 docker/docker \
      && docker --version; \
    fi

# Optional: bake a SEED-FREE image — remove ALL trajectory files from results/speedrun so the
# image itself contains no example/seed run. Used for the from-scratch ('hardened-scratch') agent:
# the "no human seed" guarantee then holds at the IMAGE level, not just via the runtime wipe.
# Normal/human-seed images leave the trajectories (incl. the human gold) intact.
ARG STRIP_SEEDS=
RUN if [ -n "$STRIP_SEEDS" ]; then \
      mkdir -p /work/results/speedrun; \
      find /work/results/speedrun -mindepth 1 -delete; \
      rm -f /work/PLAN.md; \
      echo "STRIP_SEEDS: wiped ALL of results/speedrun (trajectories, docs, logs, best/candidates) + PLAN.md — no SML artifacts left"; \
    fi

ENV PYTHONUNBUFFERED=1 PYTHONPATH=/work
# Default: run N sweeps via the agent loop (override SWEEPS or the command).
CMD ["bash","-lc","scripts/opencode_tas_loop.sh ${SWEEPS:-3}"]
