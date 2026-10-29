#!/bin/bash
# Helpers for verifying build results.

# Fail the build if any requested package is not installed.
#
# We install with --skip-unavailable/--skip-broken so a renamed or missing
# package silently no-ops instead of failing dnf. This asserts, after the
# fact, that every package we asked for is actually present in the image.
#
# Uses `rpm -q --whatprovides` so both exact package names and virtual
# provides (e.g. `netcat` -> `nmap-ncat`) are honored, and presence is
# checked regardless of which layer (base image or ours) installed it.
verify_packages_installed() {
    local missing=()
    local pkg
    for pkg in "$@"; do
        if ! rpm -q --whatprovides "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: requested packages not installed: ${missing[*]}" >&2
        return 1
    fi
    echo "All ${#} requested packages verified installed."
}

# Fail the build if any listed binary or shared object has unresolved symbols.
#
# `ldd -r` forces full relocation, so it catches symbol-version mismatches that
# plain `ldd` (which only checks that each DT_NEEDED soname is findable) misses.
#
# This exists because of 2026-09-03: Fedora's qt6-qtbase 6.11.2-2.fc44 moved
# QUntypedPropertyBinding(QPropertyBindingPrivate*) out of the
# Qt_6.11_PRIVATE_API version node into plain Qt_6, while plasma-workspace and
# kf6-* stayed at builds linked against the old node. Every soname still
# resolved, so nothing upstream noticed; the image booted to kwin_wayland with
# a cursor on a black screen and no login greeter, forever.
#
# QML/KCM plugins are the ones that matter here: they are dlopen'd at runtime,
# so no binary in the image references them and a broken one is invisible until
# a user tries to log in. Add the plugin, not just the binary that loads it.
verify_libs_resolve() {
    local broken=()
    local target unresolved
    for target in "$@"; do
        if [ ! -e "${target}" ]; then
            echo "ERROR: link-check target does not exist: ${target}" >&2
            broken+=("${target} (missing)")
            continue
        fi
        # ldd exits nonzero when -r finds unresolved symbols; grep exits
        # nonzero when it finds none. Neither should abort under pipefail.
        unresolved="$(ldd -r "${target}" 2>&1 |
            grep -E 'undefined symbol|not found' || true)"
        if [ -n "${unresolved}" ]; then
            echo "ERROR: unresolved symbols in ${target}:" >&2
            echo "${unresolved}" >&2
            broken+=("${target}")
        fi
    done
    if [ ${#broken[@]} -gt 0 ]; then
        echo "ERROR: ${#broken[@]} link-check target(s) failed: ${broken[*]}" >&2
        return 1
    fi
    echo "All ${#} link-check targets resolve cleanly."
}
