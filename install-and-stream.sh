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
  read -rp "Enter your devices desired SSID (e.g. 'SRTStreamer'): " SSID
  read -rp "Enter your devices desired password (e.g. 'mypassword' **Must be at least 8 characters**): " PASSWORD

  sudo tee "$CONFIG_FILE" >/dev/null <<EOF
DEST_HOST=${DEST_HOST}
SRT_PORT=${SRT_PORT}
TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}
SSID=${SSID}
PASSWORD=${PASSWORD}
EOF

  echo "[INFO] Config file created at $CONFIG_FILE"
  source "$CONFIG_FILE"
fi

### === Make current user passwordless sudo (if not already configured) === ###
USERNAME="$(sudo echo `whoami`)"
SUDOERS_FILE="/etc/sudoers.d/${USERNAME}-nopasswd"

if [ ! -f "$SUDOERS_FILE" ]; then
  echo "[INFO] Adding $USERNAME to sudoers with NOPASSWD..."
  echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" | sudo tee "$SUDOERS_FILE" > /dev/null
  sudo chmod 440 "$SUDOERS_FILE"
  echo "[SUCCESS] $USERNAME can now run sudo commands without a password."
else
  echo "[INFO] Sudoers file already exists for $USERNAME, skipping."
fi

### === Install Update Script === ###
echo "[INFO] Installing update script to /usr/local/bin/update..."

sudo tee /usr/local/bin/update > /dev/null <<'EOF'
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/socialites/rpi-srt-streamer/main/install.sh | sudo bash
EOF

sudo chmod +x /usr/local/bin/update


### === Install Dependencies === ###
echo "[INFO] Installing dependencies..."
sudo apt-get update
sudo apt-get install -y ffmpeg curl gnupg2 v4l-utils alsa-utils \
  iproute2 usbmuxd libimobiledevice6 libimobiledevice-utils ifuse \
  isc-dhcp-client jq usbutils net-tools network-manager bluetooth bluez \
  python3 python3-pip linux-headers-$(uname -r) build-essential git dkms ifstat \
  i2c-tools python3-smbus

### === Clone and Build v4l2loopback === ###
echo "[INFO] Cloning and building v4l2loopback..."
if [ ! -d "/usr/src/v4l2loopback" ]; then
  git clone https://github.com/umlaeute/v4l2loopback.git /tmp/v4l2loopback
  cd /tmp/v4l2loopback
  make
  sudo make install
else
  echo "[INFO] v4l2loopback already exists, skipping clone."
fi

### === Configure v4l2loopback to Load on Boot === ###
echo "[INFO] Writing v4l2loopback config..."
sudo tee /etc/modules-load.d/v4l2loopback.conf > /dev/null <<EOF
v4l2loopback
EOF

sudo tee /etc/modprobe.d/v4l2loopback.conf > /dev/null <<EOF
options v4l2loopback devices=1 video_nr=1 card_label="Preview" exclusive_caps=1
EOF


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


### === Install Node.js, npm, pnpm, and Python dependencies === ###
echo "[INFO] Installing Node.js, npm, pnpm, and Python dependencies..."
sudo curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo pip3 install aiohttp aiohttp_cors adafruit-circuitpython-ssd1306 pillow lgpio gpiozero --break-system-packages
sudo npm install -g pnpm

### === Clone and Build the Dashboard Repo === ###
DASHBOARD_REPO="https://github.com/socialites/rpi-srt-streamer-dashboard"
TEMP_DASHBOARD_DIR="/home/$USER/rpi-srt-streamer-dashboard"
FINAL_DASHBOARD_DIST="/boot/firmware/rpi-srt-streamer-dashboard/dist"

echo "[INFO] Cloning dashboard repo to ext4 filesystem..."
if [ -d "$TEMP_DASHBOARD_DIR" ]; then
  cd "$TEMP_DASHBOARD_DIR" && git pull
else
  git clone "$DASHBOARD_REPO" "$TEMP_DASHBOARD_DIR"
fi

echo "[INFO] Installing dashboard dependencies..."
cd "$TEMP_DASHBOARD_DIR"
pnpm install

