"""Watch-only wallet balances.

The operator pastes public keys into config.json; the node holds one
spend-disabled descriptor wallet per key and the dashboard reads each balance
straight off your own full node — no third-party explorer ever sees your
addresses. One wallet per key keeps each balance (and the total) a plain
getbalances call.

All RPC is injected (an `rpc` for node calls, a `wallet_rpc` for wallet-scoped
ones) so the logic here is testable without a live node — the same pattern
monitor.py uses.

Bitcoin Core's descriptor language only understands xpub/tpub, so SLIP-132
ypub/zpub keys are re-encoded to xpub here before a descriptor is built.
"""
import base64
import hashlib
import json
import os
from datetime import datetime, timezone

# SLIP-132 extended-key version bytes -> (xpub/tpub version bytes, script
# template). Core rejects ypub/zpub outright, so we swap the version bytes to
# the plain xpub/tpub the descriptor language expects and wrap the key in the
# script type the prefix implies (BIP44 legacy / BIP49 p2sh-segwit / BIP84
# native segwit). A bare xpub is, per SLIP-132, legacy P2PKH — use a zpub or a
# full descriptor for segwit/taproot.
_XPUB = bytes.fromhex("0488b21e")
_TPUB = bytes.fromhex("043587cf")
_SLIP132 = {
    "0488b21e": (_XPUB, "pkh({})"),        # xpub  legacy        BIP44
    "049d7cb2": (_XPUB, "sh(wpkh({}))"),   # ypub  p2sh-segwit   BIP49
    "04b24746": (_XPUB, "wpkh({})"),       # zpub  native segwit BIP84
    "043587cf": (_TPUB, "pkh({})"),        # tpub
    "044a5262": (_TPUB, "sh(wpkh({}))"),   # upub
    "045f1cf6": (_TPUB, "wpkh({})"),       # vpub
}

_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def _b58decode_check(s):
    n = 0
    for ch in s:
        n = n * 58 + _B58.index(ch)  # ValueError on any non-base58 char
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
    raw = b"\x00" * (len(s) - len(s.lstrip("1"))) + raw  # leading '1' -> 0x00
    data, checksum = raw[:-4], raw[-4:]
    if hashlib.sha256(hashlib.sha256(data).digest()).digest()[:4] != checksum:
        raise ValueError("bad base58 checksum")
    return data


def _b58encode_check(data):
    data = data + hashlib.sha256(hashlib.sha256(data).digest()).digest()[:4]
    n = int.from_bytes(data, "big")
    out = ""
    while n > 0:
        n, r = divmod(n, 58)
        out = _B58[r] + out
    return "1" * (len(data) - len(data.lstrip(b"\x00"))) + out


def _to_xpub(extkey):
    """SLIP-132 extended key -> (xpub/tpub, script template). Raises on an
    unknown version or a bad checksum."""
    raw = _b58decode_check(extkey)
    if len(raw) != 78:
        raise ValueError("not an extended key")
    ver = raw[:4].hex()
    if ver not in _SLIP132:
        raise ValueError(f"unrecognized extended-key version {ver}")
    new_ver, wrap = _SLIP132[ver]
    return _b58encode_check(new_ver + raw[4:]), wrap


def descriptors_for(key):
    """Return [(descriptor, is_internal)] to import for one configured key —
    the receive branch and, for ranged keys, the change branch.

    A full descriptor (anything with a '(') is trusted as-is: its checksum is
    dropped (importdescriptors recomputes it) and a `<0;1>` multipath is
    expanded into its two branches. A bare extended key is converted to xpub
    and wrapped in the script type its prefix implies.
    """
    key = key.strip()
    if "(" in key:
        body = key.split("#", 1)[0].strip()
        if "<0;1>" in body:
            return [(body.replace("<0;1>", "0"), False),
                    (body.replace("<0;1>", "1"), True)]
        return [(body, False)]
    xpub, wrap = _to_xpub(key)
    return [(wrap.format(f"{xpub}/0/*"), False),
            (wrap.format(f"{xpub}/1/*"), True)]


