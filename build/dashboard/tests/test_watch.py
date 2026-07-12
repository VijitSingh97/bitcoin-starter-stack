import base64
import json

import watch


# --- base58check (the foundation the xpub conversion rests on) ---

def test_b58_decode_known_address():
    # a canonical P2PKH address: version byte 0x00 + 20-byte hash
    data = watch._b58decode_check("1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2")
    assert data[0] == 0 and len(data) == 21


def test_b58_roundtrip():
    payload = bytes(range(25))
    assert watch._b58decode_check(watch._b58encode_check(payload)) == payload


def test_b58_rejects_tampered_checksum():
    good = watch._b58encode_check(b"hello world payload!!")
    bad = good[:-1] + ("Z" if good[-1] != "Z" else "Y")
    try:
        watch._b58decode_check(bad)
        assert False, "tampered string should not verify"
    except ValueError:
        pass


# --- SLIP-132 zpub -> xpub (Core rejects zpub; the key must survive intact) ---

# BIP84 account-0 extended public key (from the BIP84 test vectors)
BIP84_ZPUB = ("zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1"
              "ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs")


def test_zpub_converts_to_xpub_without_touching_the_key():
    xpub, wrap = watch._to_xpub(BIP84_ZPUB)
    assert xpub.startswith("xpub")
    assert wrap == "wpkh({})"  # zpub -> native segwit
    # the only difference is the 4 version bytes: the 74-byte key body is identical
    assert watch._b58decode_check(xpub)[4:] == watch._b58decode_check(BIP84_ZPUB)[4:]
    assert watch._b58decode_check(xpub)[:4].hex() == "0488b21e"


def test_ypub_maps_to_p2sh_segwit():
    # re-encode the same key body under the ypub version to exercise that branch
    body = watch._b58decode_check(BIP84_ZPUB)[4:]
    ypub = watch._b58encode_check(bytes.fromhex("049d7cb2") + body)
    _, wrap = watch._to_xpub(ypub)
    assert wrap == "sh(wpkh({}))"


def test_unknown_version_rejected():
    try:
        watch._to_xpub("1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2")  # valid b58, not an extkey
        assert False
    except ValueError:
        pass


# --- descriptor building ---

def test_bare_zpub_builds_receive_and_change_wpkh():
    descs = watch.descriptors_for(BIP84_ZPUB)
    assert len(descs) == 2
    (recv, recv_internal), (change, change_internal) = descs
    assert recv.startswith("wpkh(") and recv.endswith("/0/*)") and recv_internal is False
    assert change.endswith("/1/*)") and change_internal is True


def test_bare_xpub_is_legacy_pkh():
    body = watch._b58decode_check(BIP84_ZPUB)[4:]
    xpub = watch._b58encode_check(bytes.fromhex("0488b21e") + body)
    recv = watch.descriptors_for(xpub)[0][0]
    assert recv.startswith("pkh(")


def test_full_descriptor_passthrough_strips_checksum():
    d = "wpkh([abcd1234/84h/0h/0h]xpub6C.../0/*)#aaaaaaaa"
    out = watch.descriptors_for(d)
    assert out == [("wpkh([abcd1234/84h/0h/0h]xpub6C.../0/*)", False)]


def test_multipath_descriptor_expands_to_two_branches():
    d = "wpkh([abcd1234/84h/0h/0h]xpub6C.../<0;1>/*)"
    out = watch.descriptors_for(d)
    assert out[0] == ("wpkh([abcd1234/84h/0h/0h]xpub6C.../0/*)", False)
    assert out[1] == ("wpkh([abcd1234/84h/0h/0h]xpub6C.../1/*)", True)


# --- small helpers ---

def test_wallet_name_is_namespaced_and_sanitized():
    assert watch.wallet_name("Cold Storage!") == "watch_Cold_Storage_"
    assert watch.wallet_name("a/b\\c").startswith("watch_")


def test_birthday_ts():
    assert watch.birthday_ts("2021-01-01") == 1609459200
    assert watch.birthday_ts("") == 0
    assert watch.birthday_ts("garbage") == 0


def test_fmt_btc_trims_zeros():
    assert watch.fmt_btc(0.5) == "0.5"
    assert watch.fmt_btc(1.0) == "1"
    assert watch.fmt_btc(0) == "0"
    assert watch.fmt_btc(1.23456789) == "1.23456789"


# --- config loading ---

