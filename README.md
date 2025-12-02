# Bookstack

Bookstack is a centralised book stack from book acquisition to e-reader. It lets you self-host AutoCaliWeb as a central library and Ephemera as a book acquisition solution, and includes a merged docker-compose setup and a KOReader plugin so you can request books directly from your device and get enhanced OPDS server metadata and usability.

This repository brings those pieces together:
- A docker-compose that runs AutoCaliWeb and Ephemera together as a single deployment.
- A KOReader plugin that:
  - Lets KOReader request books from your Bookstack services from the device.
  - Enhances KOReader's built-in OPDS server with extra metadata and usability improvements.

Thanks to the original projects:
- AutoCaliWeb — https://github.com/gelbphoenix/autocaliweb
- Ephemera — https://github.com/OrwellianEpilogue/ephemera
- KOReader — https://github.com/koreader/koreader

Table of contents
- Features
- Requirements
- Quick start
- Configuration (.env)
- Install and run (docker-compose)
- KOReader plugin install & configuration
- Usage
- Troubleshooting
- Security and networking notes
- Contributing & credits
- License

Features
- Single docker-compose bringing AutoCaliWeb and Ephemera up together
- KOReader plugin to search/request books from your device
- OPDS server enhancements for improved metadata and usability when browsing on KOReader

Requirements
- Docker & Docker Compose (v2 recommended)
- A network-accessible host for the services (LAN or public IP / domain)
- A KOReader-compatible device (e.g., supported e-ink reader with KOReader installed)
- A .env file created from the template in this repository

Quick start
1. Create a .env file using the template included in this repo:
   - cp .env.template .env
   - Edit .env to set your host addresses, ports, credentials and any other required variables.
2. Copy the provided docker-compose.yml into your host environment (or use the one in this repo).
3. Start the stack:
   - docker compose up -d
4. Once services are up, install the KOReader plugin on your device (instructions below).
5. Restart KOReader and configure the plugin with your network-facing addresses for AutoCaliWeb and Ephemera.

Configuration (.env)
- This repo includes a template file (e.g., `.env.template`) — use it to generate your `.env`.
- Typical variables you should set:
  - AUTOCALIWEB_HOST (or URL)
  - AUTOCALIWEB_PORT
  - EPHEMERA_HOST (or URL)
  - EPHEMERA_PORT
  - OPTIONAL: any API keys or authentication variables required by the upstream projects
- Use hostnames or IPs reachable from your KOReader device (for example the LAN IP of the host running Docker).

Install and run (docker-compose)
1. Copy or open the docker-compose.yml in this repository.
2. Ensure your `.env` is in the same folder as `docker-compose.yml` or referenced correctly.
3. Start the services:
   - docker compose up -d
4. Watch logs to make sure everything starts cleanly:
   - docker compose logs -f

KOReader plugin — install & configure
1. On your computer, locate the plugin folder in this repository (e.g., `koreader-plugin/`).
2. Copy that folder to the `plugins` folder on your KOReader device:
   - e.g., mount the device storage and copy `koreader-plugin` into `/Koreader/plugins/` (device paths vary by device).
3. Restart KOReader.
4. In KOReader:
   - Navigate to Settings -> Plugins (or the plugin manager).
   - Enable/configure the Bookstack/OPDS enhancement plugin.
   - Enter the network-facing addresses (URIs) for your AutoCaliWeb and Ephemera services (the ones you set in `.env`).
5. Use the plugin UI on device to browse the enhanced OPDS listing and request books.

Usage
- Browse the OPDS feed in KOReader to find books available through Ephemera / AutoCaliWeb.
- Request books from your device — Bookstack will coordinate acquisition (Ephemera) and library management (AutoCaliWeb).
- The plugin improves the OPDS experience (richer metadata, better navigation) compared to KOReader's default OPDS server.

Troubleshooting
- If KOReader can't reach the services:
  - Verify the device and the host are on the same network and can reach each other's IPs.
  - Confirm ports are open and not blocked by a firewall.
  - Test the service endpoints from another device (browser or curl).
- Logs:
  - docker compose logs -f
  - Check logs for both autocaliweb and ephemera containers for errors.
- If the plugin doesn't appear in KOReader:
  - Ensure the plugin folder is in the correct plugins directory for your device and KOReader version.
  - Check KOReader console/logs for plugin-related errors.

Security and networking notes
- If exposing services to the internet, secure them appropriately:
  - Use HTTPS (reverse proxy with TLS), strong passwords and/or API tokens.
  - Consider using a VPN or tunneled connection if you need remote access but want to avoid public exposure.
- Keep your host OS, Docker, and the upstream projects up to date.

Contributing
- Contributions, fixes, and improvements are welcome.
- If you add integration improvements, tests, or documentation updates, please open a PR.
- If you find issues with the KOReader plugin or with the docker-compose, open an issue describing the environment, steps to reproduce, and logs.

Credits and upstream projects
- This repo integrates and builds on:
  - AutoCaliWeb — https://github.com/gelbphoenix/autocaliweb
  - Ephemera — https://github.com/OrwellianEpilogue/ephemera
  - KOReader — https://github.com/koreader/koreader
- Thanks to the developers and maintainers of those projects for their work.

License
- This repository uses the same license as the included upstream components unless otherwise noted. Please review individual component licenses and this repo's LICENSE file (if present) before production use.

- Add example curl commands to validate endpoints.
- Create a short troubleshooting / FAQ doc for common KOReader plugin issues.
