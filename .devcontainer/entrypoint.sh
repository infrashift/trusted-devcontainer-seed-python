#!/bin/bash
set -e

SSH_PORT="${SSH_PORT:-2222}"

if [[ "$SSH_PORT" != "2222" ]]; then
    sed -i "s/^Port 2222$/Port ${SSH_PORT}/" /etc/ssh/sshd_config
fi

mkdir -p /run/sshd

# ---- Surface HTTP(S) proxy env to interactive SSH login shells --------------
# sshd resets the process env on login, so task-level HTTP_PROXY never reaches
# the developer's shell. Write it to /etc/profile.d so `bash -l` picks it up
# (and the ForceCommand wrapper invokes `bash -lc` for VS Code Remote-SSH).
if [[ -n "${HTTP_PROXY:-}" ]]; then
    cat > /etc/profile.d/proxy.sh <<EOF
export HTTP_PROXY="${HTTP_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY:-${HTTP_PROXY}}"
export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,.consul}"
export http_proxy="\$HTTP_PROXY"
export https_proxy="\$HTTPS_PROXY"
export no_proxy="\$NO_PROXY"
EOF
    chmod 644 /etc/profile.d/proxy.sh
    echo "Rendered /etc/profile.d/proxy.sh (HTTP_PROXY=${HTTP_PROXY})"
fi

# ---- Surface the registry door to login shells ------------------------------
# Same mechanism as the proxy block above and for the same reason: sshd resets
# the environment, so the task-level REGISTRY never reaches the developer's
# shell or a VS Code terminal.
#
# REGISTRY_NAMESPACE is here because it is the part people get wrong. Nexus
# scopes a developer's write grant with a content selector matching
# `^/v2/<username>/`, so a tag has to CARRY the username -- and a tag without it
# is refused with a 403 naming the repository, which reads as "I was not granted
# access" rather than "I left my namespace off". Having the value in the shell
# means the documented command is a copy-paste rather than a thing to remember:
#
#   buildah push app:dev docker://$REGISTRY/$REGISTRY_NAMESPACE/app:dev
#
# Nothing here is a credential. `buildah login` is interactive and takes the
# developer's own SSO password; this is an address and a name.
if [[ -n "${REGISTRY:-}" ]]; then
    cat > /etc/profile.d/registry.sh <<EOF
export REGISTRY="${REGISTRY}"
export REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-}"
EOF
    chmod 644 /etc/profile.d/registry.sh
    echo "Rendered /etc/profile.d/registry.sh (REGISTRY=${REGISTRY}, namespace=${REGISTRY_NAMESPACE:-unset})"
fi

# ---- Surface the companion services to login shells ------------------------
# Same mechanism again. The devpod root puts one <NAME>_HOST / <NAME>_PORT pair
# per declared companion service in the task environment for the processes
# this container starts, and WORKSPACE_SERVICES -- `name=host:port', comma
# separated -- for this block to render into the developer's shell, where sshd
# would otherwise have dropped them. `db' becomes DB_HOST and DB_PORT; a dash
# in a name becomes an underscore. Nothing here is a credential: a service's
# own credentials live in its image, and the mesh decides who may connect.
if [[ -n "${WORKSPACE_SERVICES:-}" ]]; then
    : > /etc/profile.d/services.sh
    IFS=',' read -ra _svcs <<<"${WORKSPACE_SERVICES}"
    for _svc in "${_svcs[@]}"; do
        _name="${_svc%%=*}"; _addr="${_svc#*=}"
        _var="$(printf '%s' "${_name}" | tr 'a-z-' 'A-Z_')"
        printf 'export %s_HOST="%s"\nexport %s_PORT="%s"\n' \
            "${_var}" "${_addr%:*}" "${_var}" "${_addr##*:}" >> /etc/profile.d/services.sh
    done
    chmod 644 /etc/profile.d/services.sh
    echo "Rendered /etc/profile.d/services.sh (${WORKSPACE_SERVICES})"
fi

# ---- Install Vault-rendered authorized_keys --------------------------------
if [[ -f /secrets/authorized_keys ]]; then
    mkdir -p /home/user/.ssh
    cp /secrets/authorized_keys /home/user/.ssh/authorized_keys
    chown -R user:0 /home/user/.ssh
    chmod 700 /home/user/.ssh
    chmod 600 /home/user/.ssh/authorized_keys
    echo "Installed authorized_keys from /secrets/authorized_keys"
fi

# ---- Install Nomad-rendered SSH client config (ProxyJump to bastion) ------
if [[ -f /local/ssh_config ]]; then
    mkdir -p /home/user/.ssh
    cp /local/ssh_config /home/user/.ssh/config
    chown user:0 /home/user/.ssh/config
    chmod 600 /home/user/.ssh/config
    echo "Installed ~/.ssh/config from /local/ssh_config"
