# Proxmox VE notifications → ntfy

Wire the cluster's native PVE 9 notification system to the `ntfy` LXC this
repo deploys via Terraform (currently `10.10.41.14`, VLAN 41). Backup job
failures, replication errors, and HA/fencing events then arrive as push
notifications instead of dying in a local mailbox nobody reads.

> **As-built status (2026-11-01):** the live ntfy instance is **not**
> CT 204 (deployed as a bare OS by choice). It is the ntfy server on
> the Lenovo terminal server — `http://192.168.1.190:2586`, topic
> `homelab-alerts` — and it accepts unauthenticated publishes from the
> fleet VLANs. The alert path proven in production today is **Uptime
> Kuma (CT 202) → Lenovo ntfy**, covering Kuma's monitors — 24 real
> plus 4 group monitors as of 2026-11-04 (see the update below). One
> hard-won detail: Kuma posts a JSON body to the configured server
> URL with the topic inside the body, so the URL must be the **bare**
> server address — appending the topic to the URL makes ntfy store
> the whole JSON as literal message text (alerts arrived as raw JSON
> until this was fixed on 2026-11-01). The PVE-native webhook wiring
> below remains the plan for cluster events; when it is wired, point
> the target at the Lenovo instance and the `homelab-alerts` topic.

**Update (2026-11-04):** Kuma's coverage grew from the original 9
monitors to **24 real monitors plus 4 group monitors** (Hypervisors,
Network, Core Services, Applications — every real monitor sits in a
group), all tied to the same ntfy notification and all verified UP.
Added: Authentik, Vaultwarden, Scanopy, Paperless, Scrutiny,
Prometheus, Homepage, What's Up Docker, Home Assistant, a Kuma
self-check, Scrypted, LiveNX, LivePCA, TACACS as a TCP port check on
10.10.41.15:49, and the Hue Bridge (10.10.50.160). Two operational
notes. First, Kuma is a native git-checkout install, so an update
is: check out the new tag, run a FULL `npm ci`, then
`npm run build`, then restart — skipping the build leaves the old
frontend served against the new backend (the 2.5.9 bump showed a
version-mismatch banner, websocket errors, and blank settings pages
until the frontend was rebuilt); CT 202's RAM was raised
512 MB → 2048 MB because the vite build runs out of memory at
512 MB. Second, the remaining blind spot: Kuma sits on VLAN 41 and
cannot watch VLAN 10 — the two UniFi policies created for
Kuma → infrastructure targets pass TCP to VLAN 50 (the Hue monitor
works through them), but ICMP passes nothing and VLAN 10 targets do
not answer even on 443; still open are the Ping policy's protocol
field and whether VLAN 10 lives in UniFi's OOB zone rather than
Internal. The UniFi PDU Pro turned out to be at 192.168.0.200 on
the house LAN (not VLAN 50, as once assumed) and is not monitorable
from Kuma: it answers ping only on its own subnet and has no web
UI listening.

## How PVE 9 notifications work

Two concepts, both stored cluster-wide in `/etc/pve/notifications.cfg`
(replicated by pmxcfs — configure on **exactly one** node):

- **Targets** — *where* a notification goes. PVE 9 ships sendmail, SMTP,
  Gotify, and **webhook** targets. A webhook target performs an HTTP request
  to a configurable URL.
- **Matchers** — *what* goes *where*. A matcher routes notifications to one
  or more targets, filtered by severity (`info`, `notice`, `warning`,
  `error`, `unknown`). Matchers are **additive**: a notification is delivered
  to every matcher that matches it.

Secrets (tokens, passwords) live in `/etc/pve/priv/notifications.cfg`,
readable only by root — never in the world-readable config.

A webhook target supports (verified against the official PVE docs):

- `url`, `method` (`POST`/`PUT`/`GET`), `header` (array), `body`, `secret`
  (array of key-value pairs), `comment`
- Handlebars templating in URL/header/body: `{{ title }}`, `{{ message }}`,
  `{{ severity }}`, `{{ timestamp }}`, `{{ fields.<name> }}`,
  `{{ secrets.<name> }}`, plus `url-encode`, `escape`, and `json` helpers.

The stock `default-matcher` routes everything to `mail-to-root`, which goes
nowhere without a mail relay. We leave it alone (additive-only) and add our
own matcher.

## What we're building

- Target **`ntfy-proxmox`**: `POST http://10.10.41.14/{{ secrets.topic }}`
  with headers `Title: {{ title }}` and `Markdown: yes`, body `{{ message }}`.
  The topic name is kept in a PVE secret so it doesn't sit in the
  world-readable config.
- Matcher **`ntfy-failures`**: severity `warning,error` → `ntfy-proxmox`.

