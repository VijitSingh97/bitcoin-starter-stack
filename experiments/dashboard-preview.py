#!/usr/bin/env python3
"""Render the real dashboard with public and fictional data for README screenshots."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("fixture", ROOT / "experiments/go-dashboard/fixture.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
fixture.RESULTS["getblockchaininfo"].update(blocks=973490, headers=973490)
fixture.RESULTS["getpeerinfo"] = [{"inbound": i < 3} for i in range(10)]
fixture.RESULTS["listwalletdir"] = {"wallets": []}
fixture.RESULTS["listwallets"] = []


class Preview(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass

    def do_GET(self):
        if self.path == "/api/watch":
            body = json.dumps({
                "has_password": True,
                "wallets": [
                    {
                        "name": "Binance (public)",
                        "display_name": "Binance",
                        "key": "34xp4vRoCGJym3xR7yCVPFHoCNxv4Twseo",
                        "state": "ok",
                        "btc": "248597.59296263",
                        "example": True,
                        "history": [],
                    },
                    {
                        "name": "Your Wallet",
                        "key": "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
                        "state": "scanning",
                        "btc": None,
                        "history": [],
                    },
                ],
                "show_total": False,
                "total": None,
                "total_state": "pending",
            }).encode()
            content_type = "application/json"
        elif self.path == "/api/prices":
            body = json.dumps({
                "available": True,
                "stale": False,
                "updated_at": int(time.time()),
                "prices": {"usd": 102500, "eur": 88200, "gbp": 76700, "inr": 9100000,
                           "cad": 143000, "aud": 157000, "jpy": 15600000,
                           "rub": 8400000, "cny": 729000},
            }).encode()
            content_type = "application/json"
        else:
            try:
                with urlopen("http://127.0.0.1:18092" + self.path, timeout=5) as response:
                    body = response.read()
                    content_type = response.headers.get("Content-Type", "application/octet-stream")
            except OSError:
                self.send_error(503)
                return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="bss-screenshot-") as directory:
        binary = Path(directory) / "dashboard"
        dashboard = ROOT / "build/dashboard"
        subprocess.run(["go", "build", "-o", str(binary), "."], cwd=dashboard, check=True)
        rpc = ThreadingHTTPServer(("127.0.0.1", 18091), fixture.Handler)
        threading.Thread(target=rpc.serve_forever, daemon=True).start()
        env = dict(os.environ, RPC_URL="http://127.0.0.1:18091", RPC_USER="go", RPC_PASSWORD="fakepw",
                   STATE_DIR=directory, DATA_DIR=directory, PORT="18092", WATCH_WALLETS_B64="W10=",
                   STACK_VERSION="Go dashboard preview", TELEGRAM_BOT_TOKEN="", TELEGRAM_CHAT_ID="",
                   HEALTHCHECKS_URL="", DASHBOARD_PASSWORD="", DASHBOARD_CONTROL="0")
        process = subprocess.Popen([str(binary)], cwd=dashboard, env=env)
        try:
            print("Sanitized screenshot preview: http://127.0.0.1:18090", flush=True)
            ThreadingHTTPServer(("127.0.0.1", 18090), Preview).serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            process.terminate()
            process.wait(timeout=10)
            rpc.shutdown()
