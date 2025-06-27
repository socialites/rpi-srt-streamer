#!/bin/bash
set -e

echo "[INFO] Validating environment..."

# === Check if running on Raspberry Pi ===
if ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
  echo "[ERROR] This script is intended for Raspberry Pi devices only."
  exit 1
fi

# === Check for internet connection ===
if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
  echo "[ERROR] No internet connection detected. Please connect to the internet and try again."
  exit 1
fi

# === Determine install path ===
if [ -d "/boot/firmware" ]; then
  TARGET_DIR="/boot/firmware"
else
  TARGET_DIR="."
fi

# === Download and run the main install script ===
echo "[INFO] Downloading setup script to $TARGET_DIR..."
curl -fsSL https://raw.githubusercontent.com/socialites/rpi-srt-streamer/main/install-and-stream.sh -o "$TARGET_DIR/install-and-stream.sh"

chmod +x "$TARGET_DIR/install-and-stream.sh"

echo "[INFO] Running setup script..."
sudo "$TARGET_DIR/install-and-stream.sh"
