# Releasing a new version

Every release of `startos-admin.sh` must be signed. Installed copies verify
`startos-admin.sh.sig` against the public key embedded in the script
(`_UPDATE_PUBKEY`) before installing an update — an unsigned or mis-signed
release will be refused by every installed copy.

## Signing key

- Private key: `release-signing-key.pem` (EC P-256). **Never commit it** — it
  is listed in `.gitignore`. Keep it off the server; back it up somewhere safe
  (e.g., your password manager). Anyone holding this key can publish updates
  that installed copies will accept.
- The private key file is encrypted with a passphrase (AES-256), so `openssl`
  asks for it every time you sign. Keep the passphrase with the key's backup.
  Never store the key unencrypted on disk: that would let any program running
  as you sign a release without you.
- Public key: embedded in `startos-admin.sh` as `_UPDATE_PUBKEY`.

If the key is ever lost, generate a new pair, encrypted from the start, and
update `_UPDATE_PUBKEY` with the public key the second command prints:

```bash
openssl ecparam -genkey -name prime256v1 -noout | openssl ec -aes256 -out release-signing-key.pem
openssl ec -in release-signing-key.pem -pubout
```

To add a passphrase to an existing unencrypted key, run
`openssl ec -in release-signing-key.pem -aes256 -out release-signing-key.enc.pem`,
check that `openssl ec -in release-signing-key.enc.pem -pubout` prints the
same public key, then move the encrypted file over the original.

Note: copies installed before a key rotation will refuse updates signed with
the new key. Users must reinstall once via the curl command in the README.

## Release steps

1. Make and test your changes.
2. Bump `VERSION=` in `startos-admin.sh` (integer, +1).
3. Update `README.md` (and `BACKUP-GUIDE.md`, if backups are affected) if
   anything user-visible changed. On every release, also re-check the
   README's dated statements against the current StartOS release and update
   them: the "as of <month year>" note under *Intended use* (is each feature
   still missing from the StartOS web interface?), the supported/tested
   StartOS version under *Requirements*, and the docs.start9.com links.
4. Sign the final script (re-run this after **any** further edit, or the
   release will fail verification). It asks for the key's passphrase:

   ```bash
   openssl dgst -sha256 -sign release-signing-key.pem startos-admin.sh | base64 -w 0 > startos-admin.sh.sig
   ```

5. Verify locally, against the public key embedded in the script (the one
   installed copies trust, and the same check CI runs; no passphrase needed):

   ```bash
   awk '/^_UPDATE_PUBKEY="/,/^-----END PUBLIC KEY-----"$/' startos-admin.sh \
     | sed 's/^_UPDATE_PUBKEY="//; s/"$//' > /tmp/pub.pem
   base64 -d startos-admin.sh.sig > /tmp/sig.bin
   openssl dgst -sha256 -verify /tmp/pub.pem -signature /tmp/sig.bin startos-admin.sh
   ```

6. Commit `startos-admin.sh` and `startos-admin.sh.sig` together, push to
   `main`. Installed copies pick the release up at next launch.

## CI safety net

Every push runs `.github/workflows/ci.yml`, which verifies
`startos-admin.sh.sig` against the public key embedded in the script (plus a
shellcheck gate). If you change the script and forget step 4, the
`release-signature` job goes red — fix it by re-signing and pushing the new
`.sig`. Installed copies refuse unsigned releases, so never leave that job red.
