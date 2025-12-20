#!/usr/bin/env bash
set -euo pipefail

SVTESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SVTESTS_DIR/Makefile" ]]; then
  echo "sv-tests root not found at $SVTESTS_DIR (missing Makefile)" >&2
  exit 2
fi

usage() {
  cat <<'EOF'
usage: ./one.sh [make-target] [MAKEVAR=...] [-jN]

Defaults to: `report` (runs all tests + generates `OUT_DIR/report/report.csv`).

Examples:
  # Full pessimistic arcilator run (prefers `module top` for UVM tests):
  ARCILATOR_UVM_TOP_MODE=top ./one.sh report OUT_DIR=out_arcilator_pess -j"$(nproc)"

  # Restricted run:
  ./one.sh report OUT_DIR=out_small TESTS="chapter-16/16.2--assert-uvm.sv chapter-18/18.7--in-line-constraints--randomize_4.sv"

  # Keep tmp dirs (for reproducing a single failing test):
  RUNNER_KEEP_TMP=1 ./one.sh tests OUT_DIR=out_tmp TESTS="chapter-16/16.2--assert-uvm.sv" -j1
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

target="report"
if [[ $# -gt 0 && "${1:-}" != -* && "${1:-}" != *=* ]]; then
  target="$1"
  shift
fi

export ARCILATOR_ARTIFACTS="${ARCILATOR_ARTIFACTS:-onfail}"

RUNNERS="${RUNNERS:-arcilator}"

make_args=(
  -C "$SVTESTS_DIR"
  -s
  --no-print-directory
  RUNNERS="$RUNNERS"
  "$target"
)
if [[ -n "${RUNNER_PARAM-}" ]]; then
  make_args+=(RUNNER_PARAM="$RUNNER_PARAM")
fi

exec make "${make_args[@]}" "$@"
