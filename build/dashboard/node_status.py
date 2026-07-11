import hmac
import os
import shutil
import requests
import json
from flask import Flask, render_template_string, request, Response
from datetime import datetime

import monitor

app = Flask(__name__)

# --- CONFIGURATION ---
RPC_USER = os.environ["RPC_USER"]
RPC_PASSWORD = os.environ["RPC_PASSWORD"]
DASHBOARD_PASSWORD = os.environ.get("DASHBOARD_PASSWORD", "")
RPC_URL = 'http://172.29.0.26:8332'
BITCOIN_DIR = '/data'
DISK_WARN_FREE_GB = 50
STACK_VERSION = os.environ.get("STACK_VERSION", "dev")


def version_label():
    # "v1.3.0" for a real release, "dev" for an unversioned checkout
    return f"v{STACK_VERSION}" if STACK_VERSION and STACK_VERSION != "dev" else "dev"


@app.before_request
def check_auth():
    if not DASHBOARD_PASSWORD:
        return None
    auth = request.authorization
    if auth and auth.password and hmac.compare_digest(auth.password, DASHBOARD_PASSWORD):
        return None
    return Response("Authentication required", 401,
                    {"WWW-Authenticate": 'Basic realm="Bitcoin Node Status"'})

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

@app.route('/metrics')
def metrics():
    """Prometheus text format, hand-rolled — what the dashboard already knows."""
    lines = []

    def m(name, value):
        lines.append(f"# TYPE {name} gauge")
        lines.append(f"{name} {value}")

    blockchain = get_rpc_data("getblockchaininfo")
    if blockchain is None:
        m("bitcoin_node_up", 0)
    else:
        network = get_rpc_data("getnetworkinfo") or {}
        peers = get_rpc_data("getpeerinfo") or []
        inbound = sum(1 for p in peers if isinstance(p, dict) and p.get("inbound"))
        total, used, free = shutil.disk_usage(BITCOIN_DIR)
        m("bitcoin_node_up", 1)
        m("bitcoin_blocks", blockchain.get("blocks", 0))
        m("bitcoin_headers", blockchain.get("headers", 0))
        m("bitcoin_verification_progress", blockchain.get("verificationprogress", 0))
        m("bitcoin_pruned", int(blockchain.get("pruned", False)))
        m("bitcoin_size_on_disk_bytes", blockchain.get("size_on_disk", 0))
        m("bitcoin_disk_free_bytes", free)
        m("bitcoin_uptime_seconds", get_rpc_data("uptime") or 0)
        m("bitcoin_connections", network.get("connections", 0))
        lines.append("# TYPE bitcoin_peers gauge")
        lines.append(f'bitcoin_peers{{direction="in"}} {inbound}')
        lines.append(f'bitcoin_peers{{direction="out"}} {len(peers) - inbound}')
    return Response("\n".join(lines) + "\n", mimetype="text/plain; version=0.0.4")


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
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <title>Bitcoin Node Status</title>
                <link rel="stylesheet" href="/static/dashboard.css">
                <script>(()=>{try{const t=localStorage.getItem("dashboardTheme");document.documentElement.setAttribute("data-theme",(t==="light"||t==="dark")?t:"auto");}catch{document.documentElement.setAttribute("data-theme","auto");}})();</script>
            </head>
            <body class="center-screen">
                <canvas id="tower"></canvas>
                <button id="theme-toggle" class="theme-toggle" title="Toggle light / dark theme" aria-label="Toggle theme">Auto</button>
                <div id="live">
                <div class="loading-card">
                    <h2>Bitcoin Node Initializing</h2>
                    <div class="spinner"></div>
                    <p>Connecting to RPC at 172.29.0.26...</p>
                    <p style="color: var(--muted); font-size: 0.8rem;">The dashboard will load automatically when the node is ready.</p>
                    <p style="color: var(--faint); font-size: 0.7rem;">{{version}}</p>
                </div>
                </div>
                <script type="module" src="/static/tower.js"></script>
                <script type="module" src="/static/theme.js"></script>
                <script type="module" src="/static/refresh.js"></script>
            </body>
            </html>
        """, version=version_label())

    # Calculate Inbound vs Outbound
    inbound, outbound = 0, 0
    if isinstance(peers_list, list):
        for peer in peers_list:
            if peer.get('inbound'): inbound += 1
            else: outbound += 1
    
    # Calculate Disk
    node_bytes = blockchain.get("size_on_disk", 0)
    total, used, free = shutil.disk_usage(BITCOIN_DIR)
    free_gb = round(free / (1024**3), 2)
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
        "pruned": blockchain.get("pruned", False),
        "prune_target_gb": round(blockchain.get("prune_target_size", 0) / (1024**3), 1),
        "stack_version": version_label(),
        "node_gb": round(node_bytes / (1024**3), 2),
        "total_gb": round(total / (1024**3), 2),
        "free_gb": free_gb,
        "disk_warn": free_gb < DISK_WARN_FREE_GB,
        "disk_percent": round((node_bytes / total) * 100, 2) if total > 0 else 0,
        "last_update": last_update,
        # not "update": Jinja resolves stats.update to the dict METHOD, which
        # is always truthy and renders as its repr
        "update_note": monitor.update_available,
    }

    return render_template_string("""
    <html>
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Bitcoin Node Status</title>
        <link rel="stylesheet" href="/static/dashboard.css">
        <script>(()=>{try{const t=localStorage.getItem("dashboardTheme");document.documentElement.setAttribute("data-theme",(t==="light"||t==="dark")?t:"auto");}catch{document.documentElement.setAttribute("data-theme","auto");}})();</script>
    </head>
    <body class="center">
        <canvas id="tower"></canvas>
        <button id="theme-toggle" class="theme-toggle" title="Toggle light / dark theme" aria-label="Toggle theme">Auto</button>
        <div id="live">
        <div class="card">
            <h2>Bitcoin Node Status<span class="badge">{% if stats.pruned %}Pruned &middot; {{stats.prune_target_gb}} GB{% else %}Full{% endif %}</span></h2>
            <div class="row"><span class="label">Bitcoin Core:</span> <span>{{stats.version}}</span></div>
            <div class="row"><span class="label">Uptime:</span> <span>{{stats.uptime}}</span></div>
            <div class="row"><span class="label">Total Connections:</span> <span>{{stats.total_peers}}</span></div>
            <div class="peer-box">
                <div class="peer-tag">In: <span class="in">{{stats.inbound}}</span></div>
                <div class="peer-tag">Out: <span class="out">{{stats.outbound}}</span></div>
            </div>
            <hr>
            <div class="row"><span class="label">Blocks:</span> <span>{{stats.blocks}} / {{stats.headers}}</span></div>
            <div class="progress-bg"><div class="progress-fill" style="width: {{stats.progress}}%"></div></div>
            <div class="row"><span class="label">Sync Progress:</span> <span>{{stats.progress}}%</span></div>
            <hr>
            <div class="row"><span class="label">Node Data Size:</span> <span>{{stats.node_gb}} GB</span></div>
            <div class="row"><span class="label">Disk Capacity:</span> <span>{{stats.total_gb}} GB</span></div>
            <div class="row"><span class="label">Disk Usage:</span> <span>{{stats.disk_percent}}%</span></div>
            <div class="row"><span class="label">Disk Free:</span> <span {% if stats.disk_warn %}class="warn"{% endif %}>{{stats.free_gb}} GB{% if stats.disk_warn %} &#9888; LOW{% endif %}</span></div>
            {% if stats.update_note %}<div class="row" style="color: #f2a900; font-size: 0.8rem;">🆕 {{stats.update_note}}</div>{% endif %}
            <div class="footer">
                <span>Updated: {{stats.last_update}}</span>
                <span>{{stats.stack_version}}</span>
                <span>Auto-refresh: 30s</span>
            </div>
        </div>
        </div>
        <script type="module" src="/static/tower.js"></script>
        <script type="module" src="/static/theme.js"></script>
        <script type="module" src="/static/refresh.js"></script>
    </body>
    </html>
    """, stats=stats)

if __name__ == '__main__':
    import threading
    # Always runs: alerts and pings no-op individually when unconfigured,
    # and the update checker works regardless.
    threading.Thread(
        target=monitor.monitor_loop,
        args=(
            lambda: get_rpc_data("getblockchaininfo"),
            lambda: get_rpc_data("getnetworkinfo"),
        ),
        daemon=True,
    ).start()
    app.run(host='0.0.0.0', port=8000)