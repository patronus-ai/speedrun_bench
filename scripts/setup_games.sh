#!/usr/bin/env bash
# Fetch and build the three games at the EXACT commits the benchmark ran on, then write the paths
# the compose files need into sandbox/.env.
#
#   scripts/setup_games.sh                 # all three
#   scripts/setup_games.sh tuxemon stk     # a subset
#   GAMES_DIR=/data/games scripts/setup_games.sh
#
# Each game lives in its own repo; this repo only pins it. The pins are in games.lock -- change a
# pin there, not here. Every path is ABSOLUTE and is mounted into the containers at the SAME path:
# the SuperTux WASM build preloads its data under the directory it was compiled in, and the
# Tuxemon venv's interpreter is a symlink into its own tree, so neither survives being moved.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAMES_DIR="$(mkdir -p "${GAMES_DIR:-$ROOT/games}" && cd "${GAMES_DIR:-$ROOT/games}" && pwd)"
ENV_FILE="$ROOT/sandbox/.env"
WANT="${*:-supertux tuxemon stk}"

pin() { awk -v g="$1" -v f="$2" '$1==g {print $f}' "$ROOT/games.lock"; }

checkout() {                      # checkout <game-key> <dir-name>
  local url commit dir; url="$(pin "$1" 2)"; commit="$(pin "$1" 3)"; dir="$GAMES_DIR/$2"
  if [ ! -d "$dir/.git" ]; then git clone --filter=blob:none "$url" "$dir"; fi
  git -C "$dir" fetch --quiet origin "$commit" 2>/dev/null || git -C "$dir" fetch --quiet origin
  git -C "$dir" checkout --quiet "$commit"
  git -C "$dir" submodule update --init --recursive --quiet
  echo "  $1: $(git -C "$dir" rev-parse --short=9 HEAD) at $dir"
}

setenv() {                        # setenv KEY VALUE  -- upsert into sandbox/.env
  touch "$ENV_FILE"
  if grep -q "^$1=" "$ENV_FILE"; then sed -i "s#^$1=.*#$1=$2#" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi
}

for g in $WANT; do case "$g" in

supertux)
  checkout supertux supertux-speedrun
  STX_REPO="$GAMES_DIR/supertux-speedrun"
  # tools/stx_build_wasm.sh needs emsdk 6.0.8 (see DETERMINISM.md in that repo). The output
  # directory is part of the build: emscripten bakes it into the preloaded data, so build it
  # where it will be mounted.
  if [ ! -d "$STX_REPO/build-wasm/data" ]; then
    (cd "$STX_REPO" && bash tools/stx_build_wasm.sh)
  fi
  setenv STX_REPO "$STX_REPO"
  setenv STX_BUILD_DIR "$STX_REPO/build-wasm"
  ;;

tuxemon)
  checkout tuxemon tuxemon-speedrun
  TUX_DIR="$GAMES_DIR/tuxemon-speedrun"
  # Tuxemon needs Python 3.12 (the image's own interpreter is 3.10). Install it INSIDE the
  # checkout so the venv's interpreter symlink resolves within the one tree that is mounted.
  command -v uv >/dev/null || { echo "uv is required: https://docs.astral.sh/uv/" >&2; exit 1; }
  if [ ! -x "$TUX_DIR/.venv312/bin/python" ]; then
    UV_PYTHON_INSTALL_DIR="$TUX_DIR/.uv-python" uv python install 3.12.13      # the exact interpreter the runs used
    UV_PYTHON_INSTALL_DIR="$TUX_DIR/.uv-python" uv venv --python 3.12.13 "$TUX_DIR/.venv312"
    VIRTUAL_ENV="$TUX_DIR/.venv312" uv pip install -r "$TUX_DIR/requirements.txt"
  fi
  setenv TUX_DIR "$TUX_DIR"
  ;;

stk)
  checkout stk stk-ghosts
  STK_DIR="$GAMES_DIR/stk-ghosts"
  # Assets must be a sibling of stk-code; the native headless build applies patches/ at build
  # time only (docker/lib-patches.sh) and leaves content-addressed stamps in build/patch-stamps/.
  [ -d "$STK_DIR/stk-assets" ] || (cd "$STK_DIR" && bash scripts/fetch-assets.sh)
  [ -x "$STK_DIR/build/native/bin/supertuxkart" ] || (cd "$STK_DIR" && bash docker/build-native.sh)
  setenv STK_DIR "$STK_DIR"
  ;;

*) echo "unknown game: $g (expected: supertux tuxemon stk)" >&2; exit 2 ;;
esac; done

echo "wrote game paths to $ENV_FILE"
