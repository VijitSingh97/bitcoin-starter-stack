# Configuration

All per-box settings live in `config.json`. `configure.sh` renders them
into a gitignored `.env`, which docker compose reads. Tracked files are
never modified, so your credentials can't end up in a commit.

## config.json reference

```json
{
    "bitcoin": {
        "node_username": "create_a_username_for_node",
        "node_password": "create_a_password_for_node",
        "data_dir": "./data/bitcoin",
        "dbcache_mb": 3000
    }
}
```

| Key | Default | What it does |
|---|---|---|
| `node_username` | — (required) | RPC username for Bitcoin Core. Letters and numbers only. |
| `node_password` | — (required) | RPC password. Letters and numbers only — it passes through shell and env-file layers. |
| `data_dir` | `./data/bitcoin` | Where the blockchain lives on the host. Relative paths resolve from the repo root. |
| `dbcache_mb` | `3000` | Bitcoin Core's UTXO cache size in MB. Size it to your RAM — see [Hardware](hardware.md#ram). |

`configure.sh` refuses to run while the placeholder credentials are still
in place, and applies the defaults above for any omitted key.

## Applying changes

```bash
nano config.json
./configure.sh
docker compose up -d    # recreates only the containers whose config changed
```

## Reusing an existing node

Already have a synced chain? Point `data_dir` at it and skip the
week-long sync:

```json
"data_dir": "/home/you/.bitcoin"
```

Two requirements:

- The directory must be **owned by uid 1000** (the first user on most
  Ubuntu installs) — the bitcoin container runs as `1000:1000`.
- The chain must come from a compatible Bitcoin Core version (v28 or
  earlier data upgrades in place automatically).

The dashboard mounts the same directory read-only for its disk-usage
stats.

## What's deliberately not configurable

Static node settings (Tor-only networking, RPC bind/allow ranges) live in
[build/bitcoin/bitcoin.conf](../build/bitcoin/bitcoin.conf) and apply to
every deployment. If you need to diverge, edit that file — but you're
forking the privacy model at that point; read
[Architecture](architecture.md) first.
