#!/usr/bin/env bash
# Bump this repo to a new upstream Ollaya release.
#   scripts/bump-upstream.sh 0.19.0
# Edits: Dockerfile default OLLAYA_VERSION, Chart.yaml appVersion (+ patch-bumps the chart
# version), and the version examples in README.md. Prints the new chart version.
set -euo pipefail

new="${1:?usage: bump-upstream.sh X.Y.Z}"
[[ $new =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad version: $new" >&2; exit 1; }
cd "$(dirname "$0")/.."

chart=charts/ollaya/Chart.yaml
old=$(sed -n 's/^appVersion: "\(.*\)"/\1/p' "$chart")
oldchart=$(sed -n 's/^version: \(.*\)/\1/p' "$chart")
[[ -n $old && -n $oldchart ]] || { echo "cannot read versions from $chart" >&2; exit 1; }
[[ $old != "$new" ]] || { echo "already at $new" >&2; exit 2; }

IFS=. read -r a b c <<<"$oldchart"
newchart="$a.$b.$((c + 1))"

# portable in-place sed (GNU and BSD)
sedi() { sed -i.bak "$@" && rm -f "${@: -1}.bak"; }

sedi "s/^ARG OLLAYA_VERSION=.*/ARG OLLAYA_VERSION=$new/" Dockerfile
sedi "s/^appVersion: \".*\"/appVersion: \"$new\"/" "$chart"
sedi "s/^version: .*/version: $newchart/" "$chart"
sedi "s/$old/$new/g" README.md
sedi "s/--version $oldchart/--version $newchart/" README.md

echo "$newchart"
