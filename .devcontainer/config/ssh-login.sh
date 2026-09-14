#!/bin/bash
# ForceCommand wrapper. Two roles:
#   - Interactive TTY: drop into a plain login shell (VS Code is the editor).
#   - Non-TTY ($SSH_ORIGINAL_COMMAND set): run the command under `bash -lc`
#     so /etc/profile.d/proxy.sh (HTTP_PROXY, HTTPS_PROXY, NO_PROXY) is
#     sourced. sshd otherwise sanitizes the env on login, so a bare exec
#     would lose the proxy vars and break tools that rely on them.
export TERM=xterm-256color

if [[ -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then
    exec bash -lc "${SSH_ORIGINAL_COMMAND}"
fi
exec bash -l
