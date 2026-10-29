# Notifications & Remote Access

## Dashboard settings

The gear at the bottom right opens Telegram, Healthchecks, and new-block alert
settings. Changes apply immediately without restarting Bitcoin. A dashboard
password protects the gear when configured; without one, it follows the same
access policy as the rest of the dashboard. The gear works from localhost, a
configured private LAN address, or the Tor onion dashboard (enable
`dashboard.onion` in `config.json` and open the address shown by `./stack doctor`
in Tor Browser). Without a password, use a private IP or local hostname; custom
hostnames require a dashboard password.

Dashboard changes are written atomically to `notification_settings.json` in the
persistent `dashboard_state` volume, with owner-only permissions. They survive
reboots, container recreation, and upgrades, and the existing stack backup/restore
includes them. Saved overrides take priority over the notification values in
`config.json`. **Use server config** removes the override and restores those
values. After editing the server file, apply it and reset the override if needed.

The gear displays the saved bot token and Healthchecks ping URL so they can be
edited directly. Anyone with dashboard access can view those values. Disabling a
service clears its credentials from the dashboard override; the server
configuration is unchanged.

Three opt-in ways to keep an eye on the node when you're off the LAN:
Telegram alerts, a Healthchecks.io dead-man's switch, and dashboard access
over Tor. All three are off until configured, and every outbound
notification rides the stack's Tor proxy (`socks5h`, so even DNS resolves
through Tor) — enabling them never turns the node into a clearnet beacon.

Every value below goes in `config.json` under `notifications` (or
`dashboard`); see [Configuration](configuration.md) for the full key table.
Apply changes with `./stack apply`.

---

## Telegram alerts

A one-way pager: short messages on real state transitions, debounced so a
momentary blip never pings you and each incident fires exactly once. Nothing
controls the node over Telegram — there are no commands, so a leaked chat can
read alerts but never change anything.

| Alert | When it fires |
|---|---|
| 🚀 **Monitor online** | The dashboard started — confirms the bot works after setup. |
| 🔴 **Node down** | RPC unreachable for 3 consecutive minutes. |
| 🟢 **Node recovered** | RPC answering again after a down alert. |
| ✅ **Sync complete** | Initial block download finished — handy on first run, when it takes days. |
| 💾 **Disk low** | Free space fell below 50 GB. Re-arms if space is freed. |
| 🆕 **Update available** | A new stack release exists (checked daily, over Tor). Also a dashboard badge. Informational only. |
| 🟧 **New block** | The node accepted a new block (synced only). **Off by default** — a synced node finds ~144 a day. Enable with `notifications.alert_new_block: true`. |

Every message is prefixed with the host's name (`NODE_NAME`, the box's
hostname by default), so several nodes can share one chat.

### 1. Create a bot and get its token

Message [@BotFather](https://t.me/BotFather), send `/newbot`, and follow the
prompts. It replies with a **bot token** like `1234567890:AAF...`.

### 2. Get your chat id

Create a group (or use a direct chat), add your bot to it, and send it any
message — a bot can't start a conversation, so it must be spoken to first.
Then visit `https://api.telegram.org/bot<token>/getUpdates` and read the
`chat.id`. A group id is negative (e.g. `-1001234567890`); a direct-chat id
is positive.

### 3. Add both to `config.json`

```json
"notifications": {
    "telegram_bot_token": "1234567890:AAF...",
    "telegram_chat_id": "-1001234567890"
}
```

`./stack apply`, and you'll get the 🚀 message within a minute.

> NOTE: The bot token can send messages as your bot if leaked, but it can't
> read other chats or touch the node. Server-configured tokens live in the
> gitignored configuration and environment; dashboard overrides live in the
> private persistent settings JSON. Backups contain these credentials too.

---

## Healthchecks.io dead-man's switch

Telegram alerts come *from* the box, so the one failure they can never report
is the box itself going dark — power loss, a kernel panic, a dead NIC, the
whole host hanging. A dead machine can't send its own "I'm down".

[Healthchecks.io](https://healthchecks.io/) inverts the logic: the stack
pings a unique URL on a schedule, and **their** servers alert you when the
pings *stop*. The check runs off-box, so it survives the very outage you want
to catch. Silence is the alarm.

### 1. Create a check

Sign up (the free tier is plenty for one node) and create a check. Set its
schedule to match the stack's fixed **5-minute** ping:

- **Period — 5 minutes.** How often Healthchecks.io expects a ping.
- **Grace — 1–2 minutes.** How long a ping can be late before you're
  alerted. With a 5-minute period you're paged after roughly **6–7 minutes**
  of true silence. The stack retries a failed ping every minute until one
  gets through, so a brief Tor blip won't false-alarm even on a tight grace;
  widen the grace if you'd rather tolerate longer restarts.

Copy the check's **ping URL** — it looks like `https://hc-ping.com/<uuid>`.

### 2. Route the alert somewhere

On the check's **Integrations** tab, point it at email, Telegram, Slack, a
webhook — whatever you'll see. If you set up the Telegram bot above, send
Healthchecks.io to the **same** group so host-down and in-stack alerts land
together.

### 3. Add the ping URL to `config.json`

```json
"notifications": {
    "healthchecks_url": "https://hc-ping.com/your-uuid-here"
}
```

`./stack apply`. The first ping fires within a minute, so the check's **Last
Ping** flips from *Never* to a timestamp almost immediately — that's your
confirmation it works.

While the node's RPC is down but the box is alive, the stack pings the
check's `/fail` endpoint instead, so Healthchecks shows *down* rather than
*late* — you can tell "node broken" from "box dark".

---

## Dashboard over Tor

Reach the dashboard from anywhere — phone on cellular, another city — with no
port-forwarding, via a Tor onion service:

```json
"dashboard": {
    "password": "pickapassword1",
    "onion": true
}
```

`./stack apply`, then read your address:

```bash
docker exec tor cat /var/lib/tor/dashboard_onion/hostname
```

Open that `.onion` in [Tor Browser](https://www.torproject.org/). The address
is unguessable (an ed25519 key), but treat it as a secret and **set
`dashboard.password`** — `configure.sh` warns if you enable the onion without
one. The onion adds no host port; the ordinary dashboard port keeps its
configured loopback or private-LAN bind.

> NOTE: The onion keys live in the `tor_data` volume. Recreating it (e.g.
> `docker compose down -v`) generates a **new** address — back it up with
> `./stack backup` after enabling.
