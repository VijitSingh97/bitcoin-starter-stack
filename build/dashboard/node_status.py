import os
import shutil
import requests
import json
from flask import Flask, render_template_string
from datetime import datetime

app = Flask(__name__)

# --- CONFIGURATION ---
RPC_USER = os.environ["RPC_USER"]
RPC_PASSWORD = os.environ["RPC_PASSWORD"]
RPC_URL = 'http://172.29.0.26:8332'
BITCOIN_DIR = '/data'

def get_rpc_data(method):
    payload = json.dumps({"jsonrpc": "1.0", "id": "dashboard", "method": method, "params": []})
    try:
        response = requests.post(RPC_URL, auth=(RPC_USER, RPC_PASSWORD), data=payload, timeout=3)
        if response.status_code == 200:
            return response.json().get('result', {})
        return None
    except Exception as e:
        print(f"RPC Error ({method}): {e}")
        return None

def format_uptime(seconds):
    if seconds is None or not isinstance(seconds, (int, float)):
        return "N/A"
    days, rem = divmod(int(seconds), 86400)
    hours, rem = divmod(rem, 3600)
    minutes, _ = divmod(rem, 60)
    return f"{days}d {hours}h {minutes}m" if days > 0 else f"{hours}h {minutes}m"

@app.route('/')
def index():
    # Fetch core data
    blockchain = get_rpc_data("getblockchaininfo")
    network = get_rpc_data("getnetworkinfo")
    peers_list = get_rpc_data("getpeerinfo")
    uptime_seconds = get_rpc_data("uptime")
    
    # If blockchain info is missing, the node isn't ready
    if blockchain is None:
        return render_template_string("""
            <html>
            <head>
                <meta http-equiv="refresh" content="5">
                <style>
                    body { font-family: sans-serif; background: #0f0f0f; color: #e0e0e0; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
                    .loading-card { background: #1a1a1a; padding: 30px; border-radius: 12px; border: 1px solid #f2a900; text-align: center; }
                    .spinner { border: 4px solid #333; border-top: 4px solid #f2a900; border-radius: 50%; width: 40px; height: 40px; animation: spin 1s linear infinite; margin: 20px auto; }
                    @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
                </style>
            </head>
            <body>
                <div class="loading-card">
                    <h2 style="color: #f2a900;">Bitcoin Node Initializing</h2>
                    <div class="spinner"></div>
                    <p>Connecting to RPC at 172.29.0.26...</p>
                    <p style="color: #888; font-size: 0.8rem;">The dashboard will load automatically when the node is ready.</p>
                </div>
            </body>
            </html>
        """)

    # Calculate Inbound vs Outbound
    inbound, outbound = 0, 0
    if isinstance(peers_list, list):
        for peer in peers_list:
            if peer.get('inbound'): inbound += 1
            else: outbound += 1
    
    # Calculate Disk
    node_bytes = blockchain.get("size_on_disk", 0)
    total, used, free = shutil.disk_usage(BITCOIN_DIR)
    last_update = datetime.now().strftime("%H:%M:%S")
    
    stats = {
        "version": network.get("subversion", "Unknown") if network else "Unknown",
        "uptime": format_uptime(uptime_seconds),
        "blocks": blockchain.get("blocks", "N/A"),
        "headers": blockchain.get("headers", "N/A"),
        "progress": round(blockchain.get("verificationprogress", 0) * 100, 4),
        "total_peers": network.get("connections", 0) if network else 0,
        "inbound": inbound,
        "outbound": outbound,
        "node_gb": round(node_bytes / (1024**3), 2),
        "total_gb": round(total / (1024**3), 2),
        "disk_percent": round((node_bytes / total) * 100, 2) if total > 0 else 0,
        "last_update": last_update
    }

    return render_template_string("""
    <html>
    <head>
        <title>Bitcoin Node Status</title>
        <meta http-equiv="refresh" content="30">
        <style>
            body { font-family: -apple-system, sans-serif; background: #0f0f0f; color: #e0e0e0; display: flex; justify-content: center; padding-top: 50px; }
            .card { background: #1a1a1a; border-radius: 12px; padding: 25px; width: 420px; box-shadow: 0 8px 32px rgba(0,0,0,0.8); border: 1px solid #333; position: relative; }
            h2 { color: #f2a900; margin-top: 0; font-size: 1.5rem; border-bottom: 1px solid #333; padding-bottom: 10px; }
            .row { display: flex; justify-content: space-between; margin: 12px 0; font-family: monospace; font-size: 0.95rem; }
            .label { color: #888; }
            .peer-box { display: flex; gap: 10px; font-size: 0.8rem; margin-top: -5px; margin-bottom: 10px; }
            .peer-tag { background: #222; padding: 2px 8px; border-radius: 4px; border: 1px solid #444; }
            .in { color: #4caf50; }
            .out { color: #2196f3; }
            .progress-bg { background: #333; height: 10px; border-radius: 5px; margin: 15px 0; overflow: hidden; }
            .progress-fill { background: #f2a900; height: 100%; width: {{stats.progress}}%; transition: width 1s; }
            hr { border: 0; border-top: 1px solid #333; margin: 20px 0; }
            .footer { color: #444; font-size: 0.7rem; text-align: center; margin-top: 10px; display: flex; justify-content: space-between; }
        </style>
    </head>
    <body>
        <div class="card">
            <h2>Bitcoin Node Status</h2>
            <div class="row"><span class="label">Version:</span> <span>{{stats.version}}</span></div>
            <div class="row"><span class="label">Uptime:</span> <span>{{stats.uptime}}</span></div>
            <div class="row"><span class="label">Total Connections:</span> <span>{{stats.total_peers}}</span></div>
            <div class="peer-box">
                <div class="peer-tag">In: <span class="in">{{stats.inbound}}</span></div>
                <div class="peer-tag">Out: <span class="out">{{stats.outbound}}</span></div>
            </div>
            <hr>
            <div class="row"><span class="label">Blocks:</span> <span>{{stats.blocks}} / {{stats.headers}}</span></div>
            <div class="progress-bg"><div class="progress-fill"></div></div>
            <div class="row"><span class="label">Sync Progress:</span> <span>{{stats.progress}}%</span></div>
            <hr>
            <div class="row"><span class="label">Node Data Size:</span> <span>{{stats.node_gb}} GB</span></div>
            <div class="row"><span class="label">Disk Capacity:</span> <span>{{stats.total_gb}} GB</span></div>
            <div class="row"><span class="label">Disk Usage:</span> <span>{{stats.disk_percent}}%</span></div>
            <div class="footer">
                <span>Updated: {{stats.last_update}}</span>
                <span>Auto-refresh: 30s</span>
            </div>
        </div>
    </body>
    </html>
    """, stats=stats)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000)