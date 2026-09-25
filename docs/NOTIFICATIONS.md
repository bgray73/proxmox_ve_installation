# Proxmox VE notifications → ntfy

Wire the cluster's native PVE 8 notification system to the `ntfy` LXC this
repo deploys via Terraform (currently `10.10.41.14`, VLAN 41). Backup job
failures, replication errors, and HA/fencing events then arrive as push
notifications instead of dying in a local mailbox nobody reads.

## How PVE 8 notifications work

Two concepts, both stored cluster-wide in `/etc/pve/notifications.cfg`
(replicated by pmxcfs — configure on **exactly one** node):

- **Targets** — *where* a notification goes. PVE 8 ships sendmail, SMTP,
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