def wallet_name(name):
    """Core wallet name -> a filesystem-safe, collision-namespaced id."""
    safe = "".join(c if (c.isalnum() or c in "-_") else "_" for c in name)[:40]
    return f"watch_{safe}"


def birthday_ts(birthday):
    """A YYYY-MM-DD birthday -> unix seconds for importdescriptors, or 0 for a
    full rescan from genesis when unset/unparseable."""
    if not birthday:
        return 0
    try:
        d = datetime.strptime(str(birthday), "%Y-%m-%d")
        return int(d.replace(tzinfo=timezone.utc).timestamp())
    except ValueError:
        return 0


def fmt_btc(btc):
    """8-dp BTC with trailing zeros trimmed: 0.5, 1.23456789, 0."""
    s = f"{btc:.8f}".rstrip("0").rstrip(".")
    return s or "0"


def load_config():
    """Configured wallets, from a base64 JSON blob in the environment (base64
    so xpubs/descriptors pass through .env untouched). Drops malformed entries
    rather than failing the whole dashboard."""
    raw = os.environ.get("WATCH_WALLETS_B64", "")
    if not raw:
        return []
    try:
        items = json.loads(base64.b64decode(raw))
    except Exception:
        return []
    out = []
    for it in items if isinstance(items, list) else []:
        name = str(it.get("name", "")).strip()
        key = str(it.get("key", "")).strip()
        if name and key:
            out.append({"name": name, "key": key, "birthday": it.get("birthday")})
    return out


def ensure_wallets(rpc, wallet_rpc, wallets, pruned=False):
    """Create + import any not-yet-present watch wallets. Idempotent: skips
    wallets already loaded, and importdescriptors triggers the one-time rescan
    (so callers run this off the request path). No-op on a pruned node, whose
    rescan can't reach historical funds."""
    if not wallets:
        return
    if pruned:
        print("watch-only: node is pruned — a full node is needed to rescan "
              "historical balances; skipping wallet import")
        return
    existing = set(rpc("listwallets", []) or [])
    for w in wallets:
        name = wallet_name(w["name"])
        if name in existing:
            continue
        # a wallet from a prior run may exist on disk but be unloaded
        if wallet_rpc(name, "getwalletinfo", []) is not None:
            continue
        # Build descriptors before creating anything: a bad key (typo'd xpub,
        # unknown prefix) raises here, so we skip it cleanly — no orphan wallet,
        # and one bad entry never blocks the others or kills this thread.
        try:
            descs = descriptors_for(w["key"])
        except Exception as e:
            print(f"watch-only: skipping {w['name']!r} — bad key: {e}")
            continue
        # createwallet(name, disable_private_keys, blank, passphrase,
        #              avoid_reuse, descriptors, load_on_startup)
        if rpc("createwallet", [name, True, True, "", False, True, True]) is None:
            print(f"watch-only: could not create wallet for {w['name']!r}")
            continue
        ts = birthday_ts(w.get("birthday"))
        requests = []
        for desc, internal in descs:
            info = rpc("getdescriptorinfo", [desc])
            if not info:
                print(f"watch-only: invalid descriptor for {w['name']!r}: {desc}")
                continue
            requests.append({"desc": info["descriptor"], "timestamp": ts,
                             "active": False, "internal": internal, "range": 1000})
        if requests:
            wallet_rpc(name, "importdescriptors", [requests])


def balances(wallet_rpc, wallets):
    """(rows, total_btc_string). Each row: {name, state, btc}. state is 'ok'
    (btc set), 'scanning' (rescan in progress), or 'error'."""
    rows, total = [], 0.0
    for w in wallets:
        name = wallet_name(w["name"])
        info = wallet_rpc(name, "getwalletinfo", [])
        if info is None:
            rows.append({"name": w["name"], "state": "error", "btc": None})
        elif info.get("scanning"):
            rows.append({"name": w["name"], "state": "scanning", "btc": None})
        else:
            bal = wallet_rpc(name, "getbalances", []) or {}
            btc = (bal.get("mine", {}) or {}).get("trusted", 0) or 0
            total += btc
            rows.append({"name": w["name"], "state": "ok", "btc": fmt_btc(btc)})
    return rows, fmt_btc(total)
