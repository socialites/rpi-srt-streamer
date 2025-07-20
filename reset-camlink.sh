#!/bin/bash
echo "[INFO] Locating Camlink..."
LINE=$(lsusb | grep "0fd9:0066")
if [ -z "$LINE" ]; then
  echo "[ERROR] Camlink not found in lsusb"
  exit 1
fi
BUS=$(echo "$LINE" | awk '{print $2}' | sed 's/^0*//')
DEV=$(echo "$LINE" | awk '{print $4}' | tr -d ':' | sed 's/^0*//')
USB_PATH=$(printf "/dev/bus/usb/%03d/%03d" "$BUS" "$DEV")
echo "[INFO] Resetting Camlink at $USB_PATH"
exec /usr/local/bin/usbreset "$USB_PATH"