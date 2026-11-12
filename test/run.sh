#!/usr/bin/env bash
# Runs kora_qa's plain-Lua smoke tests (kora_lib's test/harness.lua + mocks.lua)
# and syntax-checks every Lua file. Needs lua5.4/luac5.4 (override with LUA/LUAC).
set -uo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$dir/.."
lua_bin="${LUA:-lua5.4}"
luac_bin="${LUAC:-luac5.4}"
status=0

echo "== syntax =="
while IFS= read -r -d '' file; do
    if ! "$luac_bin" -p "$file"; then status=1; fi
done < <(find "$root" -name '*.lua' -not -path '*/node_modules/*' -print0)
echo

for file in "$dir"/smoke/*.lua; do
    echo "== $(basename "$file" .lua) =="
    if ! (cd "$root" && "$lua_bin" "$file" | grep -v '^\[kora_qa\]'; exit "${PIPESTATUS[0]}"); then status=1; fi
    echo
done
exit "$status"
