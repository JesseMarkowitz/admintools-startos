# startos-admin

Interactive administrative menu for StartOS servers.

---

<details>
<summary><strong>Intended use</strong></summary>

This tool is intended for StartOS Administrators who:

- Want additional functionality not currently (June 2026) available in the graphical user interface
- Prefer menu-driven administration over manual CLI use
- Have SSH access to their server
- For StartOS SSH information see: https://docs.start9.com/start-os/0.4.0.x/user-manual/ssh.html

</details>

---

<details>
<summary><strong>Requirements</strong></summary>

- SSH access to your StartOS server as the Start9 user
- This was written for StartOS 040 (NOT 0351)
- sudo privileges (the Start9 user has these by default)
- `start-cli` available and authenticated (preinstalled on StartOS; most features use it)
- `jq`, `curl`, and `openssl` (all preinstalled on StartOS; the script checks at startup)
- bash 4.3 or newer (preinstalled on StartOS)
- Outbound internet access — only needed for update checks, stay-alive curls, and webhook forwarding; everything else works offline
  
</details>

---

<details>
<summary><strong>Security considerations</strong></summary>

**This tool may be run with elevated privileges (including `root`).** Treat it like any other privileged administrative code.

Key risks and cautions:

- **Root-level impact:** If you run this script as `root` (or via `sudo`), it can modify system state (e.g., write to `/usr/local/bin`, create/edit cron entries, create state files, make outbound HTTP requests). Mistakes or malicious changes could cause system damage or data loss.
- **Not formally vetted or approved:** This project has **not** been heavily security-audited, formally reviewed, or approved by Start9/StartOS. It may contain bugs or unsafe assumptions.
- **Backup password storage (S1 — mitigated):** When you schedule a backup, your StartOS primary password is stored in a root-only file (`/root/.startos-admin/backup-pass-<target>`, mode 600) that the cron job reads at backup time. It does **not** appear in the crontab. Residual exposure: the password is briefly visible in the process list (`ps`) while a backup is running, and the file remains if you later delete the backup cron entry (remove it manually with `sudo rm` if desired). Backups scheduled with versions ≤ 56 still have the password inline in the crontab — edit the schedule once to migrate it to the new format.
- **Update integrity verification (S2 — mitigated):** Updates and configuration-load downloads are verified against a signature (`startos-admin.sh.sig`) using a public key embedded in the script before anything is installed. A script that fails verification is never installed. Trust is anchored at first install (review the script you initially download); a compromised repository cannot push executable code without the private signing key, which is not stored in the repository.
- **Input validation:** Webhook/stay-alive URLs and keyword filters are restricted to conservative character sets, and notification titles/messages are shell-escaped, so user input cannot inject commands into the root crontab or generated forwarder scripts. `%` is rejected in values that end up in cron lines (cron treats it as a newline).
- **Outbound webhook/URL risk:** Features that `curl` a URL or POST to a webhook can leak metadata (timestamps, service names, notification text). Only use endpoints you trust, and prefer HTTPS.
- **Use at your own risk:** You are responsible for reviewing the code and deciding whether to run it in your environment.

**Recommended best practices:**

- Review the script content before running it.
- Test on a non-critical system first.

</details>

---

<details>
<summary><strong>Install</strong></summary>

SSH into your StartOS server and run:

<pre><code>curl -fsSL https://raw.githubusercontent.com/JesseMarkowitz/admintools-startos/refs/heads/main/startos-admin.sh -o startos-admin.sh && chmod +x startos-admin.sh && ./startos-admin.sh</code></pre>

This will download the script from github, set it to executable and run it the first time.
On first run:

- The script checks GitHub for a newer version.
- If a newer version exists, you will be prompted to install the newer version persistently. Downloaded updates are signature-verified against a public key embedded in the script before they are installed.
- Persistent installation places the script at: `/usr/local/bin/startos-admin`
- Also, if it was not run from the persistent installed location (such as on first run as part of curl command above) it will offer to install persistently.

After the persistent install, run:

<pre><code>startos-admin</code></pre>

