# 📡 Raspberry Pi SRT Streamer <!--- {ignore=true} -->

This project turns a Raspberry Pi 5 into a **headless SRT streaming device** using a Camlink HDMI capture card and Tailscale to route the stream to your PC. This is very similar to what the LiveU Solo does, but with a Raspberry Pi and a Camlink.

The full setup is very similar to the [GUNRUN IRL Backpack](https://www.unlimitedirl.com/backpacks), but with a Raspberry Pi instead of the LiveU Solo PRO Bonding Encoder.

Another comparable package is the [BELABOX](https://belabox.net/)

## Great For: <!--- {ignore=true} -->

- Mobile Streaming setup
- Multi-camera setup at home (i.e., kitchen stream, bedroom stream, office stream, etc.)
- Wirelessly streaming from a DSLR or any other HDMI source (e.g., a Nintendo Switch)

## Table of Contents <!--- {ignore=true} -->
<!-- @import "[TOC]" {cmd="toc" depthFrom=1 depthTo=6 orderedList=false} -->

<!-- code_chunk_output -->

  - [🧰 Requirements](#-requirements)
  - [⚙️ Features](#️-features)
  - [🔧 Setup Overview](#-setup-overview)
    - [4. (Optional) Editing the `.env` Configuration](#4-optional-editing-the-env-configuration)
- [Technical Details](#technical-details)
  - [🧪 Notes](#-notes)
  - [If you want steps similar to this for streaming from an iPhone or Android device, use this guide: How to IRL Stream to your PC from Anywhere](#if-you-want-steps-similar-to-this-for-streaming-from-an-iphone-or-android-device-use-this-guide-how-to-irl-stream-to-your-pc-from-anywherehttpsdocsgooglecomdocumentd1qczkj1ultiqqy1upaj6mvxorykmkjyo99liei9hmmwg)
  - [Useful Commands](#useful-commands)

<!-- /code_chunk_output -->



## 🧰 Requirements

* **Raspberry Pi 5** (4GB RAM or better recommended)
* **100W USB-C Cable** (Because it likely will be 20W/5A which is the amperage we need to power the Pi + peripherals)
* **100W Battery pack capable of outputting 5A** (Because the Pi will be running on battery power if you're on the go and we need to make sure it has enough power to run)
* **16GB+ microSD card**
* **USB Camlink or HDMI capture device**
* **HDMI source (e.g., camera or console)**
* **Mobile data via USB tethering or USB modem**
* **Raspberry Pi OS 32 bit**
* **Optional**: USB microphone or audio input via HDMI

## ⚙️ Features

* Auto-connects to Tailscale with your provided auth key
* Streams HDMI video + audio via SRT to a destination machine
* Starts streaming automatically on boot via `systemd`
* Logs stream output/errors to `/var/log/srt-streamer.log`
* Displays a dashboard on an OLED screen with the stream status, SRT stats, and more.
* Creates a web-accessible dashboard at `http://your-pi-hostname/` to view information about the stream.
* Creates a fallback Wi-Fi Access Point (AP) with the SSID and password you provided. This is useful if you're on the go and don't have a network connection but need to connect to the Pi to manage anything.


## 🔧 Setup Overview

### 0. (Optional) Install a screen

If you want to install a screen, connect it to the GPIO pins on the Pi.
You can use a breadboard to connect the screen to the Pi if thats easier for you.

The GPIO pins are as follows:

0.96" OLED Screen:
* VCC: Pin 1 (3.3V)
* GND: Pin 9 (GND)
* SDA: Pin 3 (GPIO2)
* SCL: Pin 5 (GPIO3)

[0.96" OLED Screen YouTube Refrence](https://youtu.be/pdaDvPCdAlY?t=123)





### 1. Flash Ubuntu Server <!--- {ignore=true} -->

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) on your Computer:

* Choose: `Other general purpose OS > Ubuntu Server 24.04 LTS (64-bit)`
* Before writing, click ⚙️ to:

  * Set hostname (`your-pi-hostname`)
    * **NOTE: If setting up multiple pis, make sure to set a unique hostname for each one or append a number to the end of the hostname (e.g. `your-pi-hostname-1`, `your-pi-hostname-2`, etc.)**
  * Enable SSH (yes)
  * Set username & password (yes)
  * Configure Wi-Fi **(yes if you want to SSH in to configure the Pi. You wont need this if you're connecting the Pi to a monitor and have a separate keyboard and mouse to use.)**

After flashing is complete, remove the card from the computer and insert it into the Pi.

### 2. Connect the Pi to your network <!--- {ignore=true} -->

If you configured your Wifi settings in the Raspberry Pi Imager, you can skip this step.

Otherwise, connect the Pi to your network using the Ethernet cable.

### 3. SSH In and Run the Script <!--- {ignore=true} -->

Boot the Pi, then SSH in using the hostname or IP you set:

```bash
ssh youruser@your-pi-hostname.local
```

### NOTE: BEFORE YOU RUN THE NEXT STEP, MAKE SURE YOU ARE CONNECTED TO THE INTERNET ON THE PI. The script will fail if you are not connected to the internet. It needs to download and install dependencies. <!--- {ignore=true} -->

Run the following command to run the install script:

```bash
sudo curl -fsSL https://raw.githubusercontent.com/socialites/rpi-srt-streamer/main/install.sh | sudo bash
```

You’ll be prompted to enter:

* Destination host
* SRT port
* Tailscale auth key

This creates `/opt/streamer/config.env`, which can be edited later.

This script:
* Creates an update script in `/usr/local/bin/update` that can be used to update the system to the latest version if you notice any issues or want to update to the latest features. Just run `sudo update` to update the system.
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
* The Pi will reboot after the script is run to apply the changes
* The Pi will start streaming automatically on boot.
* You can access the Pi's web interface at `http://your-pi-hostname/` to view the dashboard.
* The Pi will create a fallback Wi-Fi Access Point (AP) with the SSID and password you provided. This is useful if you're on the go and don't have a network connection but need to connect to the Pi to manage anything.
* The Pi will create an OLED display script if you have one.

> [!TIP]
> I would recommend [disabling Key Expiry in Tailscale](https://tailscale.com/kb/1028/key-expiry#disabling-key-expiry). This will allow you to use the same auth key for a longer period of time and you wont have to SSH in re-authenticate every 90 or 180 days when the key expires. You can do this from the Tailscale dashboard.

> [!NOTE]
> If anything went wrong during the intall, you can use the `sudo update` command to re-run the install script or just re-run the command `sudo curl -fsSL https://raw.githubusercontent.com/socialites/rpi-srt-streamer/main/install.sh | sudo bash`.

### You're now ready to stream! 🎉 <!--- {ignore=true} -->

## Everything below this point is optional. <!--- {ignore=true} -->

### 4. (Optional) Editing the `.env` Configuration

If you need to, you can edit the environment file to change the SRT destination host, port, and Tailscale auth key:

```bash
sudo nano /opt/srt-streamer/config.env
```

Update the values to match your setup:

```env
DEST_HOST="your-desktop-hostname"
SRT_PORT="1234"
TAILSCALE_AUTH_KEY="tskey-auth-..."
SSID="SRTStreamer"
PASSWORD="mypassword"
SCREEN="false" # true or false
SCREEN_SIZE="0096" # 0096, 0180, 0350, 0400
SCREEN_RGB="false" # true or false
SCREEN_TOUCH="false" # true or false
```

### 4.1. Now, rerun the `sudo update` command  <!--- {ignore=true} -->
You can also rerun the script from the dashboard: `http://your-pi-hostname/` "Restart Install and Stream" button.

This is so the script can read the configuration to regenerate the service file if changes were made to the configuration and start the streamer service


# Technical Details

## 🔁 Restart or Debug <!--- {ignore=true} -->

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

To edit configuration later using `nano` or `vim`:

```bash
sudo nano /opt/srt-streamer/config.env
sudo update
```

To update the system to the latest version:

```bash
sudo update
```

## 🧪 Notes

* Why a Raspberry Pi 5? Because its currently the most powerful Raspberry Pi and it has 4GB of RAM which is more than enough for most streaming needs. It also has a power button that can be used to easily turn the Pi on and off, and by default the USB ports can output 600mA but can be increased to 1.2A with the config script. All these benefits make it the best choice for this project.
* If you’re using multiple Raspberry Pis, set each to a **unique SRT port** (e.g., `1234`, `1235`, etc.)
* `tailscale up` is run in unattended mode with your auth key
* The `.env` file at `/opt/srt-streamer/config.env` controls stream settings and can be safely edited anytime
* Camlink audio is auto-detected on startup
* If the stream fails, try unplugging/replugging Camlink and restarting the service
* `usbreset` is compiled and used on service start to reset the Camlink device automatically, preventing the need for manual replugging
* The `systemd` service is regenerated every time the script is run, so changes to config are always applied
* If you don't have wifi, you can use a USB modem to connect to the internet or use a USB tethering cable to connect to your phone's hotspot
* This should also work if you're using USB Tethering for on-the-go internet.
* When using USB Tethering, the USB Device must be on the USB2.0 port on the Pi while the Camlink must be on the USB3.0 port. If you put both on the USB3.0 port, the Pi will not be able to connect to the internet because of the power limitations.
* To check if the Pi is connected to the internet, you can run `ping -s 8 -c 1 srt-streamer` from your phone. If you get a response, the Pi is connected to the internet.
* If you plug a 4G/5G/LTE Modem or USB Wifi Dongle into the Pi, you can use it to connect to the internet. It will be `wlan1`

## If you want steps similar to this for streaming from an iPhone or Android device, use this guide: [How to IRL Stream to your PC from Anywhere](https://docs.google.com/document/d/1qCZKj1uLtIQqY1uPAj6MvxorYKMkjYO99lIei9hmMwg)

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

```bash
journalctl -u ap0-hostapd --no-pager
```

Show logs for a specific service:
```bash
journalctl -u srt-streamer.service --no-pager
```

Show logs for a specific service and follow the logs:
```bash
journalctl -u srt-streamer.service --no-pager -f
```

[Reference for TFT Screen](https://www.cytron.io/tutorial/3.5-inch-TFT-RPI5)
[RPI Pinout](https://vilros.com/pages/raspberry-pi-5-pinout)
Some guides that didnt work:


https://vilros.com/pages/raspberry-pi-5-pinout


https://www.lcdwiki.com/3.5inch_SPI_Module_ILI9488_SKU:MSP3520