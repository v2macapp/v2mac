# Signing keys: rotation and recovery

Two Ed25519 keys decide what a V2Mac installs. Each copy of the app or helper pins exactly one
public key, compiled in. There is no second key and no revocation list, so the order below matters.

| Key | Private half | Public half pinned in | Signs |
|---|---|---|---|
| Update key | GitHub secret `UPDATE_SIGNING_KEY` (app and sandbox repos), plus the maintainer's offline backup | `AppInstaller.updateKey` (`Packages/V2MacCore/…/Updater/AppInstaller.swift`) | App updates (`files.json`), sandbox `pin.json` |
| Store key | Maintainer's login Keychain, item `v2mac-store`, plus a paper backup | `Store.publicKey` (`../sandbox/Sources/SandboxHelper/Store.swift`) and `../store/key.pub` | The plugin index `index.json` |

## Planned rotation (old key still safe)

The old key must sign the release that teaches copies the new key. Copies that skip that release
can't update in-app any more (see "Copies left behind").

1. Make the new key: `Scripts/sign-update.swift keygen <file>` (update key) or
   `swift Scripts/sign.swift keygen` in `../store` (store key; it refuses to overwrite an existing Keychain item, so rename that first). Back it up offline first.
2. Accept both keys for one release cycle: change the check to try the new key, then the old one
   (`AppInstaller.isSigned`, `SignedSandboxPin`, `Store.verify`). Release that build, signed with the
   **old** key. For the store key, the change goes into a sandbox release.
3. Wait until most installs run that build. The website download and the Homebrew cask both carry it.
4. Switch signing to the new key (replace the secret, or the Keychain item and `key.pub`), then drop
   the old key from the code in the next release.

## Compromise (someone else has the private key)

An attacker who holds the key can sign an app or sandbox update, or a store index, that every copy
accepts. They still need a way to deliver it: our GitHub releases or store repo, or a network position
that defeats HTTPS.

1. Rotate at once: release a build with only the new key, signed with the **old** key. That is the
   only way a running copy can be moved off the old key. Treat the old key as hostile from then on.
2. For the store: also publish a new `index.json` with a higher `version`. Copies refuse an older index
   (rollback check), so a stolen key can't bring back a revoked plugin with a stale index once the
   new one has been seen. It can still sign a newer one, which is why step 1 comes first.
3. Rotate every secret the key's storage shared: GitHub tokens with access to the repos (`TAP_TOKEN`,
   `SITE_TOKEN`) and the account's sessions.
4. Say so publicly: GitHub security advisory and release notes, with the SHA-256 of the clean DMG.

## Loss (the private key is gone, nobody else has it)

Nothing can be signed for copies in the field any more. In-app updates stop; nothing worse happens.

- Make a new key, ship a build that pins it, and ask users to install that DMG by hand, checking it as
  the wiki's verification page describes. Homebrew users get it through the cask.
- For the store key: a sandbox release that pins the new store key. Until users get it, the old index
  expires after 90 days (`expires`), and installs and updates from the store stop. Installed apps keep
  working.

## Copies left behind

A copy that never ran a build with the new key keeps only the old one. After the switch it reports
"not signed" for every update and never installs one. The fix is a manual install of the current DMG.
Keep the dual-key window (planned rotation, step 2) at least one release long.
