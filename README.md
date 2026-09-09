# spec-review-kit

Spec-driven, multi-model PR review where the reviewer models **propose** and the main agent **verifies**.

```
main agent (omp / claude / any)
  ├─ packet.sh   → Review Packet (spec + AC + diff + tests) + worktree pinned to PR head
  ├─ run.sh ×N   → Pi reviewers (GPT-5.6 Luna always; Claude Sonnet 5 for backend / spec'd PRs)
  │                each returns structured findings: spec_ref + code_ref + evidence + verification
  └─ verify      → main agent traces every finding in the pinned worktree → VERIFIED / REJECTED / INCONCLUSIVE
```

Full diagram + rationale: [`docs/flow.md`](docs/flow.md).

Reviewers may not invent requirements. A finding without `spec_ref`, `code_ref`, and `evidence` is dropped. Spec with two readings → `ambiguities`, not a finding.

## Layout

| Path | What |
|---|---|
| `skills/spec-review/` | Reviewer-side contract (`SKILL.md`), minimal system prompt, and scripts. Loaded into the Pi reviewer only. |
| `skills/spec-review/scripts/packet.sh` | Build the packet and the session worktree. |
| `skills/spec-review/scripts/run.sh` | Run one Pi reviewer over a packet; writes `<model>.findings.json` + `.usage.json`. |
| `skills/spec-review/scripts/aggregate.py` | Conservatively group cross-reviewer findings whose code ranges overlap; the main agent decides whether they are true duplicates. |
| `skills/spec-review/scripts/reviewers.conf` | Single source of truth for which models `run-spec-review` dispatches. |
| `skills/spec-review/scripts/bench.sh` | `save` (archive run to `$REVIEW_BENCH`) / `drop` (remove worktree) / `index`. |
| `docs/flow.md` | End-to-end flow diagram and the design decisions behind it. |
| `skills/run-spec-review/` | Orchestration skill for the main agent: build → dispatch → verify → report → teardown. |
| `docs/benchmark.md` | 58-run benchmark across 9 PRs (2 private repos) with the reasoning behind the model choices. |
| `data/index.jsonl` | Per-run usage/cost/findings rows from the benchmark (repos anonymized, findings and packets not included). |

## Install

Requires [`pi`](https://github.com/badlogic/pi-mono) ≥ 0.85, Python ≥ 3.9, `git`, `jq`, `gh` (optional, for `--pr`).

```bash
git clone https://github.com/maxjkfc/spec-review-kit ~/code/spec-review-kit
~/code/spec-review-kit/install.sh          # symlinks both skills into ~/.pi/agent/skills
pi auth check --provider openai-codex
pi auth check --provider anthropic
```

Any harness that reads Pi user skills (omp does with `skills.enablePiUser=true`) picks up `run-spec-review` automatically.

## Use

Inside the repo under review:

```bash
S=~/.pi/agent/skills/spec-review/scripts
set -a; source "$S/reviewers.conf"; set +a   # single source of truth for model ids
$S/packet.sh origin/main HEAD --pr 123 --out .review/pr123 [--spec docs/SPEC.md] [-- apps/api]
$S/run.sh .review/pr123/packet.md --model "$ALWAYS_MODEL" &
$S/run.sh .review/pr123/packet.md --model "$ESCALATE_MODEL" &
wait
$S/aggregate.py .review/pr123     # -> candidates.json; inspect candidate_duplicate groups before verification
jq '.findings' .review/pr123/*.findings.json
# ...verify each finding in .review/pr123/worktree...
$S/bench.sh drop .review/pr123
```

`--test-cmd` runs in the pinned worktree and records both the last 80 output lines and the exit status in the packet. A session lock prevents another packet build from replacing that worktree; `bench.sh drop/save` releases it.

To swap models, edit `skills/spec-review/scripts/reviewers.conf` (or export `REVIEW_ALWAYS_MODEL=...`/`REVIEW_ESCALATE_MODEL=...` for one run) — nothing else in this repo hardcodes a model id.

Or just tell your main agent "review PR 123" once the skill is installed; `skills/run-spec-review/SKILL.md` is the full procedure.

## Benchmark headline

From `docs/benchmark.md` (58 runs, 9 PRs, ~60 manually verified findings):

| Reviewer | precision | share of distinct verified defects | $/run | median wall |
|---|---:|---:|---:|---:|
| Claude Sonnet 5 | 1.00 | 13 / 22 | 0.19 | 84 s |
| GPT-5.6 Luna | 1.00 | 12 / 22 | 0.009 | 54 s |
| Gemini 3.7 Flash | 0.80 | 3 / 22 | 0 | 24 s |

- Luna + Sonnet together cover 86% of the union; they are complementary (Sonnet: cross-file wiring / transaction bugs; Luna: PR-body-vs-code mismatches).
- Reviewers **must** read a worktree pinned to the PR head. Reading the current checkout missed a shipped production bug in 12/12 runs; pinned, 3/3 models found it.
- The thin Pi harness saves ~40–60% on Sonnet and nothing meaningful on Luna. The bigger win was the model choice, not the harness.

## License

MIT
