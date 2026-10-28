#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

# shellcheck source=/dev/null
source /ctx/lib-verify.sh

##################
### Repositories
##################

# Terra publishes one repo per Fedora release and lags the bump on newer
# bases. terra$releasever then has no mirrors: the bootstrap below fails
# outright, and once past it --skip-unavailable drops every terra package
# without failing. Pin to the previous release until the current one is
# published; the check stops matching as soon as it is.
# no pipe into grep -q: it exits on first match, and the resulting SIGPIPE
# would trip pipefail even on success
terra_release="$(rpm -E %fedora)"
terra_origin="https://repos.fyralabs.com"
terra_pin=""
# Only a definite 404 counts -- a network failure reports 000 and is left
# alone, so a blip cannot silently pin the wrong release.
terra_status="$(curl -sSo /dev/null -w '%{http_code}' \
    "${terra_origin}/terra${terra_release}/repodata/repomd.xml" || true)"
if [ "${terra_status}" = "404" ]; then
    terra_pin="$((terra_release - 1))"
    echo "NOTE: terra${terra_release} is not published; falling back to terra${terra_pin}"
    terra_release="${terra_pin}"
fi

# Terra: nerd fonts, ms-core fonts, git-koji, lazyssh, ...
# (aurora does not ship the terra repo, unlike bazzite)
if [ ! -f /etc/yum.repos.d/terra.repo ]; then
    dnf5 -y install --nogpgcheck \
        --repofrompath "terra,https://repos.fyralabs.com/terra${terra_release}" \
        terra-release
fi

# Terra's metalink advertises a repomd checksum that its mirrors -- including
# the fyralabs origin -- do not always have yet. dnf rejects every mirror
# ("Usable URL not found"), the repo goes unusable, and --skip-unavailable then
# drops every terra package without failing. Go straight to the origin: no
# advertised hash, no mirror race. terra-release ships the baseurl commented
# out next to each metalink.
sed -i -e 's/^metalink=/#metalink=/' -e 's/^#baseurl=/baseurl=/' /etc/yum.repos.d/terra*.repo

# terra-release's own repo files use $releasever; pin those too, or the
# packages below come from the release we just established does not exist.
if [ -n "${terra_pin}" ]; then
    sed -i "s/[$]releasever/${terra_pin}/g" /etc/yum.repos.d/terra*.repo
fi

# Tailscale repo ships in the base image, but disabled
dnf5 config-manager setopt tailscale-stable.enabled=true

# COPRs
dnf5 -y copr enable atim/starship
dnf5 -y copr enable scottames/ghostty
# terra also ships ghostty; give the ghostty copr winning priority
dnf5 config-manager setopt 'copr:copr.fedorainfracloud.org:scottames:ghostty.priority=50'

# https://support.mozilla.org/en-US/kb/install-firefox-linux#w_install-firefox-rpm-package-recommended
dnf5 config-manager addrepo --id=mozilla \
    --set=baseurl=https://packages.mozilla.org/rpm/firefox \
    --set=gpgkey=https://packages.mozilla.org/rpm/firefox/signing-key.gpg \
    --set=gpgcheck=1 --set=repo_gpgcheck=0 --set=priority=10

# https://code.claude.com/docs/en/setup#dnf
tee /etc/yum.repos.d/claude-code.repo <<'EOF'
[claude-code]
name=Claude Code
baseurl=https://downloads.claude.ai/claude-code/rpm/stable
enabled=1
gpgcheck=1
gpgkey=https://downloads.claude.ai/keys/claude-code.asc
EOF

# https://support.1password.com/install-linux/#fedora-or-red-hat-enterprise-linux
rpm --import https://downloads.1password.com/linux/keys/1password.asc
echo -e "[1password]\nname=1Password Stable Channel\nbaseurl=https://downloads.1password.com/linux/rpm/stable/\$basearch\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=\"https://downloads.1password.com/linux/keys/1password.asc\"" >/etc/yum.repos.d/1password.repo

##############
### Packages
##############

# Packages to make sure we always have latest of
UPDATE_PACKAGES=(
    ca-certificates
)

# A few things I want to be sure I don't get from Terra repos or definitely aren't in there
PACKAGES_NOTERRA=(
    # I'd prefer non-flatpak browser so I can do 1password desktop integration easier
    firefox

    # 1Password (Integrations struggle in Flatpak install)
    1password
    1password-cli

    # Terminal
    ghostty

    # Programming stuff I find handy
    code

    # LLM
    claude-code
)

