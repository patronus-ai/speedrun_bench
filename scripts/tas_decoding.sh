#!/bin/bash
# ============================================================================================
# THE ONE PLACE THAT DEFINES SAMPLING PARAMETERS FOR EVERY OFFLINE TAS ARM.
#
# Sourced by scripts/opencode_tas_loop.sh, which exports these and records them in run_meta.txt,
# and read by .opencode/plugin/tas-decoding.js, which is what actually puts them on the wire
# (opencode's `chat.params` hook, applied to every request of every agent regardless of what
# that agent's own markdown front-matter says).
#
# WHY THIS EXISTS. Two arms compared against each other must be decoded the same way. Before
# this file:
#   * 52 of the 58 agent cards set `temperature: 0.3` in their front-matter and 6 set nothing
#     (all the mario-kart-64-tas-gpt* / -inkling and sml-tas-gpt-sol-oracle cards), so those six
#     ran at whatever the serving stack defaults to — which is 1.0 on OpenAI-compatible servers
#     and NOT 1.0 everywhere;
#   * top_p and seed were set nowhere at all, so they were the provider's default in every arm;
#   * nothing in any artifact recorded what decoding a run had used.
#
# WHAT REACHES THE ENDPOINT. opencode's hook exposes exactly temperature, topP, topK,
# maxOutputTokens and a free-form `options` bag. temperature and top_p are OpenAI-standard and
# survive every hop we use. NON-STANDARD KNOBS DO NOT: the online path (src/llm/llm_client.py)
# goes through litellm with drop_params, which SILENTLY DISCARDS top_k / min_p /
# repetition_penalty, and Baseten/vLLM only honour them when passed as extra body. So this file
# deliberately pins only parameters that are verifiably delivered. scripts/verify_decoding.sh
# checks the claim against a mock OpenAI-compatible endpoint by inspecting the actual request
# body — run it after changing anything here.
#
# CHANGING A VALUE CHANGES EVERY ARM BUILT AFTERWARDS. Do not tune it per experiment; if one arm
# needs different decoding, that is a treatment and it belongs in that arm's compose environment
# (TAS_TEMPERATURE / TAS_TOP_P / TAS_SEED override the values below), where run_meta.txt will
# record it.
# ============================================================================================

# Matches the value 52 of the 58 agent cards already carried, so pinning it centrally changes
# nothing for them and gives the six cards that set nothing the same decoding as their peers.
TAS_TEMPERATURE="${TAS_TEMPERATURE:-0.3}"

# EMPTY = do not send top_p at all, which is what every historical result was collected under
# (see "top_p and seed were set nowhere at all" above).
#
# This was briefly defaulted to 1.0, on the reasoning that 1.0 is the documented default of the
# OpenAI API / vLLM / SGLang and so pinning it is a behavioural no-op that buys reproducibility.
# That reasoning is wrong twice over:
#   * Some endpoints REFUSE the override. The Baseten Kimi-K3 deployment enforces top_p=0.95
#     server-side and 400s any client value ("Cannot override enforced sampling params"). That
#     arm burned its entire 200-turn budget on the error without submitting one candidate.
#   * Even where 1.0 is the true default, SENDING it only matches the old runs if the old
#     provider default really was 1.0 — which was never verified per model. So the change that
#     was supposed to improve comparability silently broke it.
# Sending nothing reproduces the recorded runs exactly; run_meta.txt logs `provider-default`.
#
# Set TAS_TOP_P=<float> on one arm only as a deliberate treatment, and only after checking that
# that arm's endpoint permits the override.
TAS_TOP_P="${TAS_TOP_P:-}"

# Empty = do not send a seed. Most of the endpoints these arms use (Baseten, OpenRouter) either
# ignore `seed` or honour it only per-replica, so sending one would suggest a reproducibility
# guarantee that does not exist. Set TAS_SEED=<int> on an arm whose endpoint really honours it.
TAS_SEED="${TAS_SEED:-}"

export TAS_TEMPERATURE TAS_TOP_P TAS_SEED
