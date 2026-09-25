#!/usr/bin/env bash
# Produce llvm-cov text + lcov reports from a coverage-enabled build.
# Prerequisites: configure with -DMACVNC_ENABLE_COVERAGE=ON and run ctest first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build}"
PROFDATA="${BUILD}/coverage.profdata"
LCOV_OUT="${BUILD}/coverage.lcov"
HTML_OUT="${BUILD}/coverage-html"

PROFRAW_LIST="$(find "${BUILD}" -name '*.profraw' 2>/dev/null || true)"
if [[ -z "${PROFRAW_LIST}" ]]; then
  echo "No .profraw files under ${BUILD}. Re-run tests with coverage enabled:" >&2
  echo "  make COVERAGE=ON coverage" >&2
  exit 1
fi

BINARIES=""
for t in test_cert_manager test_security_mode test_frame_pipeline test_macvnc_metrics test_cursor_map; do
  for candidate in "${BUILD}/${t}" "${BUILD}/tests/${t}"; do
    if [[ -x "${candidate}" ]]; then
      BINARIES="${BINARIES} ${candidate}"
      break
    fi
  done
done
if [[ -z "${BINARIES}" ]]; then
  echo "No test binaries found in ${BUILD}" >&2
  exit 1
fi
echo "Coverage objects:${BINARIES}"

if xcrun --find llvm-cov >/dev/null 2>&1; then
  LLVM_COV=(xcrun llvm-cov)
  LLVM_PROFDATA=(xcrun llvm-profdata)
else
  LLVM_COV=(llvm-cov)
  LLVM_PROFDATA=(llvm-profdata)
fi

# shellcheck disable=SC2086
"${LLVM_PROFDATA[@]}" merge -sparse ${PROFRAW_LIST} -o "${PROFDATA}"

OBJ_ARGS=()
for b in ${BINARIES}; do
  OBJ_ARGS+=(-object "$b")
done

echo "=== coverage report ==="
"${LLVM_COV[@]}" report "${OBJ_ARGS[@]}" -instr-profile="${PROFDATA}" \
  -ignore-filename-regex='(/tests/|/opt/|/Applications/)'

"${LLVM_COV[@]}" export "${OBJ_ARGS[@]}" -instr-profile="${PROFDATA}" \
  -ignore-filename-regex='(/tests/|/opt/|/Applications/)' \
  -format=lcov > "${LCOV_OUT}"
echo "Wrote ${LCOV_OUT}"

rm -rf "${HTML_OUT}"
if "${LLVM_COV[@]}" show "${OBJ_ARGS[@]}" -instr-profile="${PROFDATA}" \
    -ignore-filename-regex='(/tests/|/opt/|/Applications/)' \
    -format=html -output-dir="${HTML_OUT}" 2>/dev/null; then
  echo "Wrote HTML report to ${HTML_OUT}/index.html"
fi
