# morph.

**Your Mac. More alive.**

Morph is a native macOS utility that turns the MacBook camera notch into a fluid, interactive Dynamic Island: hover and click it for now playing, battery, timers, focus sessions, quick actions and a file shelf, while short activities such as charging, a new screenshot or a finished timer appear on their own. Other apps and scripts can show their own activities through a [local API](docs/LIVE_ACTIVITIES_API.md).

Swift 6, SwiftUI and AppKit. No third-party dependencies. macOS 14 or later. One private framework, DisplayServices, is used only if you turn on Replace macOS Brightness HUD.

## Build and run

```bash
# Optional: sign with your own identity so macOS privacy grants survive rebuilds
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then set DEVELOPMENT_TEAM

xcodebuild -project Morph.xcodeproj -scheme Morph -configuration Release \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/Morph.app
```

Or open `Morph.xcodeproj` in Xcode and run the **Morph** scheme. Without `Local.xcconfig` the build is ad-hoc signed, which works, but macOS will ask for permissions again after each rebuild.

Xcode builds into its own DerivedData, not `build/DerivedData`, so the two can hold different versions with the same bundle ID. Quit Morph before opening a new build, and check **Settings › Advanced › Diagnostics**: its first lines give the running version and path.

Run the tests:

```bash
xcodebuild test -project Morph.xcodeproj -scheme Morph \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData
```

The window tests open the real overlay panel on your screens for a few seconds. To write every island state out as PNG for design review, set the environment variable `TEST_RUNNER_MORPH_SNAPSHOT_DIR=/some/dir` and, because the sandboxed host can't write there, pass the build settings `CODE_SIGN_ENTITLEMENTS= ENABLE_APP_SANDBOX=NO`.

`TEST_RUNNER_MORPH_LIVE_KEY_TEST=1` posts real volume keys through the window server to prove the tap swallows them. It needs Accessibility, and it briefly moves the volume by one step for its control check before restoring it.

## Install on another Mac

1. Build Release as above, then zip it, which preserves the signature: `ditto -c -k --keepParent build/DerivedData/Build/Products/Release/Morph.app Morph.zip`
2. Copy the zip to the other Mac, unzip it and move **Morph** to Applications.
3. The build is signed for development and isn't notarized, so Gatekeeper blocks the first launch. Try to open it, then choose **Open Anyway** in System Settings → Privacy & Security.
4. Quit any older copy first. Morph 2.3 replaces a copy that's 2.3 or newer by itself, but older versions don't know how to step aside.
5. Grant permissions as each feature asks. They're per Mac and per signature, so a rebuild with a different identity asks again.

## Using it

| Gesture | Result |
| --- | --- |
| Point at the notch | The island grows slightly and shows the most relevant thing |
| Click the island | Opens the panel: Home, Timers, File Shelf |
| Click an alert | Dismisses it |
| Drag a screenshot's thumbnail | Hands the file to the app you drop it on |
| Two-finger swipe left or right over the island | Next or previous track |
| Two-finger swipe up or down, or mouse wheel | Changes the output volume |
| Click the open panel's background | Closes it |
| Left and right arrows, Space (panel opened from the menu bar) | Switch tabs, play/pause |
| Right-click the island | Settings, Pause, Quit |
| Drag a file toward the notch | The island offers itself as a drop target |
| Menu bar icon → Open Morph | Opens the panel with keyboard focus; Escape closes it |

To reach Settings with the menu bar icon hidden, right-click the island or open Morph again from Applications.

The first time Music or Spotify is running, the Home tab offers **Allow Access**, which shows the macOS Automation prompt. Morph never launches a player itself.

Morph appears on the display with a notch by default. On a display without one it draws a virtual notch in the menu bar. If the idle shape doesn't sit exactly on your camera housing, use Settings → Advanced → Notch Calibration.

## Permissions

| Permission | Why | When asked |
| --- | --- | --- |
| Automation (Music, Spotify) | Read the track, control playback | Only when you press Allow Access |
| System audio capture | Measure the music player's sound for the waveform | By macOS, the first time music plays with the bars on screen |
| Notifications | Optional timer alert | Only if you enable it |
| Dropped files, read-only | Shelf keeps a bookmark and never copies the file | Implicit in the drop |
| Network client | Spotify artwork from `https` URLs only | Never prompts |
| Accessibility | Only for Replace macOS Volume/Brightness HUD: an active event tap limited to `NX_SYSDEFINED` events, so it never sees typing. Volume replacement is on by default, so the volume keys move in exact 5% steps (Settings → System → Volume Step: 2%, 5% or 10%) | At first launch for volume, or when you turn brightness replacement on. Until granted, macOS keeps the keys |
| Screenshot folder, read-only | The one folder you choose in Settings → Screenshots, kept as a security-scoped bookmark | When you choose it |
| Network server, loopback only | The optional local API. No socket exists while it's off | Never prompts |
| Keychain | The local API's token | Only when you turn the API on |
| Notifications | Optional focus session alert | Only if you enable it |

