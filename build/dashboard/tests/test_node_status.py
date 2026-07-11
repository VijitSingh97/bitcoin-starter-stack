import node_status


# --- format_uptime ---

def test_uptime_none():
    assert node_status.format_uptime(None) == "N/A"


def test_uptime_not_a_number():
    assert node_status.format_uptime("soon") == "N/A"


def test_uptime_with_days():
    assert node_status.format_uptime(90061) == "1d 1h 1m"


def test_uptime_under_a_day():
    assert node_status.format_uptime(3660) == "1h 1m"


# --- get_rpc_data ---

def test_rpc_error_returns_none(monkeypatch):
    def boom(*args, **kwargs):
        raise node_status.requests.exceptions.ConnectionError("refused")

    monkeypatch.setattr(node_status.requests, "post", boom)
    assert node_status.get_rpc_data("uptime") is None


def test_rpc_non_200_returns_none(monkeypatch):
    class Resp:
        status_code = 500

    monkeypatch.setattr(node_status.requests, "post", lambda *a, **kw: Resp())
    assert node_status.get_rpc_data("uptime") is None


def test_rpc_uses_credentials_from_env(monkeypatch):
    seen = {}

    class Resp:
        status_code = 200

        @staticmethod
        def json():
            return {"result": {"ok": True}}

    def capture(url, auth, data, timeout):
        seen["auth"] = auth
        return Resp()

    monkeypatch.setattr(node_status.requests, "post", capture)
    assert node_status.get_rpc_data("uptime") == {"ok": True}
    assert seen["auth"] == ("testuser", "testpass")


# --- index route ---

FAKE_RPC = {
    "getblockchaininfo": {
        "blocks": 900000,
        "headers": 900000,
        "verificationprogress": 1.0,
        "size_on_disk": 800 * 1024**3,
    },
    "getnetworkinfo": {"subversion": "/Satoshi:28.0.0/", "connections": 10},
    "getpeerinfo": [{"inbound": True}, {"inbound": False}, {"inbound": False}],
    "uptime": 90061,
}

BIG_DISK = (2 * 1024**4, 1 * 1024**4, 1 * 1024**4)  # 1 TB free


def render_index(monkeypatch, rpc=FAKE_RPC, disk=BIG_DISK):
    monkeypatch.setattr(node_status, "get_rpc_data", rpc.get)
    monkeypatch.setattr(node_status.shutil, "disk_usage", lambda path: disk)
    return node_status.app.test_client().get("/")


def test_index_shows_loading_page_when_node_unreachable(monkeypatch):
    monkeypatch.setattr(node_status, "get_rpc_data", lambda method: None)
    resp = node_status.app.test_client().get("/")
    assert resp.status_code == 200
    assert b"Initializing" in resp.data


def test_index_renders_node_stats(monkeypatch):
    resp = render_index(monkeypatch)
    body = resp.data.decode()
    assert resp.status_code == 200
    assert "900000 / 900000" in body
    assert "/Satoshi:28.0.0/" in body
    assert "1d 1h 1m" in body
    assert "100.0" in body  # sync progress
    assert ">1</span>" in body  # 1 inbound peer
    assert "800.0 GB" in body  # size on disk
    assert "Pruned" not in body  # full node: no badge
    assert "LOW" not in body  # 1 TB free: no warning
    # regression: "update" as a stats key shadowed dict.update in Jinja and
    # rendered "<built-in method update of dict object ...>" on every page
    assert "🆕" not in body
    assert "built-in method" not in body


def test_update_badge_shows_when_update_available(monkeypatch):
    monkeypatch.setattr(node_status.monitor, "update_available", "Bitcoin Core 99.0 available (running 31.1.0)")
    body = render_index(monkeypatch).data.decode()
    assert "🆕 Bitcoin Core 99.0 available" in body
    assert "built-in method" not in body


# --- pruned badge and disk warning ---

def test_index_shows_pruned_badge(monkeypatch):
    rpc = dict(FAKE_RPC)
    rpc["getblockchaininfo"] = dict(
        FAKE_RPC["getblockchaininfo"],
        pruned=True, prune_target_size=10 * 1024**3, size_on_disk=11 * 1024**3,
    )
    body = render_index(monkeypatch, rpc=rpc).data.decode()
    assert "Pruned" in body
    assert "10.0 GB" in body  # prune target in the badge


def test_index_warns_on_low_disk(monkeypatch):
    low = (2 * 1024**4, 2 * 1024**4 - 20 * 1024**3, 20 * 1024**3)  # 20 GB free
    body = render_index(monkeypatch, disk=low).data.decode()
    assert "LOW" in body
    assert 'class="warn"' in body


# --- prometheus metrics ---

def test_metrics_when_node_up(monkeypatch):
    monkeypatch.setattr(node_status, "get_rpc_data", FAKE_RPC.get)
    monkeypatch.setattr(node_status.shutil, "disk_usage", lambda path: BIG_DISK)
    resp = node_status.app.test_client().get("/metrics")
    body = resp.data.decode()
    assert resp.status_code == 200
    assert "bitcoin_node_up 1" in body
    assert "bitcoin_blocks 900000" in body
    assert 'bitcoin_peers{direction="in"} 1' in body
    assert 'bitcoin_peers{direction="out"} 2' in body
    assert "bitcoin_pruned 0" in body


def test_metrics_when_node_down(monkeypatch):
    monkeypatch.setattr(node_status, "get_rpc_data", lambda method: None)
    body = node_status.app.test_client().get("/metrics").data.decode()
    assert "bitcoin_node_up 0" in body
    assert "bitcoin_blocks" not in body


def test_metrics_respects_auth(monkeypatch):
    monkeypatch.setattr(node_status, "DASHBOARD_PASSWORD", "hunter2")
    resp = node_status.app.test_client().get("/metrics")
    assert resp.status_code == 401


# --- optional basic auth ---

def test_no_password_means_no_auth(monkeypatch):
    monkeypatch.setattr(node_status, "DASHBOARD_PASSWORD", "")
    resp = render_index(monkeypatch)
    assert resp.status_code == 200


def test_auth_rejects_missing_credentials(monkeypatch):
    monkeypatch.setattr(node_status, "DASHBOARD_PASSWORD", "hunter2")
    resp = node_status.app.test_client().get("/")
    assert resp.status_code == 401
    assert "WWW-Authenticate" in resp.headers


def test_auth_rejects_wrong_password(monkeypatch):
    monkeypatch.setattr(node_status, "DASHBOARD_PASSWORD", "hunter2")
    resp = node_status.app.test_client().get("/", auth=("x", "wrong"))
    assert resp.status_code == 401


def test_auth_accepts_correct_password(monkeypatch):
    monkeypatch.setattr(node_status, "DASHBOARD_PASSWORD", "hunter2")
    monkeypatch.setattr(node_status, "get_rpc_data", FAKE_RPC.get)
    monkeypatch.setattr(node_status.shutil, "disk_usage", lambda path: BIG_DISK)
    resp = node_status.app.test_client().get("/", auth=("anyuser", "hunter2"))
    assert resp.status_code == 200
    assert b"Sync Progress" in resp.data
