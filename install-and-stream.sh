#!/bin/bash

### === CONFIGURATION === ###
CONFIG_FILE="/opt/srt-streamer/config.env"
LOG_PATH="/var/log/srt-streamer.log"
SERVICE_FILE="/etc/systemd/system/srt-streamer.service"
VIDEO_DEVICE="/dev/video0"

# Load config if it exists, otherwise prompt
if [ -f "$CONFIG_FILE" ]; then
  echo "[INFO] Config file found at $CONFIG_FILE. Loading configuration..."
  source "$CONFIG_FILE"
else
  echo "[WARN] Config not found at $CONFIG_FILE. Let's create it."

  read -rp "Enter your SRT destination host (Tailscale destination's machine name) (e.g. desktop): " DEST_HOST
  read -rp "Enter your SRT port (e.g. 1234): " SRT_PORT
  read -rp "Enter your Tailscale auth key (starts with tskey-): " TAILSCALE_AUTH_KEY

  sudo tee "$CONFIG_FILE" >/dev/null <<EOF
DEST_HOST=${DEST_HOST}
SRT_PORT=${SRT_PORT}
TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}
EOF

  echo "[INFO] Config file created at $CONFIG_FILE"
  source "$CONFIG_FILE"
fi


### === Install Dependencies === ###
echo "[INFO] Installing dependencies..."
sudo apt-get update
sudo apt-get install -y ffmpeg curl gnupg2 v4l-utils alsa-utils

### === Tailscale Setup === ###
echo "[INFO] Installing Tailscale..."
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "[INFO] Logging into Tailscale..."
sudo tailscale up --auth-key="${TAILSCALE_AUTH_KEY}" || \
  echo "[INFO] Tailscale already active."

### === Detect Camlink === ###
if [ ! -e "$VIDEO_DEVICE" ]; then
  echo "[ERROR] Camlink not detected at $VIDEO_DEVICE"
  exit 1
fi

### === Detect Audio Device === ###
AUDIO_CARD=$(arecord -l | grep -i "Cam Link" -A 1 | grep -oP 'card \K\d+')
if [ -z "$AUDIO_CARD" ]; then
  echo "[ERROR] Could not auto-detect Camlink audio device."
  exit 1
fi
AUDIO_DEVICE="hw:${AUDIO_CARD},0"
echo "[INFO] Using audio device: $AUDIO_DEVICE"

### === Create systemd Service if not exists === ###
if [ ! -f "$SERVICE_FILE" ]; then
  echo "[INFO] Creating systemd service..."
  sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=SRT HDMI Streamer with Audio
After=network.target

[Service]
ExecStart=/usr/bin/ffmpeg \\
  -f v4l2 -framerate 30 -video_size 3840x2160 -pixel_format nv12 -i ${VIDEO_DEVICE} \\
  -f alsa -i ${AUDIO_DEVICE} \\
  -c:v libx264 -preset ultrafast -tune zerolatency -vf "scale=1920:1080" -b:v 2500k \\
  -c:a aac -b:a 128k -ar 44100 -ac 2 \\
  -f mpegts "srt://${DEST_HOST}:${SRT_PORT}?pkt_size=1316&mode=caller"
Restart=always
StandardOutput=append:${LOG_PATH}
StandardError=append:${LOG_PATH}

[Install]
WantedBy=multi-user.target
EOF
fi

### === Enable and Start the Service === ###
echo "[INFO] Enabling and starting SRT streamer service..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable srt-streamer.service
sudo systemctl restart srt-streamer.service

echo "[DONE] Setup complete. Edit $CONFIG_FILE to change any stream settings."
echo "[INFO] The service file is located at: $SERVICE_FILE"
echo "[INFO] The log file is located at: $LOG_PATH"
echo "[INFO] You can now start/restart the service by running:"
echo "sudo systemctl restart srt-streamer.service"
