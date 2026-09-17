# relay-lite — setup, start to finish

This lets an AI assistant run commands on this computer and read the
results. It takes about fifteen minutes. You need a free Cloudflare account,
and a Windows PC (or any Linux machine).

## 1. Cloudflare account (free)

1. Go to <https://dash.cloudflare.com/sign-up> and create an account with
   your email. The free plan is all this needs; you will not be asked for
   a card.
2. Confirm the email Cloudflare sends you.
3. Sign in once at <https://dash.cloudflare.com>. You do not need to add a
   website or a domain. If it asks you to, skip it.
4. In the left menu open **Compute (Workers)** once. On a brand-new
   account this activates Workers; nothing else to do there.

## 2. The API token (the one manual step)

The installer needs a token that lets it create things in your account.

1. Go to <https://dash.cloudflare.com/profile/api-tokens>.
2. Click **Create Token**, then at the bottom **Get started** next to
   **Create Custom Token**.
3. Name it `relay-lite`.
4. Under **Permissions**, add three rows. Each row has three boxes:
   scope, item, level.

   | scope   | item             | level |
   |---------|------------------|-------|
   | Account | Workers Scripts  | Edit  |
   | Account | D1               | Edit  |
   | Account | Account Settings | Read  |

5. Under **Account Resources** leave *Include, All accounts* (or pick
   your account).
6. Leave everything else as it is. Click **Continue to summary**, then
   **Create Token**.
7. Copy the token that appears. **It is shown once.** Paste it somewhere
   safe for the next step (a text file you delete afterwards is fine).

## 3. Run the installer

### Windows

1. Download or unzip this repository somewhere, for example `C:\relay-lite`.
2. Open **PowerShell** (Start menu, type PowerShell).
3. Run:

   ```
   cd C:\relay-lite
   Set-ExecutionPolicy -Scope Process Bypass
   .\install.ps1
   ```

4. The first time, Windows installs its Linux layer (WSL) and asks to
   **reboot**. After the reboot, an Ubuntu window opens and asks you to
   choose a Linux username and password: pick anything and remember the
   password. Then run the same three lines again.
5. The installer now runs inside Ubuntu. When it asks, paste the token
   from step 2 and press Enter. (If it asks for a password, that is the
   Linux password from step 4; it needs it to install a few packages.)
6. If it says systemd is off and to run `wsl --shutdown`: in PowerShell run
   `wsl --shutdown`, then run the three lines from step 3 once more.

### Linux

```
cd relay-lite
./install.sh
```

Either way, the installer ends with **Done** and prints a long web address
ending in `/mcp`. That address is your key: anyone who has it can run
commands on this computer. Copy it and keep it private.

## 4. Connect the assistant

In Claude (web or app): **Settings → Connectors → Add custom connector**.
Paste the address, choose **no authentication**, save. Then in a chat, ask
it to run a command, for example "run `uname -a` on my machine".

## Afterwards

- The runner keeps working after reboots; nothing to start by hand.
- To stop it: `systemctl --user stop relay-lite` inside Ubuntu.
  To remove it entirely, also delete the Worker and the database in the
  Cloudflare dashboard.
- Lost the address? It is in `~/.config/relay-lite/env` inside Ubuntu, on
  the `RELAY_WORKER_URL` and `RELAY_URL_SECRET` lines: the address is
  `<RELAY_WORKER_URL>/<RELAY_URL_SECRET>/mcp`.
- Want a new address (say it leaked)? Delete the `RELAY_URL_SECRET` line
  from that file and run the installer again.
- Something went wrong? Run the installer again; it is safe to repeat and
  picks up where it left off. The log is `journalctl --user -u relay-lite`.
