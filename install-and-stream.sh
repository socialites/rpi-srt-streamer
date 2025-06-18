#!/bin/bash

### === CONFIGURATION === ###
CONFIG_FILE="/opt/srt-streamer/config.env"
LOG_PATH="/var/log/srt-streamer.log"
SERVICE_FILE="/etc/systemd/system/srt-streamer.service"
VIDEO_DEVICE="/dev/video0"
USBRESET_PATH="/usr/local/bin/usbreset"
RESET_SCRIPT="/usr/local/bin/reset-camlink.sh"
CAMLINK_ID="0fd9:0066"
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

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
  read -rp "Enter your Tailscale auth key (starts with tskey-auth-xxxxx): " TAILSCALE_AUTH_KEY

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
sudo apt-get install -y ffmpeg curl gnupg2 v4l-utils alsa-utils build-essential iproute2 usbmuxd libimobiledevice6 libimobiledevice-utils ifuse isc-dhcp-client jq usbutils net-tools network-manager bluetooth bluez python3

#### === Tailscale Setup === ###
echo "[INFO] Installing Tailscale..."
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
echo "[INFO] Logging into Tailscale..."
sudo tailscale up --auth-key="${TAILSCALE_AUTH_KEY}" || echo "[INFO] Tailscale already active."


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

### === Create Reset Script === ###
sudo tee "$RESET_SCRIPT" > /dev/null <<'EOF'
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
EOF

sudo chmod +x "$RESET_SCRIPT"

### === Create Network Watcher Script === ###
NETWORK_WATCHER_SCRIPT="/usr/local/bin/network-watcher.sh"
NETWORK_WATCHER_SERVICE="/etc/systemd/system/network-watcher.service"

sudo tee "$NETWORK_WATCHER_SCRIPT" > /dev/null <<'EOF'
#!/bin/bash

LOG_FILE="/var/log/network-watcher.log"
echo "[INFO] Starting network watcher..." >> "$LOG_FILE"

# Interfaces in order of priority
declare -a PRIORITY_IFACES=("enx" "usb0" "eth0" "wlan0")

while true; do
  for PREFIX in "${PRIORITY_IFACES[@]}"; do
    # Match all interfaces with the prefix
    for IFACE in $(ip -o link show | awk -F': ' "{print \$2}" | grep "^$PREFIX"); do
      # Bring up the interface if it exists and is down
      if ip link show "$IFACE" > /dev/null 2>&1; then
        if ! ip link show "$IFACE" | grep -q "UP"; then
          echo "[INFO] Bringing up interface $IFACE" >> "$LOG_FILE"
          sudo ip link set "$IFACE" up
          sudo dhclient "$IFACE" >> "$LOG_FILE" 2>&1
        fi

        # Check if the interface has an IP address
        if ip addr show "$IFACE" | grep -q "inet "; then
          CURRENT_ROUTE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
          if [ "$CURRENT_ROUTE" != "$IFACE" ]; then
            echo "[INFO] Switching default route to $IFACE" >> "$LOG_FILE"
            sudo ip route replace default dev "$IFACE"
            sleep 10  # Give time to settle
          else
            sleep 5
          fi
          break 2  # Exit both loops
        fi
      fi
    done
  done
  sleep 5
  echo "[INFO] No valid interfaces found. Retrying..." >> "$LOG_FILE"
done
EOF

sudo chmod +x "$NETWORK_WATCHER_SCRIPT"

### === Create and Enable Network Watcher Service === ###
sudo tee "$NETWORK_WATCHER_SERVICE" > /dev/null <<EOF
[Unit]
Description=Network Priority Watcher
After=network.target

[Service]
Type=simple
ExecStart=$NETWORK_WATCHER_SCRIPT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable network-watcher.service
sudo systemctl start network-watcher.service

### === Detect Audio Device === ###
AUDIO_CARD=$(arecord -l | grep -i "Cam Link" -A 1 | grep -oP 'card \K\d+')
if [ -z "$AUDIO_CARD" ]; then
  echo "[ERROR] Could not auto-detect Camlink audio device."
  exit 1
fi
AUDIO_DEVICE="hw:${AUDIO_CARD},0"
echo "[INFO] Using audio device: $AUDIO_DEVICE"

### === Create systemd Service for Streamer === ###
echo "[INFO] Creating systemd service..."
sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=SRT HDMI Streamer with Audio
After=network-watcher.service

