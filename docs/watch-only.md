# Watch-only balances

Add your public keys and the dashboard shows the balance of each, plus a total —
read straight off **your own node**. No third-party block explorer ever sees your
addresses, which is the whole reason to run a private node in the first place.

These are **watch-only** wallets: they hold public keys only. The node can see
your balance and derive your addresses, but it has no private keys and
**cannot spend** anything.

## Add a wallet from the dashboard

The dashboard has a **Watch-only balances** card with an add form:

1. **Label** — any name you like (e.g. "Cold storage").
2. **Key** — an extended public key or a full output descriptor (see below).
3. **Birthday** (optional) — the date the wallet was first used; it bounds the
   one-time rescan.

Click **Add**. The node imports the key and rescans the chain for its history —
the row shows `scanning…` while that runs, then the balance appears and stays
live. Remove a wallet with the **✕** next to it.

Wallets are **saved to the stack**: they persist across restarts (held in Bitcoin
Core, with the list stored on a small `dashboard_state` volume). No file editing
required.

> **No dashboard password?** Then anyone who can reach the page can add or remove
> wallets — the card shows a warning. Set `dashboard.password` in `config.json`
> (see [Configuration](configuration.md)) to require a login. Removing a wallet is
> harmless (watch-only, no keys), but adding one starts a chain rescan.

## What to paste for the key

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

**A single address** — paste an address (`bc1…`, `1…`, or `3…`) to watch just
that one address. Useful for a specific receive address, a donation address, or a
paper wallet. Note it tracks only that address, not a whole wallet — for your
full balance, use the account's xpub instead.

## Exchange / custodial accounts (Coinbase, River, Cash App…)

You **can't** get an xpub from a custodial service, and you can't watch a
custodial balance at all — the coins aren't held at addresses you control, they're
in the provider's pooled wallet, and the deposit addresses they show you rotate.
Watch-only balances only work for wallets where **you** hold the keys (a hardware
wallet, or a self-custody app like Sparrow/Electrum/BlueWallet). To make an
exchange balance watchable, withdraw it to your own wallet and add that wallet's
xpub.

## Requirements & the first rescan

- A **full node** (`prune_mb: 0`). Finding an existing balance means rescanning
  historical blocks, which a pruned node has thrown away — so a new import is
  skipped on a pruned node.
- The first import **rescans the chain**. A tight `birthday` keeps it to minutes;
  no birthday means a full-chain scan (tens of minutes on a full node). Once
  done, the balance stays live and there's no rescan on restart. Removing then
  re-adding the same wallet reloads it instantly — no second rescan.

### Speeding up the first scan

- **Set a birthday.** The single biggest lever — it bounds the rescan to blocks
  after that date instead of scanning from 2009.
- **Enable `blockfilterindex`.** Set `"blockfilterindex": true` in `config.json`
  (full node only). Bitcoin Core builds a compact filter of every block once,
  then *every* rescan — this wallet and every future one — uses the filters to
  skip blocks that can't match, turning a multi-hour scan into minutes. It's a
  shared, one-time-built cache: ~a few GB of extra disk and a one-time
  background build (the node keeps serving meanwhile). After `configure.sh`,
  restart the node (`docker compose up -d bitcoin`).

## Seeding from config.json (optional)

You can also predeclare wallets in `config.json`, which seeds the list on first
start (handy for a fresh deploy):

```json
"wallets": [
    { "name": "Cold storage", "key": "zpub6r...", "birthday": "2021-03-15" }
]
```

After that first start the dashboard's own list (the roster) is authoritative —
edits you make in the UI stick, and further `config.json` changes are ignored.

## Privacy & safety

- **No spend risk.** Watch-only wallets have no private keys.
- **An xpub is still sensitive.** Anyone who has it can see every address and
  balance you'll ever use under it. It's stored on the node (the wallet list and
  Bitcoin Core's wallet files) — keep access to the box and the dashboard
  controlled, and set a dashboard password if it's reachable beyond your LAN.
- **Nothing leaves the box.** Balances come from your node's own index; no
  request goes to any external service.
