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
font = ImageFont.truetype("PixelOperator.ttf", 12)
icon_font = ImageFont.truetype("lineawesome-webfont.ttf", 16)

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
    try:
        return get_output("grep '^ssid=' /etc/hostapd*.conf | cut -d '=' -f2")
    except:
        return "N/A"


def get_ip():
    try:
        return "192.168.50.1"
        #return subprocess.check_output("hostname -I | cut -d' ' -f1", shell=True).decode().strip()
    except:
        return "0.0.0.0"

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

def get_streaming_status():
    try:
        result = subprocess.check_output("systemctl status srt-streamer.service", shell=True).decode()

        # Match e.g. "; 48s ago" or "; 3min ago" or "; 2h ago"
        match = re.search(r";\s+(\d+)(?:\.\d+)?\s*(s|min|h|d|day|month|year)s?\s+ago", result)
        if not match:
            return "NOT STREAMING"

        value = int(match.group(1))
        unit = match.group(2)

        # Convert to seconds
        unit_seconds = {
            "s": 1,
            "min": 60,
            "h": 3600,
            "d": 86400,
            "day": 86400,
            "month": 2629800,
            "year": 31557600
        }

        seconds = value * unit_seconds.get(unit, 0)
        return "STREAMING" if seconds > 3 else "NOT STREAMING"
    except:
        return "UNKNOWN"

def get_tailscale_url():
    try:
        return subprocess.check_output("tailscale status --json | jq -r '.Self.DNSName'", shell=True).decode().strip()
    except:
        return "tailscale.local"

# Display Modes
def draw_mode_0():
    image = Image.new("1", (oled.width, oled.height))
    draw = ImageDraw.Draw(image)

    # Line 1 - Hostname and uptime
    draw.text((0, 0), f"{get_hostname()}  {format_uptime(get_uptime())}", font=font, fill=255)

    # Line 2 - WiFi Icon + SSID
    draw.text((0, 12), chr(61931), font=icon_font, fill=255)
    draw.text((18, 12), get_ssid(), font=font, fill=255)

    # Line 3 - IP
    draw.text((0, 22), chr(63231), font=icon_font, fill=255)
    draw.text((18, 22), get_ip(), font=font, fill=255)

    # Line 4 - Uplink
    up, down = get_kbps()
    draw.text((0, 32), chr(61587), font=icon_font, fill=255)  # up arrow
    draw.text((18, 32), f"{up} kbps", font=font, fill=255)

    # Line 5 - Downlink
    draw.text((0, 42), chr(61465), font=icon_font, fill=255)  # down arrow
    draw.text((18, 42), f"{down} kbps", font=font, fill=255)

    # Line 6 - Status
    # chr(61729) is computer icon
    draw.text((0, 52), chr(61458), font=icon_font, fill=255)  # computer icon
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