Showing volume and brightness, audio device connections and cinema mode need no permission. Audio is analyzed in memory and discarded: nothing is recorded, saved or sent, and the microphone isn't used. macOS doesn't tell apps whether audio capture was granted, so a denial appears in Settings → Music as "no audio received". To change it later, use System Settings → Privacy & Security → Screen & System Audio Recording.

The app is sandboxed with the hardened runtime in Release. Entitlements are in `Config/Morph.entitlements`. Two scoped sandbox exceptions exist for HUD replacement: `com.apple.backlightd` (brightness) and `com.apple.universalaccessAuthWarn` (the Accessibility check).

## Architecture

```text
Morph/
├── App/               Composition root, lifecycle, status item
├── Core/              Scheduling, preferences, observation helper
├── Models/            Activities, media, battery, quick actions
├── WindowManagement/  Geometry, display choice, NSPanel, window controller
├── UI/
│   ├── DesignSystem/  Color, type, spacing and motion tokens
│   ├── Components/    Shared controls
│   └── Island/        State machine, layout, controller, views
├── Services/          Activities, Audio, Battery, Files, Focus, Input, LiveActivities,
│                      Media, Screenshots, System, Timers
├── Settings/          Settings window and sections
└── Resources/
MorphTests/            Unit and real-window integration tests
docs/                  Local API documentation and examples
Config/                Build settings, Info.plist, entitlements
```

The logic with the most edge cases is in plain value types with no UI or timers, which is what makes it testable: `IslandStateMachine`, `ActivityQueue`, `WaveCaptureMachine`, `PomodoroSession`, `ScreenshotDetector`, `LiveActivityPayload`, `BatteryTransitionDetector`, `CountdownTimer`, `Stopwatch`, `NotchGeometry`, `DisplaySelector` and `IslandLayout`. All delays go through the `Scheduling` protocol, so tests run on a manual clock.

Key decisions:

- **The panel is cropped, not resized.** SwiftUI lives on a fixed canvas that never changes size, and the `NSPanel` frame only decides how much of it shows. The island can therefore morph with no window-driven layout passes. The window grows before an expansion and shrinks after a contraction has landed.
- **No polling at rest.** The panel at idle is the size of the notch, so a plain `NSTrackingArea` is enough to notice the pointer. Battery uses IOKit's power source notification. Players are followed through their own distributed notifications. Timers are computed from `ContinuousClock` instants, and `TimelineView` ticks only while a countdown or playback is actually on screen.
- **Click-through.** The panel matches the island, so nothing invisible blocks the desktop. For the same reason the island has no drop shadow: a soft shadow needs a transparent margin, and that margin would swallow clicks. Only the small transparent corners of the island's bounding rectangle still catch clicks.
- **Half-point centering.** AppKit rounds window origins to whole points, but the notch can start on a half point. `NotchGeometry.panelFrame` pads the width to keep a whole-point origin on the notch's exact center.

## Media: what's actually supported

There is no public macOS API for system-wide Now Playing. `MediaRemote` is private, so Morph doesn't use it and only the two players below are supported.

| Player | Mechanism |
| --- | --- |
| Apple Music | AppleScript dictionary, plus the `com.apple.Music.playerInfo` distributed notification |
| Spotify | Its documented AppleScript dictionary, plus `com.spotify.client.PlaybackStateChanged` |

- **The notification names are not formally documented by Apple or Spotify.** They are long-standing, and Morph uses them only as a hint to re-read state, so if one disappears playback data still refreshes when the panel opens.
- **MusicKit** isn't used: on macOS it can't observe or control what the Music app is playing.
- **Spotify OAuth** isn't implemented because local scripting already covers track, artwork, progress and transport controls.

## System integration: what's actually possible

