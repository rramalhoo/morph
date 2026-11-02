# morph.

**Your Mac. More alive.**

Morph is a native macOS utility that turns the MacBook camera notch into a fluid, interactive Dynamic Island: hover and click it for now playing, battery, timers, quick actions and a file shelf, while short activities such as charging or a finished timer appear on their own.

Swift 6, SwiftUI and AppKit. No third-party dependencies, no private frameworks. macOS 14 or later.

## Build and run

```bash
# Optional: sign with your own identity so macOS privacy grants survive rebuilds
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then set DEVELOPMENT_TEAM

xcodebuild -project Morph.xcodeproj -scheme Morph -configuration Release \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/Morph.app
```

Or open `Morph.xcodeproj` in Xcode and run the **Morph** scheme. Without `Local.xcconfig` the build is ad-hoc signed, which works, but macOS will ask for permissions again after each rebuild.

Run the tests:

```bash
xcodebuild test -project Morph.xcodeproj -scheme Morph \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData
```

The window tests open the real overlay panel on your screens for a few seconds. To write every island state out as PNG for design review, add `TEST_RUNNER_MORPH_SNAPSHOT_DIR=/some/dir` and, because the sandboxed host can't write there, `CODE_SIGN_ENTITLEMENTS= ENABLE_APP_SANDBOX=NO`.

## Using it

| Gesture | Result |
| --- | --- |
| Point at the notch | The island grows slightly and shows the most relevant thing |
| Click the island | Opens the panel: Home, Timers, File Shelf |
| Click an alert | Dismisses it |
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
| Accessibility | Only for Replace macOS Volume/Brightness HUD: an active event tap limited to `NX_SYSDEFINED` events, so it never sees typing | When you turn a Replace option on |

Showing volume and brightness, audio device connections and cinema mode need no permission. Audio is analyzed in memory and discarded: nothing is recorded, saved or sent, and the microphone isn't used. macOS doesn't tell apps whether audio capture was granted, so a denial appears in Settings → Music as "no audio received". To change it later, use System Settings → Privacy & Security → Screen & System Audio Recording.

