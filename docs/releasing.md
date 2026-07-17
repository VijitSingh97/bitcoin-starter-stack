# Releasing

How this stack is versioned and released. The pipeline is
[`scripts/release.sh`](../scripts/release.sh) plus the
[Release workflow](../.github/workflows/release.yml); preview any release
with `scripts/release.sh --dry-run`.

## One product, one version

The stack is released as a single product. The components are upstream
projects pinned by digest — Bitcoin Core (`bitcoin/bitcoin` in
`docker-compose.yml`), the tor and dashboard base images (Dockerfiles),
and the pinned pip packages. The first-party code is the dashboard, the
orchestration (`docker-compose.yml`, `configure.sh`, `./stack`), and the
configs. A release is one tag with one changelog and one upgrade path.

The pins are the ingredients manifest of each release: bumping any of
them — including a Bitcoin Core security update — is a normal release
(bump the pin, cut a patch, the gate re-tests the composed set).

Multi-arch images (amd64 and arm64/Raspberry Pi) for the two first-party
components — `tor` and `dashboard` — are built and published to GHCR
(`ghcr.io/vijitsingh97/bitcoin-starter-stack-*`) per release by the `images`
job in the [Release workflow](../.github/workflows/release.yml).
`docker compose up` pulls these prebuilt tags; it only builds locally as a
fallback (e.g. on an unreleased commit with no matching published tag). The
release artifact is also a source tarball, and the digest-pinned bases make
the build reproducible if you do build.

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
   (`git archive`, so `.github` is excluded per `.gitattributes`).

Nothing is published until the gate is green. A red gate leaves the tag
without a release — fix on `main`, bump the patch version, tag again
(release tags are protected from deletion and rewrite by a repo ruleset).

## How users get a release

- **Tarball:** download `bitcoin-starter-stack.tar.gz` from the release,
  unpack, `cp config.example.json config.json`, `./configure.sh`,
  `docker compose up -d`.
- **Git:** `git pull` (or `git checkout vX.Y.Z`), then `./stack apply` —
  add `docker compose build` when `build/` changed.
- Running stacks learn about new releases from the dashboard's daily
  update check (badge + optional Telegram 🆕 alert) — see
  [Notifications](notifications.md).
