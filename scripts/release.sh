#!/usr/bin/env bash
# Cut a release: preflight checks, then tag vVERSION and push the tag.
# The release workflow (.github/workflows/release.yml) takes it from there —
# it re-runs the full test gate against the tag and publishes the GitHub
# Release with a tarball. Nothing is published until that gate is green.
#
# Usage: scripts/release.sh [--dry-run] [-y]
#   --dry-run   Run every preflight check and print the plan; tag nothing.
#   -y          Skip the confirmation prompt.
set -euo pipefail
cd "$(dirname "$0")/.."

dry_run=0
yes=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -y) yes=1 ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

fail() {
  echo "PREFLIGHT FAILED: $1" >&2
  exit 1
}

# 1. Clean tree — a release must be exactly what's committed
[ -z "$(git status --porcelain)" ] || fail "working tree is not clean"

# 2. Valid semver in VERSION
version=$(cat VERSION 2>/dev/null || true)
echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' ||
  fail "VERSION must contain plain semver (got: '$version')"
tag="v$version"

# 3. Tag must not already exist (locally or on the remote)
git rev-parse -q --verify "refs/tags/$tag" >/dev/null &&
  fail "tag $tag already exists locally"
if git ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1; then
  fail "tag $tag already exists on origin"
fi

# 4. CHANGELOG must have a section for this version
scripts/release-notes.sh "$version" >/dev/null ||
  fail "CHANGELOG.md has no section for $version"

# 5. Soft checks: branch and CI state (warn, don't block — the release
#    workflow re-runs the full gate on the tag anyway)
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "main" ] || echo "WARN: releasing from branch '$branch', not main"
if command -v gh >/dev/null && git remote get-url origin >/dev/null 2>&1; then
  sha=$(git rev-parse HEAD)
  conclusion=$(gh run list --commit "$sha" --workflow ci.yml --limit 1 \
    --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo unknown)
  [ "$conclusion" = "success" ] || echo "WARN: CI for $sha is '$conclusion' (gate will re-run on the tag)"
fi

echo "Preflight OK: $tag from $(git rev-parse --short HEAD) on $branch"
if [ "$dry_run" = "1" ]; then
  echo "--dry-run: would tag $tag and push it. Release notes:"
  scripts/release-notes.sh "$version"
  exit 0
fi

if [ "$yes" != "1" ]; then
  printf "Tag and push %s? The release workflow publishes automatically once green. [y/N] " "$tag"
  read -r reply
  case "$reply" in y | Y) ;; *)
    echo "Aborted."
    exit 1
    ;;
  esac
fi

git tag -a "$tag" -m "Release $tag"
git push origin "$tag"
echo "Pushed $tag — watch the Release workflow: gh run watch"