| Feature | Mechanism | Real limit |
| --- | --- | --- |
| Waveform | Core Audio process tap on the player only, with an explicit state machine: `idle`, `requestingPermission`, `starting`, `capturing`, `recovering`, `unavailable`, `stopped`. FFT, RMS, band energy and transients with Accelerate off the main thread, at most 30 UI updates per second | macOS 14.2 or later. The tap runs only while the bars are on screen and music plays. Buffers arriving means the capture is alive, so silence never causes a restart. No buffers for 4 seconds means recovery, with backoff from 0.5 to 30 seconds and at most 6 attempts in a row. macOS doesn't report a denied permission: 20 seconds of pure silence from a capture that has never heard sound counts as that, and it waits for the next track. With Reduce Motion the static icon shows and nothing is captured. Settings → Music has live diagnostics. |
| Output volume | Core Audio listeners on the default output, moved when the output changes | HDMI and some USB devices have no software volume, so they show no percentage and no slider. |
| Brightness | Brightness keys, read from `systemDefined` events | **No percentage on Apple silicon without Replace.** `IODisplayGetFloatParameter` has no service there and no other public API exists, so the island shows direction only. Replace reads the real level through the private DisplayServices, built-in display only. External monitors are never assumed to work. Control Center's slider and automatic brightness can't be detected. |
| Screenshots | A directory event on one folder you chose, then the file's `kMDItemIsScreenCapture` attribute, which works in any language and filename format | macOS won't tell a sandboxed app where it saves, so you choose the folder. With the floating thumbnail on, macOS writes the file seconds after the capture. Clipboard captures create no file. Previews end when the screen locks. Morph takes no captures itself, so ScreenCaptureKit isn't used. |
| Seeking | The player's own `player position` | Sent once, at the end of a drag. Tracks without a duration can't seek, and the bar is inactive for them. |
| macOS Focus | Not read | `INFocusStatusCenter` is public, but it reports only one yes or no, needs a user prompt and a Communication Notifications entitlement that doesn't suit a build you can copy to another Mac. Morph Focus is separate, doesn't reflect the system's, and only quiets the island. |
| Peripheral batteries | `IOPowerSources`, then the `BatteryPercent` IORegistry property that Apple's keyboards, mice and trackpads publish. Needs no Bluetooth permission | IOKit is public, but that property is undocumented and could change. Other accessories show only as connected if macOS has no value. Read when a device connects, while the Battery tab is open, or every few minutes for alerts. |
| Live Activities API | HTTP on `127.0.0.1` with a Keychain token, off by default | Local only. See [the API documentation](docs/LIVE_ACTIVITIES_API.md). |

| Replacing the macOS HUDs | Off by default. An active tap on its own thread applies the change, reads it back, and only then swallows the key. If the change fails, the key goes to macOS and that output or display stays with macOS until the hardware changes | No API hides the native HUD, so it stays hidden only because the key never reaches macOS. Brightness uses the private DisplayServices framework, built-in display only, and could break in a macOS update. Option or Command/Control with a key, outputs without software volume, cinema, pause, lock and sleep all stay with macOS. Keys that send F14/F15 aren't handled. It works in the sandbox: a real key posted through the window server was swallowed, and the same key without the tap changed the volume. |
| AirPods and Bluetooth audio | A Bluetooth output appears in Core Audio while connected, so no Bluetooth permission is needed | Battery is shown only if `IOPowerSources` lists that exact device. AirPods usually aren't listed. `system_profiler` returns nothing inside the sandbox, even with the Bluetooth entitlement. |
| Cinema mode | Window geometry on Space, app and screen changes, with follow-up checks | macOS has no public "is full screen" for other apps. Below a notch, a full screen window is recognized by leaving the usable area. With no Dock on the display, that looks like a maximized window, and the "unclear" preference decides. |
| Gestures | Scroll events delivered to the island's own window | Two fingers only. Three- and four-finger swipes belong to the system. |

System output volume changes aren't reported while the panel is open, because its slider already shows them. The mute button and slider act on the real output, and on outputs without software volume the player's own volume slider appears instead.

## Lock Screen (3.0)

