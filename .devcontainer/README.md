# .devcontainer

Two things in one image, and the split is deliberate — see the header comment in
`Containerfile`.

## What came from the trusted template

    template:  ghcr.io/infrashift/trusted-devcontainer-templates/python
    version:   v1.0.1

`devcontainer.json`'s nine `features` and the `FROM` line are that template,
digest-pinned and unmodified. A `devcontainer.json` cannot *reference* a
template at build time -- a template is applied, and what it produced is what
is committed here -- so the provenance is recorded above and regenerated with:

    devcontainer templates apply \
      --template-id ghcr.io/infrashift/trusted-devcontainer-templates/python

`scripts/test.sh` proves every reference is still digest-pinned.

## What this repository added, and why each one

| Addition | Why |
| --- | --- |
| `containerUser: user` (uid 1001, **gid 0**) | The template creates `dev` (1001:1001). The platform contract is `user` in group 0, assumed by the portal's `WORKSPACE_SSH_USER`, `sshd_config`, the jobspec's volume-init chown and `/home/user/workspace` in the portal README |
| `openssh-server` | Not in the trusted base. Its absence is a workspace that starts, reports its container healthy, and refuses every connection |
| `entrypoint.sh`, `config/sshd_config`, `config/ssh-login.sh` | The workspace runtime contract — the third is the `ForceCommand` the second names |
| `workspace-skel/` | Copied into an EMPTY host volume by the jobspec's prestart task |

## The three copies

`entrypoint.sh`, `config/sshd_config` and `config/ssh-login.sh` are copies of
`terraform/live/devpod-vscode/container/config/`. That is a
real cost of decision 1 — the repository carries the contract so that
the forge's devcontainer build output is directly runnable — and it means these three files can
drift from the platform's. **If the devpod root's copies change, these must
change with them.** `make lint` at the Terraform level (`lint-workspace-contract`)
compares every seed's and example's copy against the devpod root's byte for
byte, so the drift is caught in the collection -- but not in a repository
already on the forge, which carries its own copy.
