# Releasing

How this stack is versioned and released. The pipeline is
[`scripts/release.sh`](../scripts/release.sh) plus the
[Release workflow](../.github/workflows/release.yml); preview any release
with `scripts/release.sh --dry-run`.

## One product, one version

The stack is released as a single product. The components are upstream
projects pinned by digest — Bitcoin Core (`bitcoin/bitcoin` in
`docker-compose.yml`), the tor and dashboard base images (Dockerfiles),
  and the Go build toolchain. The first-party code is the dashboard, the
orchestration (`docker-compose.yml`, `configure.sh`, `./stack`), and the
configs. A release is one tag with one changelog and one upgrade path.

The pins are the ingredients manifest of each release: bumping any of
them — including a Bitcoin Core security update — is a normal release
(bump the pin, cut a patch, the gate re-tests the composed set).

Multi-arch images (amd64 and arm64/Raspberry Pi) for the two first-party
components — `tor` and `dashboard` — are built and published to GHCR
(`ghcr.io/vijitsingh97/bitcoin-starter-stack-*`) per release by the `images`
job in the [Release workflow](../.github/workflows/release.yml).
`./stack pull` downloads these tags with the host's Docker settings;
`./stack up` starts only locally available images and never builds implicitly.
The release artifact is also a source tarball. Source builds need a controlled
build environment with its own Tor egress; see [Privacy](privacy.md).

## Single source of truth

The version lives in the top-level [`VERSION`](../VERSION) file: plain
text, one line, [SemVer](https://semver.org/). Nothing else hardcodes it —
`configure.sh` renders it into `.env`, the dashboard's update checker
compares it against the latest GitHub release, and the release workflow
refuses a tag that disagrees with it.

Versioning rules:

- **Patch** — fixes and pin bumps, no config changes.
- **Minor** — new features and new (defaulted) `config.json` keys.
- **Major** — anything that breaks an existing deployment: removed or
  renamed config keys, subnet changes, data-directory migrations.

## Cutting a release

1. Land the changes on `main` through a PR, including in the same PR:
   - bump `VERSION`
   - add the `## [X.Y.Z]` section to `CHANGELOG.md` (with its link at the
     bottom of the file)
2. From an up-to-date `main`:

   ```bash
   scripts/release.sh --dry-run   # preflight + preview the notes
   scripts/release.sh             # tag vX.Y.Z and push it
   ```

   Preflight blocks on: dirty tree, invalid semver, an already-existing
   tag (local or remote), or a missing changelog section. It warns (but
   does not block) on a non-`main` branch or red CI — the workflow gate
   re-runs everything on the tag regardless.

3. The tag push triggers the [Release workflow](../.github/workflows/release.yml):
   the **full CI suite** (shellcheck, unit tests, compose contract, e2e
   boot with the egress audit) runs against the tagged commit, and only
   then is the GitHub Release published — title, notes extracted from the
   changelog section, and a `bitcoin-starter-stack.tar.gz` source tarball
   (`git archive`, filtered by `.gitattributes`).

The tarball contains runtime source and Docker inputs, configuration, the license,
security policy, changelog, and user guides. Tests, Python parity references,
benchmark experiments, screenshots, maintainer scripts, and development metadata
stay in Git. The production dashboard image contains the compiled Go binary and
runtime web assets; test modules are excluded from the Docker build context.

Nothing is published until the gate is green. A red gate leaves the tag
without a release — fix on `main`, bump the patch version, tag again
(release tags are protected from deletion and rewrite by a repo ruleset).

## APT feed

The first APT feed must wait for a new release containing the Go dashboard so
the package version and published amd64/arm64 images match. Before that release:

1. Create a dedicated signing key for this project. Do not reuse another
   project's private key.
2. Commit its full primary fingerprint in the user onboarding command in
   `docs/privacy.md`, replacing `UNPUBLISHED`, and review that change before
   enabling the feed.
3. Store the armored private key as the `APT_SIGNING_KEY` repository secret and
   its full fingerprint as the `APT_SIGNING_FINGERPRINT` repository variable.
4. Configure GitHub Pages to deploy through GitHub Actions.
5. Decide the feed replay policy before activation. The static feed currently
   omits `Valid-Until`, so releases remain installable between releases but old
   signed snapshots do not expire. Adding an expiry requires monitored periodic
   re-signing so an idle project does not break every user's `apt update`.

After the normal source release and multi-architecture images succeed, the
release workflow builds the architecture-independent package, verifies its
signed feed locally with APT, uploads the package and checksum to the GitHub
Release, and deploys the feed to Pages.

## How users get a release

- **Tarball:** obtain and unpack `bitcoin-starter-stack.tar.gz`, then run
  `./stack init` to download missing images and start.
- **Git:** `./stack upgrade` fetches and applies a release through the guarded
  Tor download path. Source builds stay in a separately controlled environment.
- Running stacks learn about new releases from the dashboard's daily
  update check (badge + optional Telegram 🆕 alert) — see
  [Notifications](notifications.md).
