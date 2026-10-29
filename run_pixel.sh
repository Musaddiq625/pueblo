#!/usr/bin/env bash
# run_pixel.sh — launch Pueblo de las Velas on a Pixel (or any Android device)
# with Ollama running on this Mac.
#
# The phone's localhost is the PHONE, not the Mac — the script fixes that for
# you, either via USB tunnel (default) or over Wi-Fi/LAN.
#
# Usage:
#   ./run_pixel.sh              # USB: adb reverse tunnel, zero config (best)
#   ./run_pixel.sh --lan        # Wi-Fi: OLLAMA_BASE → Mac LAN IP
#   ./run_pixel.sh --mock       # canned client, no backend needed
#   ./run_pixel.sh --lan 10.0.0.42   # explicit Mac IP
#
set -euo pipefail
cd "$(dirname "$0")"

LLM="qwen3:4b-instruct-2507-q4_K_M"
MODE="usb"
MAC_IP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --mock) LLM="mock"; shift ;;
    --lan) MODE="lan"; shift
           [ $# -gt 0 ] && [[ "$1" != -* ]] && { MAC_IP="$1"; shift; } ;;
    --model=*) LLM="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

# pick a device: first physical device listed by adb
DEV=$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')
[ -z "$DEV" ] && { echo "ERROR: no Android device on adb (plug in the Pixel, USB-debugging on)."; exit 1; }
echo "Device: $DEV"

OLLAMA_ARGS=()
if [ "$LLM" != "mock" ]; then
  if [ "$MODE" = "usb" ]; then
    # localhost on the phone → localhost on the Mac, over USB. No LAN, no
    # firewall, no dart-define needed — the app's default base just works.
    adb -s "$DEV" reverse tcp:11434 tcp:11434
    echo "adb reverse set: phone localhost:11434 → Mac localhost:11434"
  else
    [ -z "$MAC_IP" ] && MAC_IP=$(ipconfig getifaddr en0 2>/dev/null || true)
    [ -z "$MAC_IP" ] && { echo "ERROR: can't find Mac LAN IP — pass it: ./run_pixel.sh --lan 192.168.x.x"; exit 1; }
    if ! lsof -iTCP:11434 -sTCP:LISTEN 2>/dev/null | grep -q '0\.0\.0\.0\|\*'; then
      echo "WARNING: Ollama is bound to localhost — LAN mode can't reach it."
      echo "         Restart it as: OLLAMA_HOST=0.0.0.0 ollama serve"
    fi
    OLLAMA_ARGS=(--dart-define=OLLAMA_BASE="http://$MAC_IP:11434")
    echo "OLLAMA_BASE=http://$MAC_IP:11434 (phone & Mac must share Wi-Fi)"
  fi
fi

exec fvm flutter run -d "$DEV" \
  --dart-define=LLM="$LLM" \
  --dart-define=DRIVER=true \
  "${OLLAMA_ARGS[@]}"
