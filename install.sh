#!/bin/bash

CONFIG_FILE="/opt/srt-streamer/config.env"

# Fallback directory (default to . if /boot/firmware doesn't exist)
TARGET_DIR="/boot/firmware"
[ ! -d "$TARGET_DIR" ] && TARGET_DIR="."

echo "[INFO] Using target directory: $TARGET_DIR"

# Screen Defaults
SCREEN="false"
SCREEN_SIZE="0096"
SCREEN_RGB="false"
SCREEN_TOUCH="false"

# Ensure config directory exists
sudo mkdir -p "$(dirname "$CONFIG_FILE")"

# Prompt for config if not found
if [ -f "$CONFIG_FILE" ]; then
  echo "[INFO] Config file found at $CONFIG_FILE. Loading configuration..."
  source "$CONFIG_FILE"
else
  echo "[WARN] Config not found at $CONFIG_FILE. Let's create it."

  read -rp "Enter your SRT destination host (Tailscale destination's machine name) (e.g. desktop): " DEST_HOST < /dev/tty
  read -rp "Enter your SRT port (e.g. 1234): " SRT_PORT < /dev/tty
  read -rp "Enter your Tailscale auth key (starts with tskey-auth-xxxxx): " TAILSCALE_AUTH_KEY < /dev/tty
  read -rp "Enter your device's desired SSID (e.g. 'SRTStreamer'): " SSID < /dev/tty
  read -rp "Enter your device's Wi-Fi password (must be at least 8 characters): " PASSWORD < /dev/tty

  # Ask if they want a screen
  while true; do
    read -rp "Does this device have a display screen? (true/false): " SCREEN < /dev/tty
    case "$SCREEN" in
      true|false) break ;;
      *) echo "Please enter 'true' or 'false'." ;;
    esac
  done

  # Only ask screen-related settings if SCREEN is true
  if [ "$SCREEN" == "true" ]; then
    echo "Select your screen size:"
    echo "1) 0.96in"
    echo "2) 1.8in"
    echo "3) 3.5in"
    echo "4) 4.0in"

    while true; do
        read -rp "#? " CHOICE < /dev/tty
        case "$CHOICE" in
            1) SCREEN_SIZE="0096"; break ;;
            2) SCREEN_SIZE="0180"; break ;;
            3) SCREEN_SIZE="0350"; break ;;
            4) SCREEN_SIZE="0400"; break ;;
            *) echo "Invalid choice. Please choose 1–4." ;;
        esac
    done

    while true; do
      read -rp "Is the screen color RGB? (true/false): " SCREEN_RGB < /dev/tty
      case "$SCREEN_RGB" in
        true|false) break ;;
        *) echo "Please enter 'true' or 'false'." ;;
      esac
    done

    while true; do
      read -rp "Does the screen have touch input? (true/false): " SCREEN_TOUCH < /dev/tty
      case "$SCREEN_TOUCH" in
        true|false) break ;;
        *) echo "Please enter 'true' or 'false'." ;;
      esac
    done
  else
    SCREEN_SIZE="0096"
    SCREEN_RGB="false"
    SCREEN_TOUCH="false"
  fi

  # Save to config
  sudo tee "$CONFIG_FILE" >/dev/null <<EOF
DEST_HOST=${DEST_HOST}
SRT_PORT=${SRT_PORT}
TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}
SSID=${SSID}
PASSWORD=${PASSWORD}
SCREEN=${SCREEN}
SCREEN_SIZE=${SCREEN_SIZE}
SCREEN_RGB=${SCREEN_RGB}
SCREEN_TOUCH=${SCREEN_TOUCH}
EOF

  echo "[INFO] Configuration saved to $CONFIG_FILE."
  set -a
  source "$CONFIG_FILE"
  set +a
fi

# === Basic Prechecks ===
echo "[INFO] Detecting Raspberry Pi model..."
if grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
  echo "[INFO] Raspberry Pi detected."
else
  echo "[ERROR] This does not appear to be a Raspberry Pi. Exiting."
  exit 1
fi

echo "[INFO] Checking internet connection..."
if ping -q -c 1 -W 2 8.8.8.8 >/dev/null; then
  echo "[INFO] Internet connection detected."
else
  echo "[ERROR] No internet connection. Please connect first."
  exit 1
fi

# === Add root to sudoers with no password prompt ===
echo "[INFO] Adding root to sudoers with NOPASSWD..."
echo "root ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/010_root-nopasswd >/dev/null
echo "[SUCCESS] root can now run sudo commands without a password."

# === Install basic dependencies ===
echo "[INFO] Installing dependencies..."
sudo apt-get update && sudo apt-get install -y curl wget git

# === Download and run the main install script ===
echo "[INFO] Downloading setup script to $TARGET_DIR..."
curl -fsSL https://raw.githubusercontent.com/socialites/rpi-srt-streamer/main/install-and-stream.sh -o "$TARGET_DIR/install-and-stream.sh"
chmod +x "$TARGET_DIR/install-and-stream.sh"

echo "[INFO] Running setup script..."
sudo "$TARGET_DIR/install-and-stream.sh"
