# Tor-only runtime networking

Bitcoin, Monero and its wallet service, Tari and its wallet service, Litecoin, Dogecoin, Bitcoin Cash,
Zcash through Zakura, and the dashboard have no direct external network route.
Their Docker network is internal; only the Tor container also joins an external
network. These services use numeric addresses for local services, and local DNS
forwarding is disabled. Bitcoin-family nodes and Monero use their native Tor
proxy settings. Tari uses its native Tor transport. Prices, alerts, and release
checks send hostnames to Tor for remote resolution. An unavailable Tor proxy
causes those requests to fail, without a direct fallback.

Zakura has no native Tor transport. Its peer list contains only four internal
TCP listeners on the Tor container. Each listener resolves and reaches one
upstream seed through Tor SOCKS4A; Zakura has no direct DNS or external route.
If Tor or every bridge is unavailable, peer discovery fails closed instead of
using clearnet.
The existing Tor container forwards LAN HTTP to the dashboard's fixed internal
address; the dashboard itself has no published port or external network.

The dashboard binds to loopback by default. To allow your trusted LAN, set
`dashboard.bind_ip` to the server's private IPv4 address, for example
`192.168.1.117`, and run `./stack apply`. Wildcards, public IPs, and IPv6 bind
addresses are rejected. Public dashboard access uses the optional onion service.
LAN HTTP is unencrypted: use a trusted LAN, or access the onion service with Tor
Browser. Do not forward the LAN dashboard through a router or reverse proxy.
The host port is owned by the Tor container and forwarded to the dashboard's
fixed internal address; the dashboard itself stays on the internal network.

Optional LAN wallet RPC uses the same boundary: a private host address on the
Tor container relays authenticated TCP to Core's fixed internal address. The
Bitcoin container keeps no host port or external route. The listener is absent
unless `bitcoin.rpc_expose` is enabled; public, wildcard, loopback, and IPv6
binds are rejected. RPC is unencrypted, so keep it on a trusted LAN and do not
forward it through a router. Exposed RPC requires a password of at least 24
characters, and each host relay accepts at most 32 concurrent connections. See
[LAN wallet RPC](configuration.md#lan-wallet-rpc-opt-in).

Zcash LAN RPC terminates at the Go dashboard's authenticated read-only proxy.
The proxy forwards only a fixed allowlist of read-only methods to Zakura's
cookie-authenticated native RPC at `172.29.0.36:8232`. Native Zakura RPC remains
unpublished on the internal Docker network and is never the target of the host
relay. The healthcheck makes the rotating cookie group-readable only to the
non-root dashboard group. Treat the internal network as part of the trusted
stack boundary because a compromised sibling container could still reach
another internal service.

Monero view-only monitoring does not publish another port. The password-protected
dashboard sends a primary address and private view key to the internal wallet
service at `172.29.0.31:18082`. That service stores only an encrypted watch-only
wallet file in its private volume. Dashboard metadata is mode `600` and does not
retain the raw view key. A private spend key or seed is never accepted, so this
path cannot sign or send. Treat the private view key and signed key images as
sensitive: use the trusted LAN dashboard or its authenticated onion service, and
do not put them in `config.json`, Git, URLs, or command lines.

Tari view-only monitoring also publishes no port. The dashboard authenticates to
the wallet sidecar's internal gRPC service at `172.29.0.37:18143`; the wallet
queries the base node's internal HTTP service at `tari:9000`. Both remain on the
internal network. Generated `TARI_WALLET_RPC_PASSWORD` and `TARI_WALLET_PASSWORD`
values are separate from the dashboard password and optional LAN mining gRPC.

Wallet creation accepts one public spend key and private view key, never a seed
or private spend key. The view key crosses the shared owner-only `tari_wallet`
volume in a mode-600 request file and that handoff is removed after creation.
The dashboard metadata does not retain it. Tari v6.1 does store the private view
key in plaintext inside its native SQLite wallet database, however; the wallet
password does not provide encryption at rest. That database and its archives are
isolated in the sidecar-only `tari_wallet_data` volume, which the dashboard cannot
read. Protect the Docker data root and
use encrypted host storage when encryption at rest is required. A view key can
reveal funds and history but cannot sign a transaction. Removing the wallet
archives that owner-only database rather than deleting it or the Tari base node.
Failed imports are retained in the same private archive for recovery; removing a
dashboard row does not erase archived view keys.

## Downloads and upgrades

Starting or applying the stack uses only images already present locally, with
automatic pulls and builds disabled. Missing images cause a failure. `./stack
pull` is the explicit download command and uses the Docker daemon's existing host
network settings. The stack neither requires a host proxy nor changes Docker's
daemon configuration. An operator-configured Docker proxy continues to apply.

The setup wizard runs `pull` only when the operator accepts its final download
and start prompt and one or more images are missing. It then starts with the same
`--pull never --no-build` policy used by routine `up` and `apply` commands.

Source installs keep a separate upgrade rule: `./stack upgrade` fetches an HTTPS
Git origin through the running stack's Tor proxy before downloading any missing
container images with host Docker. Absolute local Git origins and preloaded
images support offline upgrades. SSH Git origins are rejected.

APT, Git clones, browser downloads, and Docker registry pulls are host activity,
outside the running container boundary. They use the host connection and may
reveal its public IP unless the operator has independently configured a proxy.
This does not add an external route to the Bitcoin or dashboard containers.

## Package feed

The first package feed will be enabled with the next release. Its dedicated
public-key fingerprint is intentionally unpublished until then. The release
must replace `UNPUBLISHED` below with the committed 40-hex primary fingerprint.
The command fails closed while that placeholder remains and installs the key only
after an exact fingerprint match:

```bash
expected=UNPUBLISHED
printf '%s\n' "$expected" | grep -Eq '^[0-9A-Fa-f]{40}$' || {
  echo 'The APT signing fingerprint is not published yet.' >&2
  exit 1
}
key=$(mktemp)
trap 'rm -f "$key"' EXIT
curl --fail --show-error --silent \
  https://vijitsingh97.github.io/bitcoin-starter-stack/bitcoin-starter-stack.asc \
  --output "$key"
actual=$(gpg --batch --show-keys --with-colons "$key" |
  awk -F: '$1 == "fpr" { print $10; exit }')
[ "$actual" = "$expected" ] || {
  echo "Signing-key fingerprint mismatch: $actual" >&2
  exit 1
}
sudo install -m 0644 "$key" /usr/share/keyrings/bitcoin-starter-stack.asc
```

Install GnuPG before running this check. APT installation remains inert: it does
not launch the wizard, download container images, or start the stack. Run
`sudo bitcoin-stack init` afterward. Release consumers use prebuilt images and do
not compile on the node.

This protects the stack's network paths. It cannot guarantee anonymity against
traffic correlation, a compromised host/Tor daemon, router port forwarding, or
operator-created alternate networks and proxies.

References: [Docker internal networks](https://docs.docker.com/reference/compose-file/networks/#internal),
[Go SOCKS proxy support](https://go.dev/src/net/http/transport.go).
