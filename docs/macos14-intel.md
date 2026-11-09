# macOS 14+ and Intel support

Goal: V2Mac runs on **macOS 14 (Sonoma) or later**, on **Apple Silicon and Intel**. macOS 26+
keeps Liquid Glass exactly as it is today, and macOS 14 and 15 get the standard look with nothing
broken. Apple Silicon users must not download anything bigger than they do now.

Written 2026-11-09, from a trial build of a copy of the repo with the deployment target set to 14.0
(Xcode 27, macOS 27 SDK). The list of call sites below comes from that build plus a grep. The
compiler stops after the first error in a SwiftUI body, so more sites may show up once these are
fixed. Phase 1 keeps building until the errors stop.

## Implementation status (2026-11-09)

Release **1.10.0** is prepared for publication on 2026-11-09. The implementation branch is pushed. The signed release dry run passed, both Debug architectures and app-state tests passed in hosted CI, and startup smoke tests passed on native macOS 15 Apple Silicon and Intel. Full runtime acceptance is **not complete**: no local macOS 14/15 VMs or Intel test machine were available for the remaining interactive/network-mode checks.

| Tasks | Status and evidence |
|---|---|
| T0.1–T0.2 | Implemented and checked locally: baseline below; no readers of either duplicate Resources executable; signed helper and CLI remain in their used locations. `check-bundle.sh` checks both distributions. `BundleManifest.build` removes the target first and recreates only listed files, so removed files disappear; generated manifests omit both duplicates. Helper registration with a Developer ID signature is not checked (local builds are ad-hoc). |
| T1.1–T1.2 | Implemented: app, CLI, helper, state tests and package target 14; extension targets 26. One two-word address type replaces UInt128 on every OS, with carry/borrow, IPv6 /0, /64, /96 and /128 tests for matching, geo ranges and range conversion. Invalid prefixes are rejected before shifting. |
| T1.3–T1.6 | Implemented and compiled in Debug/Release. Glass branches retain their previous modifiers and arguments. SceneBuilder has no buildEither; the scene helper uses its public limited-availability builder functions, with a one-time auxiliary-window close on 14. Geocoding falls back to CLGeocoder. Actual Sonoma launch behavior remains unchecked. |
| T1.7 | Both architectures build Debug and Release; all 383 core tests in 60 suites and 49 app-state tests pass on this Mac; the state-test target also builds in Release. Additional availability sites are listed below. Existing deprecation/concurrency warnings remain; no new availability warnings were found in the final build. |
| T2.1–T2.4 | **Full acceptance still pending on 14/15:** macOS 15 startup/main-window smoke passed on both architectures; no local test machines were available for the full checklist. This includes SwiftData CRUD/backup, system proxy, TUN, kill switch, login items, notifications, Shortcuts, core and app updates on those OS versions. Never run the system-wide network checks beside the user's installed VPN. |
| T3.1 | Implemented: one support check gates all Sandbox entries, downloads, update checks, launch and notifications through the service; reports omit Sandbox files on unsupported Macs. CLI exposes no Sandbox command. Forced-unsupported demo launch reported `sandbox supported: false` and redirected a Sandbox Settings request to General. |
| T3.2 | ControlBridge publishing/requests and app Control Center wiring are guarded. macOS 15 startup smoke on both architectures completed without repeated extension errors. Longer log observation and macOS 14 remain unchecked. |
| T4.1–T4.3 | Implemented: Intel Info.plist pin and archive checksum are selected together; checksum fetched from the pinned release's `.dgst` and verified on download; separate core folders; architecture-specific core assets and app URLs; both app filename sets unit-tested; error text translated in all 13 catalog languages. |
| T4.4 | Both thin Release bundles pass architecture and code-signature checks on every executable. Intel dev app launches under Rosetta and produces a snapshot; bundled Intel CLI and Xray run. Local HTTP/SOCKS5 proxy smoke uses the Intel bundled Xray under Rosetta. Native Intel macOS 15 app startup, Xray version and CLI help also passed in hosted CI. The dev app's `-debugConnect` path and real Intel TUN acceptance remain unchecked. |
| T5.1 | Local packaging creates both manifests with distinct names: arm64 has patches from earlier releases; first Intel release has none. Release workflow builds, signs and publishes both sets and stable DMG aliases. Local asset-name/hash checks pass. Signed Actions dry run [42622892982](https://github.com/v2macapp/v2mac/actions/runs/42622892982) passed; its downloaded DMGs and manifests also passed project-signature, checksum, architecture and core-pin verification. Versioned release publication follows the tag. |
| T5.2 | Cask staged locally with architecture blocks; Homebrew style and strict offline audit pass for Sonoma/arm and Sonoma/Intel. Homebrew normalizes `macos: ">= :sonoma"` to `macos: :sonoma` (same minimum). The Intel hash is a local validation DMG hash: release CI must replace both hashes and the version before this branch is published. No released Intel asset exists yet, so online download audit cannot pass. |
| T5.3 | Website includes the Intel download, translated requirements, FAQ and comparison corrections. All 13 site tests and the 151-page production build pass. |
| T6.1 | CI builds both architectures on macos-26 and smoke-tests downloaded apps on macos-15 and macos-15-intel. Smoke script checks app identity, helper commands, crash detection, snapshot output and a 60-second deadline; its crash/timeout paths were exercised locally. Hosted build and Apple Silicon smoke checks passed in [42670062531](https://github.com/v2macapp/v2mac/actions/runs/42670062531). GitHub returned an internal server error before creating that run’s Intel matrix job; the standalone native Intel check passed in [42673152432](https://github.com/v2macapp/v2mac/actions/runs/42673152432). Temporary diagnostic workflows were removed. |
| T7.1–T7.4 | Updated all six README files, SPEC, all 25 tracked wiki pages named by this plan, CLAUDE.md and workspace PLAN.md. Existing untracked German/Portuguese wiki drafts are untouched. |

### Local verification notes

- Core regression command: `cd Packages/V2MacCore && swift test` with the pinned core present. The changed package passed all 383 tests in 60 suites with the original parallel scheduling restored (31.775 seconds); a serial run also passed earlier. A fake-forwarder readiness assertion now waits for its marker instead of racing its argument log. The untouched original package passed 379 tests. During changed-suite runs, the existing 100-target and custom-profile latency checks intermittently timed out against public sites; those two fixtures now redirect a public test destination inside Xray to the existing loopback HTTP server. URL safety validation, invalid configurations, blackhole outcomes and live-core process checks remain active.
- Debug and Release app builds cover both architectures and their CLI/helper/extension dependencies; the state-test target builds in both configurations. Local signature checks are ad-hoc, not Developer ID registration or notarization.
- Each final update manifest contains 59 files; arm64 has 30 patches and Intel has zero. Asset names are unique across architectures and zip SHA-256 values were rechecked. The complete local dry-run listing is generated at `reports/macos14-intel-assets.txt` (ignored build output); `.sig` names in that listing are produced only when CI has its signing key.

### Acceptance gaps and plan corrections

- GitHub retired `macos-14` on 2026-11-02. Use `macos-15` arm64 and `macos-15-intel` for hosted smoke tests; macOS 14 still requires a VM or a self-hosted runner. Source: [GitHub retirement notice](https://github.blog/changelog/2026-10-01-github-actions-macos-14-runner-image-retirement/).
- Intel updater/IPv6 test fixtures compile as x86_64, but the Xcode 27 SwiftPM test-discovery helper is arm64-only and cannot load that test bundle, even when Swift is invoked through Rosetta. Execute those suites on an Intel runner; both explicit architecture filename sets are tested in the native suite.
- Local host: macOS 27.0.1, Apple Silicon. No 14/15 behavior is inferred from successful deployment-target compilation.
- Before/after main and Settings snapshots were captured from the original commit and the changed dev app. Pixel identity is **not established**: demo rows reorder between launches and glass capture has black/blank rendering artifacts; Settings differed slightly too. Native on-screen comparison and menu-bar-panel inspection were blocked because computer-use access to V2MacDev was not approved. These remain acceptance checks, rather than claimed visual equivalence.
- Local tests never enabled TUN, system proxy or kill switch and never stopped the installed V2Mac or its core. Downloads and staging only; no app swap or helper registration was attempted.

## Decisions

| Question | Decision | Why |
|---|---|---|
| Lowest macOS | 14.0 for the app, CLI, privileged helper, `V2MacCore` and the state tests | Asked for. SwiftData, `@Observable`, `.inspector`, `ContentUnavailableView`, `onKeyPress` and `SMAppService` all need 14 at most. |
| Control Center extension | Stays at macOS 26 (its own `deploymentTarget`) | `ControlWidgetConfiguration` exists only on 26. Before 26 the system never loads the extension, and nothing in the app depends on it. |
| SDK and Xcode | Keep building with the newest SDK (Xcode 26.6 in CI, 27 locally) | Liquid Glass is chosen at run time from the SDK. Standard controls automatically look like glass on 26 and like Aqua on 14/15. |
| Glass code | `if #available(macOS 26, *)` keeps today's code; the `else` branch uses a material | The look on 26 stays exactly as it is now. |
| Architecture | **Two thin builds** (arm64 and x86_64), not one universal app | A universal app would add about 55 MB for everyone (the amd64 Xray is about 33 MB, the Swift slices about 25 MB) on top of today's 68 MB. Thin builds keep both downloads about the size of today's. |
| Existing users' update path | arm64 keeps today's asset names (`V2Mac-X.dmg`, `files.json`, the per-file zips) | 1.9.x installs already read these names. Intel gets new names that start with `intel`. |
| Secure Sandbox | Only on macOS 26 + Apple Silicon. Turned off and hidden everywhere else, for now (decided 2026-11-09) | The helper (`../sandbox/Package.swift`) needs macOS 26, and the kernel, rootfs and images are arm64 only. See "Secure Sandbox: later" for what enabling it would take. |
| Free size win | Remove the duplicate copies of `v2mac` and `V2MacPrivilegedHelper` in `Contents/Resources` | They are 5.6 MB of the installed 68 MB, and nothing reads them (the copies that are used live in `Helpers/` and `Library/HelperTools/`). |

## What blocks macOS 14 (the trial build's findings)

| Where | API | Needs | Replacement before 26 / 15 |
|---|---|---|---|
| `Packages/V2MacCore/.../GeoLists.swift`, `CustomRules.swift`, `RuleTester.swift` | `UInt128` | 15 | A small `Comparable` 128-bit value in the package (two `UInt64`s), used on every OS so there is only one code path |
| `App/V2MacApp.swift:31,39,47,54` | `.defaultLaunchBehavior` | 15 | Only on 15+. On 14, close the windows that should start hidden at launch (see T2.5) |
| `App/State/UpdateService.swift:329` (DEBUG only) | `Mutex` | 15 | `OSAllocatedUnfairLock(initialState:)` (13+), same `withLock` |
| `SidebarView.swift:166`, `ServerListView.swift:311` | `.symbolEffect(.rotate)` | 15 | No effect on 14 (`.pulse` works if a spinner is really wanted) |
| `MainView.swift:33`, `InspectorView.swift:78`, `AddSubscriptionSheet.swift:117`, `ServerEditorSheet.swift:104` | `.buttonStyle(.glassProminent)` | 26 | `.borderedProminent` |
| `RulesSidebar.swift:77` | `.buttonStyle(.glass)` | 26 | `.bordered` |
| `MainView.swift:121`, `ServerListView.swift:103,415`, `SidebarTools.swift:73`, `ConnectionBar.swift:22,174`, `MenuBarPanel.swift:518` | `.glassEffect(...)` (with `.tint`, `.interactive`) | 26 | `.background(.regularMaterial, in: shape)`, with the tint as a colour fill over it |
| `SidebarTools.swift:9`, `ConnectionBar.swift:14` | `GlassEffectContainer` | 26 | Its content without the container |
| `ConnectionBar.swift:175` | `.glassEffectID` | 26 | Nothing (no morph before 26) |
| `ServerListView.swift:141-188` | `ToolbarSpacer(.fixed)`, `.sharedBackgroundVisibility(.hidden)` | 26 | Nothing; on 14/15 toolbar items do not merge into capsules |
| `RulePickers.swift:172-197` | `MKReverseGeocodingRequest`, `MKGeocodingRequest`, `addressRepresentations.region`, `MKMapItem.location` | 26 | `CLGeocoder.reverseGeocodeLocation` / `geocodeAddressString` and `placemark.isoCountryCode` / `placemark.location` |
| `RulesSmartField.swift` | Foundation Models suggestion button, session and `@Generable` model | 26 | Hide suggestion action and annotate the model/session function; manual rules continue working |
| `CoreSettings.swift` | Indefinite `.symbolEffect(.bounce, options:)` conformance | 15 | No completion effect on 14; preserve the existing effect on 15+ |
| `AppModel.swift` | `ControlCenter.shared.reloadControls` | 26 | Do not wire or publish controls before 26 |
| `AppModel.swift` | `CSSearchableIndex.deleteAppEntities` / `indexAppEntities` | 15 | Skip server Spotlight indexing before 15; Shortcuts queries still work |
| Package update test fixtures | `Mutex.withLock` | 15 | `OSAllocatedUnfairLock`, including immutable snapshot of captured response bodies |
| `Extensions/Control/*` | `ControlWidgetConfiguration`, `.containerBackground(for: .widget)` | 26 | None: the extension stays on 26 |

Already fine on 14 (no change): `.symbolEffect(.bounce/.pulse)`, `.contentTransition(.symbolEffect(.replace))`,
`ContentUnavailableView`, `.inspector`, `onKeyPress`, `Table` + `TableColumnCustomization`, `@Entry`,
`openSettings`, `MenuBarExtra(.window)`, App Intents, `SMAppService`, `UNUserNotificationCenter`, swift-argument-parser.

## What blocks Intel

| Where | Today | Change |
|---|---|---|
| `project.yml` | `ARCHS: arm64` | Keep the default arm64; the Intel build passes `ARCHS=x86_64` on the command line |
| `Scripts/core.lock` | One `ASSET` / `SHA256` (`Xray-macos-arm64-v8a.zip`) | Add `ASSET_X86_64=Xray-macos-64.zip` and `SHA256_X86_64` for the same `VERSION` |
| `Scripts/fetch-core.sh` | Writes `Vendor/core` | `ARCH=x86_64` writes `Vendor/core-x86_64`; with no argument, nothing changes (tests and local builds keep `Vendor/core`) |
| `Scripts/pin-core-info.sh` | Always embeds the arm64 archive hash in Info.plist | Select `SHA256_X86_64` for Intel; bundle validation checks the pin |
| `Scripts/embed-core.sh` | Copies `Vendor/core/xray` | Picks `Vendor/core-x86_64` when `ARCHS` is `x86_64`, and fails if `lipo -archs` of the copied `xray` is not `$ARCHS` |
| `CoreUpdater.assetName` + its `.noRelease` text | arm64 asset; the message says "arm64" | `#if arch(x86_64)` picks `Xray-macos-64.zip`; the message becomes "No macOS build for this Mac was found in the latest releases." in all 13 languages |
| `AppInstaller.assetURLs` / `manifestURL` | `V2Mac-X.dmg`, `files.json` | `#if arch(x86_64)`: `V2Mac-X-intel.dmg`, `files-intel.json` |
| `Scripts/package-update.sh` | Asset names come from the path inside the bundle; patches come from the last 3 `V2Mac-X.dmg` | A prefix argument: Intel asset names start with `intel_`, its patches come from `V2Mac-X-intel.dmg`, and the output is `files-intel.json`. The first Intel release has no patches, which is expected |
| `Scripts/make-dmg.sh` | arm64 | `ARCH=x86_64` builds `V2Mac-X-intel.dmg` with `ARCHS=x86_64` |
| `.github/workflows/release.yml` | One build | A second Intel build (same runner, same job), its DMG + `.sha256`, `files-intel.json` (+ `.sig`) and zips, and `V2Mac-Intel.dmg` for the website |
| `../homebrew-tap/Casks/v2mac.rb` | `depends_on arch: :arm64`, `macos: :tahoe` | `on_arm`/`on_intel` blocks with their own `url` and `sha256`, `depends_on macos: ">= :sonoma"`; CI updates both hashes |
| Secure Sandbox | Offered everywhere | Hidden unless macOS 26 and arm64 (T3.1) |

The geo files (`geoip.dat`, `geosite.dat`), the Swift code, the root helper script, pf, `networksetup`
and the TUN forwarder do not depend on the architecture. Xray's amd64 build supports TUN on darwin.

## Phases and tasks

Each task ends with a build (`xcodebuild … build`), `swift test` in the package when the package
changed, and a commit in `app/` following `app/CLAUDE.md`. Phase 1 alone makes the app run on 14 for
Apple Silicon. Phase 4 adds Intel. They can ship separately.

### Phase 0: Size baseline and the free win

- **T0.1** Record the size baseline: Release `V2Mac.app` size, `du -sh Contents/*/*`, DMG size. Put the numbers
  in this doc under "Size log".
- **T0.2** Stop XcodeGen from copying the CLI and the privileged helper into `Contents/Resources`
  (`embed: false` on those two dependencies in `project.yml`, or whatever removes them there). The embed
  scripts already place them in `Helpers/` and `Library/HelperTools/`. Check: the Release bundle has no
  `Resources/v2mac` or `Resources/V2MacPrivilegedHelper`, the CLI still works (`Helpers/v2mac status`),
  and the helper still registers (signed build, or check the copy is in place for ad-hoc builds).
  The in-app updater must cope with files that are gone from the new manifest (check `BundleManifest`
  builds the new bundle only from the manifest, so old files simply disappear).

### Phase 1: macOS 14 on Apple Silicon

- **T1.1** Lower the targets: `project.yml` `deploymentTarget` → `"14.0"`, `V2MacControl` gets its own
  `deploymentTarget: "26.0"`; `Package.swift` `platforms: [.macOS(.v14)]`.
- **T1.2** Package: replace `UInt128` with a small 128-bit value type used everywhere (`GeoLists`, `CustomRules`,
  `RuleTester`). Only the operations those files use. Add tests for IPv6 ranges at the 64-bit boundary
  (`::/64`, `::ffff:0:0/96`, `/0`, `/128`), and the existing rule tests must pass unchanged.
- **T1.3** App compatibility helpers in one file, `App/Support/Compat.swift`: `glassSurface(_:in:)` (glass on 26,
  material + tint before), `prominentButtonStyle()`, `glassButtonStyle()`, `glassGroup(spacing:)`,
  `glassID(_:in:)`, and a toolbar spacer that is empty before 26. Each one is a few lines with
  `if #available(macOS 26, *)`. Replace every call site in the table above. **The 26 branch must be
  exactly today's modifier with today's arguments.**
- **T1.4** macOS 15 APIs: `.symbolEffect(.rotate)` only on 15+; `Mutex` → `OSAllocatedUnfairLock`.
- **T1.5** Launch behaviour on 14: `defaultLaunchBehavior` only on 15+. On 14, the Logs, Rules and Connections
  windows must not open at launch, and the main window must stay closed with `--cli-background`. Try
  `if #available` in the `SceneBuilder` first; if the compiler refuses, close those windows by id
  once at launch on 14 (in the app delegate).
- **T1.6** MapKit in `RulePickers.swift`: the 26 path as now; before 26 `CLGeocoder` (one request at a time, as
  the existing `shortcut:` comment already assumes).
- **T1.7** Repeat the build until no availability errors are left: app, CLI, helper, state tests, and the
  Release configuration (the DEBUG-only code hides some sites from one of them). Also search for
  `#available` warnings and deprecation warnings that are new.

### Phase 2: Behaviour on macOS 14 and 15 (cannot be seen by the compiler)

- **T2.1** Run the dev build on macOS 14 and 15 (see "How to test"). Check, with `-debugDemoData YES` and
  `-debugSnapshot`: main window, inspector, connection bar tiers at narrow and wide widths, menu bar
  panel, sheets, Settings (every tab), Rules window and map, Logs, Connections. Fix layout that only
  worked because glass capsules gave it padding (the `ToolbarSplitButton` toolbar, the connect button).
- **T2.2** SwiftData on 14: add a subscription, refresh it twice, edit, delete, groups, latency, backup round trip
  (`-debugBackupRoundTrip`). macOS 14 SwiftData crashes on some `#Predicate` shapes and on Codable
  enums with associated values: fix any crash, without changing the store schema.
- **T2.3** Core path: connect, live switch (`-debugSwitchTest YES`), exit check, TUN mode, system proxy, kill switch
  (only on a test machine or VM, never next to the user's running V2Mac), login item, notifications,
  App Shortcuts, the CLI, the in-app core update.
- **T2.4** In-app app updater on 14: `-debugAppUpdate` against a test `files.json`.

### Phase 3: Gating features that cannot exist

- **T3.1** Turn the Secure Sandbox off on macOS 14/15 and on Intel (decided; see "Secure Sandbox: later").
  One `SandboxService.isSupported` (`#available(macOS 26, *)` and `#if arch(arm64)`). When it is false,
  hide the sidebar button (`SidebarTools`), the menu bar entry (`MenuBarPanel`), the Sandbox update row
  and notification, the entry sheet and the Settings tab (or keep the tab with one line: "The Secure
  Sandbox needs a Mac with Apple Silicon and macOS 26 or later.", in all 13 languages). The service
  must never download the helper then. Check `ProblemReportSheet` and the CLI too.
- **T3.2** Control Center: on 14/15, check that the app starts cleanly with the 26-only extension inside
  (`log stream` shows no repeating errors) and that `ControlBridge` calls do nothing there.

### Phase 4: Intel build

- **T4.1** `core.lock` + `fetch-core.sh` + `embed-core.sh` as in the table. CI must check the amd64 hash too.
- **T4.2** `CoreUpdater` asset per architecture + the new error text in all 13 languages (`App/Resources/Localizable.xcstrings`, `"extractionState": "manual"`).
- **T4.3** `AppInstaller` URLs per architecture. Unit-test both name sets (test the pure function with an
  architecture parameter, and let the `#if` choose the default).
- **T4.4** `make-dmg.sh ARCH=x86_64`. Check `lipo -archs` on `MacOS/V2Mac`, `Helpers/xray`, `Helpers/v2mac`,
  `Library/HelperTools/*` and the appex: all `x86_64`. Run the Intel build under Rosetta on Apple
  Silicon (`arch -x86_64 …/V2MacDev -debugDemoData YES -debugConnect YES`) as a first smoke test.

### Phase 5: Release, updates, Homebrew, website

- **T5.1** `package-update.sh` prefix argument, `release.yml` second build and its assets. Dry run with
  "Actions → Release → Run workflow" and check the artifact holds both sets. **No tag.**
- **T5.2** Cask: `on_arm`/`on_intel`, `>= :sonoma`; the release job updates both `sha256` lines. Check with
  `brew style` and `brew audit --cask` locally. Commit in `homebrew-tap`; do not push.
- **T5.3** Website (`../site`): a second download button "Intel Mac" pointing at
  `releases/latest/download/V2Mac-Intel.dmg`, requirements text "macOS 14 or later", in every
  `strings*.ts`. Commit in `site`; do not push.

### Phase 6: CI that keeps it working

- **T6.1** `ci.yml`: keep the build on `macos-26`; also build `ARCHS=x86_64` (catches arch errors). Add a job that
  downloads both Debug apps and smoke-tests on `macos-15` (arm64; `macos-14` retired 2026-11-02) and `macos-15-intel`: launch with
  `-debugDemoData YES -debugSnapshot`, wait for the snapshot line, run `Helpers/xray version` and
  `Helpers/v2mac --help`. Upload the PNGs as an artifact.

### Phase 7: Words

- **T7.1** `README.md` and every translation (`fa`, `zh`, `ru`, `de`, `zh-Hant`): badges, "Requires …", the Intel DMG.
- **T7.2** `docs/SPEC.md`: lines 5, 42, 80, section 12.5 (glass only on 26, material fallback), Sandbox requirements.
- **T7.3** Wiki: `Home`, `Installation`, `Troubleshooting-and-FAQ`, `Known-Limitations`, `Sandbox` in every language that has them.
- **T7.4** `app/CLAUDE.md` first line and the "Building" section (Intel core, `ARCH=x86_64`); workspace `PLAN.md` status.

## Secure Sandbox: later (not part of this plan)

For now the sandbox stays on macOS 26 + Apple Silicon only (T3.1 turns it off elsewhere). The `sandbox`
repo does not change in this plan. When it is worth doing, the two steps are:

- **macOS 14/15 on Apple Silicon (small).** A trial build of `../sandbox` at macOS 14 (2026-11-09) found only
  `Mutex`/`Atomic` in `Relay.swift` and `Pty.swift` (macOS 15; use `OSAllocatedUnfairLock`) and
  `.glass`/`.glassProminent` button styles in `SandboxWindow.swift` and `StoreWindow.swift` (macOS 26). The
  Virtualization APIs it uses all exist on macOS 12–13. Also: lower `platforms` in `sandbox/Package.swift`,
  check the generated stub apps' minimum version, test a real VM boot on 14 and 15, then widen `isSupported`
  to `#available(macOS 14, *)` with arm64.
- **Intel (large, separate project).** Everything inside the VM is arm64: kernel (`kernel/build.sh`,
  `arch/arm64`), rootfs and base images (Docker `linux/arm64`), the agent (`aarch64-swift-linux-musl`), the
  Xray in the rootfs (`rootfs/xray.lock`), every plugin and the signed store index, and the helper's
  update manifest. All would need x86_64 copies across `sandbox`, `store`, `plugin-template` and the plugin repos.

## How to test without old Macs

- macOS 14 and 15 on Apple Silicon: a VM (UTM or `tart`, Virtualization framework, IPSW for 14.x/15.x).
  Copy the Debug `V2MacDev.app` in. Run TUN, the kill switch and the system proxy only inside the VM.
- Intel: the Intel build runs under Rosetta on Apple Silicon (good for the UI, the updater and Xray as a proxy;
  TUN under Rosetta is a hint, not proof). Real Intel hardware: the `macos-15-intel` GitHub runner
  (Phase 6; check it still exists), or any Intel Mac with macOS 14+. The final TUN check needs one of these.
- macOS 26+: the normal dev build. Compare snapshots before and after Phase 1. They must be identical
  (`-debugSnapshot` does not draw glass, so also look at the screen once).

## Size log

| Build | App | DMG |
|---|---|---|
| Release baseline, 2026-11-09 (0.1.0 local version) | 69,072 KiB | 27,716 KiB |
| arm64 after duplicate removal + compatibility, local Release | 64,024 KiB | 26,012 KiB |
| Intel, local Release | 66,968 KiB | 28,328 KiB |

## Agent prompts

Give the agent one prompt at a time, in order. Each one assumes the earlier ones are committed.
Start every prompt with the common part.

**Common part (put in front of each prompt):**

> You are working in `/Users/parsaradfar/Programming/Projects/v2mac/app`. Read `CLAUDE.md` (in this folder
> and the workspace one above it) and `docs/macos14-intel.md` first; the doc is the plan and its tables
> list the exact call sites. Rules: never quit, kill or restart the installed `/Applications/V2Mac.app`
> or its `xray`; test only with `V2MacDev.app`. Do not turn on TUN, the system proxy or the kill switch
> on this Mac. Do not push, tag or release. Commit each finished task in this repo, using the commit
> message rules in `CLAUDE.md` (`chore:`/`docs:`/`ci:` for internal work). Every new user-visible
> string needs all 13 languages in the string catalogs. On macOS 26+, the app must look and behave
> exactly as it does now: every `#available(macOS 26, *)` branch is today's code, unchanged. Keep
> changes minimal: no new dependencies, no refactors outside the task. When done, update the task's
> status in `docs/macos14-intel.md` and report what you checked and what you could not check.

**Prompt 1 (Phase 0):**

> Do T0.1 and T0.2. Build Release with `Scripts/make-dmg.sh`, record the sizes in the Size log, then
> remove the duplicate `Contents/Resources/v2mac` and `Contents/Resources/V2MacPrivilegedHelper` copies
> from the build (fix it in `project.yml`, then `xcodegen generate`). Show that nothing reads those
> paths (grep the app, scripts and the updater), that `Helpers/v2mac` and `Library/HelperTools/`
> still exist and are signed by `make-dmg.sh`, and that `Scripts/package-update.sh` still makes a
> manifest. Record the new size.

**Prompt 2 (T1.1, T1.2):**

> Lower the deployment targets as in T1.1 (`V2MacControl` stays on 26). Then do T1.2: replace `UInt128`
> in `Packages/V2MacCore` with one small internal 128-bit unsigned type that implements only the
> operations `GeoLists.swift`, `CustomRules.swift` and `RuleTester.swift` use, and use it on every OS.
> Add Swift Testing tests for the edge cases listed in T1.2. `swift test` must be green, including the
> `.integration` suites (run `Scripts/fetch-core.sh` first).

**Prompt 3 (T1.3, T1.4, T1.6):**

> Add `App/Support/Compat.swift` as described in T1.3 and move every call site from the "What blocks
> macOS 14" table onto it. Then T1.4 and T1.6. The 26 branch of each helper must be the exact
> modifier the call site used before, with the same arguments. Before 26, glass becomes
> `.regularMaterial` in the same shape, and a tint becomes that colour at low opacity over it.
> Build Debug and Release. Take `-debugDemoData YES -debugSnapshot` snapshots of the main window,
> the menu bar panel and Settings before and after on this Mac (macOS 26+): they must be identical.

**Prompt 4 (T1.5, T1.7):**

> Do T1.5, then T1.7: build every scheme and both configurations with deployment target 14 until no
> availability errors are left. Fix new sites the same way as in Compat.swift. List every site you
> found that was not in the doc's table, and add it to the table.

**Prompt 5 (Phase 3):**

> Do T3.1 and T3.2. One `isSupported` check decides everything about the Secure Sandbox; check every
> file that touches `model.sandbox` or `SandboxService`. On an unsupported Mac nothing is downloaded,
> no Sandbox notification fires, and no button leads to it. You can check the unsupported path on this
> Mac by temporarily forcing `isSupported` to false in a DEBUG launch argument
> (`-debugSandboxUnsupported YES`, document it in `CLAUDE.md` with the other debug arguments).

**Prompt 6 (Phase 4):**

> Do T4.1 to T4.4. Look up the SHA-256 of `Xray-macos-64.zip` for the `VERSION` in `core.lock` from that
> release's `.dgst` file and check it against the downloaded file. Keep `Vendor/core` (arm64) as the
> default so tests and the normal build do not change. Add the new error text in all 13 languages.
> Build `ARCH=x86_64 Scripts/make-dmg.sh`, check `lipo -archs` on every Mach-O file in the bundle,
> and run the Intel `V2MacDev` under Rosetta with `-debugDemoData YES -debugSnapshot` and once with
> `-debugConnect YES` on a dev-data server (never the installed app's port). Record the Intel sizes.

**Prompt 7 (Phase 5):**

> Do T5.1 to T5.3. arm64 asset names must stay exactly as they are, because installed 1.9.x
> versions download them. Show a dry-run listing of every asset the release would publish for both
> architectures. Commit the cask change in `../homebrew-tap` and the website change in `../site`, each
> in its own repo, following its `CLAUDE.md`. Push nothing.

**Prompt 8 (Phase 6):**

> Do T6.1. The smoke job must fail when the app crashes at launch or no snapshot appears within 60
> seconds. Do not push; show the workflow diff, and say what needs a push to be tried.

**Prompt 9 (Phase 7):**

> Do T7.1 to T7.4: every README translation, the SPEC lines named in T7.2, the wiki pages in every
> language that has them (commit in `../wiki`, do not push), `CLAUDE.md`, and the workspace `PLAN.md`.

**Prompt 10 (Phase 2, needs a VM or old Mac; the user runs it or hands the agent the VM):**

> Run the checklists T2.1 to T2.4 on macOS 14 and on macOS 15, inside the VM only. Fix what breaks, with
> `if #available` fallbacks that leave 26 untouched. For each item, report pass, fail with the fix, or
> not checked and why.
