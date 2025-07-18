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
icon_font = ImageFont.truetype("lineawesome-webfont.ttf", 12)

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