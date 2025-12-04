# Bookstack

Bookstack is a centralised book stack from book acquisition to e-reader. It lets you self-host AutoCaliWeb as a central library and Ephemera as a book acquisition solution, and includes a merged docker-compose setup and a KOReader plugin so you can request books directly from your device and get enhanced OPDS server metadata and usability.

This repository brings those pieces together:
- A docker-compose that runs AutoCaliWeb and Ephemera together as a single deployment.
- A KOReader plugin that:
  - Lets KOReader request books from your Bookstack services from the device.
  - Enhances KOReader's built-in OPDS server with extra metadata and usability improvements.
  - Integrates with Hardcover.app for enhanced book discovery, series information, and ratings.

Thanks to the original projects:
- AutoCaliWeb — https://github.com/gelbphoenix/autocaliweb
- Ephemera — https://github.com/OrwellianEpilogue/ephemera
- KOReader — https://github.com/koreader/koreader
- Hardcover — https://hardcover.app

Table of contents
- Features
- Requirements
- Quick start
- Configuration (.env)
- Install and run (docker-compose)
- KOReader plugin install & configuration
- Usage
- Hardcover Integration
- Troubleshooting
- Security and networking notes
- Contributing & credits
- License

## Features
- Single docker-compose bringing AutoCaliWeb and Ephemera up together
- KOReader plugin to search/request books from your device
- OPDS server enhancements for improved metadata and usability when browsing on KOReader
- Hardcover.app integration for:
  - Enhanced book discovery with author search
  - Accurate series information and ordering
  - Book ratings and descriptions
  - Library ownership tracking (see which books you already own)
  - Direct integration with Ephemera for requesting books

## Requirements
- Docker & Docker Compose (v2 recommended)
- A network-accessible host for the services (LAN or public IP / domain)
- A KOReader-compatible device (e.g., supported e-ink reader with KOReader installed)
- A .env file created from the template in this repository
- (Optional) A Hardcover.app API token for enhanced features

## Quick start
1. Create a .env file using the template included in this repo:
   - cp .env.template .env
   - Edit .env to set your host addresses, ports, credentials and any other required variables.
2. Copy the provided docker-compose.yml into your host environment (or use the one in this repo).
3. Start the stack:
   - docker compose up -d
4. Once services are up, install the KOReader plugin on your device (instructions below).
5. Restart KOReader and configure the plugin with your network-facing addresses for AutoCaliWeb and Ephemera.

## Configuration (.env)
- This repo includes a template file (e.g., `.env.template`) — use it to generate your `.env`.
- Typical variables you should set:
  - AUTOCALIWEB_HOST (or URL)
  - AUTOCALIWEB_PORT
  - EPHEMERA_HOST (or URL)
  - EPHEMERA_PORT
  - OPTIONAL: any API keys or authentication variables required by the upstream projects
- Use hostnames or IPs reachable from your KOReader device (for example the LAN IP of the host running Docker).

## Install and run (docker-compose)
1. Copy or open the docker-compose.yml in this repository.
2. Ensure your `.env` is in the same folder as `docker-compose.yml` or referenced correctly.
3. Start the services:
   - docker compose up -d
4. Watch logs to make sure everything starts cleanly:
   - docker compose logs -f

## KOReader plugin — install & configure
1. On your computer, locate the plugin folder in this repository (e.g., `koreader-plugin/`).
2. Copy that folder to the `plugins` folder on your KOReader device:
   - e.g., mount the device storage and copy `opdsbrowser.koplugin` into `/koreader/plugins/` (device paths vary by device).
3. Restart KOReader.
4. In KOReader:
   - Navigate to the menu and find "Cloud Book Library"
   - Go to "Plugin - Settings"
   - Enter the network-facing addresses (URIs) for your AutoCaliWeb and Ephemera services (the ones you set in `.env`).
   - (Optional) Enter your Hardcover Bearer Token for enhanced features
   - Enter your preferred download directory
5. Use the plugin UI on device to browse the enhanced OPDS listing, search Hardcover, and request books.

### Getting a Hardcover API Token
1. Visit https://hardcover.app and create an account (if you don't have one)
2. Go to your account settings
3. Navigate to the API section
4. Generate a new API token
5. Copy the token and add "Bearer " prefix (e.g., "Bearer abc123xyz...")
6. Enter this in the plugin settings under "Hardcover Bearer Token"

## Usage

### Library Browsing (OPDS)
- **Browse by Author**: View all authors in your library alphabetically, then drill down to their books
- **Browse by Title**: View all books in your library alphabetically
- **Browse New Titles**: See recently added books to your library
- **Search**: Search your library by title, author, or keywords

When browsing books by author, the plugin automatically:
- Fetches accurate series information from Hardcover
- Sorts books by series first, then standalone titles
- Shows series name and number in the book list
- Displays complete metadata including series info in book details

### Hardcover Integration
- **Search Author**: Find authors on Hardcover with "Known for" information
  - View all books by an author, sorted by popularity
  - See accurate series information and ordering
  - Check if books are already in your library (marked with ✓)
  - View detailed information including ratings, descriptions, and series data
  - Request books directly through Ephemera integration

The Hardcover integration intelligently caches data to minimize API calls and provides fast, responsive browsing.

### Ephemera Integration
- **Request New Book**: Search Ephemera's sources and queue books for download
- **View Download Queue**: Monitor active downloads, queued items, and completed books
- From Hardcover book details, use "Search Ephemera" to find and request books

### Book Downloads
- Download books directly from your OPDS library to your device
- Books are automatically added to your configured download directory
- Metadata is refreshed automatically after download
- File manager view updates to show newly downloaded books

## Troubleshooting
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
- If Hardcover features aren't working:
  - Verify your Bearer Token is correct and includes the "Bearer " prefix
  - Check network connectivity to api.hardcover.app
  - Review KOReader logs for Hardcover API errors
- If library ownership flags aren't showing:
  - Ensure your OPDS URL is configured correctly
  - Verify the OPDS search endpoint is working
  - Check that author names match between Hardcover and your library

## Security and networking notes
- If exposing services to the internet, secure them appropriately:
  - Use HTTPS (reverse proxy with TLS), strong passwords and/or API tokens.
  - Consider using a VPN or tunneled connection if you need remote access but want to avoid public exposure.
- Keep your host OS, Docker, and the upstream projects up to date.
- Store your Hardcover API token securely and never share it publicly.

## Contributing
- Contributions, fixes, and improvements are welcome.
- If you add integration improvements, tests, or documentation updates, please open a PR.
- If you find issues with the KOReader plugin or with the docker-compose, open an issue describing the environment, steps to reproduce, and logs.

## Credits and upstream projects
- This repo integrates and builds on:
  - AutoCaliWeb — https://github.com/gelbphoenix/autocaliweb
  - Ephemera — https://github.com/OrwellianEpilogue/ephemera
  - KOReader — https://github.com/koreader/koreader
  - Hardcover — https://hardcover.app
- Thanks to the developers and maintainers of those projects for their work.

## License
- This repository uses the same license as the included upstream components unless otherwise noted. Please review individual component licenses and this repo's LICENSE file (if present) before production use.
