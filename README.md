# startos-admin

Interactive administrative menu for StartOS servers.

---

<details>
<summary><strong>Intended use</strong></summary>

This tool is intended for StartOS Administrators who:

- Want additional functionality not currently (February 2026) available in the graphical user interface
- Prefer menu-driven administration over manual CLI use
- Have SSH access to their server
- For StartOS SSH information see: https://docs.start9.com/start-os/0.4.0.x/user-manual/ssh.html

</details>

---

<details>
<summary><strong>Requirements</strong></summary>

- SSH access to your StartOS server as the Start9 user
- This was written for StartOS 040 (NOT 0351)
  
</details>

---

<details>
<summary><strong>Security considerations</strong></summary>

**This tool may be run with elevated privileges (including `root`).** Treat it like any other privileged administrative code.

Key risks and cautions:

- **Root-level impact:** If you run this script as `root` (or via `sudo`), it can modify system state (e.g., write to `/usr/local/bin`, create/edit cron entries, create state files, make outbound HTTP requests). Mistakes or malicious changes could cause system damage or data loss.
- **Not formally vetted or approved:** This project has **not** been heavily security-audited, formally reviewed, or approved by Start9/StartOS. It may contain bugs or unsafe assumptions.
- **Backup password stored in plaintext cron entry (S1):** When you schedule a backup, your StartOS primary password is written into the root crontab in plaintext as part of the `start-cli backup create` command. This means it is visible to anyone who can run `sudo crontab -l`, and it may appear in system logs. Evaluate whether this is acceptable in your threat model before scheduling backups. You can remove a backup cron entry at any time from the Manage Cron Jobs menu.
- **Auto-update has no integrity verification (S2):** When the script checks for and installs updates, it fetches the new version from GitHub over HTTPS. No checksum, GPG signature, or other integrity mechanism is applied to verify the downloaded content. While HTTPS prevents most network-level attacks, a compromised GitHub account or repository could serve malicious code. Always review the script after an update, or disable auto-update by declining the prompt at startup.
- **Supply-chain / update risk:** Any workflow that fetches and executes code from the internet increases supply-chain risk. See the auto-update note above.
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
- If a newer version exists, you will be prompted to install the newer version persistently.
- Persistent installation places the script at: `/usr/local/bin/startos-admin`
- Also, if it was not run from the persistent installed location (such as on first run as part of curl command above) it will offer to install persistently.

After the persistent install, run:

<pre><code>startos-admin</code></pre>

from anywhere on the system.

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

Notification Forwarders
- Forwarding executables are installed in `/usr/local/bin/` (persistent via chroot)
- Each forwarder maintains a state file between cron runs within a boot session
- **State files are volatile**: they are lost on reboot. The forwarder silently catches up on the first post-boot run; notifications during downtime are not forwarded.
- Log files are similarly volatile and reset each boot.

**Mandatory reboots**
After making a change that will be persistent startos-admin will confirm you want to do this, then prompt again - reminding you that this will restart your StartOS server.

</details>

---

### Actions

The script presents an interactive menu with the following options.


---

<details>
<summary><strong>1. Create a StartOS Notification</strong></summary>

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
<summary><strong>2. Display Disk Usage by Services</strong></summary>

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
<summary><strong>3. Display Memory Usage by Services</strong></summary>

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
<summary><strong>4. Manage Cron Jobs</strong></summary>

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

  NOTE: For scheduling backups and heartbeats specific actions are available, see below: 

</details>

---

<details>
<summary><strong>5. Schedule Backups</strong></summary>

Creates a cron entry that triggers StartOS backups on a defined schedule using StartOS command line interface  `start-cli` and cron.  This requires the backup target(s) be configured (and preferably tested) in advance.

Configuration options:

- Backup target
- Services (individual selection or all)
- Schedule (cron syntax)
- Post-backup actions:
  - Optional shell command — enter the full command, e.g.: `curl -d "Backup to CIFs-0 for Nextcloud and Vaultwarden started" https://ntfy.sh/StartOS-adjective-noun-Alerts`
  - Optional StartOS standard UI notification

> **Note:** StartOS already generates a notification when a backup completes. Combining a kickoff notification with the completion notification can help estimate time it takes for backups to complete

</details>

---

<details>
<summary><strong>6. Schedule Stay-Alive Curl</strong></summary>

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
<summary><strong>7. Manage Notification Pollers </strong></summary>

Creates persistent pollers that forward StartOS notifications to external systems. Each poller periodically runs `start-cli notification list`, filters by level and/or keyword, and performs an HTTP request to forward matching entries.

Log files: `/usr/local/share/startos-admin/startos-notif-poller-<name>.log`
State files: `/usr/local/share/startos-admin/startos-admin-poller-state-<name>`

Multiple pollers may be installed simultaneously (e.g., one for all warnings, one for backup-related errors only).

**Limitations**
- **State is volatile**: State and log files are stored in StartOS's runtime layer and are lost on each reboot. On first run after each reboot, the forwarder silently re-seeds its state from the current notification list.
- **Notifications during downtime are not forwarded**: If a notification occurs while the server is offline or rebooting, it will not be forwarded. Only notifications that arrive after the first post-boot cron run will be sent.


Options:
- Create / Update Poller
- List Pollers
- Remove Poller
- View Poller Log

Configuration options when creating / updating a new poller:

- Name of Poller
- Name of URL to send to
- Notification Level Filter
- Notification Keyword Filter
- Schedule (cron syntax)

**Message format**

Forwarded messages are sent as plain text:

<pre><code>2026.02.25 10:15:00  [Warning]  btcpayserver  |  Backup Complete — Your backup completed, but some package(s) failed</code></pre>


</details>

---

<details>
<summary><strong>8. System Database</strong></summary>

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
<summary><strong>9. Backup / Restore Configuration</strong></summary>

Exports your installed cron jobs and notification forwarders as a single AES-256 encrypted backup file, and can restore them after an OS upgrade or reflash.

**Export saves:**
- All root cron entries
- All notification forwarder scripts (including embedded webhook URLs and schedules)

**Restore reinstalls** everything in a single reboot — including the `startos-admin` script itself at `/usr/local/bin/startos-admin`. This means after a reflash you need only one reboot to recover the full configuration.

**Encryption:** The backup is encrypted with AES-256-CBC (OpenSSL, PBKDF2 key derivation). The passphrase you set at export time is required to restore. There is no passphrase recovery option — a forgotten passphrase makes the backup permanently unreadable.

**Transfer workflow:**

After export, the encrypted file is saved to `/tmp/startos-config-backup.enc` and the full contents are printed to the terminal. An `scp` command is shown to pull the file off the server from your local machine:

```
scp root@<server-ip>:/tmp/startos-config-backup.enc ./
```

Before restore, an `scp` command is shown to push the file back onto a freshly reflashed server:

```
scp ./startos-config-backup.enc root@<server-ip>:/tmp/
```

**Post-reflash restore workflow:**
1. SSH into the fresh server
2. Download `startos-admin.sh` (see Install section above)
3. Run it — when prompted to install persistently, you may decline; the Restore step handles it
4. Navigate to **10) Backup / Restore configuration → 2) Restore**
5. Follow the prompts; server restarts once with everything restored

</details>

---

<details>
<summary><strong>10. Debug Mode</strong></summary>

Toggles debug mode on or off.

When enabled, shows extra output during operations and enables verbose logging for notification pollers.

Debug state persists within a boot session via a flag file. It is reset on reboot.

</details>