#!/bin/bash

unclutter -idle 0.5 &

sleep 10

URL="http://localhost:80"
SCALE_FACTOR="1"

if [[ "$SCREEN" == "true" && -n "$SCREEN_SIZE" ]]; then
  URL+="?screen=$SCREEN_SIZE"
  SCALE_FACTOR="0.6"
fi

chromium-browser \
  --noerrdialogs \
  --disable-infobars \
  --incognito \
  --no-sandbox \
  --touch-events=enabled \
  --force-device-scale-factor=$SCALE_FACTOR \
  --kiosk $URL
