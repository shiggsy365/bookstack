# Bookstack

Bookstack is a self-hosted book discovery, acquisition, library, and Kindle-delivery stack. It presents the whole workflow through a marketplace-style web application designed for modern browsers and older Kindle and Kobo browsers.

It solves two related but distinct tasks:

- **Use a book you already own:** browse Booklore and send a library file to Kindle immediately.
- **Acquire a missing book:** discover or search for it, select a Shelfmark release, monitor the download, and use it from Booklore after ingestion.

Bookstack checks search and discovery results against Booklore. A book with a confirmed Booklore download URL is labelled **Available** and defaults to **Send to Kindle**. A missing book is labelled **Request needed** and defaults to the Shelfmark request flow.

## Stack components

| Service | Purpose | Access by default |
| --- | --- | --- |
| Bookstack | Unified, Kindle-friendly web interface and SMTP delivery service | HTTPS through Traefik |
| Booklore | Library, OPDS catalogue, metadata, and book ingestion | HTTPS through Traefik |
| Shelfmark | Release-source search, release selection, and download orchestration | `http://127.0.0.1:8084` on the VPS |
| Prowlarr | Indexer management used by the acquisition workflow | `http://127.0.0.1:9696` on the VPS |
| SABnzbd | Usenet download client | `http://127.0.0.1:8080` on the VPS |
| MariaDB | Booklore database | Internal Docker network only |

Only Bookstack and Booklore are published through Traefik. Administrative services use loopback-bound HTTP ports and are not directly reachable from the internet.

## Features

- Marketplace-style **Library** and **Store** modes with persistent bottom navigation.
- Library views for **Recent**, tiled **Authors**, stacked-cover **Series**, **All Books**, and **Search**.
- Store views for **Trending**, **Popular**, **Bestsellers**, **Author Search**, and **Book Search**, with genre and publication-period filters.
- Hardcover-backed recommendations, author tiles, author bibliographies, covers, and title search.
- Optional New York Times bestseller lists and Open Library fallback metadata.
- Availability-aware book details: **Available**, **Request needed**, and **Downloading**.
- Staged Shelfmark requests which search by ISBN first, then author and title, then title only through explicit **No results found?** prompts, followed by release selection and queue monitoring.
- Booklore OPDS browsing and one-click Send to Kindle delivery.
- Four-line listing descriptions and ten-line detail descriptions.
- Hierarchical back navigation plus first/previous/next/last page controls.
- Persistent metadata caching across container rebuilds and restarts.
- A 120-second browser/provider search timeout for slower external services.
- A 150% initial viewport scale and conservative HTML/JavaScript/CSS for older Kindle and Kobo browsers.

## How it works

```text
Search or discover a book
          |
          v
Check Booklore for a usable library file
       /     \
      yes     no
      |        |
Send to       Search Shelfmark
Kindle         |
               v
          Choose a release
               |
               v
      Shelfmark/download client
               |
               v
        Booklore ingestion
               |
               v
          Send to Kindle
```

Bookstack does not replace Booklore, Shelfmark, Prowlarr, or SABnzbd. It provides a common user interface over them.

## Requirements

- A Linux host or VPS with Docker Engine and Docker Compose v2.
- DNS records for the Bookstack and Booklore hostnames pointing to the VPS.
- A working Traefik deployment on the same Docker network for HTTPS access.
- Storage paths for the Booklore library, ingestion folder, and completed downloads.
- Credentials for Booklore OPDS access.
- An SMTP account if Send to Kindle will be used.
- At least one legal download source/indexer configured in the acquisition services.

You are responsible for using indexers and downloaded material in accordance with the law and the terms of the services involved.

## Directory layout

```text
apps/bookstack/
├── .env example              Environment template
├── compose.yaml              Complete six-service stack
├── Dockerfile                Bookstack web image
├── app.py                    Flask application entry point
├── bookstack_app/            API integrations and application logic
├── templates/index.html      Kindle-compatible single-page interface
└── sabnzbd/                  Seed/configuration files for SABnzbd
```

Persistent service data is placed below `BOOKSTACK_INSTALL`; the library, ingest, and completed-download locations are controlled separately.

## Installation

### 1. Create the environment file

From the repository root:

```bash
cd apps/bookstack
cp ".env example" .env
chmod 600 .env
```

