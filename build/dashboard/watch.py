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
import re
import threading
from datetime import datetime, timezone

MAX_WALLETS = 20  # bounds rescan abuse from the write endpoints
_store_lock = threading.Lock()  # guards the shared wallet list + its file

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

# A bare address (not an extended key) is watched as a single-address descriptor,
# addr(<address>). Loose shape check only — Core's getdescriptorinfo is the real
# validator, so a bad checksum is caught at import, not here.
_ADDR_RE = re.compile(
    r"^(?:bc1|tb1|bcrt1)[0-9a-z]{20,}$"       # bech32 / bech32m (segwit, taproot)
    r"|^[13][1-9A-HJ-NP-Za-km-z]{25,34}$"      # base58 P2PKH / P2SH
)


def _looks_like_address(s):
    return bool(_ADDR_RE.match(s))


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
    try:
        xpub, wrap = _to_xpub(key)
    except ValueError:
        if _looks_like_address(key):
            return [(f"addr({key})", False)]  # watch one specific address
        raise ValueError("not an xpub/ypub/zpub, an output descriptor, or an address")
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


def provision_one(rpc, wallet_rpc, entry, pruned=False):
    """Make one watch wallet ready in Core (idempotent). Loads a wallet that
    already exists on disk (a re-add — no rescan); otherwise creates it and
    imports the descriptors, which triggers the one-time rescan (so callers run
    this off the request path). A new import needs a full node; loading an
    existing wallet works on a pruned node too."""
    name = wallet_name(entry["name"])
    if wallet_rpc(name, "getwalletinfo", []) is not None:
        return  # already loaded
    if rpc("loadwallet", [name]) is not None:
        return  # existed on disk (e.g. removed then re-added) — descriptors already imported
    # needs a fresh create + import — build descriptors first so a bad key
    # (typo'd xpub, unknown prefix) raises here, before any wallet is created
    descs = descriptors_for(entry["key"])
    if pruned:
        print(f"watch-only: node is pruned — can't rescan history; not importing {entry['name']!r}")
        return
    # createwallet(name, disable_private_keys, blank, passphrase,
    #              avoid_reuse, descriptors, load_on_startup)
    if rpc("createwallet", [name, True, True, "", False, True, True]) is None:
        print(f"watch-only: could not create wallet for {entry['name']!r}")
        return
    ts = birthday_ts(entry.get("birthday"))
    requests = []
    for desc, internal in descs:
        info = rpc("getdescriptorinfo", [desc])
        if not info:
            print(f"watch-only: invalid descriptor for {entry['name']!r}: {desc}")
            continue
        req = {"desc": info["descriptor"], "timestamp": ts,
               "active": False, "internal": internal}
        if info.get("isrange"):
            req["range"] = 1000  # a range is only valid on ranged (…/*) descriptors
        requests.append(req)
    if requests:
        wallet_rpc(name, "importdescriptors", [requests])


def ensure_wallets(rpc, wallet_rpc, wallets, pruned=False):
    """Provision every configured wallet. One bad entry never blocks the others
    or kills the calling thread."""
    for w in wallets:
        try:
            provision_one(rpc, wallet_rpc, w, pruned)
        except Exception as e:
            print(f"watch-only: skipping {w.get('name')!r}: {e}")


def deprovision(rpc, name):
    """Unload a removed wallet and drop it from Core's auto-load list. The tiny
    wallet dir is left on disk (Core has no delete-files RPC and the dashboard
    mounts the datadir read-only); a later re-add just loads it back."""
    rpc("unloadwallet", [wallet_name(name), False])


def balances(wallet_rpc, wallets):
    """(rows, total_btc_string). Each row: {name, state, btc}. state is 'ok'
    (btc set), 'scanning' (rescan in progress), or 'error'."""
    rows, total = [], 0.0
    for w in list(wallets):  # snapshot — the list can be mutated by the API
        name = wallet_name(w["name"])
        info = wallet_rpc(name, "getwalletinfo", [])
        if info is None:
            row = {"name": w["name"], "state": "error", "btc": None}
        elif info.get("scanning"):
            row = {"name": w["name"], "state": "scanning", "btc": None}
        else:
            bal = wallet_rpc(name, "getbalances", []) or {}
            btc = (bal.get("mine", {}) or {}).get("trusted", 0) or 0
            total += btc
            row = {"name": w["name"], "state": "ok", "btc": fmt_btc(btc)}
        row["key"] = w["key"]  # the UI shows a truncated form, expandable on click
        rows.append(row)
    return rows, fmt_btc(total)


def balances_view(wallet_rpc, wallets):
    """balances() plus show_total (only meaningful with more than one wallet)."""
    rows, total = balances(wallet_rpc, wallets)
    return {"wallets": rows, "total": total, "show_total": len(rows) > 1}


# --- persistence: the saved wallet list ("saved to the stack") ---------------
# Bitcoin Core persists the wallets themselves (load_on_startup); this small
# JSON sidecar persists the operator's list — labels, keys, birthdays — so the
# UI has a clean, editable roster. Lives on a writable volume (see compose),
# separate from the read-only chain datadir.

def _store_path():
    return os.environ.get("WATCH_STORE", "/state/wallets.json")


def _normalize(it):
    name = str(it.get("name", "")).strip()
    key = str(it.get("key", "")).strip()
    if name and key:
        return {"name": name, "key": key, "birthday": (it.get("birthday") or "")}
    return None


def save_store(wallets):
    """Best-effort atomic write — a missing/unwritable volume must not crash the
    dashboard, just log and keep the list in memory for this run."""
    path = _store_path()
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(wallets, f)
        os.replace(tmp, path)
    except Exception as e:
        print(f"watch store not saved ({path}): {e}")


def load_store():
    """The saved wallet list. First run seeds it from config.json (the env blob)
    so an existing declarative config carries over; after that the file — driven
    by the UI — is authoritative."""
    path = _store_path()
    if os.path.exists(path):
        try:
            with open(path) as f:
                items = json.load(f)
            return [n for n in (_normalize(it) for it in items) if n]
        except Exception as e:
            print(f"watch store unreadable ({path}): {e}")
            return []
    seed = load_config()
    save_store(seed)
    return seed


def add_entry(store, name, key, birthday=""):
    """Validate and append a wallet, persisting the list. Raises ValueError with
    a user-facing message on bad input. Returns the stored entry."""
    name = (name or "").strip()
    key = (key or "").strip()
    birthday = (birthday or "").strip()
    if not name or not key:
        raise ValueError("Name and key are both required.")
    if birthday and birthday_ts(birthday) == 0:
        raise ValueError("Birthday must be a date like 2021-03-15.")
    descriptors_for(key)  # raises ValueError on an unparseable key/descriptor
    with _store_lock:
        if len(store) >= MAX_WALLETS:
            raise ValueError(f"At most {MAX_WALLETS} wallets.")
        if any(w["name"].lower() == name.lower() for w in store):
            raise ValueError("A wallet with that name already exists.")
        entry = {"name": name, "key": key, "birthday": birthday}
        store.append(entry)
        save_store(store)
    return entry


def remove_entry(store, name):
    """Drop a wallet by name, persisting. Returns True if one was removed."""
    with _store_lock:
        for i, w in enumerate(store):
            if w["name"] == name:
                store.pop(i)
                save_store(store)
                return True
    return False
