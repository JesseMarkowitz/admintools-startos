# Automating StartOS Backups

This guide uses **StartOS Admin Tools** ([README](README.md)) to run StartOS
backups on a schedule.
It does not replace a tested backup target or a recovery plan. Complete the
manual backup test before adding automation.

> [!IMPORTANT]
> A backup is only useful if it can be decrypted and restored. Keep the
> StartOS password that encrypted each backup. Changing your StartOS password
> does not re-encrypt existing backups.

## Before you begin

- Run StartOS 0.4.0 or newer and have SSH access as the `start9` user.
- Have a backup target configured in StartOS: a supported physical drive or a
  network folder on your LAN.
- Know the StartOS primary password that will encrypt the backup.
- Plan for the interruption: StartOS stops each service it backs up, performs
  the backup, then restarts it only if it was running beforehand. A service
  that was stopped remains stopped.

> [!NOTE]
> **StartOS 0.4.1 and newer: backup format conversion.** When you create a
> backup in the web interface, StartOS 0.4.1+ offers to convert an existing
> backup on that target to a newer format. Conversion runs in the background
> and can take a long time; a scheduled backup to that target fails while it
> runs, so let it finish before the next scheduled run (or skip conversion).
> After conversion, StartOS versions older than 0.4.1 can no longer read that
> target, so don't convert a target you may need to restore onto an older
> StartOS. Conversion is started only from the web interface, never by a
> scheduled backup.

For valuable data, especially Lightning data, maintain current backups on more
than one target. A new backup replaces the prior backup on the *same* target;
use additional targets when you need independent recovery points.

## 1. Create and test a backup target

In the StartOS web interface, open **System → Backups** (StartOS 0.4.3 and
newer; **System → Create Backup** on earlier versions). Add a physical drive,
network-folder or (0.4.3+) local-folder target, select it, and create a manual
backup before you automate anything. On StartOS 0.4.3 and newer, a drive must
be added here before the tool can schedule backups to it; a drive that already
holds backups keeps them.

Confirm all of the following:

1. The backup completes and its report has no unexpected failures.
1. The target has enough free space for the services selected.
1. You recorded the password used to encrypt this backup in a secure password
   manager.
1. You understand which service data is excluded by the service itself (for
   example, Bitcoin normally excludes its blockchain because it can re-sync).

StartOS writes current-format backups to `StartOSBackupsV2`. If the target has
an old `StartOSBackups` (V1) backup for this server, read the warning in the UI
before using **Delete old backup**. Do not delete the old backup until a
current-format backup is known to exist on that target.

## 2. Install StartOS Admin Tools

SSH to the server as the `start9` user. Review the script first, then download
and run it:

```bash
curl -fsSL https://raw.githubusercontent.com/JesseMarkowitz/admintools-startos/refs/heads/main/startos-admin.sh -o startos-admin.sh
chmod +x startos-admin.sh
./startos-admin.sh
```

On its first run, the tool offers a persistent install. Accept it if you want
to run `startos-admin` from anywhere later. The tool verifies signatures for
downloaded updates; nevertheless, treat it as privileged administrative code
and only run a version you trust.

## 3. Add a backup schedule

From the main menu, choose **5) Backup schedule**, then **1) Add a new backup
schedule**. The wizard asks for:

1. **Backup target** — select the target you tested in StartOS. Each is
   listed with its name, kind and free space. On StartOS 0.4.3 and newer, a
   drive has the permanent id StartOS gave it in System → Backups. On earlier
   versions a physical drive is saved by its filesystem UUID (`uuid-<UUID>`),
   not its device name (`disk-/dev/sdb1`), because device names change when
   drives are re-plugged or the server reboots; the schedule finds the drive by
   UUID at backup time, and fails rather than writing to a different disk if it
   is not connected. After updating to 0.4.3, add such a drive in System →
   Backups; startos-admin then offers at launch to switch its schedules to the
   drive's new id.
1. **StartOS primary password** — enter it at the hidden prompt. This is the
   password that encrypts the backup.
1. **Services** — choose individual services or `all`.
1. **Schedule** — choose daily at 00:00, daily at 03:00, weekly on Sunday at
   00:00, or enter a five-field cron expression. Use a time when service
   downtime will be acceptable. **All times are the server's clock, which on
   StartOS is UTC** — not your local time. For midnight in New York, enter
   `0 4 * * *` in summer (EDT) or `0 5 * * *` in winter (EST); cron does not
   follow daylight saving for you. The wizard shows the server's current time
   to convert from.
1. **Post-backup action** — optional. A kickoff notification or trusted
   webhook can make it easier to notice a backup that takes unusually long.
   StartOS 0.4.2 and older post a completion notification themselves; StartOS
   0.4.3 and newer do not (see step 4).

Review the summary carefully, then choose one of the following:

- **Apply now** to make the schedule persistent immediately. StartOS will
  restart and your SSH connection will close.
- **Stage for later** to queue this change with other administrative changes.
  Apply it from **9) Staged changes** before the next reboot. Staged changes
  are not active and are lost if the server reboots before they are applied.

The tool enters StartOS persistence mode for you. Do **not** separately run
`chroot-and-upgrade` or edit the root crontab for a schedule created by the
tool.

## Password handling

The scheduler stores the password in
`/root/.startos-admin/backup-pass-<target>` with mode `600`; the crontab reads
it when the backup runs. The password is not written into the crontab or its
listing. It **is** carried inside the tool's encrypted configuration file
(**11) Save / Load configuration**), so a restored server keeps its schedules
working; keep that file and its passphrase as safe as the password itself.

The password is still briefly present in the process list while `start-cli`
is running the backup. This is a limitation of the current StartOS CLI syntax,
which requires the password as an argument. Give only trusted administrators
SSH and root access.

If you change the StartOS primary password, edit the schedule in **5) Backup
schedule → 2) Edit an existing backup schedule** and enter the new password.
Keep the old password safely stored for restoring backups that it encrypted.

## 4. Verify the scheduled backup

After the scheduled time:

1. Review the backup's report: on StartOS 0.4.3 and newer in **System →
   Backups → History**, on earlier versions in the notification panel. Resolve
   any service failures rather than assuming a partial backup is sufficient.
1. Check that the target has the expected current backup.
1. In Admin Tools, use **5) Backup schedule → 2) Edit an existing backup
   schedule** to review or change its target, services, schedule, password, or
   post-backup action.
1. On StartOS 0.4.3 and newer, add **10) Alerts → 1) Add an alert → Backup
   succeeded alert** and **Backup failed alert**. StartOS 0.4.3 no longer
   notifies you when a backup finishes; these send one notification per
   backup, with the errors when one fails.
1. Optionally configure **10) Alerts → 1) Add an alert → Backup staleness
   alert**. It alerts when a service has not been backed up within your
   threshold, and can also watch one target. It also catches a backup that
   hangs and never finishes, which the succeeded/failed alerts cannot see.

Use **7) Cron jobs** only to view or remove a schedule when necessary.
When you remove a schedule, or move it to another target, its password file is
deleted the next time the tool applies a change, once no cron entry (active or
commented out) refers to it. Versions before v73 left these files behind; v73
removes them the first time it applies a change.

## Recovering from a backup

For an accidentally uninstalled service, use **System → Backups** (StartOS
0.4.3 and newer) or **System → Restore from Backup** (earlier versions) in StartOS, select the backup target, enter the password that encrypted the
backup, select the service, and restore it.

For a lost or corrupted StartOS data drive, use the StartOS initial-setup
recovery flow to restore the server. Test recovery procedures on non-critical
data when possible; a successful scheduled job alone is not a restore test.

