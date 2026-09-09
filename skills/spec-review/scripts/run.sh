#!/usr/bin/env bash
# run.sh — run one Pi reviewer over a Review Packet and extract findings + usage.
#
# Usage (run inside the repo under review):
#   run.sh PACKET.md --model PROVIDER/MODEL [--thinking LEVEL] [--skill NAME]...
#
# Writes next to the packet:
#   <slug>.jsonl         raw pi json events
#   <slug>.findings.json final assistant JSON (parsed) or raw text on parse failure
#   <slug>.usage.json    {model, wall_s, turns, tool_calls, input, output, cacheRead, cacheWrite, cost}
# slug = model id with '/' -> '_'.

set -euo pipefail

packet="${1:-}"; [ -f "$packet" ] || { echo "usage: run.sh PACKET.md --model PROVIDER/MODEL [--thinking L] [--skill NAME]..." >&2; exit 2; }
shift
model=""; thinking="medium"; skills=(spec-review)
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="$2"; shift 2;;
    --thinking) thinking="$2"; shift 2;;
    --skill) skills+=("$2"); shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -z "$model" ] && { echo "--model required" >&2; exit 2; }

skill_root="$HOME/.pi/agent/skills"
agy="$HOME/.pi/agent/npm/node_modules/pi-agy"
claude_auth="$HOME/.pi/agent/npm/node_modules/pi-claude-auth"

ext_args=()
case "$model" in
  antigravity/*) ext_args=(-e "$agy");;
  anthropic/*)   ext_args=(-e "$claude_auth");;
esac
skill_args=()
for s in "${skills[@]}"; do skill_args+=(--skill "$skill_root/$s"); done

dir=$(cd "$(dirname "$packet")" && pwd)
packet="$dir/$(basename "$packet")"
slug=${model//\//_}
raw="$dir/$slug.jsonl"

# Reviewers read the session worktree created by packet.sh (pinned to the packet head), so
# what read/grep see matches the diff regardless of the repo's current checkout or edits.
head=$(sed -n 's/^repo: .* head: \([0-9a-f]*\)$/\1/p' "$packet" | head -1)
workdir="$dir/worktree"
[ -d "$workdir" ] || { echo "no session worktree at $workdir; run packet.sh first" >&2; exit 1; }
wt_head=$(git -C "$workdir" rev-parse HEAD)
[ "$wt_head" = "$head" ] || { echo "worktree HEAD $wt_head != packet head $head; rerun packet.sh" >&2; exit 1; }

start=$(date +%s)
status=0
# spec-review contract is inlined into the system prompt (saves a read-SKILL.md turn);
# extra --skill names are still loaded as discoverable skills.
(cd "$workdir" && pi --no-extensions ${ext_args[@]+"${ext_args[@]}"} \
   --no-skills "${skill_args[@]}" \
   --no-context-files --no-session \
   --tools read,grep,find,ls \
   --model "$model" --thinking "$thinking" \
   --system-prompt "$(cat "$skill_root/spec-review/system.md"; echo; awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{f=0;next} !f' "$skill_root/spec-review/SKILL.md")" \
   -p --mode json "@$packet" \
   "Review the attached packet under the spec-review contract. Reply with the JSON object only." \
   > "$raw" 2> "$dir/$slug.stderr" < /dev/null) || status=$?
end=$(date +%s)

jq -c '
  [inputs] as $ev
  | ($ev | map(select(.type=="message_end" and .message.role=="assistant"))) as $asst
  | ($ev | map(select(.type=="message_end" and .message.role=="toolResult"))) as $tools
  | {
      turns: ($asst|length),
      tool_calls: ($tools|length),
      input: ($asst|map(.message.usage.input)|add // 0),
      output: ($asst|map(.message.usage.output)|add // 0),
      cacheRead: ($asst|map(.message.usage.cacheRead)|add // 0),
      cacheWrite: ($asst|map(.message.usage.cacheWrite)|add // 0),
      cost: ($asst|map(.message.usage.cost.total)|add // 0),
      final_text: ($asst|last|.message.content|map(select(.type=="text"))|map(.text)|join(""))
    }' -n "$raw" > "$dir/$slug.summary.json"

jq --arg m "$model" --argjson w $((end-start)) --argjson s "$status" \
   '{model:$m, wall_s:$w, exit:$s, turns, tool_calls, input, output, cacheRead, cacheWrite, cost}' \
   "$dir/$slug.summary.json" > "$dir/$slug.usage.json"

final=$(jq -r '.final_text' "$dir/$slug.summary.json")
# strip an accidental ```json fence
final=$(printf '%s' "$final" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')
if printf '%s' "$final" | jq . > "$dir/$slug.findings.json" 2>/dev/null; then
  :
else
  printf '%s' "$final" > "$dir/$slug.findings.json"
  echo "WARN: final message is not valid JSON; raw text saved" >&2
fi
rm -f "$dir/$slug.summary.json"

cat "$dir/$slug.usage.json"
echo "findings: $dir/$slug.findings.json"
exit "$status"
