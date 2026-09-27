# Jev advisory risk review

Jev is an optional pull-request reviewer for this repository. It evaluates a
redacted Git diff and returns structured risk signals. It is not part of the
Proxmox VE or PBS installation path and cannot execute or approve a change.

## What it reviews

One TypeSafe System One request asks several independent questions:

- the highest-risk change category;
- operational severity on a five-level rubric;
- whether human review is appropriate;
- storage/backup risk;
- network/management-access risk; and
- possible secret exposure.

The workflow posts one updateable advisory comment on the pull request. The
result never blocks a merge. Deterministic tests and a human remain the final
authority for destructive or security-sensitive changes.

## Enable it

1. Create a TypeSafe API key at <https://console.typesafe.ai>.
2. In GitHub, open **Settings → Secrets and variables → Actions**.
3. Create a repository secret named `TYPESAFE_API_KEY`.
4. Open or update a non-draft pull request.

If the secret is absent or the API is unavailable, the workflow reports that
the advisory review was skipped and does not fail the pull request.

## Security design

The workflow uses `pull_request_target`, but it checks out only the trusted
default branch. It downloads the proposed pull request as a diff and treats it
as input data. Code from the pull-request branch is never executed with the
TypeSafe key or the write-capable GitHub token.

Before the diff leaves GitHub Actions, `automation/jev/guard.py` removes common:

- passwords, tokens, API keys, and bearer credentials;
- private-key blocks;
- IPv4 addresses, MAC addresses, email addresses; and
- serial/service-tag fields.

Input is capped at 30,000 characters. Do not rely on redaction as permission to
commit a secret: rotate any credential that reaches Git history.

## Local test

Use only a diff you are permitted to send to TypeSafe:

```bash
export TYPESAFE_API_KEY='set-in-your-shell-or-password-manager'
git diff main...HEAD > /tmp/proxmox-change.diff
python3 automation/jev/guard.py \
  --diff-file /tmp/proxmox-change.diff \
  --output /tmp/jev-report.md \
  --json-output /tmp/jev-result.json
cat /tmp/jev-report.md
```

The implementation uses the documented HTTPS endpoint directly and has no
additional Python package dependency:

- <https://docs.typesafe.ai/introduction>
- <https://docs.typesafe.ai/introduction/quickstart>

## Safety boundaries

Jev must remain advisory. Do not give this workflow permission to:

- merge pull requests;
- run scripts from the proposed branch;
- apply Terraform or Ansible;
- issue Proxmox, PBS, iDRAC, IPMI, or switch API calls; or
- delete disks, guests, snapshots, or backups.
