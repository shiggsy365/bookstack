# **📚 Bookstack**

**Bookstack** is a unified, e-reader-friendly web interface designed to bridge the gap between book discovery, library management, and device delivery. By combining the power of **Booklore** and **Shelfmark**, Bookstack allows you to manage your entire reading workflow—from requesting a new title to sending it to your Kindle—all from your e-reader's built-in browser.

## **✨ Key Features**

* **E-Reader Optimized:** A lightweight web interface specifically designed for the lower refresh rates and constraints of e-ink browsers.  
* **Universal Search:** Leveraging **Shelfmark's Universal Search**, queries are resolved against multiple metadata providers (like Google Books, OpenLibrary) to ensure high-quality results.
* **Release Selection:** View and select specific releases from your configured Prowlarr indexers. Choose the exact file, format, and size you want.
* **One-Click "Send to Kindle":** Configure your Kindle delivery address once and trigger wireless transfers directly from your library.  
* **Request Monitoring:** Track the real-time status of your Shelfmark requests, complete with detailed error messages if downloads fail.
* **Booklore Library Browser:** A clean, searchable view of your existing Booklore collection.

## **🚀 How It Works**

Bookstack acts as the "connective tissue" for your self-hosted book stack:

1. **Search:** Use the integrated search to find a title. Metadata is fetched instantly.
2. **Select:** Click "View Releases" to see available files from Prowlarr/Indexers. Select the best release for you.
3. **Track:** Monitor the download status on your dashboard queue.
4. **Deliver:** Once the book is added to your **Booklore** library, click the "Send to Kindle" button to deliver it wirelessly.

## **⚡ Quick Start**

The fastest way to get Bookstack running alongside your existing services is via Docker. Ensure you have **Booklore** and **Shelfmark** running.

### Environment Variables

| Variable | Description |
| :--- | :--- |
| `SHELFMARK_URL` | URL to your Shelfmark instance (e.g., `http://shelfmark:8084`) |
| `BOOKLORE_URL` | URL to your Booklore instance |
| `BOOKLORE_USER` | Basic Auth User for Booklore |
| `BOOKLORE_PASS` | Basic Auth Password for Booklore |
| `SMTP_SERVER` | SMTP Server for Kindle email delivery |
| `SMTP_USER` | SMTP Username/Email |
| `SMTP_PASS` | SMTP Password |

## **🛠️ Configuration**

To ensure successful delivery to your Kindle:

1. Log in to your Amazon account.  
2. Navigate to **Manage Your Content and Devices** \> **Preferences**.  
3. Scroll down to **Approved Personal Document E-mail List**.  
4. Add the `SMTP_USER` email address you configured above to the list of approved senders.

## **🤝 Contributing**

Contributions, issues, and feature requests are welcome! Feel free to check the [issues page](https://github.com/shiggsy365/bookstack/issues).

[<img src="https://github.com/shiggsy365/AIOStreamsKODI/blob/main/.github/support_me_on_kofi_red.png?raw=true">](https://ko-fi.com/shiggsy365)

## **📜 License**

Distributed under the MIT License. See LICENSE for more information.

**Version Note:** This documentation is maintained for version 2.0 (Feb 2026), featuring Shelfmark Universal Search.
