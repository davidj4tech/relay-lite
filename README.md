# relay-lite

Let an AI assistant run shell commands on your computer and read the results,
through a tiny Cloudflare Worker, with one command to set it up.

```
assistant  ──MCP──▶  Worker (Cloudflare)  ──▶  signed row in D1
                                                    ▲
your machine ◀──── relay-lite.sh polls, verifies, runs, writes the result
```

Two tools: `run_command` (queue a command and wait for its output) and
`get_result` (fetch it later). Works with any MCP client that can add a
remote server by URL: Claude (web, desktop, app, Claude Code), ChatGPT
custom connectors, and others. The machine needs no open port, no public
address and no VPN: the runner only makes outbound HTTPS calls.

> **This executes shell commands from the internet, as you.** Whoever has
> the connector URL can run anything on the machine. There is no allowlist.
> Two things stand in the way: the URL is a secret, and every queued row is
> signed with a key held only by the Worker and the runner, so getting a
> row into the database is not the same as getting it executed. Treat the
> URL like a password.

## Setting it up

**[SETUP.md](SETUP.md)** is the whole thing in plain language: creating the
free Cloudflare account, the API token with its three permissions, running
the installer on Windows or Linux, and connecting the assistant. Hand that
file to whoever is doing it.

The short version, for someone who has done this before:

1. A Cloudflare API token (Custom, Account scope): **Workers Scripts: Edit**,
   **D1: Edit**, **Account Settings: Read**.
2. Windows: from PowerShell in this folder, `.\install.ps1` (installs WSL2 +
   Ubuntu if needed, one reboot, then runs the Linux installer inside it).
   Linux or WSL: `./install.sh`.
3. Paste the printed URL into your assistant as a custom connector, no
   authentication.

The installer creates the D1 database, applies the schema, registers a
workers.dev subdomain if the account has none, generates the signing key and
the URL secret, sets both as Worker secrets, deploys the Worker, runs an
end-to-end smoke test, writes `~/.config/relay-lite/{env,relay.key}` and
starts the runner as a systemd user service. Re-running is safe: it keeps
existing ids and keys. Several machines can share one account: each gets a
Worker and database named `relay-lite-<site>` (default: the hostname). Copy
`install.conf.example` to `install.conf` to answer the prompts in advance.

## What keeps this safe enough

- **The URL is the credential.** The endpoint is `/<secret>/mcp`; every
  other path is a 404, compared in constant time. Give it to one assistant.
  Rotate it by deleting the `RELAY_URL_SECRET` line from
  `~/.config/relay-lite/env` and re-running the installer.
- **Rows are signed.** HMAC-SHA256 over the nonce and the command, keyed
  with a secret the Worker and the runner share and nothing else holds. The
  runner refuses a row that does not verify, and a nonce it has seen before.
- **Commands run as you**, with `bash -lc`, a 600 s timeout and 60 KB of
  output kept.
- **One at a time, by default.** The runner finishes each command before it
  starts the next, so a long job holds the queue behind it and nothing
  interleaves. `RELAY_PARALLEL=4` in `~/.config/relay-lite/env` runs up to
  four at once, each in its own process; results then land in whatever
  order they finish. A command can also background its own work (`nohup …
  &`, writing to a log) and return at once; a later command reads the log.

What it deliberately lacks: a login flow (OAuth), per-client permissions,
and any record of *which* assistant queued a row. If you need those, the
full relay this was distilled from is
[tmux-relay](https://github.com/davidj4tech/tmux-relay), whose runner uses
the same signature scheme.

## Files

| | |
|---|---|
| `worker/src/index.ts` | the Worker: MCP over HTTP, two tools, signing, queue-and-wait |
| `schema.sql` | one table |
| `relay-lite.sh` | the runner: poll, verify, run, write back |
| `relay-lite.service` | systemd user unit template |
| `install.sh`, `install.ps1` | the one-command setup, Linux/WSL and Windows |
| `SETUP.md` | the walkthrough for a person |

Runner log: `journalctl --user -u relay-lite -f`. Config:
`~/.config/relay-lite/env` and `relay.key`.

## License

MIT, see [LICENSE](LICENSE).
