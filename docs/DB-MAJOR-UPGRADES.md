# Database major upgrades — plan

Status: **EXECUTED 2026-11-04** — see the as-built record at the bottom of
this file. Trigger: What's Up Docker
flagged three major-version database updates on 2026-11-04. This plan exists
because none of the three is a safe blind `pull` + recreate.

## Scope

| Stack | Container | Current | Target | DB size (2026-11-04) |
|---|---|---|---|---|
| Paperless (CT 206) | paperless-db | postgres:16 | postgres:18 | 13 MB |
| Paperless (CT 206) | paperless-redis | redis:7 | redis:8 | 13 keys, RDB only |
| Authentik (VM 309) | authentik-postgresql-1 | postgres:16-alpine | postgres:18-alpine | 47 MB |

Out of scope: the application containers themselves (paperless-ngx,
goauthentik/server 2026.8.5) — image bumps for those are routine.

## Why a blind pull breaks

PostgreSQL refuses to start a new major version on an old data directory
("database files are incompatible with server"). A plain tag change +
recreate crash-loops the database container and takes the application down
with it. Redis is the exception: 8 reads 7's RDB, and Paperless's broker
holds no durable state worth migrating.

## Method: dump / restore, not pg_upgrade

Both databases are tiny (13 MB / 47 MB), so a logical dump/restore into a
fresh PG 18 data directory beats in-place `pg_upgrade`:

- No version-skew tooling (no pg_upgrade binary, no link/copy modes).
- The old data directory is never touched — it *is* the rollback.
- Restore takes seconds at these sizes; total downtime is dominated by
  container stop/start and verification, not data movement.

Compatibility gate (checked 2026-11-04): Authentik's own documentation
states PostgreSQL 14–18 is supported, so 2026.8.5 → PG 18 is a blessed
combination. Paperless-ngx supports PG 18. PostgreSQL 16 remains upstream-
supported until Nov 2028 — there is no schedule pressure on either stack.

**postgres:18 image gotcha (both stacks):** the 18 image relocates the
default data directory to `/var/lib/postgresql/18/data` and expects the
volume mounted at `/var/lib/postgresql`. Our composes mount at
`/var/lib/postgresql/data`. Either move the mount to `/var/lib/postgresql`
or pin `PGDATA=/var/lib/postgresql/data` in the compose environment —
decide at execution time and confirm with
`psql -c 'show data_directory'` in the new container *before* restoring.

## Order

1. **Paperless first** — proves the runbook end-to-end at the lowest blast
   radius. If anything surprises, it surprises on the document archive,
   not on the identity layer.
2. **Authentik second, its own window** — SSO logins pause while it runs.
   Before starting, verify the break-glass paths that do not depend on
   Authentik: PVE `pam` realm login, NPM admin direct at
   http://10.10.41.11:81, and local app logins (Paperless/WUD bgray).

## Runbook A — Paperless (CT 206, /opt/paperless)

Pre-state recorded 2026-11-04: compose images redis:7 / postgres:16 /
paperless-ngx:latest; bind mounts under /opt/paperless (pgdata 17 MB,
redisdata 5 KB); CT disk 29 GB free.

1. Snapshot CT 206 on pve02: `pre-pg18-upgrade`.
2. Record the pre-counts for later comparison:
   `select count(*) from documents_document;` and the app version from the
   Paperless UI footer.
3. Dump: `docker exec paperless-db sh -c 'pg_dumpall -U $POSTGRES_USER' > /opt/paperless/dump-pre-pg18.sql`
   — verify the file is non-trivial and contains the documents tables.
4. `docker compose down`.
5. `mv pgdata pgdata.pg16.bak` (kept untouched — rollback asset).
6. Edit docker-compose.yml: `postgres:16` → `postgres:18`,
   `redis:7` → `redis:8`; apply the PGDATA/mount decision from the gotcha
   above; create a fresh empty `pgdata`.
7. Start only the database (`docker compose up -d db`), wait for
   "ready to accept connections", confirm `show server_version;` = 18.x
   and `show data_directory;` points where the plan says it should.
8. Restore: `psql -U <superuser> -f dump-pre-pg18.sql` into the new
   database container (pg_dumpall output includes roles/globals).
9. Start the rest: `docker compose up -d` (broker on redis:8 reusing
   redisdata, webserver last).
10. Verify:
    - webserver healthy, no migration errors in its log;
    - local login as bgray works;
    - document count equals the pre-count from step 2;
    - one SSO login via https://paperless.homelab (if the NPM host exists
      by then) — otherwise verify via the OIDC authorize probe used on
      2026-11-04;
    - WUD no longer flags paperless-db / paperless-redis.
11. Rollback (any failure before step 10 passes): `docker compose down`,
    restore the original image tags, `mv pgdata.pg16.bak pgdata`,
    `docker compose up -d`. Snapshot revert is the second line.
12. Keep `pgdata.pg16.bak` and the dump for 7 days, then delete both.

Expected downtime: ~10–15 minutes.

## Runbook B — Authentik (VM 309, /opt/authentik)

