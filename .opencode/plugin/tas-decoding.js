// Pin sampling parameters for every offline TAS arm, from ONE place.
//
// The values come from scripts/tas_decoding.sh, which the loop sources and exports before it
// launches opencode; this plugin only puts them on the wire. Reading them from the environment
// (rather than hard-coding them here) is what makes the shell file the single source of truth
// and lets run_meta.txt record exactly what a run used.
//
// INERT BY DEFAULT. If TAS_TEMPERATURE / TAS_TOP_P / TAS_SEED are not in the environment this
// hook changes nothing, so an interactive `opencode` outside the loop behaves as it always did.
//
// WHY A PLUGIN AND NOT AGENT FRONT-MATTER. Front-matter is per-agent: 58 files that drift, and
// six of which had no temperature at all. `chat.params` is applied to every request of every
// agent, so one file cannot be missed.
export const TasDecoding = async () => {
  const num = (v) => {
    if (v === undefined || v === null || v === "") return undefined;
    const n = Number(v);
    return Number.isFinite(n) ? n : undefined;
  };
  const temperature = num(process.env.TAS_TEMPERATURE);
  const topP = num(process.env.TAS_TOP_P);
  const seed = num(process.env.TAS_SEED);
  return {
    "chat.params": async (_input, output) => {
      if (temperature !== undefined) output.temperature = temperature;
      if (topP !== undefined) output.topP = topP;
      // `options` is passed through to the provider as extra request body. seed is
      // OpenAI-standard, so it survives; anything non-standard would not (see the note in
      // scripts/tas_decoding.sh) and is deliberately not set here.
      if (seed !== undefined) {
        output.options = { ...(output.options || {}), seed };
      }
    },
  };
};
