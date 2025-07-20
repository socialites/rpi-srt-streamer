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
WIDTH = 320
HEIGHT = 480
LOOPTIME = 5.0  # Switch screens every 5 seconds
REFRESH_INTERVAL = 1.0  # Refresh interval in seconds
oled_reset = gpiozero.OutputDevice(4, active_high=False)