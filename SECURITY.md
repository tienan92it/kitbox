# Security

kitbox puts a shell, your code and an agent's credentials on a machine you
reach from a phone. This is what that costs, and how to keep it small.

Read the first two sections whatever you are doing. Then read the one section
that matches where you run it.

## What is on disk

Everything below survives a restart, and lives in the five volumes — or in the
one volume, if you set `STATE_DIR`.

| Path | What it is worth to someone who reads it |
| --- | --- |
| `tailscale/tailscaled.state` | An identity on your private network |
| `claude/`, `codex/` | The agent's login. Full API access, your billing |
| `kitterm/kitbox-token` | A shell. Plaintext, `chmod 600` |
| `kitterm/history/*` | Every command you typed |
| `workspace/` | Your code, and any `.env` in a repo you cloned |
| `kitterm/tokens.json` | Nothing. Hashes only |

Two things are **not** written down. Terminal output is not persisted —
`--retain-logs` is off and the entrypoint does not pass it, so scrollback lives
in a 4 MiB memory ring and dies with the container. Sessions are not recorded —
`--record` is not passed, so nothing lands in `kitterm/recordings/`.

Anything in `.env` — `TS_AUTHKEY`, `GH_TOKEN`, `ANTHROPIC_API_KEY` — is an
environment variable. Env vars are not disk, but they are visible to anyone who
can run `docker inspect` or open your hosting dashboard.

## The three that matter

**The tailnet key is the big one.** The box is a member of your private
network. With no ACL it can reach every other device you own — laptop, NAS,
internal dashboards. An API key costs you money and is revoked in thirty
seconds. A tailnet foothold is a way into everything else.

**The access token is a shell, and it types.** The entrypoint always passes
`--agent-control`, which enables `POST /api/sessions/<id>/input`. Whoever holds
the token does not just watch your terminal, they drive it. This is not
currently configurable.

**Your credentials must be readable by the box**, so they are readable by
whoever runs the box. There is no way around this. Encryption at rest defends
against a stolen drive, not against the person holding the drive.

## Baseline — do these every time

**1. Tag the tailnet node and give it no outbound rights.** The single highest
leverage control. Mint the auth key with a tag, then in your ACL:

```json
{
  "tagOwners": { "tag:kitbox": ["your@email"] },
  "acls": [
    { "action": "accept", "src": ["your@email"], "dst": ["tag:kitbox:*"] }
  ]
}
```

You can reach the box. The box can reach nothing. A stolen node key is now just
a box, not a route into your network.

**2. Make the auth key ephemeral and single-use.** Ephemeral nodes disappear
when they go offline, so a stolen state file expires on its own.

**3. Scope the GitHub token.** A fine-grained PAT, named repos, with an expiry.
Not a classic token that can read everything you own and force-push to it.

**4. Log the agent in through the browser instead of an API key.** A browser
login is revocable from your account page. A key in `.env` is visible in the
dashboard and works until you notice it is gone.

**5. Bookmark the hostname, not the `?token=` URL.** The token is needed once —
after that a cookie carries it. Tokenised URLs sync through browser history to
every device on your account.

**6. Do not clone repos with committed secrets.** `workspace/` is the least
protected thing on the disk and the easiest to forget about.

## Running on a managed host

Fly, Railway, Render, ACI. Convenient, and the trade is explicit: **the
platform can read your disk and your environment variables.** Not a flaw —
it is what hosting is. Assume any credential you put there is one support
ticket away from a stranger.

- Use the platform's secret store (`fly secrets set`) rather than committing
  `.env`. It stays out of git. It is still an env var inside the container.
- Give the box its own credentials, never your daily ones. A dedicated
  Anthropic key with a spend limit, a PAT for two repos.
- Expect volume snapshots and backups to exist. Deleting the app does not
  reliably delete every copy of the disk.
- In Tailscale mode you need no inbound networking at all. Do not add a public
  hostname you do not need.

Good for personal projects and open-source work. Better than most laptops.

## Running on your own VPS

You own the disk, so nothing reads it but you. In exchange you own patching,
the firewall, and one specific foot-gun.

**Local mode publishes a shell.** With `TS_AUTHKEY` empty the daemon binds
`0.0.0.0` inside the container. Publish the port on a public-IP host and the
only thing between the internet and a root-capable shell is a token in a URL.

With `TS_AUTHKEY` set the daemon binds `127.0.0.1` and only Tailscale reaches
it — verified: the container refuses connections on its own interface. So on
any public host, either set a tailnet key, or close the port:

```yaml
    ports: []
```

Commenting out only the list entry leaves `ports:` null and compose refuses to
start. Comment out both lines, or write `ports: []`.

Everything else is ordinary server hygiene: keep the host patched, do not
expose the Docker socket, restrict SSH to keys.

## Client work, credentials, anything under NDA

Do not run it on a managed host. Not "harden it" — do not.

You cannot promise a client that their code is confidential while it sits on
a third party's disk with an agent's credentials next to it, and no
configuration changes that. If a contract, a DPA or an NDA covers the code, the
disk has to be one you control.

For that work:

- Self-host, Tailscale mode only. No public hostname, no tunnel.
- Tag the node and give it no outbound rights, as above.
- One box per client. Shared `workspace/` volumes leak between engagements.
- No `WORKSPACE_REPO` pointing at a client repo on a box you did not provision.
- Remember `--agent-control` is always on and cannot be disabled. If your
  threat model cannot accept "the token types", kitbox is the wrong tool.
- Wipe the volumes when the engagement ends. `docker volume rm` the lot, or
  destroy the disk.

Personal and open-source work does not need any of this. Know which one you
are doing before you deploy.

## If something leaks

In this order, all of it under a minute:

1. **Tailnet** — delete the node and revoke the auth key in the admin console.
   This cuts network access first, which is what actually matters.
2. **Shell token** — `kitterm token revoke phone` in the box, or delete
   `kitterm/tokens.json` and restart. The next start mints a fresh one.
3. **Agent** — revoke the Claude or OpenAI credential from its account page.
4. **GitHub** — revoke the PAT.
5. **Then** rebuild the box. Rotating credentials on a host you no longer trust
   just hands over the new ones.

Anything typed into the box is in `kitterm/history/`. Read it to work out what
was exposed.

## Reporting a problem in kitbox itself

Open an issue at https://github.com/tienan92it/kitbox/issues. If it is a
vulnerability rather than a bug, say so and leave out the details until we have
somewhere private to put them.
