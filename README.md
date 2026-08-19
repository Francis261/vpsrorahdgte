# vps-relay

A GitHub Actions "VPS" that lives in a Docker container and migrates itself
across multiple GitHub accounts every ~5 hours. State is backed up to Google
Drive and restored on the next account, and you reach it over a stable
Cloudflare Access-protected hostname.

GitHub-hosted runners are hard-killed at 6 hours, so this repo:

1. runs a single `vps` container (pm2 + your services + opencode + sshd + cloudflared) for ~5h
2. at the 5h mark: commits + saves the container, tars host paths from `mustBackup.json`, uploads to Google Drive
3. hands off via `repository_dispatch` to the next account in `chain.json`
4. that account pulls the backup, restores, runs, and repeats
5. a scheduled watchdog on every account recovers if a lease goes stale (>45 min)

## Repo layout

```
.github/workflows/vps.yml      # the relay job (timeout 340 min, under the 360 cap)
.github/workflows/watchdog.yml # cron every 30 min, self-heal on stale lease
mustBackup.json                # what to back up + tunnel + handoff timing
chain.json                     # ordered list of accounts in the relay
Dockerfile                     # the VPS image (pm2, sshd, opencode, cloudflared, docker CLI)
services/                      # pm2 apps + seed bashrc/opencode/authorized_keys
scripts/                       # restore / run / loop / backup / handoff / heartbeat / watchdog / lease
```

## 1. Repos

- Create a repo (e.g. `vps-relay`) in **each** GitHub account you want in the chain.
- Push this code to all of them, then edit `chain.json` so it lists every
  `owner`/`repo` in relay order. The workflows must live on the **default
  branch** (`repository_dispatch` only fires there).
- Public repos = free hosted-runner minutes. Private repos bill ~1440 min/day.

## 2. Google Drive (backup storage)

1. Google Cloud Console → create a **service account** → enable the **Drive API** → download the JSON key.
2. Create a folder in your Drive, share it with the service account email (**Editor**).
3. Note the folder ID (from the folder URL, the part after `/folders/`).

## 3. Cloudflare tunnel + Access (connectivity)

Two supported modes:

**Token-based (dashboard-managed, simplest):** create the tunnel in Zero Trust →
Networks → Tunnels, then run `cloudflared tunnel run --token <TOKEN>` from your
machine once to get the token. Configure the tunnel's **Public Hostnames** in
the dashboard (`http://localhost:8080` and `ssh://localhost:22`). Store the
token in the `CF_TUNNEL_TOKEN` secret.

**Named tunnel (local config):**

```sh
cloudflared tunnel login
cloudflared tunnel create vps        # prints a UUID, creates credentials.json
cloudflared tunnel route dns vps vps.example.com
cloudflared tunnel route dns vps ssh.vps.example.com
```

Put `credentials.json` content into the `CF_TUNNEL_CREDS` secret, and the UUID
into `mustBackup.json` → `tunnel.tunnel_uuid`.

Then in the Cloudflare dashboard:

- **Zero Trust → Access → Applications** → add a self-hosted application covering
  your web and ssh hostnames, with a policy allowing your identity.
  (This is what makes `cloudflared access ...` work from your machine.)

## 4. Handoff PAT

For **each** account, create a fine-grained PAT in the **next** account's repo
(permissions: *Contents: Read and write*, *Metadata: Read*) and store it as the
`HANDOFF_PAT` secret in the **current** account's repo.

## 5. Secrets (set identically in every repo)

| Secret                        | Value |
|-------------------------------|-------|
| `GDRIVE_SERVICE_ACCOUNT_JSON` | the service account JSON key |
| `DRIVE_FOLDER_ID`             | shared Drive folder ID |
| `HANDOFF_PAT`                 | fine-grained PAT (from the **next** account) |
| `CF_TUNNEL_CREDS`             | `credentials.json` from `cloudflared tunnel create` (named-tunnel mode) |
| `CF_TUNNEL_TOKEN`             | `cloudflared tunnel run --token <TOKEN>` token (token mode) |

## 6. First boot

On account 1:

```sh
gh workflow run vps.yml --repo ACCOUNT_ONE/vps-relay
```

No backup exists yet, so it builds the image and starts fresh. From then on the
chain keeps itself alive.

## 7. Connecting

```sh
# once per machine
cloudflared access login

# web
cloudflared access https://vps.example.com

# ssh (via ~/.ssh/config)
Host vps
  HostName ssh.vps.example.com
  ProxyCommand cloudflared access ssh --hostname %h
  User root
# then: ssh vps
```

SSH auth is key-based (`services/seed/authorized_keys` — add your public keys;
they persist across handoffs because they live in the committed container).

## Operations

- **Backup config**: edit `mustBackup.json` — `containers` (commit+save), `host_paths`
  (extra files on the runner), `handoff_after_min` (default 300, keep < 330).
- **Timing**: boot ~5 min + run 300 min + backup ~5 min + handoff ~1 min → clean
  exit ~311 min, ~49 min before the 360-min hard kill.
- **Crash / missed handoff**: the watchdog on the next account detects the stale
  lease (no heartbeat > 45 min) and boots from the last-good backup.
- **SSH into the current runner** for debugging: each account's vps run logs the
  container start and heartbeat progress; check the run logs.

## Notes / limitations

- The tunnel hostname is stable (named tunnel + Access), so your URL and Access
  session survive every handoff.
- The runner VM has no public inbound IP — all access goes through Cloudflare.
- `docker save` of a heavy image counts against Drive's 15 GB free quota.
- Watchdog uses `actions: write` on the `GITHUB_TOKEN` to re-boot `vps.yml`.
- The `web_port` / `ssh_port` in `mustBackup.json` are the ports **inside** the
  container (sshd = 22, pm2 web app = 8080). The host-side debug ports are
  `8080` and `2222` (see `scripts/run.sh`).
