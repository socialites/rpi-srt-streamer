#!/usr/bin/env python3
import asyncio
import json
import subprocess
import socket
import os
import aiohttp_cors
from aiohttp import web

PORT = 80
DASHBOARD_DIR = "/boot/firmware/rpi-srt-streamer-dashboard/dist"
WS_CLIENTS = set()

def get_ap_status_and_ssid():
    ap_status = "down"
    ssid = "unavailable"
    password = "not available"

    try:
        # Check if ap0 exists and is UP
        output = subprocess.check_output(["ip", "link", "show", "ap0"]).decode()
        if "UP" in output:
            # Get SSID and password from config
            try:
                with open("/etc/hostapd-ap0.conf", "r") as f:
                    for line in f:
                        if line.startswith("ssid="):
                            ssid = line.strip().split("=")[1]
                        elif line.startswith("wpa_passphrase="):
                            password = line.strip().split("=")[1]
                if ssid != "unavailable":
                    ap_status = "up"
                else:
                    ap_status = "down"
            except Exception:
                ap_status = "down"
    except subprocess.CalledProcessError:
        ap_status = "missing"

    return ap_status, ssid, password


# === HTTP ROUTES ===

async def health(request):
    return web.Response(text="ok")

async def status(request):
    ap_status, ssid, password = get_ap_status_and_ssid()

    result = {
        "hostname": subprocess.getoutput("hostname"),
        "ip": subprocess.getoutput("hostname -I").strip(),
        "network_watcher": subprocess.getoutput("systemctl is-active network-watcher.service"),
        "srt_streamer": subprocess.getoutput("systemctl is-active srt-streamer.service"),
        "ap_ssid": ssid,
        "ap_status": ap_status,
        "ap_password": password
    }
    return web.json_response(result)

async def network_stats():
    try:
        result = subprocess.check_output(["ifstat", "-q", "-T", "1", "1"], text=True)
        lines = [line.strip() for line in result.strip().splitlines()]
        interfaces = lines[0].split()
        values = lines[2].split()

        parsed = {}
        for i, iface in enumerate(interfaces):
            parsed[iface] = {
                "in_kbps": float(values[i * 2]),
                "out_kbps": float(values[i * 2 + 1])
            }

        relevant = ("enx", "eth", "wlan")
        return {
            k: v for k, v in parsed.items()
            if any(k.startswith(prefix) for prefix in relevant)
        }

    except Exception as e:
        return {"error": str(e)}

async def network(request):
    return web.json_response(await network_stats())


async def handle_post(request):
    path = request.path
    if path.startswith("/api/restart/"):
        service = path.split("/")[-1]
        if service in ("network-watcher", "srt-streamer"):
            subprocess.run(["sudo", "systemctl", "restart", f"{service}.service"])
            return web.Response(text=f"Restarted {service}")
        elif service == "camlink":
            subprocess.run(["sudo", "bash", "/usr/local/bin/reset-camlink.sh"])
            return web.Response(text="USB reset successful")
        elif service == "ap":
            subprocess.run(["sudo", "systemctl", "restart", "ap0-hostapd"])
            subprocess.run(["sudo", "systemctl", "restart", "ap0-dnsmasq"])
            return web.Response(text="Restarted access point")
    elif path == "/api/shutdown":
        subprocess.Popen(["sudo", "shutdown", "now"])
    elif path == "/api/reboot":
        subprocess.Popen(["sudo", "reboot"])
    elif path == "/api/run-install":
        subprocess.Popen(["sudo", "/usr/local/bin/update"])
    return web.Response(text="OK")

async def scan_networks(request):
    try:
        result = subprocess.check_output(["nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list"], text=True)
        networks = []
        for line in result.strip().splitlines():
            parts = line.strip().split(":")
            if len(parts) >= 2:
                ssid, signal = parts[0], parts[1]
                security = parts[2] if len(parts) > 2 else "UNKNOWN"
                if ssid:  # skip empty SSIDs
                    networks.append({"ssid": ssid, "signal": signal, "security": security})
        return web.json_response(networks)
    except subprocess.CalledProcessError as e:
        return web.Response(status=500, text=str(e))

async def connect_wifi(request):
    data = await request.json()
    ssid = data.get("ssid")
    password = data.get("password")
    if not ssid or not password:
        return web.Response(status=400, text="Missing SSID or password")

    try:
        subprocess.check_call(["nmcli", "device", "wifi", "connect", ssid, "password", password])
        return web.Response(status=200, text=f"Connected to {ssid}")
    except subprocess.CalledProcessError as e:
        return web.Response(status=500, text=str(e))

# === WEBSOCKET SUPPORT ===

async def websocket_handler(request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    WS_CLIENTS.add(ws)

    try:
        while not ws.closed:
            await asyncio.sleep(2)
            stats = await network_stats()
            await ws.send_str(json.dumps(stats))
    except:
        pass
    finally:
        WS_CLIENTS.remove(ws)
    return ws

# === APP SETUP ===
async def serve_index(request):
    return web.FileResponse(os.path.join(DASHBOARD_DIR, "index.html"))

app = web.Application()

# Configure CORS
cors = aiohttp_cors.setup(app, defaults={
    "*": aiohttp_cors.ResourceOptions(
        allow_credentials=True,
        expose_headers="*",
        allow_headers="*",
    )
})

routes = [
    web.get('/', serve_index),
    web.get('/health', health),
    web.get('/api/status', status),
    web.get('/api/network', network),
    web.get('/api/network/ws', websocket_handler),
    web.get('/api/wifi/networks', scan_networks),
    web.post('/api/wifi/connect', connect_wifi),
    web.post('/api/restart/{service}', handle_post),
    web.post('/api/shutdown', handle_post),
    web.post('/api/reboot', handle_post),
    web.post('/api/run-install', handle_post),
]

# Add normal routes
for route in routes:
    cors.add(app.router.add_route(route.method, route.path, route.handler))

# Add static route separately
app.router.add_static('/', DASHBOARD_DIR)

HLS_DIR = "/boot/firmware/hls"
os.makedirs(HLS_DIR, exist_ok=True)
app.router.add_static('/hls/', HLS_DIR, show_index=True)

# === Graceful Shutdown Hook ===
async def on_shutdown(app):
    print("[INFO] Shutting down... closing WebSocket clients.")
    for ws in list(WS_CLIENTS):
        await ws.close(code=1001, message="Server restarting")
    print("[INFO] WebSocket clients closed.")

app.on_shutdown.append(on_shutdown)

if __name__ == '__main__':
    web.run_app(app, port=PORT)