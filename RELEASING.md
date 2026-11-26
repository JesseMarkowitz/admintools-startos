# Releasing a new version

Every release of `startos-admin.sh` must be signed. Installed copies check
the signature against a public key embedded in the script before they
install an update, and refuse an unsigned or mis-signed release.

## Signing keys

From v74 on, releases are signed with the **production signing key**, a GPG
key. During the change of keys, two releases also carry a signature from the
old key:

| Releases | `startos-admin.sh.asc` (production key) | `startos-admin.sh.sig` (old P-256 key) |
| --- | --- | --- |
| v73 and older | — | yes |
| v74, v75 | yes | yes |
| v76 and newer | yes | — (delete the file) |

Copies of v73 and older trust only the old key, and v74 and newer trust only
the production key. The two dual-signed releases let a v73 copy update.
A copy still on v73 when v76 ships will report a signature failure and has
to be reinstalled once with the curl command in the README.

- **Production signing key:** GPG `84FF9BB7F3E85F913CCF438E1A64936712ACCC07`,
  Ed25519, "Jesse Markowitz (release signing) <startos@markowitz.me>". It
  lives in vulcan's GnuPG with a passphrase, and its backup and revocation
  certificate are in the vault. Its public half is embedded in the script
  as `_UPDATE_GPG_KEY` and `_UPDATE_GPG_FPR`.
- **Old key (retiring after v75):** `release-signing-key.pem`, EC P-256,
  encrypted with a passphrase. It is listed in `.gitignore`: never commit
  it. Its public half is in `.github/workflows/ci.yml`. After v75 ships,
  delete that CI step and the `.sig` file.

Anyone holding the production key can publish updates that installed copies
will accept. Keep it off the servers.

If the production key is ever lost or compromised, revoke it, make a new one
(`gpg --quick-gen-key "<uid>" ed25519 sign never`), put its fingerprint and
`gpg --armor --export --export-options export-minimal <fpr>` into the
script, and sign that release with **both** keys, so copies with the old
embedded key can still update to it.

## Release steps

1. Make and test your changes.
2. Bump `VERSION=` in `startos-admin.sh` (integer, +1).
3. Update `README.md` (and `BACKUP-GUIDE.md`, if backups are affected) if
   anything user-visible changed. On every release, also re-check the
   README's dated statements against the current StartOS release and update
   them: the "as of <month year>" note under *Intended use* (is each feature
   still missing from the StartOS web interface?), the supported/tested
   StartOS version under *Requirements*, and the docs.start9.com links.
4. Sign the final script. Re-run this step after **any** further edit, or
   the release will fail verification. Each command asks for its key's
   passphrase:

   ```bash
   gpg --armor --detach-sign --local-user 84FF9BB7F3E85F913CCF438E1A64936712ACCC07 \
     --output startos-admin.sh.asc startos-admin.sh
   # v74 and v75 only: the old key too
   openssl dgst -sha256 -sign release-signing-key.pem startos-admin.sh | base64 -w 0 > startos-admin.sh.sig
   ```

5. Verify locally. These are the checks installed copies and CI make, and
   they need no passphrase:

   ```bash
   awk '/^_UPDATE_GPG_KEY="/,/^-----END PGP PUBLIC KEY BLOCK-----"$/' startos-admin.sh \
     | sed 's/^_UPDATE_GPG_KEY="//; s/"$//' | gpg --dearmor > /tmp/release-key.gpg
   gpgv --status-fd 1 --keyring /tmp/release-key.gpg \
     startos-admin.sh.asc startos-admin.sh | grep VALIDSIG
   # v74 and v75 only
   sed -n '/^          -----BEGIN PUBLIC KEY-----$/,/^          -----END PUBLIC KEY-----$/p' \
     .github/workflows/ci.yml | sed 's/^ *//' > /tmp/old-pub.pem
   base64 -d startos-admin.sh.sig > /tmp/sig.bin
   openssl dgst -sha256 -verify /tmp/old-pub.pem -signature /tmp/sig.bin startos-admin.sh
   ```

   The first should print a `VALIDSIG` line ending in
   `84FF9BB7F3E85F913CCF438E1A64936712ACCC07`, the second `Verified OK`.

6. Commit `startos-admin.sh` with its signature files, push to `main`.
   Installed copies pick the release up at next launch.

## CI safety net

Every push runs `.github/workflows/ci.yml`, which verifies
`startos-admin.sh.asc` against the GPG key embedded in the script and,
through v75, `startos-admin.sh.sig` against the old key (plus a shellcheck
gate). If you change the script and forget step 4, the `release-signature`
job goes red: fix it by re-signing and pushing the new signature files.
Installed copies refuse unsigned releases, so never leave that job red.
