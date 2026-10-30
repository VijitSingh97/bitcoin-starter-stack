# Tor-only networking

Bitcoin and the dashboard have no external network route. Their Docker network is
internal; only the Tor container also joins an external network. Both applications
use numeric addresses for local services, and local DNS forwarding is disabled.
Prices, alerts, and release checks send hostnames to Tor for remote resolution.
An unavailable Tor proxy causes those requests to fail, without a direct fallback.
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

## Downloads and upgrades

Starting or applying the stack uses only images already present locally, with
automatic pulls and builds disabled. Missing images cause a failure. `./stack
pull` downloads images only after verifying that the Docker daemon uses the
stack's Tor SOCKS proxy, has no proxy bypasses or registry mirrors, and that the
proxy is recognized as Tor. `./stack upgrade` fetches an HTTPS Git origin through
that proxy, then uses the same image-download checks. Absolute local Git origins
and preloaded images also support offline upgrades. SSH Git origins are rejected.

Docker Engine on Ubuntu needs this proxy configuration merged into
`/etc/docker/daemon.json`:

```json
{
  "proxies": {
    "http-proxy": "socks5h://172.29.0.25:9050",
    "https-proxy": "socks5h://172.29.0.25:9050",
    "no-proxy": ""
  }
}
```

Preserve other daemon settings. Validate the file with `sudo dockerd --validate
--config-file=/etc/docker/daemon.json`, then schedule a Docker restart; restarting
Docker can interrupt every container on the host. The proxy address is reachable
from the Ubuntu host once the stack's Tor container is running. If Tor is down,
registry downloads fail. Docker Desktop uses different proxy settings and is a
development environment, outside the supported Ubuntu deployment.

## Bootstrap and APT

Tor must already be available before the first network download. Obtain the source
and initial Tor image through an existing Tor connection, or transfer them from a
trusted machine using Tor for its downloads. Load the image locally with `docker
load`, configure the stack, and start only Tor with `./stack up tor`. Once Tor has
bootstrapped and Docker's proxy settings are active, run `./stack pull` followed by
`./stack up`. There is no automatic clearnet bootstrap exception.

For an existing Tor connection, clone with remote DNS and no proxy bypass:

```bash
NO_PROXY= no_proxy= git -c http.proxy=socks5h://127.0.0.1:9050 clone \
  https://github.com/VijitSingh97/bitcoin-starter-stack.git
```

APT is a host program. Before adding this project's feed or installing packages,
route it through an available Tor proxy. With the stack's Tor running on Ubuntu,
put the following in `/etc/apt/apt.conf.d/80-bitcoin-tor`:

```text
Acquire::http::Proxy "socks5h://172.29.0.25:9050";
Acquire::https::Proxy "socks5h://172.29.0.25:9050";
```

Check existing host/per-repository proxy overrides before relying on this setting.
Source compilation, maintainer release publishing, CI, direct Docker commands, a browser reading GitHub, and
unrelated host services are outside the running container boundary. Development
builds need their own Tor-routed build environment; setting a Docker CLI proxy
alone does not route daemon pulls or every build step. Release consumers can use
the prebuilt images without compiling on the node.

This protects the stack's network paths. It cannot guarantee anonymity against
traffic correlation, a compromised host/Tor daemon, router port forwarding, or
operator-created alternate networks and proxies.

References: [Docker internal networks](https://docs.docker.com/reference/compose-file/networks/#internal),
[Docker daemon proxies](https://docs.docker.com/engine/daemon/proxy/),
[Go SOCKS proxy support](https://go.dev/src/net/http/transport.go).