[Service]
ExecStartPre=$RESET_SCRIPT
ExecStart=/bin/bash -c '/usr/bin/ffmpeg   -f v4l2 -framerate 30 -video_size 3840x2160 -pixel_format nv12 -i $VIDEO_DEVICE   -f alsa -i $AUDIO_DEVICE   -c:v libx264 -preset ultrafast -tune zerolatency -vf "scale=1920:1080" -b:v 2500k   -c:a aac -b:a 128k -ar 44100 -ac 2   -f mpegts "srt://$DEST_HOST:$SRT_PORT?pkt_size=1316&mode=caller"   || (echo "[ERROR] ffmpeg exited with failure" >> $LOG_PATH; exit 1)'
Restart=always
StandardOutput=append:$LOG_PATH
StandardError=append:$LOG_PATH

[Install]
WantedBy=multi-user.target
EOF

### === Enable higher USB current + OTG mode (Pi 4/5 only) === ###
BOOT_CONFIG="/boot/firmware/config.txt"
REBOOT_NEEDED=false

# Detect Raspberry Pi Model
PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)

if echo "$PI_MODEL" | grep -q -E "Raspberry Pi (4|5)"; then
  echo "[INFO] Detected model: $PI_MODEL"

  if ! grep -q "usb_max_current_enable=1" "$BOOT_CONFIG"; then
    echo "[INFO] Enabling usb_max_current_enable=1 in $BOOT_CONFIG"
    echo -e "\n# Enable higher USB current\nusb_max_current_enable=1" | sudo tee -a "$BOOT_CONFIG" > /dev/null
    REBOOT_NEEDED=true
  fi

  if ! grep -q "otg_mode=1" "$BOOT_CONFIG"; then
    echo "[INFO] Enabling otg_mode=1 in $BOOT_CONFIG"
    echo -e "\n# Enable OTG mode\notg_mode=1" | sudo tee -a "$BOOT_CONFIG" > /dev/null
    REBOOT_NEEDED=true
  fi

  if [ "$REBOOT_NEEDED" = true ]; then
    echo -e "\033[1;33m[INFO] USB power and OTG settings updated. Rebooting in 5 seconds...\033[0m"
    sleep 5
    sudo reboot
    exit 0
  else
    echo "[INFO] USB power and OTG settings already configured."
  fi
else
  echo "[INFO] Pi model not Pi 4 or Pi 5. Skipping USB current/OTG config."
fi

echo -e "[${GREEN}DONE${NC}] Setup complete. Edit ${YELLOW}$CONFIG_FILE${NC} to change any stream settings."
echo -e "[${GREEN}INFO${NC}] The service file is located at: ${YELLOW}$SERVICE_FILE${NC}"
echo -e "[${GREEN}INFO${NC}] The log file is located at: ${YELLOW}$LOG_PATH${NC}"
echo -e "[${GREEN}INFO${NC}] You can now restart the service by running:"
echo -e "${GREEN}sudo systemctl restart srt-streamer.service${NC}"

### === Enable and Start Streamer === ###
echo "[INFO] Enabling and starting SRT streamer service..."
sudo systemctl daemon-reload
sudo systemctl enable srt-streamer.service
sudo systemctl restart srt-streamer.service

''' TODO: Add this back in later
### === Configure Additional Wi-Fi === ###
echo -e "\n[INFO] SRT stream started!"
echo -e "Would you like to configure a new Wi-Fi network (e.g., mobile hotspot)? [Y/n]: \c"
read -r SETUP_WIFI

if [[ "$SETUP_WIFI" =~ ^[Yy]$ ]]; then
  echo -e "\n[INFO] Installing tools..."
  sudo apt-get install -y network-manager nmtui

  echo -e "\n[INFO] Launching Wi-Fi setup. Use arrow keys and ENTER to navigate.\n"
  sudo nmtui connect

  echo -e "\n[INFO] Saved Wi-Fi connections:"
  nmcli -t -f NAME,TYPE connection show | grep ':802-11-wireless' | cut -d':' -f1

  echo -e "\nEnter the SSID you want to prioritize (e.g., your home network): \c"
  read -r PREFERRED_WIFI

  for SSID in $(nmcli -t -f NAME,TYPE connection show | grep ':802-11-wireless' | cut -d':' -f1); do
    if [ "$SSID" == "$PREFERRED_WIFI" ]; then
      sudo nmcli connection modify "$SSID" connection.autoconnect-priority 10
      echo "[INFO] Set $SSID priority to 10"
    else
      sudo nmcli connection modify "$SSID" connection.autoconnect-priority 5
      echo "[INFO] Set $SSID priority to 5"
    fi
  done

  echo -e "\n[INFO] Wi-Fi config complete. Restarting streamer to validate connection..."
  sudo systemctl restart srt-streamer.service
fi
'''

