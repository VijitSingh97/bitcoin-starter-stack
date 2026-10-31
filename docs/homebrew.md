# Homebrew installation

Homebrew support installs the same Docker Compose stack used on Linux. On macOS,
Docker Desktop supplies the Linux virtual machine that runs the containers. The
formula installs only the command and immutable stack files; it does not install
or start Docker, download images, run the wizard, or start a node.
Homebrew installs Bash, flock, jq, and OpenSSL for the host commands; Linuxbrew
also installs iproute2. Docker remains an external prerequisite.

The formula will become installable after the first release that includes this
packaging and its generated-formula pull request reaches the default branch.
Until then, the commands below describe the release path and should not be read
as availability in the current published release.

## macOS

Install and start [Docker Desktop](https://docs.docker.com/desktop/setup/install/mac-install/),
then confirm that `docker compose version` reports 2.33.1 or newer. Docker
Desktop must have enough disk space and memory for the nodes selected in the
wizard; see [node requirements](nodes.md#storage-and-resource-planning).

```sh
brew tap vijitsingh97/bitcoin-starter-stack https://github.com/VijitSingh97/bitcoin-starter-stack.git
brew install vijitsingh97/bitcoin-starter-stack/bitcoin-starter-stack
bitcoin-stack init
```

Installation is intentionally inert. `bitcoin-stack init` creates the private
configuration, asks which nodes to run, and offers to download and start their
containers. If image download is deferred, use `bitcoin-stack pull` and then
`bitcoin-stack up` when ready. The Homebrew dashboard defaults to
`http://127.0.0.1:8080`; set `dashboard.port` in `config.json` and run
`bitcoin-stack apply` to choose another host port.

The default user-owned paths survive Homebrew upgrades:

- configuration: `~/Library/Application Support/bitcoin-starter-stack/config/config.json`
- generated state and backups: `~/Library/Application Support/bitcoin-starter-stack/state/`
- chain data: `~/Library/Application Support/bitcoin-starter-stack/data/<node>/`

On macOS, set `BITCOIN_STACK_HOME` before invoking the command to move all three defaults
under another directory. The individual `BITCOIN_STACK_CONFIG_DIR`,
`BITCOIN_STACK_STATE_DIR`, and `BITCOIN_STACK_DATA_DIR` variables remain
available for separate locations.

Homebrew services do not inherit variables from a shell profile. When using
custom paths, put the same values in
`~/.homebrew/services/bitcoin-starter-stack.env`, one `KEY=value` per line, then
restart the service. Homebrew retains this service environment across upgrades.
For example:

```text
BITCOIN_STACK_HOME=/Volumes/Node Data/bitcoin-starter-stack
```

After setup succeeds, the stack can be supervised at login through launchd:

```sh
brew services start bitcoin-starter-stack
```

The service starts an already configured stack from locally available images
and processes dashboard node, port, and post-sync resource-control requests. It
does not run setup or download containers. Stopping the Homebrew service stops
the host supervisor; use `bitcoin-stack down` when the containers should also
stop.

## Linuxbrew

Homebrew on Linux is supported, although Ubuntu users can use the native APT
package instead. Install Docker Engine and Compose 2.33.1 or newer separately,
and configure Docker so the current user can run it without `sudo`. The formula
uses the same install and setup commands as macOS.

Linuxbrew follows the XDG directory convention:

- configuration: `${XDG_CONFIG_HOME:-~/.config}/bitcoin-starter-stack/config.json`
- generated state: `${XDG_DATA_HOME:-~/.local/share}/bitcoin-starter-stack/state/`
- chain data: `${XDG_DATA_HOME:-~/.local/share}/bitcoin-starter-stack/data/<node>/`

`brew services start bitcoin-starter-stack` uses a user systemd service on
Linux. A logged-out user service may require lingering to remain active; the APT
package is the simpler choice for a system-wide Ubuntu server.

## Upgrade and removal

Back up before an upgrade, then apply the new immutable payload to the existing
configuration:

```sh
bitcoin-stack backup
brew update
brew upgrade bitcoin-starter-stack
bitcoin-stack pull
bitcoin-stack apply
```

Homebrew replaces the versioned Cellar payload and retains the user-owned
configuration, dashboard state, and chain data. Uninstalling the formula also
leaves those user directories in place. Stop the service and containers first
if the installation is being retired:

```sh
brew services stop bitcoin-starter-stack
bitcoin-stack down
brew uninstall bitcoin-starter-stack
```

## Test a local release artifact

The tracked formula is a release template. A release job computes the exact
SHA-256 of the immutable tarball and renders an installable formula; a checksum
is never guessed or copied from a different archive. To exercise the same path
from a committed local branch:

```sh
version=$(cat VERSION)
git archive --worktree-attributes --format=tar.gz \
  --prefix=bitcoin-starter-stack/ \
  --output=/tmp/bitcoin-starter-stack.tar.gz HEAD
scripts/build-homebrew-formula.sh \
  --url "file:///tmp/bitcoin-starter-stack.tar.gz" \
  /tmp/bitcoin-starter-stack.tar.gz
brew tap-new --no-git local/node-manager
cp ./dist/Formula/bitcoin-starter-stack.rb \
  "$(brew --repository local/node-manager)/Formula/bitcoin-starter-stack.rb"
brew install local/node-manager/bitcoin-starter-stack
brew test local/node-manager/bitcoin-starter-stack
```

This local path installs the committed `HEAD`; it does not include uncommitted
working-tree changes. Remove the temporary tap with
`brew untap --force local/node-manager` after testing. The published formula
uses the matching tagged release asset URL and checksum.
