#!/bin/bash

# Hide mouse after 0.5s of inactivity
unclutter -idle 0.5 &

# Wait a bit to ensure desktop is ready
sleep 10

# Launch Chromium in kiosk mode
chromium-browser \
  --noerrdialogs \
  --disable-infobars \
  --kiosk http://localhost:80 \
  --incognito \
  --no-sandbox
