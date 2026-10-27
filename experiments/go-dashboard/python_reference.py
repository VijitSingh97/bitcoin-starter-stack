#!/usr/bin/env python3
import os
import sys


os.environ.update({
    "RPC_USER": "py",
    "RPC_PASSWORD": "fakepw",
    "DASHBOARD_CONTROL": "0",
    "TELEGRAM_BOT_TOKEN": "",
    "TELEGRAM_CHAT_ID": "",
    "HEALTHCHECKS_URL": "",
    "ALERT_NEW_BLOCK": "0",
    "WATCH_WALLETS_B64": "",
})
sys.path.insert(0, "/app")

import monitor
import node_status


node_status.RPC_URL = os.environ["BENCH_RPC_URL"]
monitor.check_updates = lambda _subversion, _state: None
node_status.main()
