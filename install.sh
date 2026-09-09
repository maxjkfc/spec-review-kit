#!/usr/bin/env bash
# Symlink the two skills into the Pi user skill directory.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dest="${PI_SKILLS_DIR:-$HOME/.pi/agent/skills}"
mkdir -p "$dest"
for s in spec-review run-spec-review; do
  if [ -e "$dest/$s" ] && [ ! -L "$dest/$s" ]; then
    echo "refusing to overwrite non-symlink $dest/$s" >&2; exit 1
  fi
  ln -sfn "$here/skills/$s" "$dest/$s"
  echo "linked $dest/$s -> $here/skills/$s"
done
for bin in pi git jq; do command -v "$bin" >/dev/null || echo "warning: $bin not found in PATH" >&2; done
