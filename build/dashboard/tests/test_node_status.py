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
    "getmempoolinfo": {"size": 4200, "bytes": 12 * 1024**2},
    "estimatesmartfee": {"feerate": 0.0001, "blocks": 1},  # 0.0001 BTC/kvB = 10 sat/vB
}

BIG_DISK = (2 * 1024**4, 1 * 1024**4, 1 * 1024**4)  # 1 TB free


def render_index(monkeypatch, rpc=FAKE_RPC, disk=BIG_DISK):
    monkeypatch.setattr(node_status, "get_rpc_data", lambda method, params=None: rpc.get(method))
    monkeypatch.setattr(node_status.shutil, "disk_usage", lambda path: disk)
    return node_status.app.test_client().get("/")


def test_index_shows_loading_page_when_node_unreachable(monkeypatch):
    monkeypatch.setattr(node_status, "get_rpc_data", lambda method, params=None: None)
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
    # a full node shows a "Full" badge, never "Pruned"
    assert ">Full<" in body
    assert "Pruned" not in body


def test_index_shows_stack_version(monkeypatch):
    monkeypatch.setattr(node_status, "STACK_VERSION", "1.3.0")
    body = render_index(monkeypatch).data.decode()
    assert "v1.3.0" in body


def test_index_shows_dev_when_unversioned(monkeypatch):
    monkeypatch.setattr(node_status, "STACK_VERSION", "dev")
    body = render_index(monkeypatch).data.decode()
    assert ">dev<" in body
    assert "vdev" not in body  # not v-prefixed


def test_loading_page_shows_version(monkeypatch):
    monkeypatch.setattr(node_status, "get_rpc_data", lambda method, params=None: None)
    monkeypatch.setattr(node_status, "STACK_VERSION", "1.3.0")
    body = node_status.app.test_client().get("/").data.decode()
    assert "Initializing" in body
    assert "v1.3.0" in body


def test_update_badge_shows_when_update_available(monkeypatch):
    monkeypatch.setattr(node_status.monitor, "update_available", "Bitcoin Core 99.0 available (running 31.1.0)")
    body = render_index(monkeypatch).data.decode()
    assert "🆕 Bitcoin Core 99.0 available" in body
    assert "built-in method" not in body


# --- mempool + fees ---

def test_index_shows_mempool_and_fees(monkeypatch):
    body = render_index(monkeypatch).data.decode()
    assert "Mempool:" in body
    assert "4200 tx" in body
    assert "12.0 MB" in body
    assert "10 / 10 / 10" in body  # 0.0001 BTC/kvB -> 10 sat/vB (same mock for all)


def test_index_hides_mempool_during_sync(monkeypatch):
    rpc = dict(FAKE_RPC)
    rpc["getblockchaininfo"] = dict(FAKE_RPC["getblockchaininfo"], initialblockdownload=True)
    body = render_index(monkeypatch, rpc=rpc).data.decode()
    assert "Mempool:" not in body


# --- theming ---

def test_theme_wired_on_both_pages(monkeypatch):
    # theme-init runs before paint (no flash), the toggle button and the
    # module are present, and no palette is hard-coded in the page anymore
    full = render_index(monkeypatch).data.decode()
    monkeypatch.setattr(node_status, "get_rpc_data", lambda method, params=None: None)
    loading = node_status.app.test_client().get("/").data.decode()
    for body in (full, loading):
        assert '/static/dashboard.css' in body
        assert 'data-theme' in body
        assert 'id="theme-toggle"' in body
        assert '/static/theme.js' in body
        assert '#0f0f0f' not in body  # colours live in the stylesheet now


def test_tower_and_live_refresh_wired_on_both_pages(monkeypatch):
    # the tower canvas + module are present, the live panel is swappable,
    # and the page updates by polling (no full-page meta refresh that would
    # reset the animation)
    full = render_index(monkeypatch).data.decode()
    monkeypatch.setattr(node_status, "get_rpc_data", lambda method, params=None: None)
    loading = node_status.app.test_client().get("/").data.decode()
    for body in (full, loading):
        assert '<canvas id="tower">' in body
        assert '/static/tower.js' in body
        assert 'id="live"' in body
        assert '/static/refresh.js' in body
        assert 'http-equiv="refresh"' not in body
    # the live panel carries the block height so the tower can build from it
    assert 'data-blocks="900000"' in full


def test_tower_and_refresh_assets_served():
    client = node_status.app.test_client()
    tower = client.get("/static/tower.js")
    assert tower.status_code == 200
    assert b"project" in tower.data
    assert client.get("/static/refresh.js").status_code == 200


def test_static_css_and_js_are_served():
    client = node_status.app.test_client()
    css = client.get("/static/dashboard.css")
    assert css.status_code == 200
    assert b"--accent" in css.data
    js = client.get("/static/theme.js")
    assert js.status_code == 200
    assert b"nextTheme" in js.data


def test_static_assets_respect_auth(monkeypatch):
    monkeypatch.setattr(node_status, "DASHBOARD_PASSWORD", "hunter2")
    assert node_status.app.test_client().get("/static/dashboard.css").status_code == 401


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
    assert ">Full<" not in body  # pruned and full badges are exclusive


def test_index_warns_on_low_disk(monkeypatch):
    low = (2 * 1024**4, 2 * 1024**4 - 20 * 1024**3, 20 * 1024**3)  # 20 GB free
    body = render_index(monkeypatch, disk=low).data.decode()
    assert "LOW" in body
    assert 'class="warn"' in body


# --- prometheus metrics ---

def test_metrics_when_node_up(monkeypatch):
    monkeypatch.setattr(node_status, "get_rpc_data", lambda method, params=None: FAKE_RPC.get(method))
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
    monkeypatch.setattr(node_status, "get_rpc_data", lambda method, params=None: None)
    body = node_status.app.test_client().get("/metrics").data.decode()
    assert "bitcoin_node_up 0" in body
    assert "bitcoin_blocks" not in body


def test_metrics_includes_mempool_and_fees(monkeypatch):
    monkeypatch.setattr(node_status, "get_rpc_data", lambda method, params=None: FAKE_RPC.get(method))
    monkeypatch.setattr(node_status.shutil, "disk_usage", lambda path: BIG_DISK)
    body = node_status.app.test_client().get("/metrics").data.decode()
    assert "bitcoin_mempool_txs 4200" in body
    assert 'bitcoin_fee_sat_vb{blocks="1"} 10' in body


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
    monkeypatch.setattr(node_status, "get_rpc_data", lambda method, params=None: FAKE_RPC.get(method))
    monkeypatch.setattr(node_status.shutil, "disk_usage", lambda path: BIG_DISK)
    resp = node_status.app.test_client().get("/", auth=("anyuser", "hunter2"))
    assert resp.status_code == 200
    assert b"Sync Progress" in resp.data
