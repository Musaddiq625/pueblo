#!/bin/bash
# Fire a driver command at the running game — for recording sessions.
#
# Usage:
#   ./solve.sh http://127.0.0.1:PORT/KEY=/          → seeds the ledger, launches the march
#   ./solve.sh http://127.0.0.1:PORT/KEY=/ "speed 4" → any driver command
#
# The URI is the "A Dart VM Service on macOS is available at:" line that
# flutter run prints at launch. The app must run with DRIVER=true
# (run_macos.sh sets it by default).
set -e
URI="${1:?usage: ./solve.sh <vm-service-uri> [command]}"
CMD="${2:-solve}"
URI="${URI%/}/"
ISO=$(curl -s "${URI}getVM" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['isolates'][0]['id'])")
ENC_ISO=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$ISO', safe=''))")
ENC_CMD=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$CMD', safe=''))")
curl -s "${URI}ext.pueblo.cmd?isolateId=${ENC_ISO}&cmd=${ENC_CMD}" | python3 -m json.tool