Edit `.env` and replace every placeholder. Do not commit this file; it contains database, Booklore, and SMTP secrets and is ignored by Git.

Avoid spaces around `=` when editing values:

```dotenv
PUID=1001
BOOKSTACK_HOSTNAME=books.example.com
```

### 2. Prepare host directories

Create the locations selected in `.env`. With the example paths:

```bash
sudo mkdir -p /opt/docker/apps/bookstack
sudo mkdir -p /mnt/booklore/ingest /mnt/booklore/library /mnt/booklore/complete
sudo chown -R 1001:1001 /opt/docker/apps/bookstack /mnt/booklore
```

Replace `1001:1001` with the configured `PUID:PGID`. Do not change ownership blindly if these paths already contain data used by another deployment.

Bookstack stores shared provider responses, availability data, failure backoff, and provider metrics in a shared SQLite database under `/bookstack/cache`.

### 3. Configure DNS and Traefik

Create DNS records for `BOOKSTACK_HOSTNAME` and `BOOKLORE_HOSTNAME`. The Compose labels expect a Traefik certificate resolver named `letsencrypt` and route both applications over HTTPS.

The repository-level Compose file places services on the shared network defined by `DOCKER_NETWORK`, defaulting to `aio_default`. If this app is deployed independently, ensure Traefik joins the same Docker network or adapt the networking and labels to your environment.

### 4. Validate the configuration

From the repository root:

```bash
docker compose --profile required config
```

For the Bookstack Compose file on its own:

```bash
docker compose \
  --env-file apps/bookstack/.env \
  -f apps/bookstack/compose.yaml \
  --profile required \
  config
```

Resolve all errors or unset-variable warnings before starting the stack.

### 5. Start the stack

Using the repository-level Compose file:

```bash
docker compose --profile required up -d --build bookstack booklore mariadb shelfmark prowlarr sabnzbd
```

Using the Bookstack Compose file directly:

```bash
docker compose \
  --env-file apps/bookstack/.env \
  -f apps/bookstack/compose.yaml \
  --profile required \
  up -d --build
```

Check container state and the Bookstack health endpoint:

```bash
docker compose --profile required ps
curl -fsS "https://${BOOKSTACK_HOSTNAME}/healthz"
```

The health endpoint returns `{"status":"ok"}`.

## Environment variables

All Compose interpolation and Bookstack settings live in `apps/bookstack/.env`.

### Host identity and storage

| Variable | Required | Description |
| --- | --- | --- |
| `PUID` | Yes | Host user ID used by LinuxServer containers and Booklore. |
| `PGID` | Yes | Host group ID used by LinuxServer containers and Booklore. |
| `TZ` | Yes | IANA time zone, such as `Europe/London`. |
| `BOOKSTACK_INSTALL` | Yes | Root directory for persistent configuration and the metadata cache. |
| `INGEST_FOLDER` | Yes | Host folder mounted into Booklore as `/bookdrop`. |
| `BOOK_LIBRARY` | Yes | Host folder mounted into Booklore as `/books` and Shelfmark as `/books`. |
| `DOWNLOAD_FOLDER` | Yes | Host completed-download folder mounted into Shelfmark as `/downloads`. |

### Bookstack and Booklore

| Variable | Required | Description |
| --- | --- | --- |
| `BOOKSTACK_HOSTNAME` | Yes | Public hostname used by the Bookstack Traefik router. |
| `BOOKLORE_HOSTNAME` | Yes | Public hostname used by the Booklore Traefik router. |
| `BOOKLORE_PORT` | Yes | Internal Booklore HTTP port; normally `6060`. |
| `BOOKLORE_URL` | Yes | Internal OPDS base URL; normally `http://booklore:6060/api/v1/opds`. |
| `BOOKLORE_USER` | Yes | Username used by Bookstack to authenticate to Booklore OPDS. |
| `BOOKLORE_PASS` | Yes | Password used by Bookstack to authenticate to Booklore OPDS. |

Bookstack refuses to start if `BOOKLORE_USER` or `BOOKLORE_PASS` is empty.

### Shelfmark and sources

