#!/bin/bash
# Relaunch the target app with the spike armed, collect the spike's log for a
# window, and dump it. $1 = label for the output file.
UDID=FDF48F28-12D6-4772-84D5-489516D81A37
BUNDLE=app.avas.driver
LABEL="${1:-run}"
OUT="$(dirname "$0")/log-$LABEL.txt"

xcrun simctl spawn "$UDID" log stream \
    --predicate 'subsystem == "com.baguette.network"' \
    --style compact > "$OUT" 2>&1 &
STREAM=$!
sleep 2

xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" >> "$OUT" 2>&1
sleep "${2:-30}"

kill $STREAM 2>/dev/null
wait $STREAM 2>/dev/null
echo "DONE $LABEL" >> "$OUT"