### === Install Node.js, npm, and pnpm === ###
echo "[INFO] Installing Node.js, npm, and pnpm..."
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo npm install -g pnpm

### === Clone and Build the Dashboard Repo === ###
DASHBOARD_REPO="https://github.com/socialites/rpi-srt-streamer-dashboard"
DASHBOARD_DIR="/boot/firmware/rpi-srt-streamer-dashboard"

if [ ! -d "$DASHBOARD_DIR" ]; then
  echo "[INFO] Cloning dashboard repo..."
  sudo git clone "$DASHBOARD_REPO" "$DASHBOARD_DIR"
else
  echo "[INFO] Dashboard repo already exists. Pulling latest changes..."
  cd "$DASHBOARD_DIR" && sudo git pull
fi

echo "[INFO] Installing dashboard dependencies..."
cd "$DASHBOARD_DIR"
sudo chown -R "$USER":"$USER" "$DASHBOARD_DIR"
pnpm install

echo "[INFO] Building dashboard..."
pnpm build

echo "[INFO] Generating dashboard server Python script..."
sudo tee /usr/local/bin/srt-dashboard-server.py > /dev/null <<'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import os
import json
import subprocess
import urllib.parse

PORT = 80
DASHBOARD_DIR = "/boot/firmware/rpi-srt-streamer-dashboard/dist"

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
        elif self.path == "/api/status":
            result = {
                "hostname": subprocess.getoutput("hostname"),
                "ip": subprocess.getoutput("hostname -I").strip(),
                "network_watcher": subprocess.getoutput("systemctl is-active network-watcher.service"),
                "srt_streamer": subprocess.getoutput("systemctl is-active srt-streamer.service")
            }
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
        elif self.path == "/manage" or self.path == "/manage/":
            self.path = "/index.html"
            return http.server.SimpleHTTPRequestHandler.do_GET(self)
        else:
            return http.server.SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        _ = self.rfile.read(length)
        parsed_path = urllib.parse.urlparse(self.path)
        path = parsed_path.path

        if path.startswith("/api/restart/"):
            service = path.split("/")[-1]
            if service in ("network-watcher", "srt-streamer"):
                subprocess.run(["sudo", "systemctl", "restart", f"{service}.service"])
                self.send_response(200)
                self.end_headers()
                self.wfile.write(f"Restarted {service}".encode())
                return
        elif path == "/api/shutdown":
            subprocess.Popen(["sudo", "shutdown", "now"])
        elif path == "/api/reboot":
            subprocess.Popen(["sudo", "reboot"])
        elif path == "/api/run-install":
            subprocess.Popen(["sudo", "/boot/firmware/install-and-stream.sh"])

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")

os.chdir(DASHBOARD_DIR)
with socketserver.TCPServer(("", PORT), Handler) as httpd:
    print(f"Serving HTTP on port {PORT}...")
    httpd.serve_forever()
EOF

sudo chmod +x /usr/local/bin/srt-dashboard-server.py

echo "[INFO] Creating srt-dashboard-server.service..."
sudo tee /etc/systemd/system/srt-dashboard-server.service > /dev/null <<EOF
[Unit]
Description=Raspberry Pi SRT Streamer Dashboard Server
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/srt-dashboard-server.py
Restart=always
User=$(whoami)
WorkingDirectory=/boot/firmware/rpi-srt-streamer-dashboard/dist
StandardOutput=append:/var/log/srt-dashboard-server.log
StandardError=append:/var/log/srt-dashboard-server.log

[Install]
WantedBy=multi-user.target
EOF

echo "[INFO] Enabling and starting srt-dashboard-server.service..."
sudo systemctl daemon-reload
sudo systemctl enable srt-dashboard-server.service
sudo systemctl restart srt-dashboard-server.service

echo "[INFO] Python web dashboard set up at http://$(hostname)/manage"
