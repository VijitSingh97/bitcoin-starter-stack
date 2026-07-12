# Watch-only balances

Paste your public keys into `config.json` and the dashboard shows the balance of
each, plus a total — read straight off **your own node**. No third-party block
explorer ever sees your addresses, which is the whole reason to run a private
node in the first place.

These are **watch-only** wallets: they hold public keys only. The node can see
your balance and derive your addresses, but it has no private keys and
**cannot spend** anything.

## Requirements

- A **full node** (`prune_mb: 0`). Finding an existing balance means rescanning
  historical blocks, which a pruned node has thrown away — so watch-only is
  skipped on a pruned node (you'll see a note in the dashboard logs).

## Configure

Add a `wallets` array to `config.json`, then re-run `./configure.sh` and restart
the dashboard (`docker compose up -d dashboard`):

```json
"wallets": [
    { "name": "Cold storage", "key": "zpub6r...", "birthday": "2021-03-15" },
    { "name": "Spending",     "key": "wpkh([a1b2c3d4/84h/0h/0h]xpub6C.../<0;1>/*)" }
]
```

| Field | Required | What it is |
| --- | --- | --- |
| `name` | yes | A label shown in the dashboard. |
| `key` | yes | An extended public key **or** a full output descriptor (see below). |
| `birthday` | no | `YYYY-MM-DD` the wallet was first used. Bounds the one-time rescan — without it the node rescans from genesis, which is correct but slow. |

### What to paste for `key`

**An extended public key** — the friendly option. Copy the `xpub`/`ypub`/`zpub`
your wallet shows for an account:

| Prefix | Address type it's read as |
| --- | --- |
| `zpub` | Native SegWit (`bc1q…`) — BIP84 |
| `ypub` | Nested SegWit (`3…`) — BIP49 |
| `xpub` | Legacy (`1…`) — BIP44 |

The script type is inferred from the prefix. If your wallet gives a plain `xpub`
for a SegWit account (some do), or you use Taproot, paste a **descriptor**
instead so there's no guessing.

**A full output descriptor** — the exact option. This is what "export" gives you
in Sparrow, Coldcard, Ledger Live, etc. It names the script type and derivation
explicitly, so the balance is always right:

```
wpkh([a1b2c3d4/84h/0h/0h]xpub6CUGRUo.../<0;1>/*)
```

The `<0;1>` covers both the receive and change branches. Any checksum (`#abcd…`)
is fine to leave on or off.

## First run: the rescan

The first time a key is added, the node imports it and **rescans the chain** to
find its history. This runs in the background; while it's working the dashboard
shows `scanning…` for that wallet. A tight `birthday` keeps it to minutes; no
birthday means a full-chain scan (tens of minutes on a full node). Once done,
the balance stays live as new blocks arrive — no rescan on restart.

## Privacy & safety

- **No spend risk.** Watch-only wallets have no private keys.
- **An xpub is still sensitive.** Anyone who has it can see every address and
  balance you'll ever use under it. It lives only in `config.json`, which is
  gitignored — keep that file private, same as your RPC password.
- **Nothing leaves the box.** Balances come from your node's own index; no
  request goes to any external service.
