#!/usr/bin/env bash
# bench.sh — archive a .review/<pr> directory into the central benchmark store and index it.
#
# Usage (inside the repo under review):
#   bench.sh save .review/pr46 [--label NOTE]
#   bench.sh index                       # print the index
#
# Store layout: $REVIEW_BENCH (default ~/.review-bench)
#   <repo>/<pr>/<run_ts>/{packet.md, <model>.jsonl, <model>.findings.json, <model>.usage.json, omp_*.jsonl}
#   <repo>/<pr>/verdicts.json           # manual verification, maintained by hand / append
#   index.jsonl                         # one row per (run_ts, model)
#
# Runs are moved, not copied: after save the .review/<pr> dir holds only packet.md, so the next
# run of the same PR starts clean and is archived under a new run_ts.

set -euo pipefail
store="${REVIEW_BENCH:-$HOME/.review-bench}"

cmd="${1:-}"; shift || true
case "$cmd" in
  save)
    src="${1:-}"; shift || true
    [ -d "$src" ] || { echo "usage: bench.sh save .review/<pr> [--label NOTE]" >&2; exit 2; }
    label=""
    [ "${1:-}" = "--label" ] && label="${2:-}"
    repo=$(basename "$(git rev-parse --show-toplevel)")
    pr=$(basename "$src")
    ts=$(date +%Y%m%dT%H%M%S)
    dest="$store/$repo/$pr/$ts"
    mkdir -p "$dest"
    cp "$src/packet.md" "$dest/"
    packet_bytes=$(wc -c < "$src/packet.md" | tr -d ' ')
    head_sha=$(sed -n 's/^repo: .* head: \([0-9a-f]*\)$/\1/p' "$src/packet.md" | head -1)
    n=0
    for u in "$src"/*.usage.json; do
      [ -f "$u" ] || continue
      slug=$(basename "$u" .usage.json)
      f="$src/$slug.findings.json"
      nf=$(jq '.findings|length' "$f" 2>/dev/null || echo -1)
      na=$(jq '.ambiguities|length' "$f" 2>/dev/null || echo -1)
      jq -c --arg repo "$repo" --arg pr "$pr" --arg ts "$ts" --arg label "$label" --arg head "$head_sha" \
         --argjson pb "$packet_bytes" --argjson nf "$nf" --argjson na "$na" \
         '. + {repo:$repo, pr:$pr, run_ts:$ts, harness:"pi", label:$label, head:$head, packet_bytes:$pb, findings:$nf, ambiguities:$na}' \
         "$u" >> "$store/index.jsonl"
      mv "$src/$slug".* "$dest/"
      n=$((n+1))
    done
    # OMP harness runs: omp*_<model>.jsonl written by hand; index them from the event stream.
    for o in "$src"/omp*.jsonl; do
      [ -f "$o" ] || continue
      slug=$(basename "$o" .jsonl)
      jq -c -n --arg repo "$repo" --arg pr "$pr" --arg ts "$ts" --arg label "$label" --arg head "$head_sha" --arg slug "$slug" --argjson pb "$packet_bytes" '
        [inputs] as $ev
        | ($ev|map(select(.type=="message_end" and .message.role=="assistant"))) as $a
        | ($a|last|.message.content|map(select(.type=="text"))|map(.text)|join("")|sub("^```json";"")|sub("```$";"")) as $txt
        | ($txt | try fromjson catch null) as $j
        | {repo:$repo, pr:$pr, run_ts:$ts, harness:"omp", label:$label, head:$head, packet_bytes:$pb,
           model:($a[0].message.model // $slug), slug:$slug,
           turns:($a|length), tool_calls:($ev|map(select(.type=="tool_execution_start"))|length),
           input:($a|map(.message.usage.input)|add), output:($a|map(.message.usage.output)|add),
           cacheRead:($a|map(.message.usage.cacheRead)|add), cacheWrite:($a|map(.message.usage.cacheWrite)|add),
           findings:(if $j then ($j.findings|length) else -1 end), ambiguities:(if $j then ($j.ambiguities|length) else -1 end)}' \
        "$o" >> "$store/index.jsonl"
      mv "$o" "$dest/"
      n=$((n+1))
    done
    rm -f "$src"/*.stderr "$src"/*.log
    [ -d "$src/worktree" ] && git worktree remove --force "$src/worktree" >/dev/null 2>&1
    rm -rf "$src/.session.lock"
    git worktree prune
    echo "saved $n runs -> $dest"
    ;;
  drop)
    # End a review session without archiving: remove the worktree, keep findings in place.
    src="${1:-}"; [ -d "$src" ] || { echo "usage: bench.sh drop .review/<pr>" >&2; exit 2; }
    [ -d "$src/worktree" ] && git worktree remove --force "$src/worktree" >/dev/null 2>&1
    rm -rf "$src/.session.lock"
    git worktree prune
    echo "dropped worktree for $src"
    ;;
  index)
    jq -r '[.repo,.pr,.run_ts,.harness,.model,(.wall_s//"-"),.turns,.tool_calls,.input,.cacheRead,.output,(.cost//0|tostring|.[0:6]),.findings,.ambiguities,.label]|@tsv' "$store/index.jsonl" \
      | { printf 'repo\tpr\trun\tharness\tmodel\twall\tturns\ttools\tinput\tcacheRead\toutput\tcost\tfind\tamb\tlabel\n'; cat; } | column -t -s $'\t'
    ;;
  *) echo "usage: bench.sh {save|drop|index} ..." >&2; exit 2;;
esac
