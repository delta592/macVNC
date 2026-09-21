#!/usr/bin/env bash
# Run clang-tidy over project sources using compile_commands.json.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build}"
DB="${BUILD}/compile_commands.json"

if [[ ! -f "${DB}" ]]; then
  echo "Missing ${DB}. Configure first (make configure)." >&2
  exit 1
fi

CLANG_TIDY=""
for c in clang-tidy /opt/homebrew/opt/llvm/bin/clang-tidy /usr/local/opt/llvm/bin/clang-tidy; do
  if command -v "$c" >/dev/null 2>&1 || [[ -x "$c" ]]; then
    CLANG_TIDY="$c"
    break
  fi
done
if [[ -z "${CLANG_TIDY}" ]]; then
  echo "clang-tidy not found. Install: brew install llvm" >&2
  exit 1
fi

SOURCES=()
while IFS= read -r -d '' f; do
  SOURCES+=("$f")
done < <(find "${ROOT}/src" -type f \( -name '*.c' -o -name '*.m' \) -print0)

if [[ ${#SOURCES[@]} -eq 0 ]]; then
  echo "No sources under src/" >&2
  exit 1
fi

echo "Using ${CLANG_TIDY}"
"${CLANG_TIDY}" -p "${BUILD}" --quiet "${SOURCES[@]}"
