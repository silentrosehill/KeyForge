#!/bin/bash
# Runs every test script in this folder and says which ones failed.
set -uo pipefail
cd "$(dirname "$0")"
failed=()
# run_additions.sh already runs run_screen_color.sh
for script in run_*.sh; do
  case "$script" in run_all.sh|run_screen_color.sh) continue ;; esac
  echo "== $script"
  KEYFORGE_DRY=1 "./$script" || failed+=("$script")
done
if [ ${#failed[@]} -gt 0 ]; then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "All tests passed."
