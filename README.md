# argo-shim-lite

Run Claude Code (and other Anthropic-API-compatible clients) against Argonne's internal Argo LLM API from outside the ANL network. Wraps the SSH tunnel, local proxy, and Claude launch into a single command.

## Prerequisites

- SSH access to `homes.cels.anl.gov`
- Python 3.12 with `aiohttp` (`pip install -r requirements.txt`)
- Claude Code installed:
  ```bash
  curl -fsSL https://claude.ai/install.sh | bash
  ```

## One-time setup

1. Clone this repo somewhere stable, e.g. `~/argo-shim-lite`.
2. Install the proxy's Python dependency:
   ```bash
   pip install -r requirements.txt
   ```
3. Make the launcher callable from anywhere by adding its directory to your `PATH` in `~/.bashrc`:
   ```bash
   export PATH="$HOME/argo-shim-lite:$PATH"
   ```
   Reload your shell:
   ```bash
   source ~/.bashrc
   ```

### Running from Aurora

**Login node (UAN).** Aurora UANs can't reach `homes.cels.anl.gov` directly — SSH needs to jump through `logins.cels.anl.gov`. Add this to `~/.ssh/config` on the UAN so the launcher's plain `ssh homes.cels.anl.gov` transparently routes through the jump host:

```
Host homes.cels.anl.gov
    ProxyJump logins.cels.anl.gov
```

Make sure the file is locked down or SSH will refuse to use it:

```bash
chmod 600 ~/.ssh/config
```

**Compute node (`qsub -I`).** Compute nodes can't reach `logins.cels.anl.gov` directly either, so SSH has to chain through a UAN first. The launcher detects this automatically when `$PBS_JOBID` is set and adds the extra hop, using `$PBS_O_HOST` (the UAN you submitted from) as the first jump. Override with the env vars below if needed.

## Usage

From any directory:

```bash
argonne-claude.sh
```

The script handles everything end to end:

1. Opens an SSH tunnel to `apps.inside.anl.gov` via `homes.cels.anl.gov` (you'll be prompted for MFA).
2. Starts the local proxy on port 8083.
3. Launches Claude Code wired up to the proxy.

When you exit Claude, the proxy and SSH tunnel are torn down automatically.

### Optional environment overrides

- `ARGO_USER` — override the auth token sent to Argo (defaults to `$USER`).
- `CLAUDE_EXECUTABLE` — path or name of the `claude` binary to launch (defaults to `claude`).
- `ARGO_AURORA_UAN` — UAN to use as the first SSH hop on Aurora compute nodes (defaults to `$PBS_O_HOST`, falling back to `aurora-uan-0011`).
- `ARGO_SSH_JUMP` — explicit comma-separated SSH jump chain passed as `-J`. Overrides the auto-detected compute-node default.

## How it works

1. The SSH tunnel forwards local port 8082 to `apps.inside.anl.gov:443` through `homes.cels.anl.gov`.
2. `claude-argo-proxy.py` listens on port 8083, rewrites the `Host` header, and forwards requests through the tunnel.
3. Claude Code sends requests to `http://127.0.0.1:8083/argoapi/`, which routes them to the Argo API.

### Manual setup (for debugging)

If you need to run the pieces by hand — e.g. to inspect proxy logs in isolation — open three terminals:

```bash
# Terminal 1: SSH tunnel
ssh -L 8082:apps.inside.anl.gov:443 -N homes.cels.anl.gov

# Terminal 2: Local proxy
python3.12 claude-argo-proxy.py

# Terminal 3: Claude Code
ANTHROPIC_BASE_URL="http://127.0.0.1:8083/argoapi/" \
  ANTHROPIC_AUTH_TOKEN=$USER \
  CLAUDE_CODE_SKIP_ANTHROPIC_AUTH=1 \
  claude
```

## Install Claude Code on Aurora Login Nodes

```bash
module use /soft/modulefiles
module load frameworks

# installs in .local/bin
curl -fsSL https://claude.ai/install.sh | bash
```
