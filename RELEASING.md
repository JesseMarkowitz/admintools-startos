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
- Public key: embedded in `startos-admin.sh` as `_UPDATE_PUBKEY`.

If the key is ever lost, generate a new pair and update `_UPDATE_PUBKEY`:

```bash
openssl ecparam -genkey -name prime256v1 -noout -out release-signing-key.pem
openssl ec -in release-signing-key.pem -pubout
```

Note: copies installed before a key rotation will refuse updates signed with
the new key. Users must reinstall once via the curl command in the README.

## Release steps

1. Make and test your changes.
2. Bump `VERSION=` in `startos-admin.sh` (integer, +1).
3. Update `README.md` if anything user-visible changed.
4. Sign the final script (re-run this after **any** further edit, or the
   release will fail verification):

   ```bash
   openssl dgst -sha256 -sign release-signing-key.pem startos-admin.sh | base64 -w 0 > startos-admin.sh.sig
   ```

5. Verify locally:

   ```bash
   openssl ec -in release-signing-key.pem -pubout -out /tmp/pub.pem 2>/dev/null
   base64 -d startos-admin.sh.sig > /tmp/sig.bin
   openssl dgst -sha256 -verify /tmp/pub.pem -signature /tmp/sig.bin startos-admin.sh
   ```

6. Commit `startos-admin.sh` and `startos-admin.sh.sig` together, push to
   `main`. Installed copies pick the release up at next launch.
