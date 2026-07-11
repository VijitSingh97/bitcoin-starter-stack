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


def test_index_shows_loading_page_when_node_unreachable(monkeypatch):
    monkeypatch.setattr(node_status, "get_rpc_data", lambda method: None)
    resp = node_status.app.test_client().get("/")
    assert resp.status_code == 200
    assert b"Initializing" in resp.data


def test_index_renders_node_stats(monkeypatch):
    monkeypatch.setattr(node_status, "get_rpc_data", FAKE_RPC.get)
    monkeypatch.setattr(
        node_status.shutil, "disk_usage",
        lambda path: (2 * 1024**4, 1 * 1024**4, 1 * 1024**4),
    )
    resp = node_status.app.test_client().get("/")
    body = resp.data.decode()
    assert resp.status_code == 200
    assert "900000 / 900000" in body
    assert "/Satoshi:28.0.0/" in body
    assert "1d 1h 1m" in body
    assert "100.0" in body  # sync progress
    assert ">1</span>" in body  # 1 inbound peer
    assert "800.0 GB" in body  # size on disk