from anywhere on the system.

</details>

---

<details>
<summary><strong>Command-line usage</strong></summary>

Besides the interactive menu, `startos-admin` can be used non-interactively:

```
startos-admin --version           Print version and exit
startos-admin --help              Usage summary
startos-admin --no-update-check   Skip the startup update check this launch
startos-admin --update            Check for a signed update (does NOT install)
startos-admin --update --yes      Install a verified update (SERVER RESTARTS)
startos-admin disk                Disk usage by service (plain text)
startos-admin memory              Memory usage by service (plain text)
startos-admin interfaces [svc]    Service interface URLs (tab-separated)
```

`--update` exit codes: `0` up to date · `10` update available (not installed) · `1` network failure · `3` signature verification failure. Updates installed with `--update --yes` are signature-verified first and include any staged changes in the same restart.

The data commands print plain/tab-separated output suitable for monitoring scripts, e.g. `startos-admin interfaces nextcloud | grep tor`.

</details>

---

<details>
<summary><strong>Persistence model</strong></summary>

By default, StartOS does not persist changes across reboots.  This lets users easily recover from almost all issues by rebooting the server and the base StartOS code will execute cleanly.   

There are times when it is helpful to have your changes persist across reboots.  This can be done by entering chroot edit mode.   (See documented example here: https://docs.start9.com/0.3.5.x/misc-guides/ssh-tor.html).  Changes made in this mode are preserved.  When you exit this mode your StartOS server will automatically reboot.

startos-admin has the capability built in to make changes persistent using the above approach. 

 
**What may be made persistent**

Main script (optional persistent install):
- Installed to: `/usr/local/bin/startos-admin`
- After installation, this can be executed by running: `startos-admin`

Cron jobs (created by scheduling actions):
- Backup schedules
- Stay-alive URL checks
- Notification forwarder poll schedules

Backup passwords (created by Schedule Backups):
- Stored root-only at `/root/.startos-admin/backup-pass-<target>` (mode 600, persistent via chroot)

Notification Forwarders
- Forwarding executables are installed in `/usr/local/bin/` (persistent via chroot)
- Each forwarder maintains a state file between cron runs within a boot session
- **State files are volatile**: they are lost on reboot. The forwarder silently catches up on the first post-boot run; notifications during downtime are not forwarded.
- Log files are similarly volatile and reset each boot.

**Mandatory reboots**
After making a change that will be persistent startos-admin will confirm you want to do this, then prompt again - reminding you that this will restart your StartOS server.

**Staged changes (one reboot for many changes)**
Instead of applying immediately, any change can be *staged*. Staged changes queue up (root-only file, not yet active) and are applied together with a single restart from the **Staged changes** menu. The queue survives exiting the script but is lost if the server reboots before you apply.

</details>

---

### Actions

The script presents an interactive menu with the following options, grouped into **Display**, **Create**, and **Manage**. Changes made by Create/Manage actions can be applied immediately (one restart each) or staged and applied together (see *Staged Changes*).


---

<details>
<summary><strong>1. Display Disk Used by Services</strong></summary>

Displays disk usage using shell command  'du' 

Displays:

- Total disk capacity
- Used space
- Available space
- Per-service disk usage breakdown

Use cases:

- Services consuming unexpected storage
- Backup growth over time
- Disk pressure before failures occur

</details>

---

<details>
<summary><strong>2. Display System Data</strong></summary>

Reads the full system database via `start-cli db dump` and presents it through several focused views.

Sub-options:

**1) Server Info** — hostname, StartOS version, architecture, platform, last backup time.

**2) Network** — addresses, Tor onion addresses, WiFi status, gateways (with LAN/WAN IPs), and DNS servers.

**3) Service Status** — desired state and health-check results for every installed service.

**4) Service Detail** — deep view of a single service: status, started time, last backup, registry, health checks, and dependencies.

**5) Service Interfaces** — displays all externally reachable URLs for one or more services. Select individual services (comma-separated) or all at once.

For each interface, shows:
- Interface type (`ui`, `api`, `p2p`)
- Interface name
- Network (e.g. Wired connection, tor, tunnel)
- Full URL with correct scheme and port

