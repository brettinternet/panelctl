# Development

Requires macOS 13+, Swift 5.9+ and [mise](https://mise.jdx.dev).

```sh
task init                     # install tools, create .env, install Git hooks
task check                    # Prettier, ShellCheck, warnings-as-errors build
task fix                      # apply Prettier formatting
swift test --disable-sandbox
swift build --product panelctl
swift build --product PanelCtlApp
scripts/test-release-version.sh
python3 scripts/test-signing.py # fake tools only; no keys or privacy prompts
task build:release            # universal .build/PanelCtl.app (https://taskfile.dev)
```

Tests use fake display writers and DDC channels; they never change real
displays. Opt-in environment variables:

| Variable | Effect |
| --- | --- |
| `PANELCTL_TEST_LIVE_BLACKOUT=1` | Run a geometry test that briefly covers external screens with black windows |
| `PANELCTL_ICC_EVIDENCE_DIR=<dir>` | Replay saved ICC profiles (read-only) |
| `PANELCTL_SETTINGS_FIXTURE_OUTPUT=<dir>` | Write Settings screenshots (below) |
| `PANELCTL_DISCONNECT_FIXTURE_OUTPUT=<dir>` | Write Full disconnect screenshots |
| `PANELCTL_SETTINGS_FIXTURE_WIDTH=<pt>` / `_HEIGHT=<pt>` | Screenshot window size (width 440–680) |

Recovery checks that don't change displays are in
[display recovery](display-recovery.md#testing).

## Settings screenshots

Render Settings with fake displays, without launching the app or touching real
monitors:

```sh
mkdir -p /tmp/panelctl-settings
PANELCTL_SETTINGS_FIXTURE_OUTPUT=/tmp/panelctl-settings swift test --disable-sandbox \
  --filter 'SettingsWindowTests.test(Settings|Displays|DismissInputWarning|DisplayAction)FixtureSnapshots'
```

```sh
PANELCTL_DISCONNECT_FIXTURE_OUTPUT=/tmp/panelctl-disconnect swift test --disable-sandbox \
  --filter 'DisplayDisconnectIntegrationTests|ExperimentalDisconnectTests'
```

SwiftUI exposes its accessibility tree only to a connected assistive client,
so native UI tests drive AppKit controls and check the rest through the model.

## Release

The version in `Sources/PanelCtlCore/CLIHelp.swift` must match the tag's base
version (`1.2.3` for `v1.2.3-beta.1`).

```sh
scripts/package-release.sh v1.2.3
```

This writes universal app and CLI archives with SHA-256 files to `dist/`.
Release CI requires a stable self-signed code-signing identity. Local packaging
uses the same identity when configured; otherwise it prints an ad-hoc warning.
Neither signature is Developer ID signing or notarization.

General settings shows the packaged release version. When HEAD is not at the
matching release tag, packaging appends the short Git SHA (for example,
`1.2.3 (abc1234)`) to distinguish development builds. Packaging requires a Git
checkout; bundle marketing and build numbers remain unchanged.

Release builds pass the SDK to the linker (`-Xclang-linker -isysroot`).
Without it, SwiftPM can record macOS 13.0 as the SDK and macOS runs the app
with macOS 13 behavior (for example, truncated Settings rows).
`scripts/package-app.sh` refuses binaries that don't record their SDK.

When cross-building for Intel, find the output with
`swift build … --show-bin-path` and check it with `xcrun lipo -archs`.

### Stable signing identity (owner setup)

The owner creates and retains the private key, or explicitly authorizes an
agent to provision it into the local Keychain and GitHub Actions secrets.
Without that scoped authorization, agents must not generate, export or read it.
Never put certificates with private keys, passwords or exports in the repository,
chat or logs. No Apple Developer membership is needed.

1. In **Keychain Access → Certificate Assistant → Create a Certificate**, use
   name **PanelCtl Signing**, Identity Type **Self Signed Root**, Certificate
   Type **Code Signing**, and enable overriding defaults. Choose a deliberate
   long validity period (for example 3650 days), retain the Code Signing
   extended key usage, and save in the login keychain. Keep this same identity
   across builds; another certificate with the same name is not the same identity.
2. If needed, open the certificate's Trust section and trust it for **Code
   Signing only**, not SSL or unrelated uses. Confirm it appears here:

   ```sh
   security find-identity -v -p codesigning
   ```

3. Copy the certificate's 40-character SHA-1 fingerprint (not the quoted name):

   ```sh
   export PANELCTL_SIGNING_IDENTITY=REPLACE_WITH_40_CHARACTER_CERTIFICATE_SHA1
   export PANELCTL_REQUIRE_SIGNING=1
   task build:release
   ```

   Both packaging scripts honor these variables. `PANELCTL_SIGNING_KEYCHAIN`
   optionally selects a specific keychain path. An invalid or unavailable
   configured identity fails signing; it never falls back to ad-hoc. Without an
   identity, PR/local packaging may use ad-hoc signing with a visible warning,
   unless `PANELCTL_REQUIRE_SIGNING=1`. Direct `swift build` is not app packaging.

   For local `task` runs, set
   `PANELCTL_SIGNING_IDENTITY=…` in `.env` (created from `example.env`
   by `task init`; untracked), which the Taskfile loads.
   `task copy:release` refuses to install an ad-hoc signed app, because each
   ad-hoc build would make macOS drop Accessibility and other privacy grants.

4. In Keychain Access **My Certificates**, select the identity including its
   private key and export a password-protected `.p12` outside the checkout
   (the commands below use `/private/tmp/PanelCtl-signing.p12`). Keep an encrypted
   backup in owner-controlled storage. Run these commands yourself; the password
   command prompts for the export password without putting it in shell history:

   ```sh
   base64 -i /private/tmp/PanelCtl-signing.p12 | tr -d '\n' | gh secret set PANELCTL_SIGNING_P12_BASE64 --repo brettinternet/PanelCtl
   gh secret set PANELCTL_SIGNING_P12_PASSWORD --repo brettinternet/PanelCtl
   gh secret set PANELCTL_SIGNING_IDENTITY --repo brettinternet/PanelCtl --body "$PANELCTL_SIGNING_IDENTITY"
   gh secret list --repo brettinternet/PanelCtl
   ```

   Remove the temporary export through Finder after uploading and backing it up.
   Never paste the export or password into a task, chat or log. Release CI imports
   these secrets into a job-local keychain, grants `/usr/bin/codesign` access,
   passes that keychain explicitly (without changing the search list), deletes
   the temporary `.p12`, and deletes the keychain in an `always()` step. Missing
   secrets, import failures or signing failures prevent publication. PR jobs do
   not receive these secrets. The ephemeral runner is the final cleanup boundary
   if a job is forcibly terminated.

The app identifier remains `com.brettinternet.panelctl`; the CLI/helper uses
`com.brettinternet.panelctl.cli`. Nested code is signed before the app, using
one certificate. Explicit designated requirements pin the identifier and leaf
certificate SHA-1, not the changing code hash. This is a certificate fingerprint,
not use of SHA-1 as the executable's digest algorithm. See Apple's
[code-signing requirements](https://developer.apple.com/library/archive/technotes/tn2206/).

### Signing acceptance and rotation

After setup, package **two different commits** with the same identity into
separate output directories. On each extracted app and CLI, run:

```sh
codesign --verify --deep --strict /path/to/PanelCtl.app
codesign -d -r- /path/to/PanelCtl.app
codesign -d -r- /path/to/PanelCtl.app/Contents/Helpers/panelctl
codesign -d -r- /path/to/panelctl
/path/to/PanelCtl.app/Contents/Helpers/panelctl help
```

Record the commits and the requirements: each corresponding requirement must
be identical across the two builds, contain the certificate pin and expected
identifier, and contain no `cdhash`. The fake-tool signing tests check policy
and command ordering only; they do not prove macOS accepts the certificate.

With explicit owner approval for desktop interaction, install the first app
using `scripts/install-release.swift SOURCE_APP /Applications/PanelCtl.app`,
verify opening it and Launch at Login registration, then install the second at
the same path and repeat. Confirm the bundled helper executes and the installed
signature still verifies. The installer copies the signed bundle without
re-signing; bundle location, helper lookup and `SMAppService.mainApp` are unchanged.
Do not run blackout or recovery commands to test signing. Gatekeeper still may
require **Open Anyway** after checking the release checksum: a self-signed
certificate is not notarization or Apple trust.

To rotate, create a new identity and replace all three repository secrets plus
the local fingerprint together. Retain the old key securely for any deliberate
old-line rebuilds. Rotation changes the designated requirement. Users must
remove/re-add PanelCtl's privacy grant once after rotation **or the first upgrade
from an ad-hoc build**; a stale enabled switch in System Settings does not prove
permission is valid. Builds signed with the unchanged identity are intended to
retain grants. TASK-64 checks Accessibility in the app process and requests it
only from the explicit in-app button. Fake-backed tests never open the
permission prompt or move native windows; real window movement and grant-retention
validation still require separate explicit user approval.
