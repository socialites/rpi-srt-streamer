#!/bin/bash

set -e

CONFIG_FILE="/opt/srt-streamer/config.env"
TARGET_DIR="."
REPO_URL="https://raw.githubusercontent.com/socialites/rpi-srt-streamer/main"

# Detect target directory
if [ -d "/boot/firmware" ]; then
  TARGET_DIR="/boot/firmware"
else
  TARGET_DIR="."
fi

# Ensure config directory exists
sudo mkdir -p "$(dirname "$CONFIG_FILE")"

# Prompt for config values if missing
if [ -f "$CONFIG_FILE" ]; then
  echo "[INFO] Config file found at $CONFIG_FILE. Loading configuration..."
  source "$CONFIG_FILE"
else
  echo "[WARN] Config not found at $CONFIG_FILE. Let's create it."

  read -rp "Enter your SRT destination host (Tailscale destination's machine name) (e.g. desktop): " DEST_HOST
  read -rp "Enter your SRT port (e.g. 1234): " SRT_PORT
  read -rp "Enter your Tailscale auth key (starts with tskey-auth-xxxxx): " TAILSCALE_AUTH_KEY

  sudo tee "$CONFIG_FILE" >/dev/null <<EOF
DEST_HOST=${DEST_HOST}
SRT_PORT=${SRT_PORT}
TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}
EOF
  echo "[INFO] Config file created at $CONFIG_FILE"
fi

echo "[INFO] Validating environment..."

# Check for RPi model and network
echo "[INFO] Detecting Raspberry Pi model..."
if grep -q "Raspberry Pi" /proc/device-tree/model; then
  echo "[INFO] Raspberry Pi detected."
else
  echo "[ERROR] This script is intended for Raspberry Pi devices only."
  exit 1
fi

echo "[INFO] Checking internet connection..."
if ping -q -c 1 -W 1 1.1.1.1 >/dev/null; then
  echo "[INFO] Internet connection detected."
else
  echo "[ERROR] No internet connection. Please check your network."
  exit 1
fi

# Ensure sudo without password
echo "[INFO] Adding root to sudoers with NOPASSWD..."
echo "root ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/nopasswd-root >/dev/null
echo "[SUCCESS] root can now run sudo commands without a password."

# Install packages
echo "[INFO] Installing dependencies..."
sudo apt-get update -y
sudo apt-get install -y curl wget git

# Download and run the main setup script (interactive)
echo "[INFO] Downloading setup script to $TARGET_DIR..."
curl -fsSL "$REPO_URL/install-and-stream.sh" -o "$TARGET_DIR/install-and-stream.sh"
chmod +x "$TARGET_DIR/install-and-stream.sh"

echo "[INFO] Running setup script..."
"$TARGET_DIR/install-and-stream.sh"
