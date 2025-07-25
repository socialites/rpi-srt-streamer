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
        result = subprocess.check_output([
            "nmcli", "-t", "-f", "IN-USE,SSID,RATE,SIGNAL,SECURITY", "device", "wifi", "list"
        ], text=True)

        networks = []
        for line in result.strip().splitlines():
            parts = line.split(":")
            if len(parts) >= 5:
                in_use = parts[0].strip() == "*"
                ssid = parts[1].strip()
                rate = parts[2].strip()
                signal = int(parts[3].strip())
                security = parts[4].strip() or "UNKNOWN"

                if ssid:  # skip blank SSIDs
                    networks.append({
                        "ssid": ssid,
                        "in_use": in_use,
                        "rate": rate,
                        "signal": signal,
                        "security": security
                    })

        return web.json_response(networks)

    except subprocess.CalledProcessError as e:
        return web.Response(status=500, text=f"Error scanning Wi-Fi networks: {str(e)}")

async def connect_wifi(request):
    data = await request.json()
    ssid = data.get("ssid")
    password = data.get("password")

    if not ssid:
        return web.Response(status=400, text="Missing SSID")

    # Build the nmcli connect command
    cmd = ["nmcli", "device", "wifi", "connect", ssid]
    if password:
        cmd += ["password", password]

    try:
        # Run in executor to avoid blocking the event loop
        loop = asyncio.get_event_loop()
        result = await loop.run_in_executor(None, lambda: subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True))

        # Confirm active connection switched
        check_cmd = ["nmcli", "-t", "-f", "ACTIVE,SSID", "dev", "wifi"]
        active_output = await loop.run_in_executor(None, lambda: subprocess.check_output(check_cmd, text=True))
        active_ssid = None
        for line in active_output.splitlines():
            if line.startswith("yes:"):
                active_ssid = line.split(":")[1]
                break

        if active_ssid == ssid:
            return web.json_response({"status": "success", "message": f"Connected to {ssid}"})
        else:
            return web.json_response({"status": "partial", "message": f"Tried connecting to {ssid}, but it's not the active connection"}, status=202)

    except subprocess.CalledProcessError as e:
        # Check common failure reasons
        error_output = e.output.strip() if hasattr(e, 'output') else str(e)
        if "No network with SSID" in error_output:
            msg = f"Network '{ssid}' not found."
        elif "secrets were required" in error_output or "wrong password" in error_output.lower():
            msg = "Wrong password or authentication failed."
        else:
            msg = f"Failed to connect: {error_output}"

        return web.json_response({"status": "error", "message": msg}, status=500)

async def forget_wifi(request):
    data = await request.json()
    ssid = data.get("ssid")

    if not ssid:
        return web.Response(status=400, text="Missing SSID")

    loop = asyncio.get_event_loop()

    try:
        # First find the connection name (can be different from SSID)
        conns = await loop.run_in_executor(
            None,
            lambda: subprocess.check_output(["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"], text=True)
        )

        matching_profiles = [
            line.split(":")[0]
            for line in conns.strip().splitlines()
            if line.startswith(ssid + ":wifi")
        ]

        if not matching_profiles:
            return web.json_response({"status": "not_found", "message": f"No saved connection for '{ssid}'"}, status=404)

        for profile in matching_profiles:
            await loop.run_in_executor(None, lambda: subprocess.check_call(["nmcli", "connection", "delete", profile]))

        return web.json_response({"status": "success", "message": f"Deleted profile(s) for '{ssid}'"})

    except subprocess.CalledProcessError as e:
        return web.Response(status=500, text=f"Failed to forget Wi-Fi: {e}")

async def disconnect_wifi(request):
    data = await request.json()
    ssid = data.get("ssid")

    if not ssid:
        return web.Response(status=400, text="Missing SSID")

    loop = asyncio.get_event_loop()

    try:
        # Attempt to bring down the Wi-Fi connection by SSID
        await loop.run_in_executor(None, lambda: subprocess.check_call(["nmcli", "connection", "down", ssid]))

        return web.json_response({"status": "success", "message": f"Disconnected from '{ssid}'"})

    except subprocess.CalledProcessError as e:
        return web.Response(status=500, text=f"Failed to disconnect: {e}")
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
    web.post('/api/wifi/forget', forget_wifi),
    web.post('/api/wifi/disconnect', disconnect_wifi),
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