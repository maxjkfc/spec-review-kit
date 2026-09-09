# review-bench

Raw data for the Pi/OMP spec-review benchmark. Nothing here is summarized; analyze later.

## Layout

- `index.jsonl` — one row per reviewer run: repo, pr, run_ts, harness (pi|omp), model, wall_s, turns, tool_calls, input/output/cacheRead/cacheWrite tokens, cost (USD, 0 = subscription/free), findings, ambiguities, label, head sha, packet_bytes.
- `<repo>/<pr>/<run_ts>/` — packet.md plus per-model `*.jsonl` (raw pi/omp event stream, every message with usage), `*.findings.json` (parsed reviewer output), `*.usage.json`.
- `<repo>/<pr>/verdicts.json` — manual verification of each finding against the PR head commit: VERIFIED / REJECTED / INCONCLUSIVE / INVALID_RUN, with the primary-source evidence used.

## Rounds (label field)

- `round1 smoke` / `round1-2 skill v1` — first contract; reviewers read the repo's current checkout (main), not PR head.
- `round2 skill v1` — same contract, PR 52/53 added, OMP full-harness baseline on PR 46 (`omp_full_*.jsonl`).
- `round3 skill-v2 tree=current-main` — SKILL.md v2 (verbatim spec_ref, encoding artifacts excluded, ambiguity test). Still read current main. repo-b PR 206 Sonnet result is INVALID_RUN for this reason.
- `round4 skill-v2 tree=pr-head` — run.sh now checks out a detached worktree at the packet's head sha. First clean round. This is where all three models found the VAPID wiring bug (PR 46) that later shipped as PR #48.

## Known caveats

- gemini-3.7-flash used on both harnesses because Pi's catalog has no 3.8.
- Sonnet input column is near zero because Anthropic reports prompt tokens under cacheRead.
- `omp_gemini-3.7-flash.jsonl` (PR 46) = OMP with `--no-skills` and the small system prompt; `omp_full_gemini-3.7-flash.jsonl` = OMP default system prompt + skills (the real "current status" baseline).
- Each cell is a single run unless multiple run_ts exist for the same PR/model; compare across run_ts for variance.
