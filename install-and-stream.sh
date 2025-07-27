#!/bin/bash

### === CONFIGURATION === ###
REPO_URL="https://raw.githubusercontent.com/socialites/rpi-srt-streamer/main"
CONFIG_FILE="/opt/srt-streamer/config.env"
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Screen Defaults
SCREEN="false"
SCREEN_SIZE="0096"
SCREEN_RGB="false"
SCREEN_TOUCH="false"

# Ensure config directory exists
sudo mkdir -p "$(dirname "$CONFIG_FILE")"

# Load config if it exists, otherwise prompt
if [ -f "$CONFIG_FILE" ]; then
  set -a          # Automatically export all sourced variables
  source "$CONFIG_FILE"
  set +a
else
  echo -e "[${RED}ERROR${NC}] Config file $CONFIG_FILE not found! Please run `sudo curl -fsSL https://raw.githubusercontent.com/socialites/rpi-srt-streamer/main/install.sh | sudo bash` to create it."
  exit 1
fi

# Function to generate config from template
generate_config() {
  local target_path="$1"

  if [[ -z "$target_path" ]]; then
    echo "[ERROR] generate_config requires a path as an argument"
    return 1
  fi

  local filename="$(basename "$target_path")"
  local url="${REPO_URL}/${filename}"

  if [[ "$filename" == *.template ]]; then
    local output_path="${target_path%.template}"

    echo "[INFO] Downloading template: $url"
    if ! curl -fsSL -o "/tmp/$filename" "$url"; then
      echo "[ERROR] Failed to download template $filename"
      return 1
    fi

    echo "[INFO] Expanding variables and saving to: $output_path"
    if ! envsubst < "/tmp/$filename" | sudo tee "$output_path" > /dev/null; then
      echo "[ERROR] Failed to write to $output_path"
      return 1
    fi

    rm -f "/tmp/$filename"
  else
    echo "[INFO] Downloading file: $url to $target_path"
    if ! curl -fsSL -o "$target_path" "$url"; then
      echo "[ERROR] Failed to download $filename"
      return 1
    fi
  fi
}


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
  i2c-tools python3-smbus gettext-base cmake

### === Clone and Build v4l2loopback === ###
echo "[INFO] Cloning and building v4l2loopback..."
if [ ! -d "/usr/src/v4l2loopback" ]; then
  git clone https://github.com/socialites/v4l2loopback.git /tmp/v4l2loopback
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
sudo curl -fsSL -o /tmp/usbreset.c "${REPO_URL}/usbreset.c"

gcc /tmp/usbreset.c -o usbreset
sudo mv usbreset /usr/local/bin/usbreset
sudo chown root:root /usr/local/bin/usbreset
sudo chmod u+s /usr/local/bin/usbreset
rm /tmp/usbreset.c
echo "[INFO] usbreset installed to /usr/local/bin/usbreset with setuid root"

### === Create Reset Script === ###
generate_config /usr/local/bin/reset-camlink.sh
sudo chmod +x /usr/local/bin/reset-camlink.sh

### === Create Network Watcher Script === ###
generate_config /usr/local/bin/network-watcher.sh
sudo chmod +x /usr/local/bin/network-watcher.sh

### === Create and Enable Network Watcher Service === ###
generate_config /etc/systemd/system/network-watcher.service

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
generate_config /usr/local/bin/srt-dashboard-server.py
sudo chmod +x /usr/local/bin/srt-dashboard-server.py

echo "[INFO] Creating srt-dashboard-server.service..."
generate_config /etc/systemd/system/srt-dashboard-server.service

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
export AUDIO_DEVICE="hw:${AUDIO_CARD},0"
echo "[INFO] Using audio device: $AUDIO_DEVICE"

### === Create systemd Service for SRT Streamer (Tee Pipeline) === ###
echo "[INFO] Creating SRT Streamer systemd service..."
generate_config /etc/systemd/system/srt-streamer.service.template

### === Load v4l2loopback Now === ###
echo "[INFO] Loading v4l2loopback module..."
sudo modprobe v4l2loopback devices=1 video_nr=1 card_label="Preview" exclusive_caps=1

