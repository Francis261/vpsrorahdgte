# vps-relay

A GitHub Actions "VPS" that lives in a Docker container and migrates itself
across multiple GitHub accounts every ~5 hours. State is backed up to a
self-hosted MinIO (S3) bucket and restored on the next account, and you reach
it over a stable Cloudflare Access-protected hostname.

GitHub-hosted runners are hard-killed at 6 hours, so this repo:

1. runs a single `vps` container (pm2 + your services + opencode + sshd + cloudflared) for ~5h
2. at the 5h mark: commits + saves the container, tars host paths from `mustBackup.json`, uploads to MinIO (S3)
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
scripts/storage.sh             # storage backends: minio (rclone) + ghrelease (chunked release assets)
```

## 1. Repos

- Create a repo (e.g. `vps-relay`) in **each** GitHub account you want in the chain.
- Push this code to all of them, then edit `chain.json` so it lists every
  `owner`/`repo` in relay order. The workflows must live on the **default
  branch** (`repository_dispatch` only fires there).
- Public repos = free hosted-runner minutes. Private repos bill ~1440 min/day.

## 2. Backup storage (pick a backend)

`STORAGE_BACKEND` (repo **variable**, optional) chooses where backups and the
lease go. `auto` (default) = `ghrelease` if the `STORAGE_REPO_PAT` secret is
set, otherwise `minio`.

### 2a. `ghrelease` — chunked assets on a private GitHub repo

The backup tarball is split into ≤1.5 GiB chunks and uploaded as the assets of
a GitHub release on a **private storage repo** (any account). The next round
downloads the chunks, verifies every sha256, reassembles the tarball and only
then touches `/root`.

1. Create an empty **private** repo (e.g. `OtherAccount/vps-relay-storage`) and
   push at least one commit to it (releases cannot be published from an empty
   repo — the relay will use the API, the commit just has to exist).
2. From the storage account, create a **fine-grained PAT** with
   *Contents: Read and write* scoped to that one repo, no expiration (the relay
   runs forever; an expired token halts the chain).
3. Set the secrets in **every** relay repo: `STORAGE_REPO` (`owner/name`) and
   `STORAGE_REPO_PAT`.

How a cycle swaps backups (never a moment with zero backups):

```
create DRAFT release b-<UTC ts>  →  upload manifest.json + chunk_0000..  →  verify
  →  publish (tag created)  →  only now delete the previous release + tag
```

A run killed mid-upload leaves an invisible draft, which the next cycle
garbage-collects after `STORAGE_KEEP_DRAFT_HOURS` (default 2). The lease lives
in the body of a permanent `state` release (1 GET to read, 1 PATCH per
heartbeat). Guards: `MAX_CHUNKS=998` (GitHub allows 1000 assets/release),
`CHUNK_BYTES=1610612736` (1.5 GiB — GitHub caps each asset at 2 GiB) and
`MAX_BACKUP_GB=20` (refuse rather than blow the 6h job window).

### 2b. `minio` — any S3-compatible endpoint

Backups and the lease live in a single S3 bucket on any S3-compatible store —
here a self-hosted MinIO server.

1. Create the bucket (once): `mc mb local/vps-relay`
2. Create a **scoped service account** so the runner never sees your root key:

```sh
mc admin policy create local vps-relay-policy policy.json   # allow List/Get/Put/Delete on vps-relay only
mc admin user svcacct add local <ROOT_USER> --policy /path/to/policy.json
# prints an Access Key + Secret Key → those become the two S3_* secrets
```

3. The bucket must be reachable **from the public internet** (GitHub-hosted
   runners pull from it). That means an open port (e.g. `ufw allow 9000/tcp`
   and `MINIO_SERVER_URL=http://<public-ip>:9000`) or a reverse proxy / Cloudflare
   tunnel hostname in front of MinIO's API port. Plain `http://IP:9000` is fine:
   every request is SigV4-signed.

Note: the relay keeps exactly one `host-backup.tar.gz` — the previous one is
deleted only **after** the new one has been uploaded and verified, so there is
never a cycle without a restorable backup. Steady-state usage is ~1x your state
size.

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
| `STORAGE_REPO`                | private backup repo, `owner/name` (ghrelease backend) |
| `STORAGE_REPO_PAT`            | fine-grained PAT from the storage account: *Contents: Read and write*, scoped to that repo |
| `S3_ENDPOINT`                 | MinIO API URL the runners can reach, e.g. `http://161.97.113.70:9000` (minio backend) |
| `S3_ACCESS_KEY_ID`            | service-account access key (`mc admin user svcacct add ...`) (minio backend) |
| `S3_SECRET_ACCESS_KEY`        | matching secret key (minio backend) |
| `S3_BUCKET`                   | optional, defaults to `vps-relay` (minio backend) |
| `HANDOFF_PAT`                 | fine-grained PAT (from the **next** account) |
| `CF_TUNNEL_CREDS`             | `credentials.json` from `cloudflared tunnel create` (named-tunnel mode) |
| `CF_TUNNEL_TOKEN`             | `cloudflared tunnel run --token <TOKEN>` token (token mode) |

Optional repo **variables**: `STORAGE_BACKEND` (`auto`/`ghrelease`/`minio`),
`CHUNK_BYTES` (default `1610612736` = 1.5 GiB), `MAX_BACKUP_GB` (default `20`).

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
- `docker save` of a heavy image counts against whatever disk backs your MinIO
  bucket (keep an eye on free space — the relay replaces the previous backup,
  so steady-state usage is ~1x your state size).
- Watchdog uses `actions: write` on the `GITHUB_TOKEN` to re-boot `vps.yml`.
- The `web_port` / `ssh_port` in `mustBackup.json` are the ports **inside** the
  container (sshd = 22, pm2 web app = 8080). The host-side debug ports are
  `8080` and `2222` (see `scripts/run.sh`).
