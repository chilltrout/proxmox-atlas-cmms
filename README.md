# Atlas CMMS – Proxmox VE Helper-Script

A [community-scripts](https://github.com/community-scripts/ProxmoxVE)-style LXC installer for
[Atlas CMMS](https://atlas-cmms.com/) ([Grashjs/cmms](https://github.com/Grashjs/cmms)), written against the
current two-repo engine (`community-scripts/core` + a scripts repo) and the
[DevScripts contribution rules](https://github.com/community-scripts/DevScripts/blob/main/AGENTS.md).

```
ct/atlas-cmms.sh               container creation + update_script()
install/atlas-cmms-install.sh  bare-metal install inside the container
json/atlas-cmms.json           website metadata (needed for a DevScripts PR)
```

## What gets installed

Everything upstream runs as Docker containers is installed bare-metal in one Debian 13 LXC,
mirroring `docker-compose.yml` and `nginx.conf` from the Atlas repo:

| Component | Upstream image | In the LXC |
| --- | --- | --- |
| Backend (Spring Boot, Java 17) | `intelloop/atlas-cmms-backend` | Temurin 17 + Maven build of `api/` → `/opt/atlas-cmms/atlas-cmms-api.jar`, `atlas-cmms.service` on 127.0.0.1:8080 |
| Frontend (React / CRA) | `intelloop/atlas-cmms-frontend` | Node 22 build of `frontend/` → `/opt/atlas-cmms/frontend/build`, served by nginx |
| Database | `postgres:16-alpine` | PostgreSQL 16 (PGDG), database `atlas`, user `atlas`, `unaccent` extension |
| Object storage | `pgsty/silo` (MinIO fork) | Silo .deb, `silo.service` on 127.0.0.1:9000, data in `/opt/atlas-cmms_data/storage` |
| Reverse proxy | `nginx:1.27-alpine` | nginx on port 80: `/` → UI, `/api/` → backend, `/storage/` → Silo, `/runtime-env.js` → frontend config |

Persistent data lives in `/opt/atlas-cmms_data` (never touched by updates):

```
/opt/atlas-cmms_data/.env             backend configuration (DB, JWT secret, URLs, SMTP, S3 keys, …)
/opt/atlas-cmms_data/runtime-env.js   frontend configuration (window.__RUNTIME_CONFIG__)
/opt/atlas-cmms_data/static/images    custom logos (backend hardcodes /app/static, /app is a symlink here)
/opt/atlas-cmms_data/static/config    license file location
/opt/atlas-cmms_data/storage          Silo bucket data (attachments, images)
/etc/default/silo                     Silo root credentials
/root/atlas-cmms.creds                PostgreSQL credentials (written by setup_postgresql_db)
```

Defaults: 4 vCPU, 6 GB RAM, 20 GB disk, Debian 13, unprivileged. The RAM is for the build
(the CRA build is started with a 4 GB Node heap, exactly like upstream's Dockerfile); after the
install the stack idles at well under 2 GB. The first install builds the backend and the frontend
from source and takes 10–20 minutes depending on CPU and download speed.

## Installing

The engine fetches `install/atlas-cmms-install.sh` from the *scripts base URL*, which is
`_CS_DEFAULT_URL` on line 2 of `ct/atlas-cmms.sh` (DevScripts) unless `COMMUNITY_SCRIPTS_URL`
is set. Until this script is merged upstream, the install script must be reachable at that base,
so pick one of these:

### A. From your own GitHub repository (recommended)

Push this folder (keeping the `ct/`, `install/`, `json/` layout) to a repository, then run on the
Proxmox host:

```bash
COMMUNITY_SCRIPTS_URL=https://raw.githubusercontent.com/chilltrout/proxmox-atlas-cmms/main bash -c "$(curl -fsSL https://raw.githubusercontent.com/chilltrout/proxmox-atlas-cmms/main/ct/atlas-cmms.sh)"
```

Or change line 2 of `ct/atlas-cmms.sh` to your base URL once and drop the variable:

```bash
sed -i 's|^_CS_DEFAULT_URL=.*|_CS_DEFAULT_URL="https://raw.githubusercontent.com/chilltrout/proxmox-atlas-cmms/main"|' ct/atlas-cmms.sh
```

The base URL is baked into the container's `/usr/bin/update`, so `update` keeps pulling from your
repository afterwards.

### B. From a local checkout on the Proxmox host

```bash
git clone https://github.com/community-scripts/core.git
git clone https://github.com/chilltrout/proxmox-atlas-cmms.git atlas-scripts   # or copy this folder next to core/
bash atlas-scripts/ct/atlas-cmms.sh
```

The engine resolves `core/` as a sibling directory and `install/` relative to the ct script. Set
`COMMUNITY_SCRIPTS_URL` as in A so the generated `update` command has a remote base to pull from.

### C. Upstream

New scripts go to [DevScripts](https://github.com/community-scripts/DevScripts) first (never
directly to ProxmoxVE). Copy the three files into a DevScripts fork, open a PR, and state in the
description what the install was derived from (see "Design notes"). Once promoted, the normal
`bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/atlas-cmms.sh)"`
one-liner and the website entry work without any of the above.

## First login

Open `http://<container-ip>` and use **Sign up** to create the first organization and its
administrator. Registration is open to anyone who can reach the port until you set
`ALLOWED_ORGANIZATION_ADMINS` (comma-separated e-mail addresses) in `/opt/atlas-cmms_data/.env`
and restart the backend.

Upstream also seeds an API-only super admin (`superadmin@test.com` / `pls_change_me`, login type
`SUPER_ADMIN`). Change it as described in
[SuperAdmin password update guide](https://github.com/Grashjs/cmms/blob/main/dev-docs/SuperAdmin%20password%20update%20guide.md).

## Updating

Inside the container run:

```bash
update
```

`/usr/bin/update` is generated by the engine. It pulls `ct/atlas-cmms.sh` from the scripts base it
was installed from and runs `update_script()`, which:

1. Checks `pgsty/silo` for a new release and, if there is one, stops Silo, installs the new .deb
   (keeping `/etc/default/silo`) and starts it again.
2. Checks `Grashjs/cmms` for a new GitHub release (`~/.atlas-cmms` holds the installed version).
   If there is one it stops `atlas-cmms`, refreshes Temurin 17 and Node 22, wipes and re-deploys
   `/opt/atlas-cmms` from the release tarball (`CLEAN_INSTALL=1`), rebuilds the backend jar and the
   frontend, and starts the service. Liquibase applies database migrations on the first start of
   the new version. `/opt/atlas-cmms_data` is untouched.

Without the generated command the same thing is
`bash -c "$(curl -fsSL <scripts-base>/ct/atlas-cmms.sh)"` run inside the container. If a build
step fails, the previous jar and frontend build are kept where possible (so
`systemctl start atlas-cmms` brings the old version back) and the engine remembers the unfinished
update; fix the cause (usually memory or network) and run `update` again, it re-deploys and
rebuilds.

Back up before major upgrades (see below). Upstream's
[Upgrading.md](https://github.com/Grashjs/cmms/blob/main/dev-docs/Upgrading.md) also asks you to
compare your `.env` against the latest `.env.example` for new variables; the full list of keys the
backend reads is in `api/src/main/resources/application.yml`.

## Configuration

Backend settings are environment variables in `/opt/atlas-cmms_data/.env`
(`systemctl restart atlas-cmms` after changes). The names are the same as in upstream's
`docker-compose.yml` / README. Frontend settings are in `/opt/atlas-cmms_data/runtime-env.js`
(picked up on the next browser refresh, no restart needed). Keep the two in sync for
`INVITATION_VIA_EMAIL`, `ENABLE_SSO`, `OAUTH2_PROVIDER`, `LDAP_ENABLED`, `LOGO_PATHS`,
`CUSTOM_COLORS` and `BRAND_CONFIG`, which both sides read.

**Public URL / domain / HTTPS.** The install writes the container IP into `PUBLIC_API_URL`,
`PUBLIC_FRONT_URL` and `PUBLIC_MINIO_ENDPOINT`; they are used for links in e-mails, OAuth
redirects, the mobile app and file download URLs. Give the container a DHCP reservation or static
IP. To publish it under a name, terminate TLS on your reverse proxy (Nginx Proxy Manager, Caddy,
Traefik, …) pointing at port 80 of the container, then set

```
PUBLIC_API_URL=https://cmms.example.com/api
PUBLIC_FRONT_URL=https://cmms.example.com
PUBLIC_MINIO_ENDPOINT=https://cmms.example.com/storage
```

and restart the backend. The frontend uses the relative `/api` path, so it needs no change. The
mobile app is configured with `https://cmms.example.com/api`.

**E-mail.** Set `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PWD`, `SMTP_FROM`,
`ENABLE_EMAIL_NOTIFICATIONS=true` (and `INVITATION_VIA_EMAIL=true` on both sides if invited users
should receive e-mails). `ENABLE_MAIL_HEALTH_CHECK` is `false` by default so the actuator health
endpoint does not report DOWN while no SMTP server is configured; set it back to `true` once mail
works.

**White labeling / license.** `LICENSE_KEY`, `LOGO_PATHS`, `CUSTOM_COLORS` and `BRAND_CONFIG`
work as documented upstream; logo files go to `/opt/atlas-cmms_data/static/images`. JSON values
in `.env` must be single-quoted for systemd, e.g.
`CUSTOM_COLORS='{"primary":"#EE4B2B","secondary":"#6E759F"}'`.

**Ports.** nginx listens on 80. The backend (8080), Silo (9000) and its console (9001) are bound to
127.0.0.1 only. To open the Silo console, change `MINIO_OPTS` in `/etc/default/silo`.

## Backup and restore

Stop the backend, dump the database, copy the data directory:

```bash
systemctl stop atlas-cmms
pg_dump -U postgres -Fc atlas > /root/atlas-$(date +%F).dump
tar -czf /root/atlas-data-$(date +%F).tar.gz /opt/atlas-cmms_data /etc/default/silo
systemctl start atlas-cmms
```

Restore on a fresh install by stopping `atlas-cmms`, restoring the dump with
`pg_restore -U postgres -d atlas --clean`, unpacking the tarball over `/`, fixing ownership
(`chown -R silo:silo /opt/atlas-cmms_data/storage`) and restarting `silo` and `atlas-cmms`. Proxmox
snapshots / vzdump of the whole container are of course the simplest option.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| UI loads, API calls fail | `journalctl -u atlas-cmms -e`; the backend takes 30–60 s to start and runs migrations on first boot |
| Backend loops on start with `Waiting for changelog lock` | an earlier start was interrupted; run `psql -U postgres -d atlas -c "UPDATE DATABASECHANGELOGLOCK SET LOCKED=false, LOCKGRANTED=null, LOCKEDBY=null WHERE ID=1;"` |
| `Error configuring MinIO` on start | `systemctl status silo`; credentials in `/etc/default/silo` must match `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` in `.env` |
| Attachments upload but do not open | `PUBLIC_MINIO_ENDPOINT` must be the URL the *browser* can reach, ending in `/storage` |
| Build killed during `npm run build` | out of memory; give the container at least 6 GB RAM for the update, it can be lowered again afterwards |
| nginx fails to start | `nginx -t`; the site is `/etc/nginx/sites-available/atlas-cmms` |

## Design notes (for a DevScripts PR description)

- Install sequence derived from `api/Dockerfile` (`maven:3.9.9-eclipse-temurin-17`,
  `mvn clean package -DskipTests`, `java --add-opens=java.base/java.lang=ALL-UNNAMED -jar`),
  `frontend/Dockerfile` (`node:22`, `npm ci --legacy-peer-deps`,
  `NODE_OPTIONS=--max_old_space_size=4096 npm run build`, `runtime-env-cra` → `runtime-env.js`),
  `docker-compose.yml` (PostgreSQL 16, Silo, environment variable names) and `nginx.conf`
  (single-ingress routing; `/storage/` must forward `Host` as the S3 endpoint because the backend
  rewrites presigned URLs from `MINIO_ENDPOINT` to `PUBLIC_MINIO_ENDPOINT`).
- `/app/static/{images,config}` is hardcoded in `WebMvcConfig.java` / `LogoSetupComponent.java`,
  hence the `/app → /opt/atlas-cmms_data` symlink.
- Maven comes from Debian; it is installed after `setup_java` so Temurin (which provides
  `java8-runtime-headless`) satisfies its dependency instead of pulling OpenJDK 21.
- `unaccent` is created by a Liquibase changelog (`CREATE EXTENSION IF NOT EXISTS`); it is also
  pre-created by `setup_postgresql_db` so the migration never depends on role privileges.
- Releases: Grashjs/cmms publishes GitHub releases (v1.9.0 at the time of writing) as source
  tarballs only, so `fetch_and_deploy_gh_release … "tarball"` + rebuild is the only option; the
  prebuilt artifacts exist solely as Docker images.
- `var_arm64` is left unset (never run on arm64). All components ship arm64 builds
  (Temurin, NodeSource, PGDG, Silo .deb), so it is likely to work but is unverified.
- Not yet tested on a live Proxmox host. Syntax-checked, and every helper call was checked against
  the current `core` engine sources.

## License

The scripts are MIT like the rest of community-scripts. Atlas CMMS itself is AGPL-3.0 with an
optional commercial license for white labeling and advanced features
(see the upstream `COMMERCIAL_LICENSE.MD`).