echo "[INFO] Building dashboard..."
pnpm build

echo "[INFO] Copying built dashboard to /boot/firmware..."
sudo mkdir -p "$FINAL_DASHBOARD_DIST"
sudo cp -r "$TEMP_DASHBOARD_DIR/dist/"* "$FINAL_DASHBOARD_DIST"

echo "[INFO] Generating dashboard server Python script..."
sudo tee /usr/local/bin/srt-dashboard-server.py > /dev/null <<'EOF'
#!/usr/bin/env python3
import asyncio
import json
import subprocess
import socket
import os
import aiohttp_cors
from aiohttp import web

PORT = 80
DASHBOARD_DIR = "/boot/firmware/rpi-srt-streamer-dashboard/dist"
WS_CLIENTS = set()

def get_ap_status_and_ssid():
    ap_status = "down"
    ssid = "unavailable"
    password = "not available"

    try:
        # Check if ap0 exists and is UP
        output = subprocess.check_output(["ip", "link", "show", "ap0"]).decode()
        if "UP" in output:
            # Get SSID and password from config
            try:
                with open("/etc/hostapd-ap0.conf", "r") as f:
                    for line in f:
                        if line.startswith("ssid="):
                            ssid = line.strip().split("=")[1]
                        elif line.startswith("wpa_passphrase="):
                            password = line.strip().split("=")[1]
                if ssid != "unavailable":
                    ap_status = "up"
                else:
                    ap_status = "down"
            except Exception:
                ap_status = "down"
    except subprocess.CalledProcessError:
        ap_status = "missing"

    return ap_status, ssid, password


# === HTTP ROUTES ===

async def health(request):
    return web.Response(text="ok")

async def status(request):
    ap_status, ssid, password = get_ap_status_and_ssid()

    result = {
        "hostname": subprocess.getoutput("hostname"),
        "ip": subprocess.getoutput("hostname -I").strip(),
        "network_watcher": subprocess.getoutput("systemctl is-active network-watcher.service"),
        "srt_streamer": subprocess.getoutput("systemctl is-active srt-streamer.service"),
        "ap_ssid": ssid,
        "ap_status": ap_status,
        "ap_password": password
    }
    return web.json_response(result)

async def network_stats():
    try:
        result = subprocess.check_output(["ifstat", "-q", "-T", "1", "1"], text=True)
        lines = [line.strip() for line in result.strip().splitlines()]
        interfaces = lines[0].split()
        values = lines[2].split()

        parsed = {}
        for i, iface in enumerate(interfaces):
            parsed[iface] = {
                "in_kbps": float(values[i * 2]),
                "out_kbps": float(values[i * 2 + 1])
            }

        relevant = ("enx", "eth", "wlan")
        return {
            k: v for k, v in parsed.items()
            if any(k.startswith(prefix) for prefix in relevant)
        }

    except Exception as e:
        return {"error": str(e)}

async def network(request):
    return web.json_response(await network_stats())




async def handle_post(request):
    path = request.path
    if path.startswith("/api/restart/"):
        service = path.split("/")[-1]
        if service in ("network-watcher", "srt-streamer"):
            subprocess.run(["sudo", "systemctl", "restart", f"{service}.service"])
            return web.Response(text=f"Restarted {service}")
        elif service == "camlink":
            subprocess.run(["sudo", "bash", "/usr/local/bin/reset-camlink.sh"])
            return web.Response(text="USB reset successful")
        elif service == "ap":
            subprocess.run(["sudo", "systemctl", "restart", "ap0-hostapd"])
            subprocess.run(["sudo", "systemctl", "restart", "ap0-dnsmasq"])
            return web.Response(text="Restarted access point")
    elif path == "/api/shutdown":
        subprocess.Popen(["sudo", "shutdown", "now"])
    elif path == "/api/reboot":
        subprocess.Popen(["sudo", "reboot"])
    elif path == "/api/run-install":
        subprocess.Popen(["sudo", "/boot/firmware/install-and-stream.sh"])
    return web.Response(text="OK")