Filtering:
- Excludes loopback (`lo`) and internal bridge (`lxcbr0`) gateways
- Excludes link-local IPv6 (`fe80::`) addresses
- Wraps IPv6 addresses in brackets
- Prefers SSL when available; falls back to plain scheme or `tcp://`/`ssl://` for interfaces without an explicit scheme (e.g. peer, ZeroMQ)

Use cases:
- Quickly find the URL for any service interface
- Verify which addresses are reachable on each network
- Input for automated testing or monitoring

</details>

---

<details>
<summary><strong>3. Display Memory Used by Services</strong></summary>

Displays memory usage using start-cli package stats

Displays:

- Per-service memory usage
- Percentage of total memory consumed by each service

Use cases:

- Diagnosing performance issues
- Identifying memory-heavy services
- Capacity planning

</details>

---

<details>
<summary><strong>4. Create a StartOS Notification</strong></summary>

Creates a one-time notification using StartOS command line interface  `start-cli`.

This notification appears in the StartOS UI under the standard notification panel.

You may specify:
- Service name (optional)
- Priority level: `info`, `warning`, or `error`
- Title
- Message

Use cases:
- Manual status reporting
- Custom system alerts
- Testing notification forwarders

</details>

---

<details>
<summary><strong>5. Create a Backup Schedule</strong></summary>

Creates a cron entry that triggers StartOS backups on a defined schedule using StartOS command line interface  `start-cli` and cron.  This requires the backup target(s) be configured (and preferably tested) in advance.

Configuration options:

- Backup target
- Services (individual selection or all)
- Schedule (cron syntax)
- Post-backup actions:
  - Optional shell command — enter the full command, e.g.: `curl -d "Backup to CIFs-0 for Nextcloud and Vaultwarden started" https://ntfy.sh/StartOS-adjective-noun-Alerts`
  - Optional StartOS standard UI notification

Your StartOS primary password is saved to a root-only file (`/root/.startos-admin/backup-pass-<target>`, mode 600) that the cron job reads at backup time — it does not appear in the crontab.

> **Note:** StartOS already generates a notification when a backup completes. Combining a kickoff notification with the completion notification can help estimate time it takes for backups to complete

</details>

---

<details>
<summary><strong>6. Create a Stay-Alive Curl</strong></summary>

Creates a cron job that periodically uses curl to perform a HTTP request to a specified URL.


Configuration options:

- URL to send to
- Schedule (cron syntax)
 
Use cases:

