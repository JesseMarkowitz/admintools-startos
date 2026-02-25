# startos-admin

Interactive admin menu for StartOS servers.

## Install

SSH into your StartOS server and run:

```bash
curl -fsSL https://raw.githubusercontent.com/JesseMarkowitz/admintools-startos/refs/heads/main/startos-admin.sh -o startos-admin.sh && chmod +x startos-admin.sh && ./startos-admin.sh
```

On first run, the script will check for updates. If a newer version is available, it will offer to install itself persistently to `/usr/local/bin/startos-admin`. After that, simply run:

```bash
startos-admin
```

---

## Actions

### 1. Create a StartOS Notification

Allows you to create a one-time notification with whatever information you would like to provide. The notification will show up just like any other notification in the notification section of the StartOS user interface.

You can specify:

- **What service it comes from** — or leave blank
- **The message priority** — info, warning, or error
- **Message title**
- **Message body**

---

### 2. Display Disk Used by Services

Shows the total, used, and available disk space on your server, followed by a breakdown of how much disk space is used by each of the different services installed on your StartOS server.

---

### 3. Display Memory Used by Services

Shows the current memory usage, as well as the percentage of total memory used by each of your services.

---

### 4. Display Current Cron Jobs

Shows all the cron jobs currently scheduled on your server. You can use [https://crontab.guru/](https://crontab.guru/) to translate the numbers into natural language of when the job will run. It also gives you the option to delete any of these jobs if they are no longer needed.

> You should only keep jobs you are actively using.

---

### 5. Schedule Backups

Adds a cron entry that will automatically kick off backups on a schedule you define.

You can specify:

- **Backup target** — where to send the backup. You must have already created the target in the StartOS UI and manually tested it first.
- **Services to back up** — select specific services or all of them.
- **Schedule** — how frequently and at what time backups run, using cron syntax. Use [https://crontab.guru/](https://crontab.guru/) to verify your expression.
- **Post-backup notification** — optionally browse to a URL (useful for services like NTFY) and/or create a StartOS notification. Since StartOS already notifies you when a backup completes, combining this with the kick-off notification gives you elapsed time for each backup run.

---

### 6. Schedule Stay-Alive Curl

Causes your StartOS server to browse to a URL on a regular schedule — for example, a monitoring service like [https://healthchecks.io/](https://healthchecks.io/).

That service can be configured to alert you if it stops receiving the request within a defined time window. Hence the name: **Stay Alive**.

**Why this matters:** If your StartOS server goes offline — whether because your internet connection fails or the server itself fails — nothing on your server can notify you that it has failed. You need an external service to detect the silence and send that alert.

---

### 7. Manage Notification Forwarders

Sets up a persistent background poller that periodically checks `start-cli notification list`, filters notifications by level and/or keyword, and forwards matching ones via HTTP POST to a webhook URL of your choosing.

Each forwarder (poller) runs on its own cron schedule and sends messages in a plain-text format:

```
2026.02.25 10:15:00  [Warning]  btcpayserver  |  Backup Complete — Your backup completed, but some package(s) failed
```

You can install multiple pollers with different filters — for example, one for all warnings and another for errors only.

**You can specify:**

- **Poller name** — a unique identifier (e.g. `backup-errors`, `all-warnings`)
- **Webhook URL** — where to POST notifications
- **Level filter** — all levels, warning and above, error only, or a custom selection
- **Keyword filter** — optional, matched case-insensitively against the title and message
- **Check frequency** — every 5, 15, or 30 minutes, hourly, or a custom cron expression

Pollers are installed persistently to `/usr/local/bin/` and survive server reboots. Each poller maintains its own state file so it only forwards new notifications it hasn't seen before.
