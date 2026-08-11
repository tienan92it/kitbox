# kitbox

A container that runs coding agents and serves their terminals to your phone.

The agent lives in the box, not on your laptop. Close the lid, get on a train,
open the URL on your phone, and the session is still there — same scrollback,
same running command.

Inside: [kitterm](https://github.com/tienan92it/kitterm) serving a real terminal
over the web, the agent CLIs you ask for, Tailscale for private access, git, and
the tools worth having when your only screen is a phone.

## Quick start

```sh
git clone https://github.com/tienan92it/kitbox && cd kitbox
cp .env.example .env
```

Put a Tailscale auth key in `.env`
([get one](https://login.tailscale.com/admin/settings/keys)), then:

```sh
docker compose up -d
docker compose logs
```

The logs end with the URL to open:

```
================================================================
  Open this on your phone and your laptop:
    https://kitbox.tail1234.ts.net/?token=ktk_…
================================================================
```

Open it, run `claude`, and you have an agent you can supervise from anywhere on
your tailnet.

Without a `TS_AUTHKEY` it runs in local mode instead, on
`http://localhost:4990` — useful for trying it out, useless for a phone.

> If `docker compose` is not a command on your machine (colima and other
> non-Desktop setups often ship the standalone binary), use `docker-compose`
> with a hyphen. Everything else is identical.

## Deploying to a cloud

It is only a Docker host, so any of them work the same way. On a fresh VM:

```sh
curl -fsSL https://get.docker.com | sh
git clone https://github.com/tienan92it/kitbox && cd kitbox
cp .env.example .env && $EDITOR .env
docker compose up -d
```

Or skip the build and pull the published image:

```sh
docker run -d --name kitbox --env-file .env \
  -v kitbox-ts:/var/lib/tailscale \
  -v kitbox-kitterm:/home/vscode/.kitterm \
  -v kitbox-claude:/home/vscode/.claude \
  -v kitbox-codex:/home/vscode/.codex \
  -v kitbox-work:/workspace \
  ghcr.io/tienan92it/kitbox:latest
```

**On a public-IP host, use the Tailscale mode.** With `TS_AUTHKEY` set the
daemon binds loopback and only Tailscale reaches it. Local mode binds every
interface, and the token is then the only thing between the internet and a
shell — remove the `ports:` mapping from `docker-compose.yml` if you are not
using it.

Before running this anywhere but your own machine, read
[SECURITY.md](SECURITY.md): what ends up on the disk, and which deployments
suit which work. Client code and personal projects do not want the same setup.

### Managed platforms, with no server to run

Fly, Railway, Render and Azure Container Instances will all run this image, and
in Tailscale mode it needs **no inbound networking at all** — it dials out and
`tailscale serve` does the rest, so there is no port, hostname or load balancer
to configure. What they will not give you is five volumes: one persistent disk
per instance is the rule everywhere.

`STATE_DIR` collapses the five into one. Point it at the mounted disk and the
paths that must outlive a restart are gathered there:

```sh
docker run -d --env-file .env \
  -e STATE_DIR=/data -v kitbox-data:/data \
  ghcr.io/tienan92it/kitbox:latest
```

| On the volume | What it is |
| --- | --- |
| `/data/tailscale` | node identity — the stable hostname |
| `/data/kitterm` | the token behind your bookmark |
| `/data/claude`, `/data/codex` | agent logins |
| `/data/workspace` | your code, unless `WORKSPACE_DIR` says otherwise |

They are symlinked rather than moved, so leaving `STATE_DIR` unset keeps the
five-volume compose setup working exactly as before — one image serves both.

Anything outside the volume is gone on the next deploy, which is the point:
redeploy as often as you like and the URL you bookmarked, the agent's login and
the working tree all survive it.

Also pick an instance that **does not sleep**. Scale-to-zero platforms — Cloud
Run, App Runner, Cloudflare Containers — stop the container on idle and hand
back a fresh disk, which ends the running command you left an agent working on.
That is the one thing kitbox exists to prevent.

## Configuration

Everything lives in `.env`; see `.env.example` for the full list. The ones that
matter:

| Variable | What it does |
| --- | --- |
| `TS_AUTHKEY` | Join a tailnet. Empty means local mode. |
| `TS_HOSTNAME` | The name the box takes, so the URL is stable. |
| `TS_SERVE_HTTP` | Serve without a certificate. See below. |
| `AGENTS` | Build-time: which CLIs to install. `claude` is always in. |
| `WORKSPACE_REPO` | Cloned into `/workspace` on first start. |
| `STATE_DIR` | Gather all persistent state onto one volume. See above. |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | Git identity for the agent's commits. |

### Agents

`AGENTS` is a build argument, comma-separated:

```sh
docker compose build --build-arg AGENTS=claude,codex,opencode
```

| Name | Package | Maintained by |
| --- | --- | --- |
| `claude` | `@anthropic-ai/claude-code` | Anthropic |
| `codex` | `@openai/codex` | OpenAI |
| `grok` | `@vibe-kit/grok-cli` | community, **not** xAI |
| `opencode` | `opencode-ai` | community |

Adding one is a file: drop `agents/<name>.sh` in and ask for it by name.

Most agents can log in interactively in the browser terminal, which is easier
than managing API keys. Claude and Codex keep their credentials on the `claude`
and `codex` volumes, so that login survives a restart. `grok` and `opencode`
write elsewhere under `$HOME` and are not persisted — give them API keys in
`.env`, or add a volume for their config directory.

## Why the volumes matter

Five named volumes, and none is decoration:

- `/var/lib/tailscale` — the node's identity. Without it every restart joins as
  a *new* machine, so `kitbox` becomes `kitbox-2`, then `-3`, and your
  bookmark breaks each time.
- `/home/vscode/.kitterm` — the access token. Without it every restart mints a
  new one and the link you saved stops working.
- `/home/vscode/.claude` and `/home/vscode/.codex` — agent auth, so you log in
  once.
- `/workspace` — your code. Bind-mount a host directory here instead if you
  prefer.

## When something is wrong

```sh
docker exec kitbox doctor
```

It checks, in the order a request actually travels: the daemon, the shell
integration, DNS, reachability of the agent's API, the tailnet, what is being
served, and whether TLS certificates are failing. Each of these has bitten this
project at least once.

| Symptom | Cause |
| --- | --- |
| `uname -sm` says `Darwin` | You are in a terminal on your Mac, not the box. |
| Connection times out, TLS never completes | No certificate. Enable **HTTPS Certificates** in the [tailnet DNS settings](https://login.tailscale.com/admin/dns), or set `TS_SERVE_HTTP=1`. |
| Agent: "Unable to connect… timed out" | DNS. MagicDNS is unreachable under userspace networking; the box declines it with `--accept-dns=false`, so check `doctor`. |
| Startup stops at `joining the tailnet` | The machine is waiting for approval at [admin/machines](https://login.tailscale.com/admin/machines). |
| `403 non-loopback Host` | The URL's hostname is not the one the box trusts. Use the full `*.ts.net` name. |
| `403 missing or invalid token` | Working as intended — add `?token=…`. |
| `/api/…/commands` is always `[]` | No shell integration, so no command marks. `doctor` checks this. |

### HTTPS vs HTTP

Certificates come from the tailnet, and only when **HTTPS Certificates** is
enabled. If it is not, the TLS handshake fails and each attempt burns a Let's
Encrypt authorization — five in an hour rate-limit the name. `TS_SERVE_HTTP=1`
skips certificates entirely.

The tailnet is WireGuard-encrypted either way, so this is not sending your
keystrokes in the clear. What you lose is a *secure context*: a plain-HTTP
origin cannot be installed to your phone's home screen. Worth turning HTTPS on.

## Building against an unreleased kitterm

The image downloads a kitterm release tarball. To test a build that has not
shipped, drop it into `dist/` and it wins over the download:

```sh
cd ../kitterm && ./scripts/build-release-linux.sh v0.15.1
cp dist/kitterm-v0.15.1-linux-arm64.tar.gz ../kitbox/dist/
cd ../kitbox && docker compose build
```
