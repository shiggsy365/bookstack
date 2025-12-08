# **Bookstack**

Bookstack is a centralised book stack from book acquisition to e-reader. It lets you self-host Booklore as a central library and Ephemera as a book acquisition solution, and includes a merged docker-compose setup and a KOReader plugin so you can request books directly from your device and get enhanced OPDS server metadata and usability.

This repository brings those pieces together:

* A docker-compose that runs Booklore and Ephemera together as a single deployment.  
* A KOReader plugin that:  
  * Lets KOReader browse and download books from your Booklore library.  
  * Lets KOReader request books from Ephemera directly from the device.  
  * Integrates with Hardcover.app for enhanced book discovery, series information, and ratings.

Thanks to the original projects:

* Booklore — https://github.com/avilapa/booklore  
* Ephemera — https://github.com/OrwellianEpilogue/ephemera  
* KOReader — https://github.com/koreader/koreader  
* Hardcover — https://hardcover.app

## **Table of contents**

* [Features](https://www.google.com/search?q=%23features)  
* [Requirements](https://www.google.com/search?q=%23requirements)  
* [Quick start](https://www.google.com/search?q=%23quick-start)  
* [Configuration (.env)](https://www.google.com/search?q=%23configuration-env)  
* [Install and run (docker-compose)](https://www.google.com/search?q=%23install-and-run-docker-compose)  
* [KOReader plugin install & configuration](https://www.google.com/search?q=%23koreader-plugin-install--configuration)  
* [Usage](https://www.google.com/search?q=%23usage)  
* [Series Information Handling](https://www.google.com/search?q=%23series-information-handling)  
* [Hardcover Integration](https://www.google.com/search?q=%23hardcover-integration)  
* [Optional: Project Title Patch](https://www.google.com/search?q=%23optional-project-title-patch)  
* [Troubleshooting](https://www.google.com/search?q=%23troubleshooting)  
* [Security and networking notes](https://www.google.com/search?q=%23security-and-networking-notes)  
* [Contributing & credits](https://www.google.com/search?q=%23contributing--credits)  
* [License](https://www.google.com/search?q=%23license)

## **Features**

* Single docker-compose bringing Booklore and Ephemera up together  
* KOReader plugin to browse and download books from your Booklore library  
* KOReader plugin to search/request books via Ephemera from your device  
* OPDS integration with enhanced metadata and usability when browsing on KOReader  
* Flexible series information extraction with multiple sources  
* Hardcover.app integration for:  
  * Enhanced book discovery with author search  
  * Accurate series information and ordering  
  * Book ratings and descriptions  
  * Library ownership tracking (see which books you already own)  
  * Direct integration with Ephemera for requesting books

## **Requirements**

* Docker & Docker Compose (v2 recommended)  
* A network-accessible host for the services (LAN or public IP / domain)  
* A KOReader-compatible device (e.g., supported e-ink reader with KOReader installed)  
* A .env file created from the template in this repository  
* (Optional) A Hardcover.app API token for enhanced features

## **Quick start**

1. Create a .env file using the template included in this repo:

   cp .env.template .env

Edit .env to set your host addresses, ports, credentials and any other required variables.

2. Copy the provided docker-compose.yml into your host environment (or use the one in this repo).  
3. Start the stack:

   docker compose up \-d

4. Once services are up, install the KOReader plugin on your device (instructions below).  
5. Restart KOReader and configure the plugin with your network-facing addresses for Booklore and Ephemera.

## **Configuration (.env)**

This repo includes a template file (.env.template) — use it to generate your .env.

Typical variables you should set:

* BOOKLORE\_HOST (or URL)  
* BOOKLORE\_PORT  
* EPHEMERA\_HOST (or URL)  
* EPHEMERA\_PORT  
* PUID / PGID (user/group IDs)  
* TZ (timezone)  
* Optional: any API keys or authentication variables required by the upstream projects

Use hostnames or IPs reachable from your KOReader device (for example the LAN IP of the host running Docker).

## **Install and run (docker-compose)**

1. Copy or open the docker-compose.yml in this repository.  
2. Ensure your .env is in the same folder as docker-compose.yml or referenced correctly.  
3. Start the services:

   docker compose up \-d

4. Watch logs to make sure everything starts cleanly:

   docker compose logs \-f

## **KOReader plugin — install & configure**

1. On your computer, locate the plugin folder in this repository (opdsbrowser.koplugin/).  
2. Copy that folder to the plugins folder on your KOReader device:  
   * e.g., mount the device storage and copy opdsbrowser.koplugin into /koreader/plugins/ (device paths vary by device).  
3. Restart KOReader.  
4. In KOReader:  
   * Navigate to the menu and find "Cloud Book Library"  
   * Go to "Plugin \- Settings"  
   * Enter the network-facing OPDS URL for your Booklore service (e.g., https://booklore.example.com/api/v1/opds)  
   * Enter OPDS username and password if configured  
   * Enter your Ephemera URL (e.g., http://example.com:8286)  
   * Enter your preferred download directory  
   * Configure series handling (see [Series Information Handling](https://www.google.com/search?q=%23series-information-handling))  
   * (Optional) For Hardcover integration, edit /koreader/settings/opdsbrowser.lua and add your Bearer Token  
5. Use the plugin UI on device to browse your library, search Hardcover, and request books via Ephemera.

### **Getting a Hardcover API Token**

1. Visit https://hardcover.app and create an account (if you don't have one)  
2. Go to your account settings  
3. Navigate to the API section  
4. Generate a new API token  
5. Copy the token and add "Bearer " prefix (e.g., "Bearer abc123xyz...")  
6. Edit /koreader/settings/opdsbrowser.lua and add:

   \["hardcover\_token"\] \= "Bearer YOUR\_TOKEN\_HERE",

## **Usage**

### **Hardcover Integration**

* **Search Author**: Find authors on Hardcover with "Known for" information  
  * View all books by an author, sorted by popularity  
  * See accurate series information and ordering  
  * Check if books are already in your library (marked with ✓)  
  * View detailed information including ratings, descriptions, and series data  
  * Request books directly through Ephemera integration

The Hardcover integration intelligently caches data to minimize API calls and provides fast, responsive browsing.

### **Ephemera Integration**

* **Request New Book**: Search Ephemera's sources and queue books for download  
* **View Download Queue**: Monitor active downloads, queued items, and completed books  
* From Hardcover book details, use "Search Ephemera" to find and request books

### **Book Downloads**

* Upon performing a library sync from the menu, all books in your booklore library have placeholders created on your device in the Home/Library folder  
* When a placeholder is opened, the book is downloaded from OPDS and replaces the placeholder  
* Metadata is refreshed automatically after download  
* File manager view updates to show newly downloaded books  
* KOReader automatically restarts after successful download to ensure UI shows the real book immediately  

## **Series Information Handling**

When importing books from OPDS, the plugin attempts to scrape series information using the following specific order of priority:

1. **OPDS Metadata Fields (Standard)** It searches the OPDS feed for \<meta property="belongs-to-collection" id="series"\> and \<meta property="group-position"\>.  
   *Note: Group positions are normalised (e.g., 1.0 becomes 1, while 1.5 remains 1.5).*  
2. **Publisher Field (Optional)** **Condition:** Only if the setting 'Use Publisher as Series' is set to **YES**.  
   It checks the \<dc:publisher\> field for data formatted like "SeriesName Number".  
3. **Description Tags** It checks the book description for series information enclosed in pipes, for example: |Reacher 3| or |SeriesName Number|.  
4. **Hardcover API (Fallback)** If no series information is found using the methods above, the plugin will attempt to fetch dynamic series data from Hardcover.app (requires API token).

### **Book Sorting**

Regardless of which method is used to find the series, books are always sorted intelligently:

1. **Series books first** \- Grouped by series name  
2. **Within each series** \- Ordered by book number (numerically)  
3. **Standalone books last** \- Sorted alphabetically by title

**Example Display:**

Jack Reacher Series:  
\- Killing Floor \- Reacher \#1 \- Lee Child  
\- Die Trying \- Reacher \#2 \- Lee Child  
\- Tripwire \- Reacher \#3 \- Lee Child

Standalone:  
\- The Affair \- Lee Child

## **Hardcover Integration**

The plugin includes deep integration with Hardcover.app for enhanced book discovery and metadata:

* **Author Search**: Search Hardcover's database of authors and see their most popular works  
* **Book Discovery**: Browse complete bibliographies with accurate series information  
* **Library Checking**: Automatically checks which books you already own in your Booklore library  
* **Series Information**: Can be used as primary or fallback source for series data (see [Series Information Handling](https://www.google.com/search?q=%23series-information-handling))  
* **Ratings & Reviews**: See community ratings and detailed descriptions  
* **Ephemera Integration**: Request missing books directly from Hardcover book details

All Hardcover data is intelligently cached for 5 minutes to minimize API calls while maintaining responsiveness.

## **Optional: Project Title Patch**

This repository includes an optional user patch located in patches/2-toolbar-replace-button.lua. This patch is designed for "Project: Title" \+ OPDS Browser users.

It replaces the default **Favourites (heart)** button on the top toolbar with a shortcut to this plugin:

* **Tap:** Open OPDS Browser Main Menu  
* **Hold:** Sync OPDS Library (build placeholders)

**To install:**

1. Copy patches/2-toolbar-replace-button.lua to your device.  
2. Place it in your KOReader user patches directory (typically /koreader/patches/).  
3. Restart KOReader.

## **Troubleshooting**

* If KOReader can't reach the services:  
  * Verify the device and the host are on the same network and can reach each other's IPs.  
  * Confirm ports are open and not blocked by a firewall.  
  * Test the service endpoints from another device (browser or curl).  
* Logs:

  docker compose logs \-f

Check logs for both booklore and ephemera containers for errors.

* If the plugin doesn't appear in KOReader:  
  * Ensure the plugin folder is in the correct plugins directory for your device and KOReader version.  
  * Check KOReader console/logs for plugin-related errors.  
* If Hardcover features aren't working:  
  * Verify your Bearer Token is correct and includes the "Bearer " prefix  
  * Check network connectivity to api.hardcover.app  
  * Review KOReader logs for Hardcover API errors  
  * Edit the settings file directly: /koreader/settings/opdsbrowser.lua  
* If series information isn't displaying correctly:  
  * Check your "Use Publisher as Series" setting in plugin settings  
  * Verify your OPDS feed includes the expected fields (publisher or summary)  
  * If using Hardcover mode, ensure your API token is configured  
  * Check KOReader logs for series extraction messages  
* If library ownership flags aren't showing:  
  * Ensure your Booklore OPDS URL is configured correctly  
  * Verify the OPDS search endpoint is working  
  * Check that author names match between Hardcover and your library  
* If book downloads fail:  
  * Check that the download directory exists and is writable  
  * Verify authentication credentials if your Booklore instance requires them  
  * Check KOReader logs for specific error messages  
* If KOReader restart after download doesn't work:  
  * Check logs for "RestartNavigation: No restart method available\!"  
  * Restart feature may not be available on your device/KOReader version  
  * Book will still open directly as fallback  
  * See [Restart Navigation Guide](https://www.google.com/search?q=RESTART_NAVIGATION.md) for details  

## **Security and networking notes**

* If exposing services to the internet, secure them appropriately:  
  * Use HTTPS (reverse proxy with TLS), strong passwords and/or API tokens.  
  * Consider using a VPN or tunneled connection if you need remote access but want to avoid public exposure.  
* Keep your host OS, Docker, and the upstream projects up to date.  
* Store your Hardcover API token securely and never share it publicly.  
* Consider enabling authentication on your Booklore instance if it will be network-accessible.

## **Contributing**

* Contributions, fixes, and improvements are welcome.  
* If you add integration improvements, tests, or documentation updates, please open a PR.  
* If you find issues with the KOReader plugin or with the docker-compose, open an issue describing the environment, steps to reproduce, and logs.

## **Credits and upstream projects**

This repo integrates and builds on:

* Booklore — https://github.com/avilapa/booklore  
* Ephemera — https://github.com/OrwellianEpilogue/ephemera  
* KOReader — https://github.com/koreader/koreader  
* Hardcover — https://hardcover.app

Thanks to the developers and maintainers of those projects for their work.

## **License**

This repository uses the same license as the included upstream components unless otherwise noted. Please review individual component licenses and this repo's LICENSE file (if present) before production use.