| Variable | Required | Description |
| --- | --- | --- |
| `SHELFMARK_PORT` | Yes | Shelfmark HTTP port; normally `8084`. |
| `SHELFMARK_URL` | Yes | Internal Shelfmark URL; normally `http://shelfmark:8084`. |
| `AA_BASE_URL` | Service-dependent | Primary source URL passed to Shelfmark. |
| `AA_MIRROR_URLS` | Service-dependent | Shelfmark mirror URL list. |
| `LIBGEN_MIRROR_URLS` | Service-dependent | Shelfmark Libgen mirror URL list. |
| `ZLIB_MIRROR_URLS` | Service-dependent | Shelfmark Z-Library mirror URL list. |
| `USING_TOR` | Yes | Enables Shelfmark's Tor mode when `true`; otherwise `false`. |

Mirror domains can change. Maintain these values according to Shelfmark's current guidance and your permitted sources.

### Database

| Variable | Required | Description |
| --- | --- | --- |
| `DATABASE_URL` | Yes | Booklore JDBC URL; normally `jdbc:mariadb://mariadb:3306/booklore`. |
| `DB_USER` | Yes | MariaDB application user used by Booklore. |
| `DB_PASSWORD` | Yes | Strong password shared by MariaDB and Booklore. |
| `MYSQL_DATABASE` | Yes | MariaDB database name; normally `booklore`. |
| `MYSQL_ROOT_PASSWORD` | Yes | Strong MariaDB root password. |

### Send to Kindle

| Variable | Required | Description |
| --- | --- | --- |
| `SMTP_SERVER` | For delivery | SMTP server, such as `smtp.gmail.com`. |
| `SMTP_PORT` | For delivery | STARTTLS SMTP port, normally `587`. |
| `SMTP_USER` | For delivery | SMTP login and message sender address. |
| `SMTP_PASS` | For delivery | SMTP password or provider-specific app password. |
| `MAX_KINDLE_ATTACHMENT_MB` | No | Maximum attachment size; defaults to `25`. |

The recipient Kindle address is not stored in `.env`. Each browser saves its chosen address in a one-year `kindle_email` cookie through **Settings**.

### Optional discovery integrations

| Variable | Required | Description |
| --- | --- | --- |
| `OPENLIBRARY_CONTACT` | Recommended | Contact email included in the Open Library user agent. |
| `GOOGLE_BOOKS_API_KEY` | No | Google Books key used only for the explicit on-demand Book Search fallback. |
| `NYT_BOOKS_API_KEY` | No | New York Times Books API key used for bestseller pages. |
| `HARDCOVER_API_KEY` | No | Hardcover token used for trending, genres, and new releases. |

Features backed by an unconfigured optional provider may be unavailable or fall back to another metadata source.

## Initial service configuration

### Booklore

1. Open `https://BOOKLORE_HOSTNAME` and complete Booklore's setup.
2. Confirm that the library uses `/books` and that its ingestion workflow watches `/bookdrop` as appropriate for your Booklore version.
3. Create or choose the credentials used for OPDS access.
4. Put the same credentials in `BOOKLORE_USER` and `BOOKLORE_PASS`.
5. Confirm that the OPDS endpoint is reachable from the Bookstack container.

The important requirement is that completed acquisitions ultimately enter the library exposed through Booklore OPDS.

### Prowlarr, Shelfmark, and SABnzbd

These interfaces are intentionally local-only. From your computer, create an SSH tunnel and leave it running:

```bash
ssh -NT \
  -L 9696:127.0.0.1:9696 \
  -L 8084:127.0.0.1:8084 \
  -L 8080:127.0.0.1:8080 \
  my-vps
```

The command appearing to “hang” is normal: `-N` opens no remote shell because the terminal is carrying the tunnels. Keep it open, or add `-f` after confirming key-based authentication works.

Open the services locally:

- Prowlarr: `http://127.0.0.1:9696`
- Shelfmark: `http://127.0.0.1:8084`
- SABnzbd: `http://127.0.0.1:8080`

Then:

1. Add and test your permitted indexers in Prowlarr.
2. Complete SABnzbd's server and category configuration if Usenet is part of the workflow.
3. Configure Shelfmark to use the required indexers/download clients and verify its completed-download path.
4. Submit a test acquisition and confirm that the file reaches Booklore's ingestion workflow.

Container-to-container addresses use service names, not `127.0.0.1`. For example, another container reaches Prowlarr as `http://prowlarr:9696` and SABnzbd as `http://sabnzbd:8080`.

### Send to Kindle

