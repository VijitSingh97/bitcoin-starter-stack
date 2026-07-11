"""Lightweight operational alerts for a single node.

Telegram gets a short message on real state transitions (debounced, one per
incident); Healthchecks.io gets a periodic dead-man ping so an outside service
notices when this whole box goes dark — the one failure a monitor running on
the box can never report. Both are off until configured, and both ride the
stack's Tor SOCKS proxy so neither is a clearnet beacon.
"""
import os
import shutil
import time

import requests

TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")
HEALTHCHECKS_URL = os.environ.get("HEALTHCHECKS_URL", "").strip().rstrip("/")
NODE_NAME = os.environ.get("NODE_NAME", "bitcoin-node")

TOR_PROXY = "socks5h://172.29.0.25:9050"  # socks5h: DNS resolves through Tor too
PROXIES = {"http": TOR_PROXY, "https": TOR_PROXY}

TICK_SECONDS = 60
PING_EVERY_TICKS = 5   # healthchecks cadence: every 5 minutes
DOWN_AFTER_TICKS = 3   # debounce: this many consecutive RPC failures = down
DISK_WARN_FREE_GB = 50


def enabled():
    return bool(TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID) or bool(HEALTHCHECKS_URL)


def send_telegram(text):
    if not (TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID):
        return
    try:
        requests.post(
            f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage",
            json={"chat_id": TELEGRAM_CHAT_ID, "text": f"[{NODE_NAME}] {text}"},
            proxies=PROXIES, timeout=30,
        )
    except Exception as e:
        print(f"Telegram send failed: {e}")


def ping_healthchecks(healthy):
    if not HEALTHCHECKS_URL:
        return
    url = HEALTHCHECKS_URL if healthy else HEALTHCHECKS_URL + "/fail"
    try:
        requests.get(url, proxies=PROXIES, timeout=10)
    except Exception as e:
        print(f"Healthchecks ping failed: {e}")


def tick(get_blockchain_info, state, disk_path="/data"):
    """One monitoring pass. A small state machine: alerts fire on transitions,
    never repeatedly. Everything observable is injected so tests can drive it."""
    info = get_blockchain_info()
    healthy = info is not None

    if healthy:
        if state.get("down_alerted"):
            send_telegram("🟢 node recovered — RPC is answering again")
            state["down_alerted"] = False
        state["fails"] = 0

        ibd = info.get("initialblockdownload")
        if state.get("ibd") and ibd is False:
            send_telegram(f"✅ initial sync complete at height {info.get('blocks')}")
        state["ibd"] = ibd

        free_gb = shutil.disk_usage(disk_path).free / 1024**3
        if free_gb < DISK_WARN_FREE_GB:
            if not state.get("disk_alerted"):
                send_telegram(f"💾 disk low: {free_gb:.0f} GB free")
                state["disk_alerted"] = True
        else:
            state["disk_alerted"] = False
    else:
        state["fails"] = state.get("fails", 0) + 1
        if state["fails"] == DOWN_AFTER_TICKS and not state.get("down_alerted"):
            send_telegram(f"🔴 node down — RPC unreachable for {DOWN_AFTER_TICKS} minutes")
            state["down_alerted"] = True

    # First tick pings immediately (confirms the check works), then throttled
    if state.get("ticks", 0) % PING_EVERY_TICKS == 0:
        ping_healthchecks(healthy)
    state["ticks"] = state.get("ticks", 0) + 1
    return state


def monitor_loop(get_blockchain_info):
    send_telegram("🚀 node monitor online")
    state = {}
    while True:
        try:
            tick(get_blockchain_info, state)
        except Exception as e:
            print(f"Monitor tick failed: {e}")
        time.sleep(TICK_SECONDS)
