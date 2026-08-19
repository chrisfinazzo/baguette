#!/bin/bash
# Both-mode run: let the app settle under mild conditioning, then flip the
# knob file to offline mid-flight (no relaunch) and see what the app does.
UDID=FDF48F28-12D6-4772-84D5-489516D81A37
BUNDLE=app.avas.driver
DIR="$(dirname "$0")"
OUT="$DIR/log-b.txt"

echo both > /tmp/SpikeNet.mode
echo '{"latencyMs":300,"chunks":4,"chunkIntervalMs":100,"lossPercent":0,"offline":false}' > /tmp/SpikeNet.json

xcrun simctl spawn "$UDID" log stream \
    --predicate 'subsystem == "com.baguette.network"' \
    --style compact > "$OUT" 2>&1 &
STREAM=$!
sleep 2

xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" >> "$OUT" 2>&1
sleep 55
xcrun simctl io "$UDID" screenshot "$DIR/screen-online.png" > /dev/null 2>&1

echo "=== FLIPPING TO OFFLINE ===" >> "$OUT"
echo '{"latencyMs":300,"chunks":4,"chunkIntervalMs":100,"lossPercent":0,"offline":true}' > /tmp/SpikeNet.json
sleep 35
xcrun simctl io "$UDID" screenshot "$DIR/screen-offline.png" > /dev/null 2>&1

echo "=== BACK ONLINE ===" >> "$OUT"
echo '{"latencyMs":300,"chunks":4,"chunkIntervalMs":100,"lossPercent":0,"offline":false}' > /tmp/SpikeNet.json
sleep 20

kill $STREAM 2>/dev/null
wait $STREAM 2>/dev/null
echo "DONE" >> "$OUT"