1. Configure valid SMTP credentials in `.env`. Gmail normally requires an app password rather than the normal account password.
2. In Amazon, open **Manage Your Content and Devices**, then the personal document settings.
3. Add `SMTP_USER` to the approved personal document sender list.
4. Rebuild/restart Bookstack after changing SMTP values.
5. Open Bookstack, select **Settings**, enter the destination Kindle email, and save it.
6. Send a small book from **Library** as an end-to-end test.

Bookstack downloads the selected file from Booklore into temporary storage, enforces `MAX_KINDLE_ATTACHMENT_MB`, sends it over STARTTLS SMTP, and removes the temporary data when the request ends.

## Using Bookstack

### Library

Library is the opening mode. Its navigation bar contains **Recent**, **Authors**, **Series**, **All Books**, and **Search**.

- Recent and All Books use compact marketplace listings with covers, metadata, availability, and four description lines.
- Authors are displayed as image tiles; selecting one opens that author's books.
- Series are displayed as tiles with the series name, three stacked covers, and author name; selecting one opens its books.
- Selecting a book opens a detail view with up to ten description lines and **Send to Kindle** when the file is available.

### Store

Store provides **Trending**, **Popular**, **Bestsellers**, **Author Search**, and **Book Search**. Recommendation and search views support genre and publication-period filters where applicable.

Hardcover supplies trending, popular, author, and primary book-search data. Book Search displays a **Book not found?** action which queries Google Books only when selected; identical Google searches are cached for 24 hours. The New York Times API supplies bestseller charts when configured. Search results are checked against Booklore before actions are displayed.

- **Available** opens a detail page with **Send to Kindle**.
- **Request needed** searches Shelfmark's direct-download channel by ISBN first. If no compatible release is found, **No results found?** prompts search all enabled Shelfmark release sources by author plus title and finally title only. These request searches bypass metadata providers such as Google Books.
- **Downloading** links to the download queue.

Shelfmark release lookups accept EPUB, MOBI, and AZW3 results. Browser and upstream search requests allow up to 120 seconds for e-reader connections and slower providers.

### Navigation

The bottom bar provides the main menu, first/previous/next/last page controls, and page numbering. The menu links to **Library**, **Store**, **Downloads**, and **Settings**. Hierarchical views expose a back action through the context bar. The bottom-left button displays the current main section and opens the menu for Library, Store, Downloads, and Settings. The redundant bottom-right tile shortcut has been removed.

The page requests an initial viewport scale of 150%. Browser zoom controls remain available where supported.

### Downloads

Choose **Downloads** to view Shelfmark's active, completed, or failed requests. A completed download may take additional time to appear in **Library** while Booklore ingests and scans it.

### Settings

Choose **Settings** to save the Kindle delivery address for the current browser. Clearing cookies or switching devices requires entering it again.

## Metadata and caching

Bookstack batches visible-page enrichment through Open Library. Google Books is used only when explicitly selected from Store Book Search.

- Successful resolved metadata is cached for 30 days.
- Empty results are cached for 6 hours before retrying.
- The persistent SQLite cache is shared by all Gunicorn workers and coalesces identical in-flight provider requests.
- The cache survives restarts and image rebuilds through the `/data` volume.

Discovery responses use stale-cache fallback during transient provider failures, and failures are briefly cached to prevent repeated taps from hammering an unavailable service. Booklore availability checks use a five-minute local catalogue snapshot instead of one OPDS search per book. The Authors catalogue is cached for 24 hours.

Text responses are compressed when the browser advertises gzip support. The main HTML uses ETag revalidation, discovery responses have short HTTP cache lifetimes, and proxied covers are cached for seven days. Gunicorn uses two threaded workers with four threads each so slow Shelfmark searches do not block ordinary navigation.

Provider cache and call metrics are available without credentials at `/health/providers`.

To force metadata to be fetched again, stop Bookstack and remove only the metadata cache database from `${BOOKSTACK_INSTALL}/bookstack/cache`. This is normally unnecessary.

## Updating and routine operation

Rebuild Bookstack after changing its code:

```bash
docker compose --profile required up -d --build bookstack
```

Pull third-party images and recreate the stack:

```bash
docker compose --profile required pull
docker compose --profile required up -d --build
```

Useful commands:

```bash
docker compose --profile required ps
docker compose --profile required logs -f --tail=200 bookstack
docker compose --profile required restart bookstack
```

