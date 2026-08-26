# Bookstack

Bookstack is a self-hosted book discovery, acquisition, library, and Kindle-delivery interface. It presents Grimmory and Shelfmark as a marketplace-style web application while retaining compatibility with older Kindle and Kobo browsers.

- **Library** browses books already held in Grimmory and can send them to Kindle.
- **Store** discovers books, checks local availability, and requests missing titles through Shelfmark.
- **Downloads** tracks Shelfmark requests.
- **Settings** stores the destination Kindle address in the current browser.

![alt text](https://github.com/shiggsy365/bookstack/blob/main/Screenshots/Book%20Detail%20View.png?raw=true "Library (OPDS Browser)")

## Stack

The default [compose.yaml](compose.yaml) is the canonical core stack:

| Service | Purpose | Default access |
| --- | --- | --- |
| Bookstack | Unified web interface and Kindle delivery | HTTPS through Traefik |
| Grimmory | Library, OPDS catalogue, metadata, and ingestion | HTTPS through Traefik |
| Shelfmark | Release search and acquisition | `127.0.0.1:8084` |
| MariaDB | Grimmory database | Docker network only |

The optional [compose.usenet.yaml](compose.usenet.yaml) overlay adds:

| Service | Purpose | Default access |
| --- | --- | --- |
| Prowlarr | Usenet indexer management | `127.0.0.1:9696` |
| SABnzbd | Usenet download client | `127.0.0.1:8080` |

Only Bookstack and Grimmory are exposed through Traefik. Administrative ports bind to VPS loopback and should be reached through an SSH tunnel.

## Main features

- Marketplace-style Library and Store modes.
- Recent, Authors, Series, All Books, and Search library views.
- Trending, Popular, Bestsellers, Author Search, and Book Search store views.
- Grimmory availability detection and one-click Send to Kindle.
- Shelfmark searches staged by ISBN, author and title, then title.
- EPUB, MOBI, and AZW3 release selection and download monitoring.
- Persistent metadata caching, stale-provider fallback, and request coalescing.
- Four-line listing descriptions and ten-line detail descriptions.
- E-reader navigation, 150% initial viewport scale, and conservative browser code.

## Requirements

- Linux with Docker Engine and Docker Compose v2.
- Traefik on the same Docker network.
- DNS records for the Bookstack and Grimmory hostnames.
- Grimmory OPDS credentials.
- SMTP credentials for Send to Kindle.
- Storage for the library, inbox, incomplete downloads, and service configuration.
- Legal access to any configured acquisition sources.

## Quick start

Commands below assume the current directory is `apps/bookstack`.

### 1. Configure the environment

```bash
cp ".env example" .env
chmod 600 .env
```

Replace every placeholder in `.env`. Use `NAME=value` syntax without spaces around `=`. The file contains secrets and is ignored by Git.

### 2. Create storage directories

Using the example paths:

```bash
sudo mkdir -p /opt/docker/apps/bookstack
sudo mkdir -p /mnt/books/library /mnt/books/inbox /mnt/books/incomplete
sudo chown -R 1001:1001 /opt/docker/apps/bookstack /mnt/books
```

Use the configured `PUID:PGID`. Do not change ownership blindly when directories already contain data.

### 3. Validate and start

Core stack:

```bash
docker compose config
docker compose pull
docker compose up -d
```

Core stack plus optional Usenet services:

```bash
docker compose -f compose.yaml -f compose.usenet.yaml config
docker compose -f compose.yaml -f compose.usenet.yaml pull
docker compose -f compose.yaml -f compose.usenet.yaml up -d
```

No Compose profiles are required. Use the same two `-f` arguments for future Usenet-stack commands.

Bookstack uses the public multi-architecture image `ghcr.io/shiggsy365/bookstack:latest`. The Compose build context remains available for local development:

```bash
docker compose up -d --build bookstack
```

### 4. Check health

```bash
docker compose ps
curl -fsS "https://${BOOKSTACK_HOSTNAME}/healthz"
```

A healthy Bookstack response is `{"status":"ok"}`. Bookstack waits for healthy Grimmory and Shelfmark services before starting.

## Environment variables

### Host and storage

| Variable | Required | Purpose |
| --- | --- | --- |
| `PUID`, `PGID` | Yes | Host ownership used by Grimmory and LinuxServer containers. |
| `TZ` | Yes | IANA timezone, for example `Europe/London`. |
| `BOOKSTACK_INSTALL` | Yes | Persistent service configuration and Bookstack cache root. |
| `BOOK_LIBRARY` | Yes | Final library. Mounted into Grimmory as `/books`, and into Shelfmark and SABnzbd as `/downloads`. |
| `BOOK_INBOX` | Yes | Grimmory ingestion/watch folder mounted as `/bookdrop`. |
| `BOOK_INCOMPLETE` | With Usenet | SABnzbd incomplete-download directory. |
| `BOOK_DATA` | No | Optional parent path for organising the three book directories; Compose does not consume it directly. |

The former `INGEST_FOLDER` and `DOWNLOAD_FOLDER` variables are no longer used.

### Bookstack and Grimmory

| Variable | Required | Purpose |
| --- | --- | --- |
| `BOOKSTACK_HOSTNAME` | Yes | Public Bookstack hostname used by Traefik. |
| `GRIMMORY_HOSTNAME` | Yes | Public Grimmory hostname used by Traefik. |
| `GRIMMORY_PORT` | Yes | Internal Grimmory port, normally `6060`. |
| `GRIMMORY_URL` | Yes | OPDS base URL, normally `http://grimmory:6060/api/v1/opds`. |
| `GRIMMORY_USER`, `GRIMMORY_PASS` | Yes | Grimmory OPDS credentials used by Bookstack. |

Bookstack refuses to start without both Grimmory credentials.

### Shelfmark

| Variable | Required | Purpose |
| --- | --- | --- |
| `SHELFMARK_PORT` | Yes | Internal and loopback-bound Shelfmark port, normally `8084`. |
| `SHELFMARK_URL` | Yes | Internal URL, normally `http://shelfmark:8084`. |
| `AA_BASE_URL` | Source-dependent | Primary source URL passed to Shelfmark. |
| `AA_MIRROR_URLS` | Source-dependent | Anna's Archive mirror list. |
| `LIBGEN_MIRROR_URLS` | Source-dependent | Libgen mirror list. |
| `ZLIB_MIRROR_URLS` | Source-dependent | Z-Library mirror list. |
| `USING_TOR` | Yes | Enables Shelfmark Tor mode when `true`. |

Maintain source URLs according to Shelfmark guidance and applicable law.

### Database

| Variable | Required | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | Yes | Grimmory JDBC URL, normally `jdbc:mariadb://mariadb:3306/grimmory`. |
| `DB_USER` | Yes | MariaDB application user. |
| `DB_PASSWORD` | Yes | Password shared by MariaDB and Grimmory. |
| `MYSQL_DATABASE` | Yes | Database name, normally `grimmory`. |
| `MYSQL_ROOT_PASSWORD` | Yes | MariaDB root password. |

### Send to Kindle

| Variable | Required | Purpose |
| --- | --- | --- |
| `SMTP_SERVER` | For delivery | SMTP host. |
| `SMTP_PORT` | For delivery | STARTTLS port, normally `587`. |
| `SMTP_USER`, `SMTP_PASS` | For delivery | SMTP login credentials. |
| `MAX_KINDLE_ATTACHMENT_MB` | No | Attachment limit, default `25`. |

The Kindle recipient is saved in a one-year browser cookie under **Settings**, not in `.env`. Add `SMTP_USER` to Amazon's approved personal-document senders.

### Discovery providers

| Variable | Required | Purpose |
| --- | --- | --- |
| `OPENLIBRARY_CONTACT` | Recommended | Contact address included in the Open Library user agent. |
| `HARDCOVER_API_KEY` | No | Trending, popular, authors, genres, and primary title search. |
| `NYT_BOOKS_API_KEY` | No | New York Times bestseller lists. |
| `GOOGLE_BOOKS_API_KEY` | No | Explicit **Book not found?** fallback only. |

Unavailable optional providers are omitted or replaced by supported fallbacks.

## Initial service setup

### Grimmory

1. Open `https://GRIMMORY_HOSTNAME` and complete setup.
2. Configure the library at `/books` and, if used, the watched ingestion folder at `/bookdrop`.
3. Put its OPDS credentials in `GRIMMORY_USER` and `GRIMMORY_PASS`.
4. Confirm Bookstack can reach `GRIMMORY_URL`.

### Shelfmark and optional Usenet services

Create a local SSH tunnel when administrative access is needed:

```bash
ssh -NT \
  -L 8084:127.0.0.1:8084 \
  -L 9696:127.0.0.1:9696 \
  -L 8080:127.0.0.1:8080 \
  my-vps
```

Then open Shelfmark on port 8084, Prowlarr on 9696, or SABnzbd on 8080. Configure only the services you use. Container-to-container addresses use service names such as `http://prowlarr:9696` and `http://sabnzbd:8080`, never `127.0.0.1`.

Shelfmark and SABnzbd both write completed files to the host `BOOK_LIBRARY` path. Grimmory exposes that path as `/books`. SABnzbd uses `BOOK_INCOMPLETE` while a download is unfinished; `BOOK_INBOX` remains available for Grimmory's separate watch-folder workflow.

### Send to Kindle

1. Configure SMTP values and restart Bookstack.
2. Approve `SMTP_USER` in Amazon's personal-document settings.
3. Save the destination Kindle address under Bookstack **Settings**.
4. Send a small library book as an end-to-end test.

## Application behaviour

Library opens by default. Its views are **Recent**, **Authors**, **Series**, **All Books**, and **Search**. Authors and series use tiles; book lists use compact marketplace rows.

Store provides **Trending**, **Popular**, **Bestsellers**, **Author Search**, and **Book Search**. Hardcover supplies primary discovery, NYT supplies configured bestseller charts, and Google Books is queried only after selecting **Book not found?**. Search results are checked against the cached Grimmory catalogue.

Availability actions are:

- **Available** — open details and Send to Kindle.
- **Request needed** — search Shelfmark by ISBN, then author/title, then title.
- **Downloading** — open the download queue.

The bottom section button opens Library, Store, Downloads, and Settings. Hierarchical views provide a back button, and listings provide first/previous/next/last controls and page numbering.

## Caching and performance

- Resolved metadata: 30 days.
- Empty metadata results: 6 hours.
- Grimmory catalogue snapshot: 5 minutes.
- Author catalogue: 24 hours.
- Proxied covers: 7 days.
- Identical Google searches: 24 hours.

The SQLite cache is shared by Gunicorn workers and persists at `${BOOKSTACK_INSTALL}/bookstack/cache`. Provider failures use brief backoff and stale-cache fallback. Provider metrics are available at `/health/providers`.

Searches may run for up to 120 seconds. Responses support gzip and ETag revalidation.

## Operations

```bash
# Update the core stack
docker compose pull
docker compose up -d

# Inspect Bookstack
docker compose ps
docker compose logs -f --tail=200 bookstack
docker compose restart bookstack

# Validate configuration
docker compose config
```

For the optional Usenet stack, add `-f compose.yaml -f compose.usenet.yaml` to each command.

The `main` branch publishes `latest` for AMD64 and ARM64. Version tags publish matching semantic-version image tags.

## Backups

Back up:

- `.env`, securely and separately from source control.
- `${BOOKSTACK_INSTALL}/mariadb/config` with a database-aware method or while services are quiesced.
- `${BOOKSTACK_INSTALL}/grimmory/data`.
- `${BOOKSTACK_INSTALL}/shelfmark/config`.
- Optional `${BOOKSTACK_INSTALL}/prowlarr/config` and `${BOOKSTACK_INSTALL}/sabnzbd`.
- `BOOK_LIBRARY`, `BOOK_INBOX`, and any important files in `BOOK_INCOMPLETE`.

The Bookstack metadata cache is disposable.

## Troubleshooting

### Compose reports unset variables

Run commands from `apps/bookstack`, confirm `.env` exists, and use `NAME=value` syntax. Validate with `docker compose config`.

### Bookstack is unhealthy

```bash
docker compose logs --tail=200 bookstack
docker compose exec bookstack python -c \
  "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:5000/healthz').read().decode())"
```

Check Grimmory and Shelfmark health and ensure internal URLs use Docker service names.

### A completed download is missing from Library

Check `BOOK_LIBRARY` volume mappings, ownership, Grimmory scanning, and Shelfmark/SABnzbd logs. A completed acquisition may still require a Grimmory scan before it appears in OPDS.

### Send to Kindle fails

Confirm the browser has a Kindle address saved, Amazon approves `SMTP_USER`, SMTP credentials are correct, and the file is under `MAX_KINDLE_ATTACHMENT_MB`.

### Metadata is blank or slow

The first lookup may require external requests. Check `/health/providers`, container logs, API credentials, and outbound network access. Later requests should use the persistent cache.

## Security

- Keep `.env` private and mode `600`.
- Do not expose MariaDB, Shelfmark, Prowlarr, or SABnzbd publicly.
- Protect public routes with appropriate Traefik authentication.
- Rotate credentials if `.env` is disclosed.
- Keep images and the host updated.

## Development

The application uses Flask and Gunicorn. Preserve older e-reader compatibility when modifying `templates/index.html`: prefer traditional JavaScript and broadly supported HTML/CSS.

```bash
python3 -m compileall -q app.py bookstack_app
docker compose config
docker compose up -d --build bookstack
```

## Support

Issues and feature requests can be submitted through this repository. Add an explicit licence before redistributing the project.

[<img src="https://github.com/shiggsy365/AIOStreamsKODI/blob/main/.github/support_me_on_kofi_red.png?raw=true">](https://ko-fi.com/shiggsy365)