fi

# ---- Install Vault-rendered jump key (bastion authentication) -------------
if [[ -f /secrets/jump_key ]]; then
    mkdir -p /home/user/.ssh
    cp /secrets/jump_key /home/user/.ssh/jump_key
    chown user:0 /home/user/.ssh/jump_key
    chmod 600 /home/user/.ssh/jump_key
    echo "Installed ~/.ssh/jump_key for ssh-egress ProxyJump"
fi

# Belt-and-braces: re-assert .ssh perms in case of bind-mounted content
if [[ -d /home/user/.ssh ]]; then
    chown -R user:0 /home/user/.ssh 2>/dev/null || true
    chmod 700 /home/user/.ssh 2>/dev/null || true
    [[ -f /home/user/.ssh/authorized_keys ]] && chmod 600 /home/user/.ssh/authorized_keys 2>/dev/null || true
fi

# ---- Runtime devcontainer feature install (node) --------------------------
# Demonstrates the http-egress gateway in action at first boot. The
# devcontainer.json under /home/user/workspace/.devcontainer/ is the source of
# truth for both features; the github-cli one is already baked in at build
# time, so we install only `node` here. Gated by a sentinel so subsequent
# container restarts are fast.
SENTINEL=/home/user/.devcontainer-features.runtime-applied

# This runs in the BACKGROUND, after sshd is already accepting connections,
# and it downloads as `user` rather than as root. Both matter:
#
# 1. ORDERING. It used to run inline, before sshd started, so a fresh deploy
#    had a ~132s window with no sshd at all — `ssh -p 2224` was refused and
#    `make verify` failed on "ssh through traefik".
#
# 2. IDENTITY. The sidecar sets TransparentProxy.UID=0, which EXEMPTS uid 0
#    from the consul-cni redirect — Envoy itself runs as uid 0 and must not
#    have its own traffic re-redirected. The entrypoint runs as root, so its
#    traffic to http-egress.virtual.consul (240.0.0.12) was never redirected
#    into the mesh and had nowhere to go: it always burned the full connect
#    timeout and failed. That was permanent, not a startup race. `user` is
#    uid 1001, whose traffic IS redirected, so the fetch has to happen there.
#
# So: download through the mesh as `user`, then install as root from the local
# copy (the feature's install.sh needs to write /usr/local).
FEATURE_URL="https://github.com/devcontainers/features/archive/refs/heads/main.tar.gz"

install_node_feature() {
    [[ -f "${SENTINEL}" ]] && return 0
    command -v devcontainer >/dev/null 2>&1 || return 0

    local tmpdir
    tmpdir=$(mktemp -d)
    chown user:0 "${tmpdir}"
    chmod 775 "${tmpdir}"

    # Wait for the mesh egress path to come up, probing as `user` through the
    # proxy — the real path, not just a TCP connect — with a short per-attempt
    # timeout so a hung path retries instead of stalling.
    local ready=0 i
    for i in $(seq 1 60); do
        # -L matters: github.com redirects archive downloads to
        # codeload.github.com, so a probe without it "succeeds" on the 302
        # while the real fetch is still blocked by the allow-list.
        if runuser -u user -- env \
             HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" \
             NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,.consul}" \
             curl -fsSL --connect-timeout 3 --max-time 20 -o /dev/null \
             "${FEATURE_URL}" 2>/dev/null; then
            ready=1
            break
        fi
        sleep 5
    done
    if [[ "${ready}" != "1" ]]; then
        echo "WARN: http-egress not reachable after ~5min — skipping runtime feature 'node'." >&2
        echo "      Check the sm-http-egress deployment and its allow-list." >&2
        rm -rf "${tmpdir}"
        return 0
    fi

    echo "Installing runtime devcontainer feature: node (via http-egress)..."
    if runuser -u user -- env \
         HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" \
         NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,.consul}" \
         curl -fsSL "${FEATURE_URL}" -o "${tmpdir}/features.tgz" \
       && VERSION=20 NVMINSTALLPATH=/usr/local/share/nvm bash -c '
            set -e
            cd "$1"
            tar xzf features.tgz
            cd features-main/src/node
            chmod +x install.sh
            bash ./install.sh
          ' _ "${tmpdir}"
    then
        touch "${SENTINEL}"
        chown user:0 "${SENTINEL}"
        echo "Runtime feature 'node' installed."
    else
        echo "WARN: runtime feature install failed (continuing). Check http-egress allow-list." >&2
    fi
    rm -rf "${tmpdir}"
}

# Backgrounded before the exec: the subshell keeps running as a child of the
# exec'd sshd (same PID 1) and inherits stdout/stderr, so its progress still
# lands in the Nomad task log.
install_node_feature &

echo "Starting sshd on port ${SSH_PORT}..."
exec /usr/sbin/sshd -D -e
