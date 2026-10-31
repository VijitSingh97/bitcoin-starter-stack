# Watch-only balances

Bitcoin, Litecoin, and Bitcoin Cash read confirmed unspent balances from **your
own node**, so no third-party block explorer receives your addresses. Bitcoin
accepts public keys only; Litecoin and Bitcoin Cash accept one public address per
row. Monero uses a private view key plus optional signed key images. None of these
paths accepts a private spending key or can send funds.

Bitcoin **watch-only** entries hold public keys only. The node can see
your balance and derive your addresses, but it has no private keys and
**cannot spend** anything.

## Add a wallet from the dashboard

The dashboard has a **Watch-only balances** card with an add form:

1. **Label** — any name you like (e.g. "Cold storage").
2. **Key** — an extended public key, public output descriptor, or address (see below).
   For a bare `xpub`, choose the address type your wallet uses.
3. **Birthday** (optional) — retained for existing Core-wallet imports. It does
   not make the default pruned UTXO-set scan faster.

Click **Add**. On the default pruned node, the row stays pending while Bitcoin
Core's `scantxoutset` checks the live UTXO set, then shows the confirmed balance
and caches it with the scan height and time. A first scan commonly takes minutes,
but its time depends on hardware and current workload. Later reads use the cache
and are fast; the displayed height and time show how fresh the result is. Remove
a wallet with the **✕** next to it.

The public wallet list, confirmed scan cache, and balance snapshots persist across
restarts in the private `dashboard_state` volume. Existing Core watch-only wallets
remain supported. No file editing is required.

The chart shows our saved balance observations, not historical transactions.
Overlapping confirmed UTXOs are counted once in a combined total. When Core
wallets and scan results are mixed, the dashboard withholds the combined total
because it cannot establish whether they overlap.

The same public key cannot be added twice under different labels. If an older
saved list contains exact duplicate keys, only its first entry is used, keeping
the balance from being counted twice; the original file is preserved until the
next wallet change.

Wallet changes are confirmed only after the roster is saved. If the state volume
cannot be written or the roster cannot be read, the manager reports an error and
preserves the existing file. A damaged roster is never reset to an empty list.
Restart the dashboard after correcting the file or state-volume problem.

If the saved scan cache is corrupt, unreadable, or unwritable, the dashboard
reports it as unavailable and stops expensive scans until storage is repaired
and the dashboard restarts. The wallet list and snapshot history stay intact.
The rebuildable `watch_scan_cache.json` can be backed up and removed from the
state volume to request a new scan; keep `wallets.json` and
`balance_history.json` intact.