PACKAGES=(
    # Shell / prompt stuff
    fish
    fzf
    plocate
    starship
    tealdeer
    thefuck
    zoxide

    # Editors
    joe
    jupp
    nano

    # Dotfiles / keys
    # (completions generated below; terra's chezmoi-*-completion subpackages
    # hard-pin an exact chezmoi version and hold it back from updates)
    chezmoi
    keychain # 3.0.4-4+ gates /etc/profile.d/keychain.sh on ~/.keychainrc (rhbz#2529776)

    # /etc under version control
    etckeeper

    # btrfs housekeeping; openvox-control profile::btrfs enables the timers
    bees
    btrfsmaintenance

    # Programming stuff
    bat
    bat-extras
    direnv
    gh
    git-filter-repo
    git-koji # terra
    git-lfs
    git-subtree
    jq
    libffi-devel
    mise
    mise-bash-completion
    mise-fish-completion
    nodejs
    nodejs-npm
    perl-App-cpanminus
    perl-CPAN
    perltidy
    pre-commit
    ripgrep
    ruby-devel
    rubygem-puppet-lint
    rubygems
    rubygems-devel
    ruff
    ShellCheck
    shfmt
    sqlite
    sqlite-tools
    ugrep
    uv
    yamllint
    yq

    # Containers
    distrobox
    podman
    # podman-docker # conflicts with docker-ce; skip
    podman-compose
    podman-tui
    podlet
    kontainer

    # Handy tools
    age
    htop
    hugo
    lazyssh # terra
    mtr
    netcat
    powertop
    rclone
    tailscale

    # Fonts
    bitstream-vera-fonts-all
    bitstreamverasansmono-nerd-fonts
    droidsansmono-nerd-fonts
    fira-code-fonts
    firacode-nerd-fonts
    firamono-nerd-fonts
    google-android-emoji-fonts
    google-roboto-fonts
    ms-core-tahoma-fonts
    ms-core-verdana-fonts
    noto-nerd-fonts
    robotomono-nerd-fonts
    ubuntu-nerd-fonts
    ubuntumono-nerd-fonts
    ubuntusans-nerd-fonts

    # Running as a VM guest (VMware, qemu/kvm/libvirt)
    open-vm-tools
    open-vm-tools-desktop
    qemu-guest-agent
    spice-vdagent
    spice-webdavd

    # Various (de)compression tools
    7zip
    bzip2
    bzip3
    bzip3-grep
    bzip3-tools
    gzip
    ncompress
    unzip
    xz
    zip
    zstd
)

# 1Password's %post does a bare `mkdir /usr/local`, which fails on ostree
# images where /usr/local is a symlink to /var/usrlocal (and dnf5 fails the
# whole transaction on %post errors). Swap in a real directory for the
# transaction and restore the symlink afterwards.
usrlocal_target=""
if [ -L /usr/local ]; then
    usrlocal_target=$(readlink /usr/local)
    rm /usr/local
    mkdir /usr/local
fi

# Snapshot /var so we can tell what this transaction adds. /var is
# machine-local on bootc and is reset on deploy, so anything created here has
# to be recreated by tmpfiles.d rather than shipped in the image.
# (/var/cache, /var/log and /var/tmp are build mounts, not part of the image.)
var_dirs() {
    find /var -mindepth 1 \
        \( -path /var/cache -o -path /var/log -o -path /var/tmp \) -prune -o \
        -type d -print | sort
}
var_dirs >/tmp/var-dirs-before

dnf5 -y upgrade --skip-unavailable                                       "${UPDATE_PACKAGES[@]}"
dnf5 -y install --skip-unavailable --skip-broken --disable-repo='terra*' "${PACKAGES_NOTERRA[@]}"
dnf5 -y install --skip-unavailable --skip-broken                         "${PACKAGES[@]}"

if [ -n "${usrlocal_target}" ]; then
    # Relocate launchers scriptlets dropped in /usr/local/bin (1password ships
    # 1password-mcp there) to /usr/bin so they survive restoring the symlink.
    if [ -d /usr/local/bin ]; then
        for f in /usr/local/bin/*; do
            # -e alone would skip dangling symlinks, which is exactly what
            # these launchers can be at this point in the build
            [ -e "$f" ] || [ -L "$f" ] || continue
            # rewrite relative symlink targets so they still resolve from /usr/bin
            if [ -L "$f" ]; then
                target=$(readlink "$f")
                case "$target" in
                /*) ;;
                *) ln -sfn "$(realpath -m "$(dirname "$f")/$target")" "$f" ;;
                esac
            fi
            mv -f "$f" "/usr/bin/${f##*/}"
            echo "relocated ${f} -> /usr/bin/${f##*/}"
        done
    fi
    # warn about (and drop) anything left outside /usr/local/bin
    find /usr/local -mindepth 1 -not -type d | while read -r f; do
        echo "WARNING: discarding unexpected /usr/local content: $f" >&2
    done
    rm -rf /usr/local
    ln -s "${usrlocal_target}" /usr/local
fi

##############
### Services
##############

SYSTEMCTL=(
    chrony-wait.service
    etckeeper.timer
    man-db-cache-update.service
    man-db-restart-cache-update.service
    plocate-updatedb.timer
    podman.socket
    tailscaled.service
    # qemu-guest-agent/spice are udev/socket activated; only vmtoolsd needs enabling
    vmtoolsd.service
)

