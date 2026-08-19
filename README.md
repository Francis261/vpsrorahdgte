# vps-relay

A GitHub Actions "VPS" that lives in an **LXD virtual machine (own kernel)** and
migrates itself across GitHub accounts every ~5 hours. State is backed up to
Google Drive and restored on the next account, and you reach it over a stable
Cloudflare Access-protected hostname.

GitHub-hosted runners are hard-killed at 6 hours, so this repo:

1. runs a single LXD VM (`vps`) with its own kernel (sshd + your services + opencode + cloudflared) for ~5h
2. at the 5h mark: exports the VM (`lxc export`) and uploads the archive to Google Drive
3. hands off via `repository_dispatch` to the next account in `chain.json`
4. that account pulls the backup, imports the VM, starts it, and repeats
5. a scheduled watchdog on every account recovers if a lease goes stale (>45 min)

## Repo layout

```
.github/workflows/vps.yml      # the relay job (timeout 340 min, under the 360 cap)
.github/workflows/watchdog.yml # cron every 30 min, self-heal on stale lease
mustBackup.json                # VM config + tunnel + handoff timing
chain.json                     # ordered list of accounts in the relay
services/seed/                 # cloud-init seed: bashrc, opencode.json, authorized_keys
services/hello/                # tiny pm2-style web app (runs as a systemd service in the VM)
scripts/                       # vm / restore / loop / backup / handoff / heartbeat / watchdog / lease
```

## 1. Repos

- Create a repo (e.g. `vps-relay`) in **each** GitHub account you want in the chain.
- Push this code to all of them, then edit `chain.json` so it lists every
  `owner`/`repo` in relay order. The workflows must live on the **default
  branch** (`repository_dispatch` only fires there).
- Public repos = free hosted-runner minutes. Private repos bill ~1440 min/day.
- Public runners are 4 vCPU / 16 GB RAM; private are 2 vCPU / 8 GB RAM. Both
  expose `/dev/kvm` (the job does `chmod 666 /dev/kvm` so LXD can use
  hardware acceleration; it falls back to slow software emulation if not).

## 2. Google Drive (backup storage)

1. Google Cloud Console → create a **service account** → enable the **Drive API** → download the JSON key.
2. Create a folder in your Drive, share it with the service account email (**Editor**).
3. Note the folder ID (from the folder URL, the part after `/folders/`).

> Since mid-2026 the relay uses an **OAuth token** (`RCLONE_DRIVE_TOKEN`) for
> the account that *owns* the folder, because a service account cannot write to
> a personal My Drive folder. The SA secret is kept as a fallback.

## 3. Cloudflare tunnel + Access (connectivity)

Two supported modes:

**Token-based (dashboard-managed, simplest):** create the tunnel in Zero Trust →
Networks → Tunnels, then run `cloudflared tunnel run --token <TOKEN>` from your
machine once to get the token. Configure the tunnel's **Public Hostnames** in
the dashboard (`http://localhost:8080` and `ssh://localhost:22`). Store the
token in the `CF_TUNNEL_TOKEN` secret. The token is baked into the VM at first
boot (cloud-init) and the VM's cloudflared dials out to Cloudflare.

**Named tunnel (local config):**

```sh
cloudflared tunnel login
cloudflared tunnel create vps        # prints a UUID, creates credentials.json
cloudflared tunnel route dns vps vps.example.com
cloudflared tunnel route dns vps ssh.vps.example.com
```

Put `credentials.json` content into the `CF_TUNNEL_CREDS` secret, and the UUID
into `mustBackup.json` → `tunnel.tunnel_uuid`. (Token mode is preferred.)

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
| `GDRIVE_SERVICE_ACCOUNT_JSON` | the service account JSON key (fallback) |
| `RCLONE_DRIVE_TOKEN`          | rclone OAuth token JSON (preferred; owner account) |
| `DRIVE_FOLDER_ID`             | Drive folder ID |
| `HANDOFF_PAT`                 | fine-grained PAT (from the **next** account) |
| `CF_TUNNEL_CREDS`             | `credentials.json` from `cloudflared tunnel create` (named-tunnel mode) |
| `CF_TUNNEL_TOKEN`             | `cloudflared tunnel run --token <TOKEN>` token (token mode) |

## 6. First boot

On account 1:

```sh
gh workflow run vps.yml --repo ACCOUNT_ONE/vps-relay
```

No backup exists yet, so the job installs LXD, launches a fresh
`ubuntu:24.04` VM (cloud-init seeds sshd + root password, cloudflared, the
hello app, and opencode), and starts the relay. From then on the chain keeps
itself alive.

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
# then: ssh vps   (password: set in services/seed/user-data, default Frank986532)
```

SSH auth supports both root password and key auth (`services/seed/authorized_keys`;
the seed persists inside the VM disk, so it survives handoffs).

## Operations

- **VM config**: edit `mustBackup.json` → `vm` block (name, image, cpu, mem,
  disk) and `handoff_after_min` (default 300, keep < 330).
- **Timing**: boot ~6 min (snap LXD + VM boot; fresh boot also pulls the cloud
  image + runs cloud-init) + run 300 min + backup/export ~5 min + handoff ~1 min
  → clean exit ~312 min, ~48 min before the 360-min hard kill.
- **Crash / missed handoff**: the watchdog on the next account detects the stale
  lease (no heartbeat > 45 min) and boots from the last-good backup.
- **SSH into the current runner** for debugging: each account's vps run logs the
  VM start and heartbeat progress; check the run logs.

## Notes / limitations

- The tunnel hostname is stable (named tunnel + Access), so your URL and Access
  session survive every handoff.
- The runner VM has no public inbound IP — all access goes through Cloudflare.
- Nested virtualization is "experimental" per GitHub: `/dev/kvm` exists on x86
  runners and LXD VMs work in practice, but if KVM is unusable LXD falls back to
  software emulation (much slower).
- `lxc export` of the VM (gzipped) counts against Drive's 15 GB free quota; the
  relay keeps the last 5 backups (`KEEP_BACKUPS`).
- The VM has its own kernel: you get real `dmesg`, can load kernel modules, and
  could later switch the guest image (e.g. Alpine, Debian) in `mustBackup.json`.
- The `web_port` / `ssh_port` in `mustBackup.json` are the ports **inside** the
  VM (sshd = 22, hello web app = 8080).