Set `dashboard.password` in `config.json` to view personal wallets and add or remove
entries. Fresh Bitcoin state includes one clearly marked public example; see
[Bitcoin public example](#bitcoin-public-example-and-seeding-from-configjson).

## Litecoin and Bitcoin Cash addresses

The Litecoin and Bitcoin Cash cards accept a label and one public address. After
the node is fully synced, the dashboard validates the address with that daemon and
runs its native `scantxoutset` call. The result is a confirmed UTXO snapshot at the
displayed scan height, not transaction history. Extended public keys, descriptors,
Litecoin MWEB addresses, private keys, and seeds are not accepted in these forms.

Scans run in the background and a confirmed result is reused for up to one hour.
The row is **Pending** before its first successful scan. If the node is syncing or
a later scan fails, a prior confirmed amount remains visible as **Stale** or
**Error**; an unverified failure is never displayed as a zero balance. Saved
snapshot charts and watch lists survive dashboard restarts.

Fresh state includes two sourced public examples:

- **Linux Mint** for Litecoin, from its
  [official donors page](https://www.linuxmint.com/donors.php).
- **Bitcoin Cash Node** for Bitcoin Cash, from its
  [official project site](https://bitcoincashnode.org/en/).

Examples are clearly marked and excluded from personal totals. Removing one is
persistent; restarting the dashboard does not add it back.

## Monero view-only wallets

A Monero address alone cannot reveal incoming outputs. Open the Monero card,
then use **View-only wallets**:

1. Enter a label, the primary mainnet address, the private view key, and an
   optional restore height. Use `0` when unsure; it scans safely from genesis but
   takes longer.
2. Or paste JSON in this form:

   ```json
   {"name":"Cold storage","address":"4...","view_key":"...","restore_height":0}
   ```

3. Submit it and wait while the wallet scans. **Pending** is not a zero balance.

The form never accepts a private spend key or seed phrase. The resulting wallet
cannot sign or send transactions. The private view key is write-only in the UI:
it creates an encrypted watch-only wallet file, then is not stored in dashboard
metadata or returned by the API. Do not place it in `config.json`, Git, or a shell
command. The label, address, scan state, and balance snapshots stay in private
mode-600 dashboard state. Encrypted wallet files stay in the private
`monero_wallets` Docker volume; removing a dashboard row stops monitoring but
does not delete that encrypted file. Stack backups, release archives, and Debian
packages do not copy this private volume. After a disaster restore, remove and
add the Monero row again from your original address and private view key.

### Received-only and current balances

A view key detects incoming outputs but cannot determine by itself whether an
output was later spent. Until complete key images are imported, the dashboard
labels the amount **Received only**, not current balance. This follows Monero's
[view-only wallet guide](https://www.getmonero.org/resources/user-guides/view_only.html),
which says outgoing transactions require matching key images for a correct balance.

Export signed key images from the spending wallet and paste the native wallet-RPC
JSON object:

```json
{"offset":0,"signed_key_images":[{"key_image":"...","signature":"..."}]}
```

A wrapper response containing that object under `result` is accepted too. The
GUI/CLI encrypted binary `.key_images` file is not accepted. Some hardware-wallet
view-only flows cannot export key images; in that case keep using received-only
amounts. Import key images again after receiving or spending, because new outputs
need new coverage. A snapshot is marked verified/current only after the wallet is
fully scanned and fresh key-image coverage is complete.

The stack uses Monero's authenticated
[`generate_from_keys`, `get_balance`, and `import_key_images` wallet RPCs](https://docs.getmonero.org/rpc-library/wallet-rpc/)
inside Docker. That wallet service has no host port and no public internet route.

On fresh Monero wallet state, the dashboard seeds the official **Monero General
Fund** as a public example using the address and published view key from Monero's
[contribution page](https://www.getmonero.org/get-started/contributing/). A view
key is not a spending key, but it reveals received outputs, so treat personal view
keys as sensitive. The example is always received-only: the project has not
published complete current key images, so the dashboard does not claim an
accurate current balance. Removing the example is persistent and it is not seeded
into an existing wallet roster.

## Reference-only cards

Dogecoin shows the [Dogecoin Foundation](https://foundation.dogecoin.com/about/)
address and Zcash shows the [Tor Project](https://donate.torproject.org/cryptocurrency/)
transparent address as sourced examples. They intentionally have no balance:
Dogecoin's current pruned daemon cannot discover arbitrary address UTXOs, and
Zakura's default checkpoint-pruned mode omits the address index. The dashboard
does not query an external explorer to fill those gaps.

**Dogecoin:** an address watched before initial sync or before its first payment
can be tracked going forward. Adding an old address to an already-pruned node
cannot establish its full balance: `importaddress` refuses a historical rescan,
and skipping the rescan can miss older unspent funds. Upstream's proposed
[UTXO scanner](https://github.com/dogecoin/dogecoin/pull/3665) remains unmerged
as of October 31, 2026. Its current RPC requires a private spending key, so it
also fails this dashboard's public-key-only requirement. A full archival rescan or a separately built address
index would be needed with the current released daemon.

**Zcash / Zakura:** this is a limitation of our current storage profile, not a
claim that every pruned Zcash implementation lacks wallet support. Zakura 1.7.0
can retain transparent address indexes while pruning transaction bodies, but
requires a fresh database with checkpoint sync disabled. Upstream describes
that mode as slower and less secure against some chain attacks; it also retains
extra indexes with no published sizing estimate. We keep the default profile.
See the [release notes](https://github.com/zakura-core/zakura/releases/tag/v1.7.0)
and [checkpoint configuration](https://github.com/zakura-core/zakura/blob/v1.7.0/crates/zakura-consensus/src/config.rs).
Shielded addresses additionally need a viewing key and wallet scanner; a public
address alone is insufficient. Zallet and lightwalletd are separate wallet/index
services, not a small switch that enables balances in our existing database.

Tari has no bundled public example. Its view-only flow requires a separate wallet
service plus a public spend key, private view key, and birthday; the current stack
only runs the Tari node. Pruning itself does not prevent a current balance:
Tari retains live unspent outputs and supports scanning them through its
[UTXO synchronization service](https://github.com/tari-project/tari/blob/v6.1.0/base_layer/core/src/base_node/sync/rpc/sync_utxos_task.rs).
Adding a view-only wallet service is therefore feasible without an archival node,
but cannot recover complete history for spent outputs that were already pruned.
The [view-only initializer](https://github.com/tari-project/tari/blob/v6.1.0/applications/minotari_console_wallet/src/init/mod.rs)
stores no private spend key.

## Bitcoin: the Genesis address is a special case

The Genesis address `1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa` is not added automatically.
It can be watched manually, but it is a poor reference for comparing balances:
the original 50 BTC genesis coinbase is unspendable and is excluded from Bitcoin
Core's wallet balance. Explorers may attribute it to this address. That explains
a 50 BTC difference, but does not establish that every other difference is correct.

The dashboard displays the balance reported by your node without adding 50 BTC.
Existing saved entries are preserved.
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

Pruned-node scans derive receive and change indexes 0–999 from an account xpub.
Coins outside that bounded range need a more precise descriptor or a later wider
scan. Extended public keys are privacy-sensitive: anyone with one can follow the
derived addresses and balances.

**A full output descriptor** — the exact option. This is what "export" gives you
in Sparrow, Coldcard, Ledger Live, etc. It names the script type and derivation
explicitly; the result still covers only the supplied descriptor and scan range:

```
wpkh([a1b2c3d4/84h/0h/0h]xpub6CUGRUo.../<0;1>/*)
```

The `<0;1>` covers both the receive and change branches. Any checksum (`#abcd…`)
is fine to leave on or off.

**A single address** — paste an address (`bc1…`, `1…`, or `3…`) to watch just
that one address. Useful for a specific receive address, a donation address, or a
paper wallet. Note it tracks only that address, not a whole wallet — for your
account balance within the scanned range, use its xpub instead.

## Exchange / custodial accounts (Coinbase, River, Cash App…)

You **can't** get an xpub from a custodial service, and you can't watch a
custodial balance at all — the coins aren't held at addresses you control, they're
in the provider's pooled wallet, and the deposit addresses they show you rotate.
Watch-only balances only work for wallets where **you** hold the keys (a hardware
wallet, or a self-custody app like Sparrow/Electrum/BlueWallet). To make an
exchange balance watchable, withdraw it to your own wallet and add that wallet's
xpub.

## Requirements and scan limits

- The default pruned node needs no external address indexer. It asks Bitcoin Core
  to scan the current UTXO set, so it can find confirmed unspent balances without
  historical block files.
- The scan does not provide transaction history, spent outputs, or mempool activity.
  It reports confirmed unspent balance as of the displayed scan height.
- A new scan is asynchronous. Pending means no balance result has been confirmed
  yet; it never means zero. There is no guaranteed completion time.
- Wallets already imported into a synced Bitcoin Core wallet keep their normal,
  accurate cached balance and are fast to read.
- Only public addresses, public descriptors, and extended public keys are accepted.
  Never paste a seed phrase or private key; the dashboard rejects them.
- `blockfilterindex` and `prune_mb: 0` remain manual compatibility settings for
  advanced archival setups. They are not required for the default UTXO-set scan.

## Bitcoin public example and seeding from config.json

Fresh installs start with one public example address disclosed by Binance in
2022. It is labeled **Public example** and excluded from personal totals, so its
balance cannot be mistaken for yours or for Binance's total reserves. It is one
address, not proof of the exchange's solvency. Its first UTXO-set scan stays
pending until complete. You can remove it after setting a dashboard
password, or opt out before first start with `"wallets": []`. See Binance's
[original address disclosure](https://www.binance.com/en-IN/blog/community/2895840147147652626).

You can instead predeclare your own wallets in `config.json`, which seeds the
list on first start:

```json
"wallets": [
    { "name": "Cold storage", "key": "zpub6r...", "birthday": "2021-03-15" }
]
```

After that first start the dashboard's own list (the roster) is authoritative —
edits you make in the UI stick, and further `config.json` changes are ignored.

## Privacy & safety

- **No spending keys.** Bitcoin, Litecoin, and Bitcoin Cash accept public material
  only. Monero accepts a private view key, but rejects private spend keys and seeds;
  none of these paths can sign or send.
- **An xpub is still sensitive.** Anyone who has it can follow the addresses and
  balances derived from that account. It's stored in the private wallet list;
  existing Core watch-wallet files can also contain it. Keep access to the box and dashboard
  controlled, and set a dashboard password if it's reachable beyond your LAN.
- **Wallet data stays on the box.** Balances come directly from your nodes;
  wallet keys and addresses are never sent to external services. The separate BTC
  and XMR price lookups send only asset and currency names to CoinGecko through Tor.

## Native wallet smoke test

Maintainers can opt into isolated Litecoin and Bitcoin Cash regtest proofs. The
test builds temporary local images, exercises funded and zero-balance addresses
through the authenticated dashboard API, and removes its owned resources:

```bash
RUN_NATIVE_WALLET_SMOKE=1 tests/test_native_wallets.sh
```

Set `NATIVE_WALLET_CHAIN=litecoin` or `bitcoincash` to run one daemon. This test
needs Docker and is intentionally skipped by default.