Morph follows lock, unlock, sleep and fast user switching through public notifications (`NSWorkspace` session, sleep and display notifications) and the long-standing `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed notifications, cross-checked with `CGSessionCopyCurrentDictionary`. `LockScreenCoordinator` owns one testable state machine (`active`, `locking`, `locked`, `unlocking`, `suspended`, `unknown`). A dark display alone is never taken as a lock.

- **On lock:** private activities (screenshots, Live API activities, now playing, files) are dropped, the panel and any drag end, the island collapses to the notch, audio capture stops, volume and brightness keys go back to macOS, and the panel leaves the screen once the lock settles.
- **On unlock:** the window returns on the right display with fresh notch geometry, services resynchronize, activities that are still current come back, and the Welcome Island greets once per unlock (time-of-day greeting in the system language, time, battery, music if playing). Waking without a password, changing displays or returning while the island is busy doesn't welcome.
- **Music:** keeps playing in Apple Music or Spotify. Morph doesn't pause it and doesn't capture audio while locked.
- **Notifications:** timer and focus notifications are scheduled ahead with `UserNotifications`, so macOS delivers them while locked. Battery, device and activity notifications are only sent when the island can't show them, are rate-limited, and name nothing unless *Allow Sensitive Previews* is on.

Settings: **Lock Screen** and **Notifications** sections. Notification permission is asked when a notification switch is turned on; a denied permission is never asked again from Morph, only changed in System Settings › Notifications.

### Limitations

- **No public API lets an app draw over the macOS lock screen.** Morph shows nothing while locked, including no music player. The lock screen's own Now Playing controls come from macOS.
- Whether notifications appear on the lock screen, and with previews, is decided by macOS and the user's Notification settings.
- The lock animation is only visible if macOS still draws apps when the lock begins; usually the lock screen covers it at once.
- `com.apple.screenIsLocked` and the `CGSSessionScreenIsLocked` key are long-standing but undocumented. If they stop working, Morph treats the session as unlocked rather than guessing.
- No calendar integration, so the welcome never shows appointments.

### Manual tests (not yet run on hardware)

Lock with Control-Command-Q; unlock with password and with Touch ID; play music through a lock; let a timer end while locked (with *Notify When Timer Ends* on); sleep and wake; switch users and back; several quick lock/unlock cycles; MacBook with an external display. After each unlock, press the volume keys and confirm 5% steps with Morph's HUD. **Settings › Advanced › Diagnostics** shows the session state and return count.

## Transfers, AirDrop and Continuity (3.1)

- **Transfers:** one `TransferManager` for downloads, uploads and AirDrop (`pending`, `transferring`, `paused`, `completed`, `failed`, `cancelled`, `unknown`), with bytes, a known total, measured speed and remaining time. Percentages appear only when the total is known. Updates reach the island at most twice a second and group into one activity, so several transfers don't make the island bounce. A panel tab lists active and recent transfers; history is memory-only and its duration is configurable.
- **Downloads:** only through a folder you choose (Settings › Transfers). Browser partial files mean "in progress"; a finished file counts only with a fresh quarantine marker, so copied or saved files aren't called downloads.
- **Uploads:** reported by scripts or apps to `/v1/transfers` on the existing local API (still off by default). Morph can't see other apps' traffic.
- **AirDrop:** send from the Shelf with macOS's own picker. Received files are recognized by their quarantine agent (`sharingd`) once they've arrived. The ring fills with real progress when there is any and turns slowly when there isn't, then becomes a checkmark.
- **iPhone Continuity:** there's no public API for reading other apps' Live Activities, mirrored or not. Morph shows activities from **Morph Companion** (`Companion/MorphCompanion.xcodeproj`, iOS 17+) paired by QR code, with end-to-end encryption over the local network, revocation, expiry and rate limits.

Details, the API and examples in curl, Python and Swift: [docs/TRANSFERS_AND_CONTINUITY.md](docs/TRANSFERS_AND_CONTINUITY.md).

### Installing Morph Companion

Open `Companion/MorphCompanion.xcodeproj` in Xcode, choose your team under Signing (a free Apple ID works for your own iPhone), connect the iPhone and run. Then on the Mac: Settings › Continuity › Enable iPhone Sync › Pair iPhone…, and scan the code with the iPhone's Camera. Both devices must be on the same network.

### Manual tests (not yet run on hardware)

A real download in Safari, Chrome and Firefox into the watched folder; an upload reported by a script; AirDrop sending from the Shelf and receiving a file from an iPhone; pairing the Companion on a real iPhone, reconnecting after Wi-Fi drops, revoking it; activities with a countdown; lock and unlock during a transfer. Automated tests simulate these; they don't replace them.

## Not implemented

- AirPods battery beyond the above: no public API, and no private ones are used. Left and right earbuds and the case are never shown separately.
- Screenshots taken by Morph itself, and screenshot history.
- Reading or changing macOS Focus.
- Other players, browsers: see above.

## Activity priorities

Highest first. A higher priority interrupts a lower one, and the same kind of event updates in place rather than stacking up.

1. Battery alerts
2. Answers to a gesture or command
3. Volume and brightness
4. Screenshots
5. Device changes, then timers and focus sessions
6. Live Activities from other apps
7. Battery and music events
8. Decorative

While you drag a slider, only a critical alert can appear. What waited appears when you let go. While a focus session or Morph Focus is on, anything below timers stays out of the island.

## How to test the new features

- **Screenshots:** in Settings → Screenshots, turn on previews and choose the folder shown under Options in Command-Shift-5. Take a screenshot, then try each action and drag the thumbnail into another app.
- **Focus:** open the Focus tab and start a session, with short durations from Settings → Focus. Quit and reopen Morph mid-session.
- **API:** turn it on in Settings → Activities, copy the token, and run the [examples](docs/examples).
- **Battery:** open the Battery tab with a Bluetooth keyboard, mouse or AirPods connected.

- **Volume:** in Settings → System, turn on Show Volume HUD, then Replace macOS Volume HUD, and grant Accessibility. Press the volume keys and mute: one HUD should appear, with no macOS indicator.
- **Waveform:** play music in Apple Music and allow audio capture when macOS asks. Try songs with heavy bass and sparse vocals: the center bars follow the low end and the edges follow the highs. Pause, and the bars settle and stay still before the island returns to rest.
- **Brightness:** do the same with the Brightness options, then press the brightness keys. Without Replace, the HUD shows direction only, alongside the macOS indicator.
- **AirPods:** connect and disconnect them, then switch outputs in Control Center.
- **Cinema:** make a video full screen in Safari, then leave. Compact and Hidden behave as selected in Settings → System.
- **Gestures:** with the pointer on the island and music playing, swipe two fingers left and right, then up and down.

## Verification status

Morph 2.3, on a MacBook Air M5 with macOS 27.2 and Xcode 27.2. The suite runs under the real sandbox, including the real `NSPanel`, real `NSEvent`s through it, the FFT against synthesized tones, and every Settings screen in a real window.

Proven automatically:

- **HUD replacement:** with Accessibility granted, a sandboxed app holds the active tap. A real volume key posted through the window server reached it and was swallowed with the volume unchanged. The same kind of key without the tap moved the volume from 50% to 44%.
- **Live API:** create, update and end over a real socket, under the sandbox, from outside clients using the curl, Python and Swift examples. The server refused connections on the Mac's LAN address.
- **Screenshots:** real files, the real directory watcher and the real attribute, including the lock rules. The attribute was confirmed on real screenshots from this Mac.
- **Keychain:** storing, replacing and deleting a throwaway token.

### Manual tests still required

These need a person, a physical device or a screen capture that the development environment can't do:

- [ ] **Morph 2.3 running as the installed app.** Every check above ran in the test host, not in a launched Release copy
- [ ] **Waveform with real music**, including the audio capture prompt, Spotify, Apple Music, pausing, changing output and sleep: the recovery rules are tested against a simulated capture, and real capture has never run against a playing track
- [ ] **HUD replacement with physical keys,** on the built-in and external keyboards, watching that the macOS indicator stays hidden, and with speakers, AirPods and HDMI
- [ ] **A real screenshot** through Command-Shift-5, each action on the preview, and dragging into another app. The file watcher was tested with files marked the same way
- [ ] The local API from the installed app, including creating the Keychain token
- [ ] Focus notifications, and a session across quitting Morph
- [ ] Battery tab with real Bluetooth peripherals: the development Mac had none connected
- [ ] Seeking with real players, and the moving light on real covers
- [ ] Revoking Accessibility and force-quitting Morph while keys are held: macOS should get them back
- [ ] Sleep and wake, output changes and Reduce Motion with the HUD
- [ ] Animation quality on real hardware: the new HUD was checked as still frames, not in motion
- [ ] **Cinema mode on a real full screen window**
- [ ] AirPods: connect, disconnect and change output
- [ ] Trackpad gestures with real fingers, and a real mouse wheel
- [ ] Idle shape against the camera housing, with no seam
- [ ] A physical click doesn't take focus from the active app
- [ ] Allow Access, then track, artwork, play/pause, next and previous in Apple Music
- [ ] File drag in and out, Quick Look
- [ ] Power changes, a timer finishing, low battery alerts
- [ ] Launch at login, notifications, menu bar actions, right-click menu
- [ ] Display changes, Spaces
- [ ] VoiceOver, and Tab navigation (needs Full Keyboard Access)
