#!/usr/bin/env bash
# run_macos.sh — launch Pueblo de las Velas on macOS with Ollama on localhost.
#
# Usage:
#   ./run_macos.sh                # real model (default below)
#   ./run_macos.sh --mock         # canned client, no model needed
#   ./run_macos.sh --model X      # a different ollama model tag
#   ./run_macos.sh --demo         # fast night for demos
#
set -euo pipefail
cd "$(dirname "$0")"

MODEL="qwen3:4b-instruct-2507-q4_K_M"
LLM="$MODEL"
DEMO=""
DRIVER="--dart-define=DRIVER=true"

while [ $# -gt 0 ]; do
  case "$1" in
    --mock) LLM="mock"; shift ;;
    --model) LLM="$2"; shift 2 ;;
    --model=*) LLM="${1#*=}"; shift ;;
    --demo) DEMO="--dart-define=DEMO=1"; shift ;;
    --no-driver) DRIVER=""; shift ;;
    *) shift ;;
  esac
done

# Ollama up? start it if not (macOS app or cli).
if [ "$LLM" != "mock" ] && ! curl -sf -m 2 http://localhost:11434/api/tags >/dev/null; then
  echo "Ollama not responding — starting it in the background…"
  (ollama serve >/dev/null 2>&1 &) || open -a Ollama || true
  for i in $(seq 1 10); do
    curl -sf -m 2 http://localhost:11434/api/tags >/dev/null && break
    sleep 1
  done
  curl -sf -m 2 http://localhost:11434/api/tags >/dev/null \
    || { echo "ERROR: Ollama still not up — run 'ollama serve' manually."; exit 1; }
  echo "Ollama is up."
fi

exec fvm flutter run -d macos \
  --dart-define=LLM="$LLM" \
  $DRIVER $DEMO