This catches vzdump backup failures, replication errors, and HA/fencing
events (all emitted at `error` severity), plus anything PVE flags as a
warning. Successful backups (`info`) are deliberately **excluded** — a
nightly "backup OK" ping trains you to ignore the channel, and then you miss
the one that matters.

Prerequisite: the PVE nodes must reach the ntfy LXC on TCP 80. The Nexus
data trunks carry VLAN 41 to the PVE hosts (see `network/PORT-MAP.md`); if
the datacenter firewall is managed by Terraform, set `pve_node_ips` to the
nodes' management IPs so the allow rule is created (see `firewall.tf`).

## Topic naming and access control

Suggested topic: **`proxmox-alerts`** — the same topic
`docs/BACKUP-RESTORE-TESTS.md` uses, so all Proxmox alerting lands in one
place. Make it unguessable if you prefer (e.g. `proxmox-alerts-7f3a`):
ntfy has no auth by default, so anyone who can reach the server can publish
to — and subscribe to — any topic.

Lock it down in layers:

1. **Firewall first.** Restrict TCP 80 on the ntfy LXC to the PVE nodes and
   your admin hosts. The repo's Terraform datacenter firewall is the place
   for this.
2. **ntfy auth (stronger).** Enable authentication in ntfy's `server.yml`
   (`auth-file`), create a user, and issue an access token. Then add a PVE
   secret `ntfy_token` to the webhook target and a header
   `Authorization: Bearer {{ secrets.ntfy_token }}`. The token then lives in
   the root-only protected config, never on the wire in plaintext beyond TLS.

## GUI path

1. **Datacenter → Notifications → Notification Targets → Add → Webhook**
   - Name: `ntfy-proxmox`, Method: `POST`
   - URL: `http://10.10.41.14/{{ secrets.topic }}`
   - Headers: `Title` = `{{ title }}`, `Markdown` = `yes`
   - Body: `{{ message }}`
   - Secrets: `topic` = `proxmox-alerts` (your chosen topic)
   - Comment: `ntfy alerts (Terraform: ntfy LXC)`
2. **Notification Matchers → Add**
   - Name: `ntfy-failures`, Severity: `Warning`, `Error`
   - Targets: `ntfy-proxmox`
3. Use the **Test** action on the `ntfy-proxmox` target row.

## pvesh path

Same thing from one PVE node (`header`/`body`/`secret` values are
base64-encoded — that is how PVE stores them):

```bash
TOPIC="proxmox-alerts"  # or your chosen topic name

pvesh create /cluster/notifications/endpoints/webhook \
  --name ntfy-proxmox \
  --method post \
  --url "http://10.10.41.14/{{ secrets.topic }}" \
  --header "name=Title,value=$(printf '%s' '{{ title }}' | base64 -w0)" \
  --header "name=Markdown,value=$(printf '%s' 'yes' | base64 -w0)" \
  --body "$(printf '%s' '{{ message }}' | base64 -w0)" \
  --secret "name=topic,value=$(printf '%s' "$TOPIC" | base64 -w0)" \
  --comment "ntfy alerts (Terraform: ntfy LXC)"

pvesh create /cluster/notifications/matchers \
  --name ntfy-failures \
  --match-severity warning,error \
  --target ntfy-proxmox \
  --comment "Backup failures, replication errors, fencing -> ntfy"
```

Or run the script (check first, apply on purpose):

```bash
scripts/configure_ntfy_alerts.sh                 # report current state
scripts/configure_ntfy_alerts.sh --apply          # create + test (asks first)
```

`NTFY_HOST` / `NTFY_TOPIC` env vars (or `--ntfy-host` / `--ntfy-topic`)
override the defaults.

## Test and confirm delivery

```bash
pvesh create /cluster/notifications/targets/ntfy-proxmox/test
```

Confirm it lands: subscribe with `curl -N http://10.10.41.14/proxmox-alerts/json`,
open the ntfy web app at `http://10.10.41.14`, or watch the topic in the ntfy
phone app. Then trigger a real one — e.g. run a backup job against a stopped
test guest — and confirm the failure notification arrives.

## Troubleshooting

- **Test succeeds but nothing arrives**: wrong topic (check the secret), or
  the PVE node can't reach the ntfy LXC — `curl -d test
  http://10.10.41.14/proxmox-alerts` from the node tells you which.
- **HTTP errors in the log**: check the node's journal for notification
  delivery errors; they name the target and the status code.
- **Duplicate notifications**: expected — matchers are additive. Don't
  "fix" it by deleting the default-matcher; it only feeds local mail.
- **Too noisy / too quiet**: adjust the matcher's severities
  (`pvesh set /cluster/notifications/matchers/ntfy-failures
  --match-severity warning,error,unknown`).
- **Re-check quarterly**: a silent notification path is worse than none,
  because you believe you're covered. Re-run the test target whenever you
  touch the firewall or the ntfy LXC.
