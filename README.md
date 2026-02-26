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
- **Supply-chain / update risk:** The script can check for updates and may offer to install a newer version. Any workflow that fetches and executes code from the internet increases supply-chain risk.
- **Outbound webhook/URL risk:** Features that `curl` a URL or POST to a webhook can leak metadata (timestamps, service names, notification text). Only use endpoints you trust, and prefer HTTPS.
- **Cleartext in cron risk:** Actions in cron are stored in cleartext.  Scheduling backups requires the password specified in cleartext. You are responsible for evaluating that risk and determining if it is acceptable to you.
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
- Forwarding executables are installed in `/usr/local/bin/`
- Each executable is intended to be independently runnable and scheduled.
- Each forwarder maintains a state file so it only forwards notifications it hasn't already seen.
- Location and naming are determined by the script's implementation; treat these as part of the persistent footprint.

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

Post command notifications can be StartOS notifications or using curl to go to a web page.

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
  - Optional HTTP request (e.g., NTFY, webhook) - might look like: curl -d "Backup to CIFs-0 for Nextcloud and Vaultwarden started" https://ntfy.sh/StartOS-adjective-noun-Alerts
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

Creates persistent pollers that forward StartOS notifications to external systems.  Each poller periodically runs `start-cli notification list`, filters the notifications by level and/or keyword and performs a HTTP request to a specified URL to forward matching entries.  

Each poller saves log files at: /var/log/startos-notif-poller-<name>.log (i.e. if your poller is named backups, the log is at /var/log/startos-notif-poller-backups.log).  They also maintain a state file to prevent duplicate forwarding 

Multiple pollers may be installed simultaneously (e.g., one for all warnings, one for backup-related errors only).


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