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
2. **Key** — an extended public key, public output descriptor, or address (see below).
   For a bare `xpub`, choose the address type your wallet uses.
3. **Birthday** (optional) — the date the wallet was first used; it bounds the
   one-time rescan.

Click **Add**. The node imports the key and rescans the chain for its history —
the row shows `Pending history…` or `scanning…` while that runs, then the balance appears and stays
live. Remove a wallet with the **✕** next to it.

Wallets are **saved to the stack**: they persist across restarts (held in Bitcoin
Core, with the list stored on a small `dashboard_state` volume). No file editing
required.

The same public key cannot be added twice under different labels. If an older
saved list contains exact duplicate keys, only its first entry is used, keeping
the balance from being counted twice; the original file is preserved until the
next wallet change.

Wallet changes are confirmed only after the roster is saved. If the state volume
cannot be written or the roster cannot be read, the manager reports an error and
preserves the existing file. A damaged roster is never reset to an empty list.
Restart the dashboard after correcting the file or state-volume problem.

Set `dashboard.password` in `config.json` to view personal wallets and add or remove
entries. Without a password, only the public Genesis example is visible and the
wallet controls are disabled. See [Configuration](configuration.md).

## Genesis example

Fresh full-node installs watch `1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa` as **Genesis**
from the beginning of the chain. The original 50 BTC genesis coinbase is unspendable
and is excluded from Bitcoin Core's wallet balance; explorers may include it in
their address total. The dashboard displays the balance reported by your node.

Set `"wallets": []` before first start to skip this example, or remove it from the
dashboard afterward. A saved wallet list is never overwritten by the default.
Existing entries named Satoshi for this exact address display as Genesis without
renaming their Core wallet or losing their balance history.

## What to paste for the key

**An extended public key** — the friendly option. Copy the `xpub`/`ypub`/`zpub`
your wallet shows for an account:

| Prefix | Address type it's read as |
| --- | --- |
| `zpub` | Native SegWit (`bc1q…`) — BIP84 |
| `ypub` | Nested SegWit (`3…`) — BIP49 |
| `xpub` | Legacy (`1…`) — BIP44 |

The script type is inferred from the prefix. A plain `xpub` does not identify its
script type: for a SegWit account, select **Native SegWit** (`bc1q…`) or **Nested
SegWit** (`3…`) in the form. Legacy remains the default. A wallet-exported public
descriptor is more precise, and is required for Taproot.

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
  done, the balance stays live and there's no rescan on restart. Reusing a label
  for a different key creates a separate Core wallet; old wallet files are retained.
- A birthday must be on or before the first payment. Leave it blank to check the
  whole chain if you are unsure. Receiving without ever sending still creates a
  balance; spending is not required for discovery.

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
- **Wallet data stays on the box.** Balances come from your node's own index;
  wallet keys and addresses are never sent to external services. The separate BTC
  price lookup sends only Bitcoin and currency names to CoinGecko through Tor.
