#!/bin/bash

# Hide mouse after 0.5s of inactivity
unclutter -idle 0.5 &

# Wait a bit to ensure desktop is ready
sleep 10

# Launch Chromium in kiosk mode
chromium-browser \
  --noerrdialogs \
  --disable-infobars \
  --incognito \
  --no-sandbox \
  --touch-events=enabled \
  --force-device-scale-factor=0.6 \
  --kiosk http://localhost:80 \
  #--app=http://localhost:80 \
  #--window-size=320,480 \
  #--window-position=0,0 \
