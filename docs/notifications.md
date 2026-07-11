# Notifications & Remote Access

Three opt-in features for keeping an eye on the node when you're not on the
LAN. All three are off by default, and all outbound notification traffic
rides the stack's Tor proxy — none of it is a clearnet beacon from your IP.

## Telegram alerts

A one-way pager: short messages on real state transitions, debounced so a
momentary blip never pings you and each incident fires exactly once.

| Alert | When it fires |
|---|---|
| 🚀 **Monitor online** | The dashboard started — confirms the bot works after setup. |
| 🔴 **Node down** | RPC unreachable for 3 consecutive minutes. |
| 🟢 **Node recovered** | RPC answering again after a down alert. |
| ✅ **Sync complete** | Initial block download finished — handy on first run, when it takes days. |
| 💾 **Disk low** | Free space fell below 50 GB. Re-arms if space is freed. |
| 🆕 **Update available** | A new Bitcoin Core release or stack release exists (checked daily, over Tor). Also shown as a dashboard badge. Informational only — nothing auto-updates. |

Nothing controls the node over Telegram — there are no commands, so a
leaked chat can read alerts but never change anything.

### Setup (about five minutes)

1. **Create a bot:** message [@BotFather](https://t.me/BotFather) on
   Telegram, send `/newbot`, follow the prompts. It replies with a **bot
   token** like `1234567890:AAF...`.
2. **Get your chat id:** message [@userinfobot](https://t.me/userinfobot)
   (or your new bot, then visit
   `https://api.telegram.org/bot<token>/getUpdates`). Your numeric id is
   the **chat id**.
3. **Send your bot a message first** (bots can't initiate chats), then:

```json
"notifications": {
    "telegram_bot_token": "1234567890:AAF...",
    "telegram_chat_id": "123456789"
}
```

4. `./configure.sh && docker compose up -d` — you'll get the 🚀 message
   within a minute.

Messages are prefixed with the host's name (`NODE_NAME`, defaults to the
box's hostname) so multiple stacks can share one chat.

## Healthchecks.io dead-man's switch

Telegram alerts come *from* the box — so the one failure they can never
report is the box itself going dark (power loss, kernel panic, dead NIC).
[Healthchecks.io](https://healthchecks.io/) inverts that: the stack pings a
URL every 5 minutes, and *their* servers alert you when the pings stop.

1. Create a check at healthchecks.io (free tier is fine). Set the period
   to ~5 minutes and a grace period you're comfortable with.
2. Paste the ping URL into `config.json`:

```json
"notifications": {
    "healthchecks_url": "https://hc-ping.com/your-uuid-here"
}
```

While the node's RPC is down (but the box alive), the stack pings the
`/fail` endpoint instead, so the check shows *failing* rather than *late* —
you can distinguish "node broken" from "box dark".

## Dashboard over Tor

Reach the dashboard from anywhere — phone on cellular, another city —
without port-forwarding anything, via a Tor onion service:

```json
"dashboard": {
    "password": "pickapassword1",
    "onion": true
}
```

Then `./configure.sh && docker compose up -d`, and get your address:

```bash
docker exec tor cat /var/lib/tor/dashboard_onion/hostname
```

Open that `.onion` address in [Tor Browser](https://www.torproject.org/).
The address is unguessable (derived from an ed25519 key), but treat it as
a secret and **set `dashboard.password`** — `configure.sh` warns if you
enable the onion without one. No host port is opened; inbound arrives only
through the Tor network.

The onion keys live in the `tor_data` volume — recreating it (e.g.
`docker compose down -v`) generates a new address.
