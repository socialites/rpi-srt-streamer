Web portal for each pi? or a center client for all pis

A health check endpoint that can be hit, simple web server running on the pi that can be hit from the phone to check if the Pi is connected to the internet. (http://srt-streamer/health) or a simple interface that does (ping -s 8 -c 1 srt-streamer)

Try magiclantern for camera to remove focus square and keep on indefinitely

Field Rescue Terminal (Bluetooth)

3. Use curl to a lightweight local HTTP server (optional)
If you add a minimal HTTP server on the Pi, you can curl http://srt-streamer:80/health from your phone and have the Pi respond with a 200 OK. Minimal footprint, no stream interference.