echo "[INFO] Python web dashboard set up at http://$(hostname)/manage"

### === Setup Emergency Wi-Fi Access Point (always-on) === ###
echo "[INFO] Installing Wi-Fi Access Point dependencies..."
sudo apt-get install -y iw hostapd dnsmasq

echo "[INFO] Marking ap0 as unmanaged by NetworkManager..."
sudo mkdir -p /etc/NetworkManager/conf.d
generate_config /etc/NetworkManager/conf.d/unmanaged-ap0.conf

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
generate_config /etc/hostapd-ap0.conf.template

# Write dnsmasq config
generate_config /etc/dnsmasq-ap0.conf

# Create systemd service for hostapd
generate_config /etc/systemd/system/ap0-hostapd.service

# Create systemd service for dnsmasq
generate_config /etc/systemd/system/ap0-dnsmasq.service

# Create AP watchdog script
generate_config /usr/local/bin/check-ap0.sh
sudo chmod +x /usr/local/bin/check-ap0.sh

# Create systemd service for watchdog
generate_config /etc/systemd/system/ap0-watchdog.service

# Create systemd timer for watchdog
generate_config /etc/systemd/system/ap0-watchdog.timer

# Create splash only if it hasnt been created yet per our spec
if [ ! -f "/usr/share/plymouth/themes/pix/splashv1" ]; then
  echo "[INFO] Creating splash..."
  generate_config /usr/share/plymouth/themes/pix/splash.png
  sudo plymouth-set-default-theme -R pix
  sudo touch /usr/share/plymouth/themes/pix/splashv1
else
  echo "[INFO] Splash already exists, skipping."
fi

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
echo -e "[${GREEN}INFO${NC}] The service file is located at: ${YELLOW}/etc/systemd/system/srt-streamer.service${NC}"
echo -e "[${GREEN}INFO${NC}] The log file is located at: ${YELLOW}/var/log/srt-streamer.log${NC}"
echo -e "[${GREEN}INFO${NC}] Access Point '$SSID' is up. You can now connect and SSH to 192.168.50.1 in case you need to make any changes and you dont have a network connection."
echo -e "[${GREEN}INFO${NC}] You can now access the dashboard at http://$(hostname)"


if [[ $SCREEN == "true" && ($SCREEN_SIZE == "0096" || $SCREEN_SIZE == "0180") ]]; then
    # === Add OLED Support ===
    echo "[INFO] Small screen detected"
    echo -e "\n[INFO] === OLED Setup ($SCREEN_SIZE) ===\n"
    echo "[INFO] Installing OLED service..."

    echo "[INFO] Downloading fonts..."
    generate_config /usr/local/bin/PixelOperator.ttf
    sudo chmod 644 /usr/local/bin/PixelOperator.ttf
    generate_config /usr/local/bin/lineawesome-webfont.ttf
    sudo chmod 644 /usr/local/bin/lineawesome-webfont.ttf

    echo "[INFO] Creating oled.py..."
    sudo curl -L -o /usr/local/bin/oled.py "${REPO_URL}/oled${SCREEN_SIZE}.py"
    sudo chmod +x /usr/local/bin/oled.py

    sudo curl -fsSL -o /etc/systemd/system/oled.service "${REPO_URL}/oled.service"

    sudo systemctl daemon-reexec
    sudo systemctl daemon-reload
    sudo systemctl enable oled.service
    sudo systemctl start oled.service
fi

