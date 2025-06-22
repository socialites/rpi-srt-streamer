# 📡 Raspberry Pi SRT Streamer

This project turns a Raspberry Pi 5 into a **headless SRT streaming device** using a Camlink HDMI capture card and Tailscale to route the stream to your PC. This is very similar to what the LiveU Solo does, but with a Raspberry Pi and a Camlink.

The full setup is very similar to the [GUNRUN IRL Backpack](https://www.unlimitedirl.com/backpacks), but with a Raspberry Pi instead of the LiveU Solo PRO Bonding Encoder.

Another comparable package is the [BELABOX](https://belabox.net/)

## Great For:

- Mobile Streaming setup
- Multi-camera setup at home (i.e., kitchen stream, bedroom stream, office stream, etc.)
- Wirelessly streaming from a DSLR or any other HDMI source (e.g., a Nintendo Switch)

## 🧰 Requirements

* **Raspberry Pi 5** (4GB RAM or better recommended)
* **100W USB-C Cable** (Because it likely will be 20W/5A which is the amperage we need to power the Pi + peripherals)
* **100W Battery pack capable of outputting 5A** (Because the Pi will be running on battery power if you're on the go and we need to make sure it has enough power to run)
* **16GB+ microSD card**
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

  * Set hostname (srt-streamer) NOTE: If setting up multiple pis, make sure to set a unique hostname for each one or append a number to the end of the hostname (e.g. srt-streamer-1, srt-streamer-2, etc.)
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
  * Checks usb0, eth0, and wlan0 (in that order) for a valid connection and sets the default route to the first one found
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

* Why a Raspberry Pi 5? Because its currently the most powerful Raspberry Pi and it has 4GB of RAM which is more than enough for most streaming needs. It also has a pwoer button that can be used to easily turn the Pi on and off, and by default the USB ports can output 600mA but can be increased to 1.2A with the config script. All these benefits make it the best choice for this project.
* If you’re using multiple Raspberry Pis, set each to a **unique SRT port** (e.g., `1234`, `1235`, etc.)
* You can monitor or forward the SRT stream using OBS, FFmpeg, or GStreamer on your PC
* `tailscale up` is run in unattended mode with your auth key
* The `.env` file at `/opt/srt-streamer/config.env` controls stream settings and can be safely edited anytime
* Camlink audio is auto-detected on startup; if the stream fails, try unplugging/replugging Camlink and restarting the service
* `usbreset` is compiled and used on service start to reset the Camlink device automatically, preventing the need for manual replugging
* The systemd service is regenerated every time the script is run, so changes to config are always applied
* If you don't have wifi, you can use a USB modem to connect to the internet or use a USB tethering cable to connect to your phone's hotspot
* This should also work if you're using USB Tethering for on-the-go internet.
* When using USB Tethering, the USB Device must be on the USB2.0 port on the Pi while the Camlink must be on the USB3.0 port. If you put both on the USB3.0 port, the Pi will not be able to connect to the internet because of the power limitations.
* To check if the Pi is connected to the internet, you can run `ping -s 8 -c 1 srt-streamer` from your phone. If you get a response, the Pi is connected to the internet.

## If you want steps similar to this for streaming from an iPhone or Android device, use this guide: [How to IRL Stream Using SRT](https://docs.google.com/document/d/1qCZKj1uLtIQqY1uPAj6MvxorYKMkjYO99lIei9hmMwg)

## Useful Commands
```bash
watch -n 1 'echo -n "srt-streamer: "; systemctl is-active srt-streamer; echo -n "network-watcher: "; systemctl is-active network-watcher'
```
Output will look like:
```bash
srt-streamer: active
network-watcher: active
```

```bash
watch -n 2 'systemctl status srt-streamer --no-pager -n 5; echo "----------------------"; systemctl status network-watcher --no-pager -n 5'
```
Shows last 5 log lines for each every 2 seconds