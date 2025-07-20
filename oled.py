#!/usr/bin/env python3
import os

# === Read config ===
def load_display_config():
    config_path = "/opt/srt-streamer/config.env"
    config = {
        "SCREEN": "false",
        "SCREEN_SIZE": "0096",
        "SCREEN_RGB": "false",
        "SCREEN_TOUCH": "false"
    }
    if os.path.exists(config_path):
        with open(config_path) as f:
            for line in f:
                if line.strip() and not line.strip().startswith("#") and "=" in line:
                    key, value = line.strip().split("=", 1)
                    config[key] = value.lower()
    return config

# Apply config
cfg = load_display_config()
if cfg["SCREEN"] != "true":
    exit(0)

SCREEN_SIZE = cfg["SCREEN_SIZE"]
SCREEN_RGB = cfg["SCREEN_RGB"] == "true"
SCREEN_TOUCH = cfg["SCREEN_TOUCH"] == "true"

if SCREEN_SIZE == "0096":
    from oled0096 import run_oled_display
    run_oled_display()

elif SCREEN_SIZE == "0350":
    from oled0350 import run_oled_display
    run_oled_display()

else:
    print(f"Unsupported screen size: {SCREEN_SIZE}")
    exit(1)