def test_load_config_from_b64(monkeypatch):
    blob = [{"name": "Cold", "key": "zpub...", "birthday": "2021-01-01"},
            {"name": "", "key": "x"},          # dropped: no name
            {"name": "y", "key": ""}]          # dropped: no key
    monkeypatch.setenv("WATCH_WALLETS_B64", base64.b64encode(json.dumps(blob).encode()).decode())
    cfg = watch.load_config()
    assert len(cfg) == 1 and cfg[0]["name"] == "Cold"


def test_load_config_empty_and_malformed(monkeypatch):
    monkeypatch.delenv("WATCH_WALLETS_B64", raising=False)
    assert watch.load_config() == []
    monkeypatch.setenv("WATCH_WALLETS_B64", "not base64 json!!")
    assert watch.load_config() == []


# --- balances aggregation ---

class FakeWalletRpc:
    def __init__(self, table):
        self.table = table  # {wallet: {"getwalletinfo": ..., "getbalances": ...}}

    def __call__(self, wallet, method, params=None):
        return self.table.get(wallet, {}).get(method)


def test_balances_sums_only_ready_wallets():
    wallets = [{"name": "A", "key": "z"}, {"name": "B", "key": "z"}, {"name": "C", "key": "z"}]
    table = {
        "watch_A": {"getwalletinfo": {"scanning": False}, "getbalances": {"mine": {"trusted": 0.5}}},
        "watch_B": {"getwalletinfo": {"scanning": {"duration": 10}}},  # rescanning
        "watch_C": {"getwalletinfo": None},                            # error
    }
    rows, total = watch.balances(FakeWalletRpc(table), wallets)
    assert total == "0.5"  # only A counts
    assert rows[0] == {"name": "A", "state": "ok", "btc": "0.5"}
    assert rows[1]["state"] == "scanning"
    assert rows[2]["state"] == "error"


# --- wallet provisioning ---

class FakeRpc:
    def __init__(self, existing=(), descriptor_ok=True):
        self.existing = list(existing)
        self.descriptor_ok = descriptor_ok
        self.calls = []

    def __call__(self, method, params=None):
        self.calls.append((method, params))
        if method == "listwallets":
            return self.existing
        if method == "createwallet":
            return {"name": params[0]}
        if method == "getdescriptorinfo":
            return {"descriptor": params[0] + "#ck"} if self.descriptor_ok else None
        return None


def test_ensure_creates_and_imports_new_wallet():
    rpc = FakeRpc()
    imports = []
    wallet_rpc = lambda w, m, p=None: (
        None if m == "getwalletinfo" else imports.append((w, m, p)))
    watch.ensure_wallets(rpc, wallet_rpc, [{"name": "Cold", "key": BIP84_ZPUB, "birthday": "2021-01-01"}])
    methods = [c[0] for c in rpc.calls]
    assert "createwallet" in methods
    assert imports and imports[0][1] == "importdescriptors"
    reqs = imports[0][2][0]
    assert len(reqs) == 2 and all(r["timestamp"] == 1609459200 for r in reqs)
    assert [r["internal"] for r in reqs] == [False, True]


def test_ensure_skips_already_loaded_wallet():
    rpc = FakeRpc(existing=["watch_Cold"])
    watch.ensure_wallets(rpc, lambda *a, **k: None, [{"name": "Cold", "key": BIP84_ZPUB}])
    assert [c[0] for c in rpc.calls] == ["listwallets"]  # nothing created


def test_ensure_is_a_noop_on_pruned_node():
    rpc = FakeRpc()
    watch.ensure_wallets(rpc, lambda *a, **k: None, [{"name": "Cold", "key": BIP84_ZPUB}], pruned=True)
    assert rpc.calls == []


def test_ensure_skips_bad_key_without_crashing_or_orphaning():
    # a typo'd key must not create an orphan wallet, kill the thread, or block
    # the good wallets that follow it
    rpc = FakeRpc()
    imports = []
    wallet_rpc = lambda w, m, p=None: (
        None if m == "getwalletinfo" else imports.append((w, m, p)))
    watch.ensure_wallets(rpc, wallet_rpc, [
        {"name": "Bad", "key": "not-a-valid-key"},
        {"name": "Good", "key": BIP84_ZPUB},
    ])
    created = [p[0] for m, p in rpc.calls if m == "createwallet"]
    assert created == ["watch_Good"]          # bad one skipped, no orphan
    assert imports and imports[0][0] == "watch_Good"  # good one still imported