if [[ $SCREEN == "true" && $SCREEN_SIZE == "0350" ]]; then
    echo "[INFO] Installing Screen Interface..."
    sudo apt-get install -y chromium-browser xdotool unclutter

    mkdir -p /home/root/kiosk
    cd /home/root/kiosk
    generate_config /home/root/kiosk/start-kiosk.sh
    chmod +x /home/root/kiosk/start-kiosk.sh

    # Autostart setup
    AUTOSTART_FILE="/etc/xdg/lxsession/LXDE-pi/autostart"
    AUTOSTART_ENTRY="@/home/root/kiosk/start-kiosk.sh"
    AUTOSTART_TOUCH="@/home/root/kiosk/fix-touch.sh"

    if ! grep -Fxq "$AUTOSTART_ENTRY" "$AUTOSTART_FILE"; then
        echo "[INFO] Adding kiosk autostart entry to $AUTOSTART_FILE"
        echo "$AUTOSTART_ENTRY" | tee -a "$AUTOSTART_FILE" > /dev/null
    else
        echo "[INFO] Kiosk autostart entry already present."
    fi

    generate_config /home/root/kiosk/fix-touch.sh
    chmod +x /home/root/kiosk/fix-touch.sh

    if ! grep -Fxq "$AUTOSTART_TOUCH" "$AUTOSTART_FILE"; then
        echo "[INFO] Adding touch fix entry to $AUTOSTART_FILE"
        echo "$AUTOSTART_TOUCH" | tee -a "$AUTOSTART_FILE" > /dev/null
    else
        echo "[INFO] Touch fix entry already present."
    fi

    echo "[INFO] Kiosk setup complete. Reboot for it to launch."
fi

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

  if ! grep -q "otg_mode=1" "$BOOT_CONFIG"; then
    echo "[INFO] Enabling otg_mode=1 in $BOOT_CONFIG"
    echo -e "\n# Enable OTG mode\notg_mode=1" | sudo tee -a "$BOOT_CONFIG" > /dev/null
    REBOOT_NEEDED=true
  fi

  # Conditionally enable I2C if screen size is 0096 (i.e., OLED)
  if [ "$SCREEN_SIZE" == "0096" ]; then
    if ! grep -q "^dtparam=i2c_arm=on" "$BOOT_CONFIG"; then
      echo "[INFO] Enabling i2c_arm=on in $BOOT_CONFIG (for OLED screen)"
      echo -e "\n# Enable I2C for OLED\ndtparam=i2c_arm=on" | sudo tee -a "$BOOT_CONFIG" > /dev/null
      REBOOT_NEEDED=true
    fi
  fi

  # Enable SPI and install LCD35-show if using 3.5" TFT
  if [ "$SCREEN_SIZE" == "0350" ]; then
    if ! grep -q "dtoverlay=tft35a" "$BOOT_CONFIG"; then
      echo "[INFO] Installing TFT screen driver (LCD35-show)"
      # Backup config just in case
      [ ! -f "$BOOT_CONFIG.bak" ] && sudo cp "$BOOT_CONFIG" "$BOOT_CONFIG.bak"
     # Clone and run LCD-show with reboot disabled
     git clone https://github.com/socialites/LCD-show.git /tmp/LCD-show
     cd /tmp/LCD-show

        # Temporarily override reboot inside sudo call
        sudo bash -c '
            reboot() { echo "[INFO] Blocked reboot in LCD-show"; };
            export -f reboot;
            ./LCD35-show
        '

        # === Modify config.txt to set correct rotation ===
        echo "[INFO] Patching LCD-show config.txt rotation..."
        sudo sed -i 's/^dtoverlay=tft35a:rotate=90/dtoverlay=tft35a:rotate=0/' "$BOOT_CONFIG"

      REBOOT_NEEDED=true
    else
      echo "[INFO] TFT screen already configured. Skipping LCD35-show."
    fi
  fi

  if [ "$REBOOT_NEEDED" = true ]; then
    echo -e "[${YELLOW}INFO${NC}] USB power, OTG, and screen settings updated. Rebooting when finished"
  else
    echo "[INFO] USB power, OTG, and I2C/SPI settings already configured."
  fi
else
  echo "[INFO] Pi model not Pi 4 or Pi 5. Skipping USB current/OTG/I2C/SPI config."
fi

if [ "$REBOOT_NEEDED" = true ]; then
  echo -e "[${YELLOW}INFO${NC}] Rebooting..."
  sleep 5
  sudo reboot
  exit 0
fi

## TODO: Add rotation = 0 to config.txt

### === Enable and Start Streamer === ###
echo "[INFO] Enabling and starting SRT streamer service..."
sudo systemctl restart srt-streamer.service