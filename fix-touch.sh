#!/bin/bash

# Wait until the X server and touchscreen are ready
export DISPLAY=:0
TRIES=0
MAX_TRIES=10

until xinput list | grep -q "ADS7846 Touchscreen"; do
  sleep 1
  TRIES=$((TRIES + 1))
  if [[ $TRIES -ge $MAX_TRIES ]]; then
    echo "Touchscreen not found, giving up."
    exit 1
  fi
done

# Apply transformation matrix (90° rotation)
xinput set-prop "ADS7846 Touchscreen" "Coordinate Transformation Matrix" 0 1 0 -1 0 1 0 0 1
