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

## Features

- Create StartOS notifications
- Display disk usage by service
- Display memory usage by service
- View and manage cron jobs
- Schedule automated backups
- Schedule stay-alive curl jobs
- Manage notification forwarders (webhook)
- Auto-update from GitHub