Pre-state recorded 2026-11-04: compose images postgres:16-alpine /
goauthentik/server 2026.8.5 (server + worker); DB 47 MB; VM disk 26 GB
free. PostgreSQL data lives in the compose-managed volume — identify it
with `docker volume ls` / `docker compose config` at execution time.

1. Confirm the break-glass paths (see Order, item 2) *before* touching
   anything.
2. Snapshot VM 309 on pve02: `pre-pg18-upgrade`.
3. Dump: `docker exec authentik-postgresql-1 sh -c 'pg_dumpall -U $POSTGRES_USER' > /opt/authentik/dump-pre-pg18.sql`
   — verify size and content.
4. `docker compose down`.
5. Preserve the old data: if a named volume, leave it untouched and create
   a new volume for PG 18 (record both volume names in the as-built note);
   if a bind mount, `mv` it to `*.pg16.bak` as in Runbook A.
6. Edit docker-compose.yml: `postgres:16-alpine` → `postgres:18-alpine`;
   apply the same PGDATA/mount decision as Runbook A.
7. Start only PostgreSQL, confirm 18.x + data directory, restore the dump
   as in Runbook A step 8.
8. `docker compose up -d` for server + worker.
9. Verify:
    - server healthy, no migration errors in server/worker logs;
    - akadmin (break-glass) login works; bgray login works;
    - one native OIDC flow end-to-end (PVE or Grafana login via
      Authentik);
    - one proxy-gated app end-to-end (uptime.homelab: 302 → login →
      through);
    - embedded outpost shows connected in the Authentik admin UI;
    - WUD no longer flags authentik-postgresql-1.
10. Rollback mirrors Runbook A: down, old image tag, old volume/data
    back in place, up. Snapshot revert is the second line.
11. Keep the old volume/data and the dump for 7 days, then delete.

Expected downtime: ~15–30 minutes including verification. Existing
sessions on gated/OIDC apps largely survive; new logins pause.

## After both

- Update the as-built notes (this repo + fleet inventory): new image tags
  for CT 206 and VM 309.
- WUD will from then on track the postgres:18 / redis:8 lines — future
  flags on these containers are minor/patch updates, which are safe to
  pull normally.
- Close this plan out by moving it to an as-built record (what ran, when,
  any deviations), the same way the TACACS+ work was recorded.

## As-built — executed 2026-11-04

Both runbooks ran back-to-back at Brett's direction ("Do both / Now").
Final state, verified live:

| Stack | Container | Now running | Verified |
|---|---|---|---|
| Paperless (CT 206) | paperless-db | postgres:18 (18.6) | version + data_directory, doc count, users, HTTP 302, webserver healthy |
| Paperless (CT 206) | paperless-redis | redis:8 | PING/PONG |
| Authentik (VM 309) | authentik-postgresql-1 | postgres:18-alpine (18.6) | version, healthy, 6 users, OIDC discovery 200, gated-app chain to login page 200 |

Roll-back assets in place before each swap: PVE snapshots `pre-pg18-upgrade`
on CT 206 and VM 309; pg_dumpall dumps at `/opt/paperless/dump-pre-pg18.sql`
(293 KB) and `/opt/authentik/dump-pre-pg18.sql` (17.8 MB); compose backups
`docker-compose.yml.bak-pre-pg18` beside each compose file.

Deviations from the runbooks above (all deliberate, all kept):

1. **The PGDATA gotcha fired exactly as predicted** — the postgres:18
   entrypoint refused the old mount layout and crash-looped paperless-db
   before any data existed (guard message names the "unused
   mount/volume"). Fix, both stacks: a `docker-compose.override.yml`
   pinning `PGDATA: /var/lib/postgresql/data` on the database service.
   Paperless's override contains only that; it sits beside the main
   compose in /opt/paperless.
2. **Authentik's data move used the override too**: the override also
   repoints the postgresql service at a new volume
   `authentik_database_pg18` (declared `external: true`). The old volume
   `authentik_database` (PG 16 data) is untouched. Paperless kept its
   bind mount; its PG 16 data is at `/opt/paperless/pgdata.pg16.bak`.
3. **First Authentik attempt was a clean no-op**: /opt/authentik is
   root-owned, so the un-sudoed pass failed every file write (backup,
   dump, sed, override) with Permission denied and simply restarted the
   untouched PG 16 stack. Re-ran the whole pass under sudo; no state was
   harmed. Lesson recorded: on VM 309, work in /opt/authentik as root
   from the start.
4. **Paperless document count was 0 before and 0 after** — the archive
   is still empty; nothing was lost in the upgrade (auth_user = 2,
   carried over).
5. My synthetic outpost probe (bare curl, Host header only) returns 500
   from the VM itself post-upgrade; the production path is proven
   instead: NPM's own auth subrequest got the expected 401 and the full
   uptime.homelab chain (302 → outpost start → Authentik flow page)
   returns 200. The bare probe is not a reliable health signal; don't
   chase it.

Retention: old data dirs/volumes and both dumps are kept until
**2026-11-11**, then deleted (pgdata.pg16.bak, authentik_database
volume, both dump files). WUD re-tracks the 18/8 lines from its next
check; the three major-upgrade flags clear.
