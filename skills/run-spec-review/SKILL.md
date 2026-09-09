---
name: run-spec-review
description: Orchestrate a spec-driven multi-model PR review from the main agent. Use when the user asks to review a PR, branch, or diff with the packet/reviewer/verify flow ("run spec review", "review PR N with Luna/Sonnet", "跑 review"). The main agent builds the packet, dispatches Pi reviewers, then verifies every finding itself. Do NOT load `spec-review` here; that is the reviewer's contract.
---

# run-spec-review

Main agent = packet builder + verifier. Reviewers (Pi + Luna / Sonnet) = proposers. Never trust a finding until you traced it in the pinned worktree.

Evidence for this design: `docs/benchmark.md (in spec-review-kit)` (58 runs, 9 PRs). Key facts: Luna + Sonnet precision 1.00, union recall ~86%; Gemini Flash unreliable (removed); reviewers must read the PR head, not the current checkout.

## 0. Preconditions

```bash
S=~/.pi/agent/skills/spec-review/scripts
set -a; source "$S/reviewers.conf"; set +a   # -> $ALWAYS_MODEL, $ESCALATE_MODEL
pi auth check --provider "${ALWAYS_MODEL%%/*}" --json
pi auth check --provider "${ESCALATE_MODEL%%/*}" --json
```

Model ids live in one place: `spec-review/scripts/reviewers.conf`. Never hardcode a model id anywhere else in this flow — edit that file (or export `REVIEW_ALWAYS_MODEL`/`REVIEW_ESCALATE_MODEL` for a one-off run) to change models, so a swap is a one-line diff instead of a skill-prose hunt.

Run everything from the repo root of the PR. Working tree may be dirty; reviewers read the session worktree, not the checkout.

## 1. Build the packet

Merged PR (benchmark / retro review):
```bash
c=$(gh pr view N --json mergeCommit -q .mergeCommit.oid)
$S/packet.sh "$c~1" "$c" --pr N --out .review/prN [--spec FILE] [--test-cmd "go test ./..."] [-- PATHSPEC...]
```

Open PR / local branch:
```bash
$S/packet.sh origin/main HEAD --pr N --out .review/prN [--spec FILE] [-- PATHSPEC...]
```

- `--spec FILE`: a real spec/PRD if one exists (`docs/*_SPEC.md`, issue body). Without it, the PR body is the spec and every reviewer finding of category `spec` is weaker.
- `-- PATHSPEC`: restrict to the code that matters (`-- apps/api`). Lockfiles and generated bundles are always excluded.
- Output: `.review/prN/packet.md` and `.review/prN/worktree` (detached, pinned to HEAD of the range). Check `wc -c packet.md`; 20–110 KB is the tested range.
- Add `.review/` to `.git/info/exclude` once per repo.

## 2. Pick reviewers

| Condition | Reviewers |
|---|---|
| Always | `$ALWAYS_MODEL` |
| Any of: backend / service code, a real spec file, touches config, auth, persistence, payments, concurrency | + `$ESCALATE_MODEL` |
| Pure frontend / docs / tests only | `$ALWAYS_MODEL` alone |

Current defaults (`reviewers.conf`): `ALWAYS_MODEL=openai-codex/gpt-5.6-luna`, `ESCALATE_MODEL=anthropic/claude-sonnet-5`. Do not add a third model as a standing reviewer (Gemini Flash was tried and removed — see `docs/benchmark.md`). Do not run one reviewer twice as a substitute for the second model (the escalate model's runs vary; the always model's are stable).


## 3. Run reviewers in parallel

```bash
$S/run.sh .review/prN/packet.md --model "$ALWAYS_MODEL" &
[ -n "${need_escalate:-}" ] && $S/run.sh .review/prN/packet.md --model "$ESCALATE_MODEL" &
wait
```

Each writes `.review/prN/<provider>_<model>.findings.json` (+ `.usage.json`, `.jsonl`). `run.sh` refuses to start if `worktree` HEAD != packet head; rerun `packet.sh` in that case. Expect 30–150 s wall, Luna ≈ $0.01, Sonnet ≈ $0.15–0.25.

Quick dump:
```bash
for f in .review/prN/*.findings.json; do echo "== $f"; jq -r '(.findings[] | "[\(.severity)/\(.category)] \(.claim)\n   \(.code_ref) conf=\(.confidence)"), (.ambiguities[]? | "? \(.question)")' "$f"; done
```

## 4. Verify every finding yourself

For each finding, in `.review/prN/worktree` (never the checkout):

1. Open `code_ref`; confirm the lines say what `evidence` claims.
2. Follow `verification`: trace the call, grep the caller, run the named test.
3. Check `spec_ref` against the packet text.
4. Verdict:
   - **VERIFIED** — the failure path exists on the PR head and the spec/correctness claim holds.
   - **REJECTED** — code or spec contradicts the claim. Record why.
   - **INCONCLUSIVE** — spec has two readings, or you could not trace it in reasonable time. Report as a question, not a defect.
5. Dedup across reviewers before reporting; same defect from both models is one finding, mark which found it.

Heuristics from the benchmark:
- Luna `category: spec` with `confidence < 0.9` or claims containing 完整/所有/should/must without a quoted spec line → treat as ambiguity first.
- Sonnet cross-file findings (config wiring, DI, transaction boundaries) have been correct every time so far; still trace them.
- `ambiguities` are questions for the PR author, not findings.

## 5. Report

Per finding: `[Pn] Title` + Location / Problem / Rationale / Impact / Fix, found-by, verdict. Severity map: high → P1 (P0 if data loss / security / money), medium → P2, low → P3. Close with `Total: P0 x / P1 x / P2 x / P3 x` and the list of INCONCLUSIVE questions.

## 6. Teardown

```bash
$S/bench.sh drop .review/prN                                  # normal review: remove worktree, keep findings
$S/bench.sh save .review/prN --label "..."                    # benchmark: archive to $REVIEW_BENCH (default ~/.review-bench) and remove worktree
```

Record verdicts in `<bench-store>/<repo>/verdicts.json` only when archiving.

## Not in scope (V1)

Herdr orchestration, risk scoring, a third standing reviewer, Sonnet-as-arbiter. See `docs/benchmark.md` §6 for why.