systemctl enable "${SYSTEMCTL[@]}"

#######################
### Shell completions
#######################

mkdir -p /etc/fish/completions /etc/bash_completion.d

tailscale completion fish >/etc/fish/completions/tailscale.fish
tailscale completion bash >/etc/bash_completion.d/tailscale

# redirect $HOME because starship and 1password/op really like to write cache files under /root/
HOME=/var/tmp starship completions fish >/etc/fish/completions/starship.fish
HOME=/var/tmp starship completions bash >/etc/bash_completion.d/starship

HOME=/var/tmp op --cache=false completion fish >/etc/fish/completions/op.fish
HOME=/var/tmp op --cache=false completion bash >/etc/bash_completion.d/op

npm completion >/etc/bash_completion.d/npm

HOME=/var/tmp chezmoi completion fish >/etc/fish/completions/chezmoi.fish
HOME=/var/tmp chezmoi completion bash >/etc/bash_completion.d/chezmoi

# the HOME=/var/tmp redirects above leave dotfiles (and an op daemon socket)
# behind; drop them so they don't end up in the image
rm -rf /var/tmp/.config /var/tmp/.cache /var/tmp/.local

####################
### Image hygiene
####################

# 1Password's scriptlets create these groups directly instead of shipping
# sysusers.d, which `bootc container lint` flags, and the build container
# allocates them from the 1000+ range. The setgid helpers (BrowserSupport,
# 1password-mcp, op) carry that numeric GID in the image, so on a real system
# they land on a human's group. Setgid to your own group is no privilege
# change, the kernel leaves AT_SECURE unset, and BrowserSupport aborts
# ("running without libc's security"): the browser extension shows
# "Connection problem". Pin the GIDs and re-own the files.
# 900-902: system range (a setgid binary on a user-range GID would hand out
# that user's group), clear of the base image (allocates downward from 999),
# and the same numbers freizzite pins. Hosts whose /etc/group predates this
# keep their old numbers (systemd-sysusers never renumbers), so each existing
# host needs `groupmod -g` once to match.
declare -A OP_GIDS=([onepassword]=900 [onepassword-mcp]=901 [onepassword-cli]=902)
: >/usr/lib/sysusers.d/freirora-1password.conf
for group in onepassword onepassword-mcp onepassword-cli; do
    old_gid="$(getent group "${group}" | cut -d: -f3)" || continue
    new_gid="${OP_GIDS[${group}]}"
    if [ "${old_gid}" != "${new_gid}" ]; then
        groupmod -g "${new_gid}" "${group}"
        # chgrp clears setgid; put it back on files that had it
        find /usr /opt -xdev -gid "${old_gid}" -print0 | while IFS= read -r -d '' f; do
            mode="$(stat -c %a "${f}")"
            chgrp -h "${new_gid}" "${f}"
            [ -L "${f}" ] || chmod "${mode}" "${f}"
        done
    fi
    echo "g ${group} ${new_gid}" >>/usr/lib/sysusers.d/freirora-1password.conf
done
[ -s /usr/lib/sysusers.d/freirora-1password.conf ] ||
    rm -f /usr/lib/sysusers.d/freirora-1password.conf
for f in /opt/1Password/1Password-BrowserSupport /opt/1Password/1password-mcp /usr/bin/op; do
    [ -e "${f}" ] || continue
    stat -c '%a %G %n' "${f}"
    [ "$(stat -c %a "${f}")" = 2755 ] || { echo "ERROR: ${f} lost setgid" >&2; exit 1; }
done

# dnf4 state (dragged in by etckeeper-dnf/dnf-plugins-core) and rpm-state are
# build artifacts. Drop them before the /var snapshot so we don't bother
# recreating them at boot.
rm -rf /var/lib/dnf /var/lib/rpm-state

# Everything else this build added under /var gets a tmpfiles.d entry (so it's
# recreated on a fresh deploy) and is then removed from the image.
var_dirs >/tmp/var-dirs-after
{
    echo "# Generated at image build time by build_files/build.sh"
    comm -13 /tmp/var-dirs-before /tmp/var-dirs-after | while read -r d; do
        printf 'd %s 0%s %s %s - -\n' \
            "$d" "$(stat -c '%a' "$d")" "$(stat -c '%U' "$d")" "$(stat -c '%G' "$d")"
    done
} >/usr/lib/tmpfiles.d/freirora-var.conf

comm -13 /tmp/var-dirs-before /tmp/var-dirs-after | tac | while read -r d; do
    rm -rf "$d"
done

# Fail the build if any requested package didn't actually get installed.
# Both lists: `--skip-unavailable` silently drops anything unresolvable, so
# an unverified list is a list that can quietly go missing.
verify_packages_installed "${PACKAGES_NOTERRA[@]}" "${PACKAGES[@]}"

###################
### Image branding
###################

# Last, after every dnf transaction: /usr/lib/os-release is rpm-owned.
/ctx/image-info
