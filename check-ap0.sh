#!/bin/bash

if ! ip link show ap0 &>/dev/null; then
  echo "[watchdog] ap0 missing, recreating..."

  iw dev wlan0 interface add ap0 type __ap || true
  ip addr add 192.168.50.1/24 dev ap0
  ip link set ap0 up

  systemctl restart ap0-hostapd
  systemctl restart ap0-dnsmasq
else
  echo "[watchdog] ap0 is up"
fi