If running the standalone file, add `--env-file apps/bookstack/.env -f apps/bookstack/compose.yaml` to these commands.

## Backups

Back up at least:

- `apps/bookstack/.env`, stored securely and separately from source control.
- `${BOOKSTACK_INSTALL}/mariadb/config`, including the Booklore database.
- `${BOOKSTACK_INSTALL}/booklore/data`.
- `${BOOKSTACK_INSTALL}/prowlarr/config`.
- `${BOOKSTACK_INSTALL}/shelfmark/config`.
- `${BOOKSTACK_INSTALL}/sabnzbd`.
- `BOOK_LIBRARY` and unprocessed files in `INGEST_FOLDER` or `DOWNLOAD_FOLDER`.

The metadata cache is disposable. Stop or quiesce database-writing services before a filesystem-level database backup, or use a database-aware backup method.

## Troubleshooting

### A local admin page refuses to connect

Confirm the container is running and listening on the VPS:

```bash
docker compose --profile required ps
curl -v http://127.0.0.1:9696/
```

A `302` response from Prowlarr is healthy and redirects to its login page. If the VPS responds but your computer does not, recreate the SSH tunnel and test `curl -v http://127.0.0.1:9696/` in a second local terminal.

If SSH to the raw IP times out but `ssh my-vps` works, use the alias; it may contain the correct port, user, key, or proxy settings.

### Compose reports unset variables

Run Compose from the repository root, where the Bookstack include declares its environment file, or explicitly pass it:

```bash
docker compose \
  --env-file apps/bookstack/.env \
  -f apps/bookstack/compose.yaml \
  --profile required \
  config
```

Ensure every value uses `NAME=value` syntax and contains no placeholder text.

### Bookstack is unhealthy

```bash
docker compose --profile required logs --tail=200 bookstack
docker compose --profile required exec bookstack python -c \
  "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:5000/healthz').read().decode())"
```

Check that Booklore and Shelfmark are running and that their internal URLs use Docker service names.

### A download is not in My Library

Check Shelfmark's completed path, Booklore's book-drop configuration, volume mappings, file ownership, and Booklore ingestion logs. Shelfmark completion means acquisition finished; it does not necessarily mean Booklore has ingested the file.

### Send to Kindle fails

Check that:

- A Kindle email is saved under **Settings** in the same browser.
- `SMTP_USER` is approved by Amazon as a personal document sender.
- SMTP credentials and the STARTTLS port are correct.
- The file is below `MAX_KINDLE_ATTACHMENT_MB`.
- Bookstack can download the selected file from Booklore.

Inspect Bookstack logs for the returned SMTP or delivery error.

### Metadata remains blank or slow

The first lookup requires external provider requests; later requests use the persistent cache. Check Bookstack logs for Hardcover, Google Books, or Open Library errors and verify outbound network access. Shelfmark searches can remain active for up to 120 seconds; ordinary metadata and catalogue providers use shorter timeouts and bounded transient retries.

## Security notes

- Keep `.env` private and use restrictive file permissions.
- Do not expose MariaDB, Prowlarr, Shelfmark, or SABnzbd directly to the internet.
- Protect public Bookstack and Booklore routes with your Traefik authentication middleware where appropriate.
- Rotate database, Booklore, and SMTP credentials if `.env` is disclosed.
- Keep Docker images and the host operating system updated.
- The Kindle destination is stored client-side in a cookie; avoid a shared browser profile if that is undesirable.

## Development

The web application uses Flask and Gunicorn. The interface intentionally avoids modern browser-only features for older e-ink devices. The default viewport scale is 150%. Preserve this compatibility when changing `templates/index.html`: prefer traditional JavaScript and broadly supported HTML/CSS, then test on a current browser and the target Kindle.

Basic validation:

```bash
python3 -m compileall -q apps/bookstack/bookstack_app apps/bookstack/app.py
docker compose \
  --env-file apps/bookstack/.env \
  -f apps/bookstack/compose.yaml \
  --profile required \
  config
```

## License and support

No standalone licence file is currently included in this application directory. Add an explicit licence before distributing the project. Issues and feature requests can be submitted through the project repository.

## Contribute

[<img src="https://github.com/shiggsy365/AIOStreamsKODI/blob/main/.github/support_me_on_kofi_red.png?raw=true">](https://ko-fi.com/shiggsy365)

