#!/bin/bash

### === CONFIGURATION === ###
CONFIG_FILE="/opt/srt-streamer/config.env"
LOG_PATH="/var/log/srt-streamer.log"
SERVICE_FILE="/etc/systemd/system/srt-streamer.service"
VIDEO_DEVICE="/dev/video0"
USBRESET_PATH="/usr/local/bin/usbreset"
CAMLINK_ID="0fd9:0066"

# Ensure config directory exists
sudo mkdir -p "$(dirname "$CONFIG_FILE")"

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
sudo apt-get install -y ffmpeg curl gnupg2 v4l-utils alsa-utils build-essential

### === Install or Reinstall usbreset === ###
echo "[INFO] (Re)installing usbreset..."
cat << 'EOF' | sudo tee /tmp/usbreset.c >/dev/null
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <linux/usbdevice_fs.h>
#include <sys/ioctl.h>

int main(int argc, char **argv) {
  if (argc != 2) {
    printf("Usage: %s /dev/bus/usb/BBB/DDD\n", argv[0]);
    return 1;
  }
  int fd = open(argv[1], O_WRONLY);
  if (fd < 0) {
    perror("Error opening device");
    return 1;
  }
  printf("Resetting USB device %s\n", argv[1]);
  int rc = ioctl(fd, USBDEVFS_RESET, 0);
  if (rc < 0) {
    perror("Error in ioctl");
    return 1;
  }
  printf("Reset successful\n");
  close(fd);
  return 0;
}
EOF

gcc /tmp/usbreset.c -o usbreset
sudo mv usbreset "$USBRESET_PATH"
sudo chown root:root "$USBRESET_PATH"
sudo chmod u+s "$USBRESET_PATH"
rm /tmp/usbreset.c
echo "[INFO] usbreset installed to $USBRESET_PATH with setuid root"

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

### === Find Camlink USB path === ###
BUS_DEV=$(lsusb | grep "$CAMLINK_ID" | awk '{print $2, $4}' | sed 's/://')
USB_PATH=$(printf "/dev/bus/usb/%03d/%03d" ${BUS_DEV%% *} ${BUS_DEV##* })
if [ -z "$USB_PATH" ]; then
  echo "[ERROR] Could not find Camlink on USB bus."
  exit 1
fi
echo "[INFO] Found Camlink USB path: $USB_PATH"

### === Create systemd Service === ###
echo "[INFO] Creating systemd service..."
sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=SRT HDMI Streamer with Audio
After=network.target

[Service]
ExecStartPre=/bin/bash -c 'echo "[INFO] Resetting Camlink..."; ${USBRESET_PATH} ${USB_PATH} || (echo "[ERROR] usbreset failed" >> ${LOG_PATH}; exit 1)'
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