async def scan_networks(request):
    try:
        result = subprocess.check_output(["nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list"], text=True)
        networks = []
        for line in result.strip().splitlines():
            parts = line.strip().split(":")
            if len(parts) >= 2:
                ssid, signal = parts[0], parts[1]
                security = parts[2] if len(parts) > 2 else "UNKNOWN"
                if ssid:  # skip empty SSIDs
                    networks.append({"ssid": ssid, "signal": signal, "security": security})
        return web.json_response(networks)
    except subprocess.CalledProcessError as e:
        return web.Response(status=500, text=str(e))

async def connect_wifi(request):
    data = await request.json()
    ssid = data.get("ssid")
    password = data.get("password")
    if not ssid or not password:
        return web.Response(status=400, text="Missing SSID or password")

    try:
        subprocess.check_call(["nmcli", "device", "wifi", "connect", ssid, "password", password])
        return web.Response(status=200, text=f"Connected to {ssid}")
    except subprocess.CalledProcessError as e:
        return web.Response(status=500, text=str(e))

# === WEBSOCKET SUPPORT ===

async def websocket_handler(request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    WS_CLIENTS.add(ws)

    try:
        while not ws.closed:
            await asyncio.sleep(2)
            stats = await network_stats()
            await ws.send_str(json.dumps(stats))
    except:
        pass
    finally:
        WS_CLIENTS.remove(ws)
    return ws

# === APP SETUP ===
async def serve_index(request):
    return web.FileResponse(os.path.join(DASHBOARD_DIR, "index.html"))

app = web.Application()

# Configure CORS
cors = aiohttp_cors.setup(app, defaults={
    "*": aiohttp_cors.ResourceOptions(
        allow_credentials=True,
        expose_headers="*",
        allow_headers="*",
    )
})

routes = [
    web.get('/', serve_index),
    web.get('/health', health),
    web.get('/api/status', status),
    web.get('/api/network', network),
    web.get('/api/network/ws', websocket_handler),
    web.get('/api/wifi/networks', scan_networks),
    web.post('/api/wifi/connect', connect_wifi),
    web.post('/api/restart/{service}', handle_post),
    web.post('/api/shutdown', handle_post),
    web.post('/api/reboot', handle_post),
    web.post('/api/run-install', handle_post),
]

# Add normal routes
for route in routes:
    cors.add(app.router.add_route(route.method, route.path, route.handler))

# Add static route separately
app.router.add_static('/', DASHBOARD_DIR)

HLS_DIR = "/boot/firmware/hls"
os.makedirs(HLS_DIR, exist_ok=True)
app.router.add_static('/hls/', HLS_DIR, show_index=True)

# === Graceful Shutdown Hook ===
async def on_shutdown(app):
    print("[INFO] Shutting down... closing WebSocket clients.")
    for ws in list(WS_CLIENTS):
        await ws.close(code=1001, message="Server restarting")
    print("[INFO] WebSocket clients closed.")

app.on_shutdown.append(on_shutdown)

if __name__ == '__main__':
    web.run_app(app, port=PORT)
EOF

sudo chmod +x /usr/local/bin/srt-dashboard-server.py

echo "[INFO] Creating srt-dashboard-server.service..."
sudo tee /etc/systemd/system/srt-dashboard-server.service > /dev/null <<EOF
[Unit]
Description=Raspberry Pi SRT Streamer Dashboard Server
After=network.target

[Service]
ExecStartPre=/bin/bash -c 'fuser -k 80/tcp || true'
ExecStartPre=/bin/bash -c 'while ss -tulpn | grep -q ":80 "; do echo "[INFO] Waiting for port 80 to free up..."; sleep 1; done'
ExecStart=/usr/bin/python3 /usr/local/bin/srt-dashboard-server.py
Restart=always
User=$(whoami)
WorkingDirectory=/boot/firmware/rpi-srt-streamer-dashboard/dist
StandardOutput=append:/var/log/srt-dashboard-server.log
StandardError=append:/var/log/srt-dashboard-server.log
RestartSec=2
KillMode=mixed
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "[INFO] Enabling and starting srt-dashboard-server.service..."
sudo systemctl daemon-reload
sudo systemctl enable srt-dashboard-server.service
sudo systemctl restart srt-dashboard-server.service

### === Detect Audio Device === ###
AUDIO_CARD=$(arecord -l | grep -i "Cam Link" -A 1 | grep -oP 'card \K\d+')
if [ -z "$AUDIO_CARD" ]; then
  echo "[ERROR] Could not auto-detect Camlink audio device."
  exit 1
fi
AUDIO_DEVICE="hw:${AUDIO_CARD},0"
echo "[INFO] Using audio device: $AUDIO_DEVICE"

### === Create systemd Service for SRT Streamer (Tee Pipeline) === ###
echo "[INFO] Creating systemd service..."
sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=SRT HDMI Streamer with Audio and Preview (single process)
After=network-watcher.service
Requires=network-watcher.service

[Service]
ExecStartPre=$RESET_SCRIPT
ExecStart=/bin/bash -c '/usr/bin/ffmpeg \
  -f v4l2 -framerate 30 -video_size 3840x2160 -pixel_format nv12 -i /dev/video0 \
  -f alsa -i $AUDIO_DEVICE \
  -filter_complex "[0:v]split=2[main][preview];[preview]scale=640:360,format=yuv420p[previewout]" \
  -map "[previewout]" -c:v libx264 -preset ultrafast -tune zerolatency -b:v 500k \
  -f hls -hls_time 2 -hls_list_size 3 -hls_flags delete_segments /boot/firmware/hls/preview.m3u8 \
  -map "[main]" -map 1:a -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2500k \
  -f mpegts "srt://$DEST_HOST:$SRT_PORT?pkt_size=1316&mode=caller" \
  || (echo "[ERROR] ffmpeg exited with failure" >> $LOG_PATH; exit 1)'
Restart=always
StandardOutput=append:$LOG_PATH
StandardError=append:$LOG_PATH

[Install]
WantedBy=multi-user.target
EOF

### === Load v4l2loopback Now === ###
echo "[INFO] Loading v4l2loopback module..."
sudo modprobe v4l2loopback devices=1 video_nr=1 card_label="Preview" exclusive_caps=1

echo "[INFO] Python web dashboard set up at http://$(hostname)/manage"

### === Setup Emergency Wi-Fi Access Point (always-on) === ###
echo "[INFO] Installing Wi-Fi Access Point dependencies..."
sudo apt-get install -y iw hostapd dnsmasq

echo "[INFO] Marking ap0 as unmanaged by NetworkManager..."
sudo mkdir -p /etc/NetworkManager/conf.d
sudo tee /etc/NetworkManager/conf.d/unmanaged-ap0.conf > /dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:ap0
EOF

sudo systemctl reload NetworkManager

echo "[INFO] Setting up emergency Wi-Fi Access Point (always-on)..."

# Only create if not already up
if ! ip link show ap0 &>/dev/null; then
  # Create ap0
  sudo iw dev wlan0 interface add ap0 type __ap || true
  sudo ip addr add 192.168.50.1/24 dev ap0
  sudo ip link set ap0 up
fi

# Write hostapd config
cat <<EOF | sudo tee /etc/hostapd-ap0.conf > /dev/null
interface=ap0
ssid=$SSID
hw_mode=g
channel=6
wpa=2
wpa_passphrase=$PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
EOF

# Write dnsmasq config
cat <<EOF | sudo tee /etc/dnsmasq-ap0.conf > /dev/null
interface=ap0
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.100,255.255.255.0,24h
EOF

# Create systemd service for hostapd
sudo tee /etc/systemd/system/ap0-hostapd.service > /dev/null <<EOF
[Unit]
Description=Hostapd for ap0
After=network.target

[Service]
ExecStart=/usr/sbin/hostapd /etc/hostapd-ap0.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Create systemd service for dnsmasq
sudo tee /etc/systemd/system/ap0-dnsmasq.service > /dev/null <<EOF
[Unit]
Description=DNSMasq for ap0
After=network.target

[Service]
ExecStart=/usr/sbin/dnsmasq -C /etc/dnsmasq-ap0.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Create AP watchdog script
sudo tee /usr/local/bin/check-ap0.sh > /dev/null <<'EOF'
#!/bin/bash

if ! ip link show ap0 &>/dev/null; then
  echo "[watchdog] ap0 missing, recreating..."

  iw dev wlan0 interface add ap0 type __ap || true
  ip addr add 192.168.50.1/24 dev ap0
  ip link set ap0 up

  systemctl restart ap0-hostapd
  systemctl restart ap0-dnsmasq
else
  echo "[watchdog] ap0 is up"
fi
EOF

sudo chmod +x /usr/local/bin/check-ap0.sh

# Create systemd service for watchdog
sudo tee /etc/systemd/system/ap0-watchdog.service > /dev/null <<EOF
[Unit]
Description=Check and restore ap0 if missing
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/check-ap0.sh
EOF

# Create systemd timer for watchdog
sudo tee /etc/systemd/system/ap0-watchdog.timer > /dev/null <<EOF
[Unit]
Description=Run ap0 watchdog every 30 seconds

[Timer]
OnBootSec=60
OnUnitActiveSec=30

[Install]
WantedBy=timers.target
EOF

# Reload systemd
sudo systemctl daemon-reload

# Enable and start both services
sudo systemctl enable ap0-hostapd
sudo systemctl enable ap0-dnsmasq
sudo systemctl start ap0-hostapd
sudo systemctl start ap0-dnsmasq

# Enable and start watchdog
sudo systemctl enable ap0-watchdog.timer
sudo systemctl start ap0-watchdog.timer

# === Enable srt-streamer BEFORE reboot ===
echo "[INFO] Enabling SRT streamer service..."
sudo systemctl daemon-reload
sudo systemctl enable srt-streamer.service

echo -e "[${GREEN}DONE${NC}] Setup complete. Edit ${YELLOW}$CONFIG_FILE${NC} to change any stream settings."
echo -e "[${GREEN}INFO${NC}] The service file is located at: ${YELLOW}$SERVICE_FILE${NC}"
echo -e "[${GREEN}INFO${NC}] The log file is located at: ${YELLOW}$LOG_PATH${NC}"
echo -e "[${GREEN}INFO${NC}] Access Point '$SSID' is up. You can now connect and SSH to 192.168.50.1 in case you need to make any changes and you dont have a network connection."
echo -e "[${GREEN}INFO${NC}] You can now access the dashboard at http://$(hostname)"

# === Add OLED Support ===
echo "[INFO] Installing OLED service..."

echo "[INFO] Downloading fonts..."
sudo curl -L -o /usr/local/bin/PixelOperator.ttf https://raw.githubusercontent.com/socialites/rpi-srt-streamer/main/PixelOperator.ttf
sudo chmod 644 /usr/local/bin/PixelOperator.ttf
sudo curl -L -o /usr/local/bin/lineawesome-webfont.ttf https://raw.githubusercontent.com/socialites/rpi-srt-streamer/main/lineawesome-webfont.ttf
sudo chmod 644 /usr/local/bin/lineawesome-webfont.ttf

echo "[INFO] Creating oled.py..."
sudo tee /usr/local/bin/oled.py > /dev/null << 'EOF'
#!/usr/bin/env python3
import time
import subprocess
import socket
from datetime import datetime, timedelta
from PIL import Image, ImageDraw, ImageFont
import board
import busio
import adafruit_ssd1306
import gpiozero
import re

# === Display Settings ===
WIDTH = 128
HEIGHT = 64
LOOPTIME = 5.0  # Switch screens every 5 seconds
REFRESH_INTERVAL = 1.0  # Refresh interval in seconds
oled_reset = gpiozero.OutputDevice(4, active_high=False)

# Fonts
font = ImageFont.truetype("/usr/local/bin/PixelOperator.ttf", 12)
icon_font = ImageFont.truetype("/usr/local/bin/lineawesome-webfont.ttf", 12)

# OLED setup
i2c = board.I2C()
oled_reset.on()
time.sleep(0.1)
oled_reset.off()
time.sleep(0.1)
oled_reset.on()
oled = adafruit_ssd1306.SSD1306_I2C(WIDTH, HEIGHT, i2c, addr=0x3C)
oled.fill(0)
oled.show()

# === Utility Functions ===
def get_output(cmd):
    try:
        return subprocess.check_output(cmd, shell=True).decode().strip()
    except:
        return "?"

def get_uptime():
    return int(float(open("/proc/uptime").read().split()[0]))

def format_uptime(seconds):
    return time.strftime('%H:%M:%S', time.gmtime(seconds))

def get_hostname():
    return socket.gethostname()

def get_ssid():
    ssid = "N/A"
    ap_status = "down"

    try:
        ssid = get_output("grep '^ssid=' /etc/hostapd*.conf | cut -d '=' -f2")
    except:
        ssid = "N/A"

    try:
        # Check if ap0 exists and is UP
        output = subprocess.check_output(["ip", "link", "show", "ap0"]).decode()
        if "UP" in output:
            try:
                if ssid != "N/A":
                    ap_status = "up"
                else:
                    ap_status = "down"
            except Exception:
                ap_status = "down"
    except subprocess.CalledProcessError:
        ap_status = "missing"

    return ap_status, ssid


def get_ip(interface="ap0"):
    try:
        output = subprocess.check_output(f"ip addr show {interface}", shell=True).decode()
        match = re.search(r'inet (\d+\.\d+\.\d+\.\d+)/', output)
        if match:
            return match.group(1)
        else:
            return "0.0.0.0"
    except Exception:
        return "0.0.0.0"

"""
def get_kbps(interface="wlan0"):
    try:
        with open(f"/sys/class/net/{interface}/statistics/tx_bytes") as f: tx1 = int(f.read())
        with open(f"/sys/class/net/{interface}/statistics/rx_bytes") as f: rx1 = int(f.read())
        time.sleep(0.5)
        with open(f"/sys/class/net/{interface}/statistics/tx_bytes") as f: tx2 = int(f.read())
        with open(f"/sys/class/net/{interface}/statistics/rx_bytes") as f: rx2 = int(f.read())
        return round((tx2 - tx1) * 2 / 1024, 1), round((rx2 - rx1) * 2 / 1024, 1)
    except:
        return 0.0, 0.0
"""

def get_kbps():
    try:
        result = subprocess.check_output(["ifstat", "-q", "-T", "1", "1"], text=True)
        lines = [line.strip() for line in result.strip().splitlines()]

        # Headers and values
        headers = lines[0].split()
        values = lines[2].split()

        total_in = 0.0
        total_out = 0.0

        for i, iface in enumerate(headers):
            if iface in ("tailscale0", "ap0", "Total"):
                continue

            in_kbps = float(values[i * 2])
            out_kbps = float(values[i * 2 + 1])
            total_in += in_kbps
            total_out += out_kbps

        return round(total_out, 1), round(total_in, 1)  # up, down

    except Exception as e:
        return 0.0, 0.0

def parse_duration(text):
    # Matches groups like '2min', '39s', '1h', etc.
    matches = re.findall(r"(\d+)(s|min|h|d|day|month|year)s?", text)
    unit_seconds = {
        "s": 1,
        "min": 60,
        "h": 3600,
        "d": 86400,
        "day": 86400,
        "month": 2629800,
        "year": 31557600
    }

    total_seconds = sum(int(value) * unit_seconds[unit] for value, unit in matches)
    return total_seconds


def get_streaming_status():
    try:
        result = subprocess.check_output("systemctl status srt-streamer.service", shell=True).decode()

        # Match duration in the line like "; 2min 39s ago"
        match = re.search(r";\s+(.+?)\s+ago", result)
        if not match:
            return "NOT STREAMING"

        duration_text = match.group(1)
        seconds = parse_duration(duration_text)

        # Get total outbound KB/s
        total_out, _ = get_kbps()
        print(f"[STREAM STATUS] Time since active: {seconds}s, Outbound: {total_out} KB/s")

        return "STREAMING" if seconds > 3 and total_out >= 100 else "NOT STREAMING"
    except:
        return "UNKNOWN"

def get_tailscale_url():
    try:
        return subprocess.check_output("tailscale status --json | jq -r '.Self.DNSName'", shell=True).decode().strip()
    except:
        return "Tailscale Offline"

# Display Modes
def draw_mode_0():
    image = Image.new("1", (oled.width, oled.height))
    draw = ImageDraw.Draw(image)

    # Line 1 - Hostname and uptime
    draw.text((0, 0), f"{get_hostname()}  {format_uptime(get_uptime())}", font=font, fill=255)

    # Line 2 - WiFi Icon + SSID
    draw.text((0, 12), chr(61931), font=icon_font, fill=255)
    ap_status, ssid = get_ssid()
    draw.text((18, 12), f"{ssid} - {ap_status}", font=font, fill=255)

    # Line 3 - IP
    # 63231 is the network wired icon
    draw.text((0, 22), chr(63382), font=icon_font, fill=255)
    draw.text((18, 22), get_ip(), font=font, fill=255)

    # Line 4 - Uplink
    up, down = get_kbps()
    draw.text((0, 32), chr(62338), font=icon_font, fill=255)  # up arrow
    draw.text((18, 32), f"{up} kbps", font=font, fill=255)

    # Line 5 - Downlink
    draw.text((0, 42), chr(62337), font=icon_font, fill=255)  # down arrow
    draw.text((18, 42), f"{down} kbps", font=font, fill=255)

    # Line 6 - Status
    # chr(61729) is computer icon
    # chr(61458) is the rising bars icon
    # chr(62003) is the server icon
    draw.text((0, 52), chr(63424), font=icon_font, fill=255) # signal/satellite
    draw.text((18, 52), get_streaming_status(), font=font, fill=255)

    oled.image(image)
    oled.show()

def draw_mode_1():
    image = Image.new("1", (oled.width, oled.height))
    draw = ImageDraw.Draw(image)

    # Line 1 - Hostname and uptime
    draw.text((0, 0), f"{get_hostname()}  {format_uptime(get_uptime())}", font=font, fill=255)

    # Line 2 - Globe icon + Tailscale URL
    draw.text((0, 12), chr(62845), font=icon_font, fill=255)  # globe
    draw.text((18, 12), f"http://{get_tailscale_url()}", font=font, fill=255)

    oled.image(image)
    oled.show()

# Main loop
mode = 0
last_switch = time.time()

while True:
    if mode == 0:
        draw_mode_0()
    else:
        draw_mode_1()

    # Flip mode every LOOPTIME seconds
    if time.time() - last_switch > LOOPTIME:
        mode = 1 - mode
        last_switch = time.time()

    time.sleep(REFRESH_INTERVAL)
EOF

sudo chmod +x /usr/local/bin/oled.py

sudo tee /etc/systemd/system/oled.service > /dev/null << 'EOF'
[Unit]
Description=OLED Status Display
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/oled.py
Restart=always
RestartSec=5
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable oled.service
sudo systemctl start oled.service

echo "[INFO] Checking if the OTG and USB current settings are correct..."

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

  if ! grep -q "dtparam=i2c_arm=on" "$BOOT_CONFIG"; then
    echo "[INFO] Enabling i2c_arm=on in $BOOT_CONFIG"
    echo -e "\n# Enable i2c_arm=on\ndtparam=i2c_arm=on" | sudo tee -a "$BOOT_CONFIG" > /dev/null
    REBOOT_NEEDED=true
  fi

  if ! grep -q "otg_mode=1" "$BOOT_CONFIG"; then
    echo "[INFO] Enabling otg_mode=1 in $BOOT_CONFIG"
    echo -e "\n# Enable OTG mode\notg_mode=1" | sudo tee -a "$BOOT_CONFIG" > /dev/null
    REBOOT_NEEDED=true
  fi

  if [ "$REBOOT_NEEDED" = true ]; then
    echo -e "[${YELLOW}INFO${NC}] USB power and OTG settings updated. Rebooting in 5 seconds..."
    sleep 5
    sudo reboot
    exit 0
  else
    echo "[INFO] USB power, OTG, and I2C settings already configured."
  fi
else
  echo "[INFO] Pi model not Pi 4 or Pi 5. Skipping USB current/OTG/I2C config."
fi

### === Enable and Start Streamer === ###
echo "[INFO] Enabling and starting SRT streamer service..."
sudo systemctl restart srt-streamer.service