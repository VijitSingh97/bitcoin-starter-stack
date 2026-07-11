#!/usr/bin/env bash
# Print the CHANGELOG.md section for one version, for use as release notes.
# Exits 1 if the version has no section — a release without notes is a bug.
#
# Usage: scripts/release-notes.sh <version> [changelog]
set -euo pipefail

version=${1:?usage: release-notes.sh <version> [changelog]}
changelog=${2:-CHANGELOG.md}

notes=$(awk -v ver="$version" '
  BEGIN { gsub(/\./, "\\.", ver) }  # dots in the version are literal, not regex
  $0 ~ "^## \\[" ver "\\]" { found = 1; next }
  found && /^## \[/ { exit }
  found { print }
' "$changelog")

# Trim leading blank lines (command substitution already strips trailing ones)
notes=$(printf '%s' "$notes" | sed '/./,$!d')

if [ -z "$notes" ]; then
  echo "No CHANGELOG.md section found for version $version" >&2
  exit 1
fi
printf '%s\n' "$notes"
