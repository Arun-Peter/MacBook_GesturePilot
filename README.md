# GesturePilot

GesturePilot is a personal macOS menu-bar utility for assigning actions to exact three- or four-finger trackpad swipes and exact three-finger Magic Mouse swipes.

**[Download the compiled GesturePilot app for Apple silicon](https://github.com/Arun-Peter/MacBook_GesturePilot/raw/refs/heads/main/outputs/GesturePilot.zip)**, then follow the installation steps below. The `Sources/`, `App/`, `scripts/`, and `Tests/` folders contain the source and supporting files for anyone who wants to change and rebuild the app.

## Compatibility

| Requirement | Current status |
| --- | --- |
| Compiled ZIP architecture | Apple silicon (`arm64`): M1 or later. The supplied binary does not run on Intel Macs. |
| Minimum macOS version | macOS 13 Ventura, declared in `App/Info.plist` and the compiler deployment target. |
| Validation | Built and automated checks passed on macOS 26.7.2. Gesture workflows were also checked manually on the development Mac. Other macOS versions have not been systematically tested. |
| Input devices | A supported Apple trackpad and/or Apple Magic Mouse. Ordinary third-party mice do not provide the required multitouch contact data. |
| Permission | Accessibility permission, granted by the recipient on their Mac. |
| Runtime dependencies | macOS frameworks only. Xcode, Python, Homebrew and a Codex/ChatGPT subscription are not required to run the compiled app. |
| Distribution signing | Ad-hoc signed; not Developer ID signed or notarized by Apple. |

macOS 13 is the deployment minimum, not a guarantee that every gesture has been
verified on every macOS release. Exact finger counting uses Apple's private
`MultitouchSupport.framework`, so an OS update may require compatibility work.
An Intel build from source may be possible, but has not been validated; the
current build script targets the architecture of the Mac running it.

## Install a shared compiled ZIP

1. [Download `outputs/GesturePilot.zip`](https://github.com/Arun-Peter/MacBook_GesturePilot/raw/refs/heads/main/outputs/GesturePilot.zip)
   and extract it to get `GesturePilot.app`.
2. Move the app to `/Applications`, then open it. When updating, quit the previous
   instance before replacing it.
3. Because this build is not notarized, macOS may block the first launch. If you
   trust the sender and your Mac permits an exception, follow Apple's
   [Open Anyway instructions](https://support.apple.com/en-us/102445) in
   **System Settings → Privacy & Security** after attempting to open the app.
   This exception may be unavailable on a managed Mac; ask your IT administrator
   if their policy blocks it.
4. Grant **Accessibility** access to GesturePilot when prompted, or enable it in
   **System Settings → Privacy & Security → Accessibility**. Relaunch GesturePilot
   after granting access if gestures are not active.
5. Use the palm icon in the menu bar to open Settings, choose a device and assign
   gestures. Three-finger physical clicks initially have **No Action** assigned.

The recipient configures their own gesture mappings. The compiled ZIP does not
contain the developer's saved settings or transfer macOS permission grants.

GitHub's **Code → Download ZIP** includes the source files and the compiled app
archive in `outputs/`. Download `outputs/GesturePilot.zip` directly if you only
want to install the app. Clone the repository and use the build instructions
below if you want to change its functionality. Rebuilds update
`outputs/GesturePilot.zip`; commit the rebuilt ZIP with source changes so the
download matches the current code.

For smoother distribution, a future release would need Developer ID signing
and Apple notarization. The current ad-hoc signature verifies bundle integrity
but does not identify an Apple-verified developer.

## Default gestures

Default mappings:

- Swipe down: minimize every minimizable window.
- Swipe up: restore the windows minimized by GesturePilot.
- Swipe left/right: no action.

Magic Mouse defaults:

- Three-finger swipe down: minimize the focused window.
- Three-finger swipe up: maximize the focused window to the usable screen area.
- Three-finger swipe left/right: no action.

The settings window has separate Trackpad and Magic Mouse profiles. Each direction and the **3-Finger Click** row can use Minimize Current, Maximize Current, Minimize All, Restore, Toggle Minimize/Restore, Mission Control, App Exposé, Close Current Window, Quit Current App, or No Action. Finger count, per-device sensitivity, mappings, and launch-at-login are saved between launches.

The click is a physical button press with exactly three fingers resting still on the surface, for both devices. It always uses three fingers, even with four-finger trackpad swipes selected. Rest the fingers briefly (at least 0.1 seconds), press and release within one second, then lift. The action runs on release while the same fingers are still resting. Movement, a swipe, a drag, a long hold, a finger-count change, or a foreground-app change cancels the click action. Lift all fingers before another custom click.

Three-finger clicks initially use **No Action**. Choose an action per device to enable interception. Only an eligible three-finger button sequence is consumed; ordinary one/two-finger clicks and light taps pass through. If both touch surfaces are in use, the click is left alone rather than guessing which device pressed. Other external mice are not identified by this contact-based attribution; avoid resting three fingers on a tracked device while clicking a different mouse. Existing macOS gesture preferences are not changed. Click monitoring uses Accessibility permission and is recreated after sleep alongside the multitouch detector.

**Close Current Window** presses the focused window's normal close button. **Quit Current App** sends a normal quit request, never a force-quit. Applications retain their usual save/cancel handling. Their status says **requested**, since an app may show a prompt or cancel the request.

Mission Control and App Exposé launch Apple's `/System/Applications/Mission Control.app` through LaunchServices, with argument `0` or `2`. The launcher stays in the background so App Exposé targets the frontmost application. They do not depend on keyboard shortcuts. The status says **requested** when macOS accepts the launch, or reports a launch error; it does not report a window count or claim the overview is visible.

Current-window actions resolve the frontmost application's focused window, main window, or first usable top-level window in that order. Minimization first sets the Accessibility minimized attribute and then falls back to pressing the window's minimize button for applications with nonstandard Accessibility behavior.

Windows minimized by either **Minimize Current Window** or **Minimize All Windows** are retained in the in-memory restore list. Restore removes successfully restored windows and keeps a window in the list when macOS reports a temporary restore failure so the gesture can retry it.

Closing the settings window leaves GesturePilot running in the menu bar. Open GesturePilot from Applications, or choose **Settings…** from its menu-bar icon, to show the window again.

Before sleep, GesturePilot releases its multitouch device connections. After wake, screen wake, or session reactivation, it rediscovers enabled devices and retries while Bluetooth devices reconnect.

## Build

```sh
./scripts/build-app.sh
```

The signed application is assembled under `/private/tmp/GesturePilotBuild`, and a distributable ZIP is written to `outputs/GesturePilot.zip`. Keeping the development bundle outside indexed folders prevents macOS from registering it as a second installed copy.

## Validation

The build runs swipe/contact tests and 22 button-routing cases covering both devices, ordinary one/two-finger clicks, disabled mappings, stale contacts, concurrent devices, swipes, drags, lifted fingers, long holds and foreground changes. No mouse events are posted by these tests.

`Tests/ActionFixture.m` provides two disposable windows whose close/quit delegates can veto a request. Build it with `zsh Tests/build-action-fixture.sh`. After quitting the normal GesturePilot instance, launch the fixture from `/private/tmp/GesturePilot-ActionTest/GesturePilotActionTest.app`, then run the installed GesturePilot with `--test-close-quit-fixture`. Only that exact fixture bundle is targeted. The report in `/private/tmp/GesturePilot-ActionTest/test-result.txt` checks cancellation, closing only one window and normal quit. For a repeat run, quit the fixture and remove its `allow-close`, `allow-quit`, `close-result` and `quit-result` files before launching it again. Relaunch GesturePilot normally afterwards.

The installed `--test-detector-restart` mode checks both touch devices and click monitoring across a stop/start cycle. Physical multi-finger clicks still require a real-device test.

## Permissions

GesturePilot requests Accessibility permission so it can change other applications' window state. Exact finger counting on trackpads and Magic Mouse uses Apple's private `MultitouchSupport.framework`; this makes the utility suitable for personal/direct distribution rather than the Mac App Store, and a future macOS release may require compatibility work.

## Implementation

The app is written in Objective-C and compiles with the standard macOS Command Line Tools. It dynamically loads the private multitouch framework at runtime and does not install a driver or background system extension.

## Project layout and future development

This folder is the source project. Open this folder in your editor and run
`./scripts/build-app.sh` from its root. The build resolves all source paths
relative to the script, so the project can be moved again without changing code.
Requirements are macOS, Apple Command Line Tools and Python 3; no downloaded
third-party library is required to build the current app.

- `Sources/Native/`: application and click-recognition source.
- `App/`: bundle metadata and code-signing requirements.
- `scripts/`: build, palm icon generation and icon packaging.
- `Tests/`: disposable-window test fixture and its build script.
- `outputs/`: the downloadable `GesturePilot.zip` is tracked; other local build
  archives are excluded from source control.
- `local-backup/`: a local snapshot of gesture settings and migration checksums,
  excluded from source control.

Generated `work/` and `.build/` directories are also ignored. These directories
are not required inputs for a clean build. Historical research and diagnostics
from the previous checkout are not dependencies of this project.

## Signing and macOS application files

The current app is **ad-hoc signed**. There is no private signing key or signing
certificate to preserve. Keep `App/GesturePilot.requirements` and the bundle
identifier `com.arun.GesturePilot` in `App/Info.plist` when updating this app.
The build script applies a fresh signature to each compiled bundle. Signatures
are embedded in the resulting executable and app bundle, including its
`Contents/_CodeSignature` directory. This is not Developer ID notarization.

A macOS application is normally a `.app` bundle. Finder presents it as one app,
but it is a directory containing the executable, metadata, icon and signature.
The executable here is `GesturePilot.app/Contents/MacOS/GesturePilot` (a Mach-O
binary without a filename extension). A `.pkg` is an installer package, not the
application itself. A `.dmg` is a disk image, and a `.zip` is a compressed archive.
GesturePilot currently distributes the `.app` inside a ZIP; no `.pkg` is needed.

A successful build writes `outputs/GesturePilot.zip`. To install a build, quit
GesturePilot, extract that ZIP, replace `/Applications/GesturePilot.app`, and
open it again. The uncompressed development bundle remains under
`/private/tmp/GesturePilotBuild` to avoid duplicate indexed app copies in the
source project. The installed application and macOS permission grants are
separate from this source folder.

## Local settings backup

Moving source does not change the installed app's preferences. The optional
`local-backup/com.arun.GesturePilot.plist` snapshot can restore the mappings later.
Quit GesturePilot first, then run from this project root:

```sh
defaults import com.arun.GesturePilot "$PWD/local-backup/com.arun.GesturePilot.plist"
```

Importing replaces this app's saved preferences. Reopen the app afterwards.
Accessibility permission and launch-at-login registration must be configured
separately on a new Mac. Do not include `local-backup/` in a public repository.

Source repository: [Arun-Peter/MacBook_GesturePilot](https://github.com/Arun-Peter/MacBook_GesturePilot).
The ignore rules keep other generated builds, local settings and private signing
material out of source control. No open-source license has been selected yet.
