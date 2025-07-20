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