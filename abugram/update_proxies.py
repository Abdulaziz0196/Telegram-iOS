#!/usr/bin/env python3
"""Refresh abugram/proxies.txt, the MTProxy list the Abugram app downloads on launch.

Collects public MTProxy links, keeps the ones that accept a TCP connection, puts fake-TLS
("ee") proxies first because they survive DPI blocking best, and writes up to MAX_PROXIES lines.
"""
import concurrent.futures
import os
import socket
import sys
import time
import urllib.parse
import urllib.request

SOURCES = [
    "https://raw.githubusercontent.com/SoliSpirit/mtproto/master/all_proxies.txt",
    "https://raw.githubusercontent.com/ALIILAPRO/MTProtoProxy/main/mtproto.txt",
]
MAX_PROXIES = 60
TIMEOUT = 4.0
OUTPUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "proxies.txt")


def fetch(url):
    try:
        with urllib.request.urlopen(url, timeout=20) as response:
            return response.read().decode("utf-8", "replace")
    except Exception as error:  # a dead source must not stop the refresh
        print(f"source failed: {url}: {error}", file=sys.stderr)
        return ""


def parse(line):
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(line).query)
    try:
        host = query["server"][0].rstrip(".")
        port = int(query["port"][0])
        secret = query["secret"][0]
    except (KeyError, IndexError, ValueError):
        return None
    if not host or not 0 < port < 65536 or not secret:
        return None
    return host, port, secret


def is_fake_tls(secret):
    lowered = secret.lower()
    if lowered.startswith("ee"):
        return True
    try:
        import base64
        raw = base64.urlsafe_b64decode(secret + "=" * (-len(secret) % 4))
        return raw[:1] == b"\xee"
    except Exception:
        return False


def reachable(proxy):
    host, port, _ = proxy
    start = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=TIMEOUT):
            return proxy, time.monotonic() - start
    except OSError:
        return proxy, None


def main():
    proxies = {}
    for source in SOURCES:
        for line in fetch(source).splitlines():
            parsed = parse(line)
            if parsed:
                proxies.setdefault((parsed[0], parsed[1]), parsed)
    print(f"collected {len(proxies)} proxies")
    if not proxies:
        print("no proxies collected; keeping the existing list", file=sys.stderr)
        return

    alive = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
        for proxy, latency in pool.map(reachable, proxies.values()):
            if latency is not None:
                alive.append((not is_fake_tls(proxy[2]), latency, proxy))
    alive.sort()
    print(f"{len(alive)} reachable")
    if not alive:
        print("nothing reachable; keeping the existing list", file=sys.stderr)
        return

    lines = [
        "# Abugram built-in MTProxy list. The app downloads this file on every launch.",
        "# Updated automatically by .github/workflows/update-proxies.yml; one t.me/proxy link per line.",
    ]
    for _, _, (host, port, secret) in alive[:MAX_PROXIES]:
        lines.append("https://t.me/proxy?" + urllib.parse.urlencode({"server": host, "port": port, "secret": secret}))
    with open(OUTPUT, "w") as output:
        output.write("\n".join(lines) + "\n")
    print(f"wrote {len(lines) - 2} proxies to {OUTPUT}")


if __name__ == "__main__":
    main()
