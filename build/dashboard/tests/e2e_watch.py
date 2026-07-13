"""E2E: provision a watch-only wallet of each supported key type against the
REAL node, exercising watch.descriptors_for + provision_one (including the
range-only-for-ranged-descriptors fix) end to end. Run inside the dashboard
container by tests/test_e2e.sh — it can't run in plain CI because it needs a
live bitcoind.

Satoshi's genesis key predates HD wallets (BIP32), so it has no xpub/zpub — the
Satoshi cases use its address and its actual genesis-coinbase public key (both
resolve to 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa). The xpub/zpub cases use standard
BIP test vectors, since no real Satoshi extended key exists.
"""
import json
import os
import sys

import requests

import watch

RPC = "http://172.29.0.26:8332"
AUTH = (os.environ["RPC_USER"], os.environ["RPC_PASSWORD"])


def rpc(method, params=None, wallet=None):
    url = RPC + (f"/wallet/{wallet}" if wallet else "")
    body = {"jsonrpc": "1.0", "id": "e2e", "method": method, "params": params or []}
    r = requests.post(url, auth=AUTH, data=json.dumps(body), timeout=120)
    return r.json().get("result") if r.status_code == 200 else None


GENESIS_ADDR = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
GENESIS_PUBKEY = ("04678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f6"
                  "1deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5f")
XPUB = ("xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3"
        "rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V")           # BIP84 account xpub
ZPUB = ("zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqt"
        "fSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs")           # same key, BIP84 zpub

CASES = [
    ("xpub", XPUB),
    ("zpub", ZPUB),
    ("satoshi-address", GENESIS_ADDR),
    ("satoshi-pubkey", f"pkh({GENESIS_PUBKEY})"),
]

fails = []
for label, key in CASES:
    entry = {"name": label, "key": key, "birthday": ""}
    # pruned=False: this fresh node has ~no blocks, so the import/rescan is
    # trivial regardless of the prune setting — we're testing the RPC contract,
    # not a historical rescan.
    try:
        watch.provision_one(rpc, lambda w, m, p=None: rpc(m, p, wallet=w), entry, pruned=False)
    except Exception as e:  # noqa: BLE001 — surface any failure with its label
        fails.append(f"{label}: provision raised {e!r}")
        continue
    name = watch.wallet_name(label)
    info = rpc("getwalletinfo", wallet=name)
    if not info or not info.get("descriptors") or info.get("private_keys_enabled"):
        fails.append(f"{label}: wallet {name} is not a watch-only descriptor wallet ({info})")
    else:
        print(f"  OK {label}: {name} provisioned (watch-only)")

# The two Satoshi forms must actually watch the genesis address.
for label in ("satoshi-address", "satoshi-pubkey"):
    ai = rpc("getaddressinfo", [GENESIS_ADDR], wallet=watch.wallet_name(label))
    if not (ai and ai.get("ismine")):
        fails.append(f"{label}: genesis address is not watched (ismine != true)")
    else:
        print(f"  OK {label}: watches {GENESIS_ADDR}")

if fails:
    print("FAIL: watch-only provisioning\n  " + "\n  ".join(fails))
    sys.exit(1)
print("PASS: watch-only provisioning for xpub / zpub / address / pubkey")