- Monitoring services such as [healthchecks.io](https://healthchecks.io/)
- Dead-man switch alerting systems

If your server goes offline (hardware failure, ISP outage, power loss), it cannot self-report. An external service can detect missed check-ins and alert you.


</details>

---

<details>
<summary><strong>7. Manage Cron Jobs</strong></summary>

Displays entire crontab file including comments with all root level cron jobs configured on the system.  Gives option to delete one or more jobs as well as option to add a job.

Options:

- View / Delete existing cron entries
- Add new entry (allows specification of schedule, command and post command notifications)

Post command notifications can be StartOS notifications or any shell command (e.g., curl with parameters to NTFY or a webhook).

There are tools online to assist with interpreting the cron scheduling - such as: [crontab.guru](https://crontab.guru/).  

**Recommendation:** only keep jobs that are actively required.

Use cases:

- Schedule automated reminders
- Schedule other recurring activities

  NOTE: For scheduling backups and heartbeats specific actions are available, see above.

</details>

---

<details>
<summary><strong>8. Manage Notification Forwarders</strong></summary>

Creates persistent forwarders that forward StartOS notifications to external systems. Each forwarder periodically runs `start-cli notification list`, filters by level and/or keyword, and performs an HTTP request to forward matching entries.

Log files: `/usr/local/share/startos-admin/startos-notif-poller-<name>.log`
State files: `/usr/local/share/startos-admin/startos-admin-poller-state-<name>`

Multiple forwarders may be installed simultaneously (e.g., one for all warnings, one for backup-related errors only).

**Limitations**
- **State is volatile**: State and log files are stored in StartOS's runtime layer and are lost on each reboot. On first run after each reboot, the forwarder silently re-seeds its state from the current notification list.
- **Notifications during downtime are not forwarded**: If a notification occurs while the server is offline or rebooting, it will not be forwarded. Only notifications that arrive after the first post-boot cron run will be sent.


Options:
- Create / Update Forwarder
- List Forwarders
- Remove Forwarder
- View Forwarder Log

Configuration options when creating / updating a forwarder:

- Name of Forwarder
- URL to send to
- Notification Level Filter
- Notification Keyword Filter
- Schedule (cron syntax)

**Message format**

Forwarded messages are sent as plain text:

<pre><code>2026.02.25 10:15:00  [Warning]  btcpayserver  |  Backup Complete — Your backup completed, but some package(s) failed</code></pre>


</details>

---

<details>
<summary><strong>9. Staged Changes</strong></summary>

Every change this tool makes (cron jobs, backup schedules, forwarders) requires a server restart to become persistent. Staging lets you queue several changes and apply them all with **one** restart.

At the end of each change wizard you choose **Apply now** (restart immediately — any staged changes are included in the same restart) or **Stage for later** (add to the queue, no restart yet).

From this menu you can:

- View the queue (each entry shows what it does and when it was staged)
- Apply all staged changes — one restart activates everything
- Delete staged change(s) — safe, they were never applied

**Important:** staged changes are NOT active until applied. Views (cron list, forwarder list) show only what is currently active. The queue survives exiting the script, but is **lost if the server reboots** before you apply.

The queue is stored root-only at `/root/.startos-admin/staged-changes` (it can contain backup-password material).

</details>

---

<details>
<summary><strong>10. Save / Load Configuration</strong></summary>

Saves your installed cron jobs and notification forwarders as a single AES-256 encrypted configuration file, and can load them back after an OS upgrade or reflash.

**Save stores:**
- All root cron entries
- All notification forwarder scripts (including embedded webhook URLs and schedules)
- All scheduled-backup password files (root-only secrets, carried inside the encrypted file)

**Load reinstalls** everything in a single reboot: cron jobs, notification forwarder scripts, backup password files, and the `startos-admin` script itself (downloaded fresh from GitHub and **signature-verified** before install — if verification fails, the rest of the load proceeds but the script is not reinstalled).

**Encryption:** The configuration file is encrypted with AES-256-CBC (OpenSSL, PBKDF2 key derivation) and protected by an HMAC-SHA256 integrity check that detects tampering or corruption before any load begins. The passphrase you set when saving is required to load. There is no passphrase recovery option — a forgotten passphrase makes the file permanently unreadable. Files saved by versions ≤ 56 (no integrity check) can still be loaded; a warning is shown.

**Transfer workflow:**

After saving, the encrypted file is written to `/tmp/startos-config-backup.enc` and the full contents are printed to the terminal. An `scp` command is shown to pull the file off the server from your local machine:

```
scp start9@<server-ip>:/tmp/startos-config-backup.enc ./
```

Before loading, an `scp` command is shown to push the file back onto a freshly reflashed server:

```
scp ./startos-config-backup.enc start9@<server-ip>:/tmp/
```

**Post-reflash load workflow:**
1. SSH into the fresh server
2. Download `startos-admin.sh` (see Install section above)
3. Run it — when prompted to install persistently, you may decline; the Load step installs the latest version as part of the same reboot
4. Navigate to **10) Save / Load configuration → 2) Load configuration**
5. Follow the prompts; server restarts once with everything loaded

</details>

---

<details>
<summary><strong>11. Documentation</strong></summary>

Built-in documentation for every menu action, in the same order as the main menu, plus a troubleshooting guide.

</details>

---

<details>
<summary><strong>12. Debug Mode</strong></summary>

Toggles debug mode on or off.

When enabled, shows extra output during operations and enables verbose logging for notification pollers.

Debug state persists within a boot session via a flag file. It is reset on reboot.

</details>
