#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" != "--memory-operations" ]]; then
  print -u2 "Old100k legacy events are not current Mio operation-history acceptance. Use --memory-operations with a fresh output directory."
  exit 2
fi
swift build -c release --product MioBench
benchmark_output="${2:-/tmp/mio-memory-operations-$(date +%Y%m%d-%H%M%S)}"
.build/release/MioBench trace-bench --output "$benchmark_output" --rounds 500