The app is sandboxed with the hardened runtime in Release. Entitlements are in `Config/Morph.entitlements`. It holds no credentials and stores no tokens. Two scoped sandbox exceptions exist for HUD replacement: `com.apple.backlightd` (brightness) and `com.apple.universalaccessAuthWarn` (the Accessibility check).

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
├── Services/          Activities, Battery, Media, Files, Timers, System
├── Settings/          Settings window and sections
└── Resources/
MorphTests/            Unit and real-window integration tests
Config/                Build settings, Info.plist, entitlements
```

The logic with the most edge cases is in plain value types with no UI or timers, which is what makes it testable: `IslandStateMachine`, `ActivityQueue`, `BatteryTransitionDetector`, `CountdownTimer`, `Stopwatch`, `NotchGeometry`, `DisplaySelector` and `IslandLayout`. All delays go through the `Scheduling` protocol, so tests run on a manual clock.

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
| Waveform | Core Audio process tap on the player only, FFT with Accelerate off the main thread, at most 30 UI updates per second | macOS 14.2 or later. The tap runs only while the bars are on screen and music plays. If only silence arrives, it stops, and the static icon returns until the next track. |
| Output volume | Core Audio listeners on the default output, moved when the output changes | HDMI and some USB devices have no software volume, so they show no percentage and no slider. |
| Brightness | Brightness keys, read from `systemDefined` events | **No percentage on Apple silicon.** `IODisplayGetFloatParameter` has no service there, and the registry's brightness values didn't change when brightness did, so the island shows direction only. Control Center's slider and automatic brightness can't be detected. |
| Replacing the macOS HUDs | Off by default. An active tap on its own thread applies the change, reads it back, and only then swallows the key. If the change fails, the key goes to macOS and that output or display stays with macOS until the hardware changes | No API hides the native HUD, so it stays hidden only because the key never reaches macOS. Brightness uses the private DisplayServices framework, built-in display only, and could break in a macOS update. Option or Command/Control with a key, outputs without software volume, cinema, pause, lock and sleep all stay with macOS. Keys that send F14/F15 aren't handled. Whether a sandboxed app may hold an active tap after Accessibility is granted is not yet confirmed. If it can't, Settings shows that macOS refused the tap and the keys keep working natively. |
| AirPods and Bluetooth audio | A Bluetooth output appears in Core Audio while connected, so no Bluetooth permission is needed | Battery is shown only if `IOPowerSources` lists that exact device. AirPods usually aren't listed. `system_profiler` returns nothing inside the sandbox, even with the Bluetooth entitlement. |
| Cinema mode | Window geometry on Space, app and screen changes, with follow-up checks | macOS has no public "is full screen" for other apps. Below a notch, a full screen window is recognized by leaving the usable area. With no Dock on the display, that looks like a maximized window, and the "unclear" preference decides. |
| Gestures | Scroll events delivered to the island's own window | Two fingers only. Three- and four-finger swipes belong to the system. |

System output volume changes aren't reported while the panel is open, because its slider already shows them. The mute button and slider act on the real output, and on outputs without software volume the player's own volume slider appears instead.

## Not implemented

- AirPods battery beyond the above: no public API, and no private ones are used.
- Other players, browsers: see above.

## How to test the new features

- **Volume:** in Settings → System, turn on Show Volume HUD, then Replace macOS Volume HUD, and grant Accessibility. Press the volume keys and mute: one HUD should appear, with no macOS indicator.
- **Waveform:** play music in Apple Music and allow audio capture when macOS asks. Try songs with heavy bass and sparse vocals: the center bars follow the low end and the edges follow the highs. Pause, and the bars settle and stay still before the island returns to rest.
- **Brightness:** do the same with the Brightness options, then press the brightness keys. Without Replace, the HUD shows direction only, alongside the macOS indicator.
- **AirPods:** connect and disconnect them, then switch outputs in Control Center.
- **Cinema:** make a video full screen in Safari, then leave. Compact and Hidden behave as selected in Settings → System.
- **Gestures:** with the pointer on the island and music playing, swipe two fingers left and right, then up and down.

## Verification status

Automated on a MacBook Air M5 with macOS 27.2 and Xcode 27.2: the suite runs under the real sandbox, including the real `NSPanel`, real `NSEvent`s through it, the FFT against synthesized tones, and every Settings screen in a real window. Tests that need key focus are skipped while the session is locked, and the one that needs real focus reports a known issue when another app is holding it.

Checked against the running Release app:

- Hover: moving the real cursor onto the notch grows the window from 180×32 to 320×68, and leaving collapses it, with no flicker. The cursor was warped, which isn't identical to a physical mouse.
- Volume: ten rapid system volume changes took the window from 260×33 to 324×49 once, with no intermediate size. It closed about 1.9 s after the last change.
- Key handling: the real engine changed real volume, mute and brightness under the sandbox in 6–18 ms per key, confirmed by read-back. These were simulated presses passed to the engine, not physical keys through a tap.
- Opening Morph a second time brings up Settings, with one instance running.
- Battery against `pmset`, the Apple Music status script against the Music app, real Core Audio output reading, the Automation probe and tap creation under the sandbox.

### Manual tests still required

The development environment can't capture the screen or post system-wide events, and the session was locked during the last checks:

- [ ] **Waveform with real music**, including the audio capture prompt: real capture has never run against a playing track
- [ ] **Cinema mode on a real full screen window.** The detector is built from a real measurement, but the Mac locked before the fix could be confirmed end to end
- [ ] **HUD replacement with physical keys:** the sandboxed active tap after granting Accessibility, and the macOS indicator staying hidden, on the built-in and external keyboards, speakers and AirPods
- [ ] Revoking Accessibility and force-quitting Morph while keys are held: macOS should get them back
- [ ] Sleep and wake, output changes and Reduce Motion with the HUD
- [ ] AirPods: connect, disconnect and change output
- [ ] Trackpad gestures with real fingers, and a real mouse wheel
- [ ] Idle shape against the camera housing, with no seam
- [ ] Animation quality, and Reduce Motion
- [ ] A physical click doesn't take focus from the active app
- [ ] Allow Access, then track, artwork, play/pause, next, previous and seek in Apple Music
- [ ] Spotify, which isn't installed on the development Mac
- [ ] File drag in and out, Quick Look
- [ ] Power changes, a timer finishing, low battery alerts
- [ ] Launch at login, notifications, menu bar actions, right-click menu
- [ ] Display changes, Spaces, sleep and wake
- [ ] VoiceOver, and Tab navigation (needs Full Keyboard Access)
