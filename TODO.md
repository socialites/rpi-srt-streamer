Try magiclantern for camera to remove focus square and keep on indefinitely

Field Rescue Terminal (Bluetooth)
Field Rescue Terminal USB SSH

Maybe switch restarts to "start" and "stop"?

After reboot or shutdown, call the refresh status? After the other reboots, call it too?

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