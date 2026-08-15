#!/usr/bin/env bash
# Newest build time among a set of tracked packages, as a unix epoch.
#
# The image rebuilds when its base moves, but a few packages come from vendor
# repos that move independently of it -- Firefox security releases in
# particular. This reports when any of them was last built so the gate can
# compare that against the timestamp on our published image.
#
# `%{buildtime}` rather than the repo file mtime on purpose: it does not change
# when a repo is re-synced or remirrored, so a mirror refresh cannot trigger a
# build on its own.
#
# Queried through dnf in a Fedora container instead of parsing repodata by
# hand: the repos between them use .gz, .zst and .zck, and dnf already matches
# exact package names and picks the newest build.
#
# Fails OPEN and silent: any problem prints nothing and exits 0, so a broken
# query leaves the other gate signals to decide rather than blocking every
# build or forcing a spurious one.
#
# Inputs, via the environment:
#   TRACKED   one "<package> <repo-id> <baseurl>" per line, blank/# ignored
#   IMAGE     container image to run dnf in (default: Fedora 44)
#
# Prints, on success:  <epoch> <package>

set -uo pipefail

IMAGE="${IMAGE:-quay.io/fedora/fedora:44}"
[ -n "${TRACKED:-}" ] || exit 0

repo_args=()
packages=()
while read -r pkg repo url; do
    [ -z "${pkg}" ] && continue
    case "${pkg}" in \#*) continue ;; esac
    repo_args+=("--repofrompath=${repo},${url}" "--repo=${repo}")
    packages+=("${pkg}")
done <<<"${TRACKED}"

[ "${#packages[@]}" -gt 0 ] || exit 0

# gpgcheck off: this only ever reads metadata, never installs anything
out="$(timeout 300 podman run --rm "${IMAGE}" \
    dnf -q --setopt='*.gpgcheck=0' \
    "${repo_args[@]}" \
    repoquery --qf '%{buildtime} %{name}\n' --latest-limit 1 \
    "${packages[@]}" 2>/dev/null)" || exit 0

# highest epoch wins; ignore anything that is not "<digits> <name>"
newest="$(awk '$1 ~ /^[0-9]+$/ && $1 > max { max = $1; who = $2 }
               END { if (max) print max, who }' <<<"${out}")"
[ -n "${newest}" ] || exit 0
echo "${newest}"
