# 📡 Raspberry Pi SRT Streamer

This project turns a Raspberry Pi 5 into a **headless SRT streaming device** using a Camlink HDMI capture card and Tailscale to route the stream to your PC. This is very similar to what the LiveU Solo does, but with a Raspberry Pi and a Camlink.

## 🧰 Requirements

* **Raspberry Pi 5** (4GB RAM or better recommended)
* **64GB+ microSD card**
* **USB Camlink or HDMI capture device**
* **HDMI source (e.g., camera or console)**
* **Mobile data via USB tethering or USB modem**
* **Ubuntu Server 24.04+ (ARM64)**
* **Optional**: USB microphone or audio input via HDMI

## ⚙️ Features

* Auto-connects to Tailscale with your provided auth key
* Streams HDMI video + audio via SRT to a destination machine
* Starts streaming automatically on boot via `systemd`
* Logs stream output/errors to `/var/log/srt-streamer.log`

## 🔧 Setup Overview

### 1. Flash Ubuntu Server

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) on your Computer:

* Choose: `Other general purpose OS > Ubuntu Server 24.04 LTS (64-bit)`
* Before writing, click ⚙️ to:

  * Set hostname (srt-streamer)
  * Enable SSH (yes)
  * Set username & password (yes)
  * Configure Wi-Fi if needed (yes)

After flashing is complete, remove and re-insert the SD card into your Computer so the boot volume is mounted.

### 2. Add Install Script to `/Volumes/system-boot`

Copy `install-and-stream.sh` to the **boot volume (/Volumes/system-boot)** of the SD card. This script:

* Installs dependencies
* Connects to Tailscale using your auth key
* Detects Camlink audio automatically
* Prompts for configuration input
* Always regenerates the systemd service for consistency
* Creates a systemd service that:
  * Resets the Camlink USB device on service start
  * Streams `/dev/video0` and HDMI/USB audio
  * Sends via SRT to the specified destination

### 3. SSH In and Run the Script

Boot the Pi, then SSH in using the hostname or IP you set:

```bash
ssh youruser@srt-streamer.local
```

### NOTE: BEFORE YOU RUN THE NEXT STEP, MAKE SURE YOU ARE CONNECTED TO THE INTERNET ON THE PI. The script will fail if you are not connected to the internet. It needs to download and install dependencies.

Then run:

```bash
sudo /boot/firmware/install-and-stream.sh
```

You’ll be prompted to enter:

* Destination host
* SRT port
* Tailscale auth key

This creates `/opt/streamer/config.env`, which can be edited later.


### 4. Editing the `.env` Configuration (Optional)

If you need to, you can edit the environment file to change the SRT destination host, port, and Tailscale auth key:

```bash
sudo nano /opt/srt-streamer/config.env
```

Update the values to match your setup:

```env
DEST_HOST="your-desktop-hostname"
SRT_PORT="1234"
TAILSCALE_AUTH_KEY="tskey-auth-..."
```

### 4.1. Now, rerun the install-and-stream.sh script

This is so the script can read the configuration to regenerate the service file if changes were made to the configuration and start the streamer service

Then start/restart the streamer service:

```bash
sudo systemctl restart srt-streamer.service
```

## 🔁 Restart or Debug

To restart the stream:

```bash
sudo systemctl restart srt-streamer.service
```

To check logs:

```bash
cat /var/log/srt-streamer.log
```

To stream the logs to check for errors:
```bash
tail -f /var/log/srt-streamer.log
```

To edit configuration later:

```bash
sudo nano /opt/srt-streamer/config.env
sudo /boot/firmware/install-and-stream.sh
```

## 🧪 Notes

* If you’re using multiple Raspberry Pis, set each to a **unique SRT port** (e.g., `1234`, `1235`, etc.)
* You can monitor or forward the SRT stream using OBS, FFmpeg, or GStreamer on your PC
* `tailscale up` is run in unattended mode with your auth key
* The `.env` file at `/opt/srt-streamer/config.env` controls stream settings and can be safely edited anytime
* Camlink audio is auto-detected on startup; if the stream fails, try unplugging/replugging Camlink and restarting the service
* `usbreset` is compiled and used on service start to reset the Camlink device automatically, preventing the need for manual replugging
* The systemd service is regenerated every time the script is run, so changes to config are always applied
* If you don't have wifi, you can use a USB modem to connect to the internet or use a USB tethering cable to connect to your phone's hotspot
* This should also work if you're using USB Tethering for on-the-go internet.

## If you want steps similar to this for streaming from an iPhone or Android device, use this guide: [How to IRL Stream Using SRT](https://docs.google.com/document/d/1qCZKj1uLtIQqY1uPAj6MvxorYKMkjYO99lIei9hmMwg)