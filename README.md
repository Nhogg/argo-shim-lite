# argo-shim-lite

Run Claude Code (and other Anthropic-API-compatible clients) against an Argonne-hosted LLM API. Supports two backends, picked explicitly with `--backend`:

- **`argo`** — Argonne's internal Argo LLM API. Requires an SSH tunnel to `apps.inside.anl.gov` via `homes.cels.anl.gov` plus a local proxy. Works from outside the ANL network.
- **`asksage`** — Ask Sage's Anthropic-compatible endpoint. Defaults to the Argonne-hosted tenant (`https://api.asksage.anl.gov/server/anthropic`); override with `ASKSAGE_BASE_URL` to target a different tenant such as the public `https://api.asksage.ai/server/anthropic`. No tunnel or proxy needed; just an API key.

## Common prerequisites

- Claude Code installed:
  ```bash
  curl -fsSL https://claude.ai/install.sh | bash
  ```

## One-time setup

1. Clone this repo somewhere stable, e.g. `~/argo-shim-lite`.
2. Add the launcher's directory to your `PATH` in `~/.bashrc`:
   ```bash
   export PATH="$HOME/argo-shim-lite:$PATH"
   ```
3. Open a new shell (or `qsub -I` if you'll be running on a compute node) and verify:
   ```bash
   which argonne-claude.sh
   ```
   If it prints a path, setup is done — skip to [Usage](#usage). On Aurora this normally just works because ALCF's system config sources user `.bashrc`s for login shells. If `which` returns "not found", do step 4.
4. *(Only if step 3 failed.)* Login shells on your system don't source `~/.bashrc` automatically. Bridge `~/.bash_profile` so they do:
   ```bash
   echo '[ -f ~/.bashrc ] && . ~/.bashrc' >> ~/.bash_profile
   source ~/.bash_profile
   ```
   `>>` creates `~/.bash_profile` if it doesn't exist and appends if it does. Alternative: duplicate the `export PATH=...` line into `~/.bash_profile` directly — works, but you have to keep the two files in sync from now on.

### Argo backend setup

- SSH access to `homes.cels.anl.gov`
- Python 3.12 with `aiohttp` (`pip install -r requirements.txt`)

#### Running from Aurora

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

### AskSage backend setup

Get your API key from the Ask Sage platform (Settings → Account → Manage your API Keys). The launcher targets the Argonne-hosted tenant (`api.asksage.anl.gov`) by default, which is where Argonne accounts live; if your account is on a different tenant, set `ASKSAGE_BASE_URL` to that tenant's `/server/anthropic` URL (e.g. `https://api.asksage.ai/server/anthropic` for the public site).

See [Identity](#identity) below for how to give the launcher your key — the recommended fallback is a token file at `~/.asksage/token`:

```bash
mkdir -p ~/.asksage && chmod 700 ~/.asksage
echo 'your-asksage-key' > ~/.asksage/token
chmod 600 ~/.asksage/token
```

## Usage

`--backend` is required. From any directory:

```bash
# Argo backend, using $USER as your Argo identity
argonne-claude.sh --backend=argo

# Argo with an overridden identity
argonne-claude.sh --backend=argo --identity=jdoe

# AskSage backend (identity comes from ~/.asksage/token by default)
argonne-claude.sh --backend=asksage

# AskSage with the key passed inline
argonne-claude.sh --backend=asksage --identity=sk-asksage-...
```

### Identity

The `--identity` flag is the unified way to tell the launcher who you are. It maps to whatever the chosen backend actually needs:

| Backend  | What `--identity` means | Fallback if `--identity` is omitted          |
|----------|-------------------------|----------------------------------------------|
| argo     | Your Argo username      | `$ARGO_USER`, then `$USER`                   |
| asksage  | Your Ask Sage API key   | `$ASKSAGE_API_KEY`, then `~/.asksage/token`  |

**Why the two backends fall back differently:** the Argo username is not a secret (SSH+MFA is what actually authenticates you to the tunnel), so `$USER` is a safe default and no setup is needed. The Ask Sage API key *is* a credential, so it should live in a permission-restricted file like `~/.asksage/token` rather than in `~/.bashrc` (which is frequently world-readable and often committed to dotfile repos). If you want to skip `--identity` for daily use:

- **Argo** — usually nothing to do. Only set `export ARGO_USER=<name>` in `~/.bashrc` if your Argo username differs from `$USER`.
- **AskSage** — drop the key into `~/.asksage/token` as shown above. Avoid putting it in `~/.bashrc`.

### Argo flow

1. Opens an SSH tunnel to `apps.inside.anl.gov` via `homes.cels.anl.gov` (you'll be prompted for MFA).
2. Starts the local proxy on port 8083.
3. Launches Claude Code wired up to the proxy.

When you exit Claude, the proxy and SSH tunnel are torn down automatically.

### AskSage flow

1. Resolves your API key from env or token file.
2. Queries `${ASKSAGE_BASE_URL}/v1/models` to discover which models the tenant serves. Picks the first entry (AskSage returns them in capability order — most-capable first) as `ANTHROPIC_MODEL`, and the first `haiku` model as `ANTHROPIC_SMALL_FAST_MODEL`. Skip the query by setting `ASKSAGE_MODEL` and/or `ASKSAGE_SMALL_FAST_MODEL` yourself.
3. Probes whether the tenant accepts Claude Code's newer adaptive-thinking mode (`thinking: {type: "adaptive"}`, which Opus 4.7 turns on by default). If the backend rejects it, sets `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1` for this run so Claude Code falls back to the legacy enabled/disabled mode the backend understands. When AskSage adds support upstream, the probe stops finding the rejection and the flag is no longer set — no code change needed. Skip the probe by setting `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` yourself.
4. Launches Claude Code with `ANTHROPIC_BASE_URL` pointed at the Ask Sage endpoint, the discovered model env vars, and (if applicable) the adaptive-thinking opt-out.

### Optional environment overrides

Common:

- `CLAUDE_EXECUTABLE` — path or name of the `claude` binary to launch (defaults to `claude`).

Argo only:

- `ARGO_USER` — fallback identity if `--identity` is not passed (defaults to `$USER`).
- `ARGO_AURORA_UAN` — UAN to use as the first SSH hop on Aurora compute nodes (defaults to `$PBS_O_HOST`, falling back to `aurora-uan-0011`).
- `ARGO_SSH_JUMP` — explicit comma-separated SSH jump chain passed as `-J`. Overrides the auto-detected compute-node default.

AskSage only:

- `ASKSAGE_API_KEY` — fallback identity if `--identity` is not passed.
- `ASKSAGE_TOKEN_FILE` — path to read the API key from (defaults to `~/.asksage/token`). Used only if neither `--identity` nor `$ASKSAGE_API_KEY` is set.
- `ASKSAGE_BASE_URL` — full Anthropic-compatible endpoint URL (defaults to `https://api.asksage.anl.gov/server/anthropic`). Set this to point at a different AskSage tenant, e.g. `https://api.asksage.ai/server/anthropic` for the public site.
- `ASKSAGE_MODEL` — short-circuit the model discovery query; passed straight through as `ANTHROPIC_MODEL`. Useful when you want to pin a specific model (e.g. `claude-sonnet-4-6`) or when the discovery query is failing.
- `ASKSAGE_SMALL_FAST_MODEL` — same idea for `ANTHROPIC_SMALL_FAST_MODEL` (Claude Code's small/fast model used for cheap background tasks).

## How it works

### Argo

1. The SSH tunnel forwards local port 8082 to `apps.inside.anl.gov:443` through `homes.cels.anl.gov`.
2. `claude-argo-proxy.py` listens on port 8083, rewrites the `Host` header, and forwards requests through the tunnel.
3. Claude Code sends requests to `http://127.0.0.1:8083/argoapi/`, which routes them to the Argo API.

### AskSage

Claude Code sends requests directly to the AskSage Anthropic-compatible endpoint (defaults to Argonne's tenant at `https://api.asksage.anl.gov/server/anthropic`; override with `ASKSAGE_BASE_URL`), authenticated with your Ask Sage API key. No tunnel or proxy involved.

The launcher also points `NODE_EXTRA_CA_CERTS` at `certs/incommon-rsa-server-ca-2.pem` (a public intermediate from Sectigo, signed by USERTrust which is in Mozilla's root store). The ANL AskSage server does not include this intermediate in its TLS handshake, which would otherwise cause Claude Code's bundled Node runtime to fail verification with "SSL certificate verification failed". If you've already set `NODE_EXTRA_CA_CERTS` yourself, the launcher leaves it alone.

### Manual setup (for debugging Argo)

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
