# 30nama native app for Apple TV (tvOS)

An Apple TV app: an unofficial client for 30nama.com. It is a native SwiftUI port of [30nama-tizenos](https://github.com/msharifi99/30nama-tizenos), with the same screens, design and behaviour.

> **Disclaimer:** This is an unofficial, community project. It is not affiliated with, endorsed by, or supported by 30nama. You need your own valid 30nama subscription to use it. No content is bundled with this app.

## Acknowledgements

This app builds directly on [**30nama-tizenos**](https://github.com/msharifi99/30nama-tizenos) by [Rebin Sharifi (@msharifi99)](https://github.com/msharifi99). That project worked out the 30nama API (endpoint discovery, host and key probing, QR sign-in, streams, progress reporting) and the "One Stage" TV design. It also built the TMDB enrichment. The tvOS version follows its architecture and design spec closely. Thank you for the initial contribution.

## Features

- Sign in by scanning a QR code with your phone, or continue as a guest
- TV UI:
  - a backdrop that crossfades and slowly drifts behind every screen
  - billboard, hero carousel, rows, Top 10 and continue watching
  - details, search, archive and settings screens
- An icon rail that expands when focused. Back from a top-level screen opens it, and Back in the rail asks before exiting.
- HLS playback at the highest available quality, with resume and progress reporting to 30nama
- Player controls:
  - progress bar with a time bubble while seeking
  - skip intro and skip recap
  - Up Next card with an autoplay countdown
  - audio and subtitle sheet, and an episodes sheet
- Persian (fa) and English (en) subtitles, with adjustable size
- Persian UI with full right-to-left layout and Persian digits
- Optional TMDB enrichment: trending rows, title logos, cast and crew, reviews and recommendations

## Requirements

| What | Version |
|---|---|
| Mac | macOS with Xcode 15 or later (tvOS 17 SDK or later) |
| Apple TV | Apple TV HD or Apple TV 4K on tvOS 17 or later |
| Apple ID | Any Apple ID. A free one works, but the app expires after 7 days (see below). |
| Optional | [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), only needed to regenerate the Xcode project |

## Compile

1. Get the source and open the project:
   ```bash
   cd 30nama-tvos
   open Nama30TV.xcodeproj
   ```
   The Xcode project is generated from `project.yml`. If you change `project.yml` or add files, regenerate it:
   ```bash
   xcodegen generate
   ```
2. Optional: [set up TMDB](#optional-tmdb-setup).
3. Build from Xcode with **Product > Build** (⌘B), or from the command line without signing:
   ```bash
   xcodebuild -project Nama30TV.xcodeproj -scheme Nama30TV -sdk appletvsimulator -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO build
   ```

### Run in the simulator

1. Install the tvOS simulator once (about 3.8 GB). In Xcode use **Settings > Components**, or run:
   ```bash
   xcodebuild -downloadPlatform tvOS
   ```
2. In Xcode choose an **Apple TV** simulator as the run destination and press **Run** (⌘R).
3. The keyboard arrows, Return (Select) and Escape (Back/Menu) control the app. You can also use the on-screen remote under **Window > Show Apple TV Remote**.

## Install on an Apple TV

### 1. Signing

1. In Xcode go to **Settings > Accounts** and add your Apple ID.
2. Select the **Nama30TV** project, then the **Nama30TV** target, then **Signing & Capabilities**.
3. Leave **Automatically manage signing** on and pick your **Team**.
4. If Xcode says the bundle identifier is taken, change `com.nama30.tv` to something unique, such as `com.yourname.30nama`. You can also set `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` and regenerate.

You can also set the team without opening Xcode's UI: add `DEVELOPMENT_TEAM = ABCDE12345` to `Config/Secrets.xcconfig` (see `Config/Secrets.example.xcconfig`).

### 2. Pair the Apple TV with Xcode

The Mac and the Apple TV must be on the same network.

1. On the Apple TV open **Settings > Remotes and Devices > Remote App and Devices**. Stay on this screen.
2. In Xcode open **Window > Devices and Simulators** (⇧⌘2).
3. The Apple TV appears under **Discovered**. Click **Pair** and enter the code shown on the TV.
4. Wait for Xcode to finish preparing the device. The first time can take a few minutes.

### 3. Turn on Developer Mode (tvOS 16 and later)

After the first install attempt, open **Settings > Privacy & Security > Developer Mode** on the Apple TV, turn it on and restart when asked.

### 4. Run

1. In Xcode choose your Apple TV as the run destination.
2. Press **Run** (⌘R). Xcode builds, installs and launches **30nama** on the TV.
3. The app stays on the Home Screen, so you can launch it later without Xcode.

### Free Apple ID vs paid developer account

- **Free Apple ID:** the app expires after **7 days**. Connect the Apple TV to Xcode and press Run again to renew it. Your settings and sign-in are kept.
- **Paid Apple Developer Program:** the app is valid for a year.

### Alternative: sideloading tools

You can also export a signed build (**Product > Archive**, then **Distribute App > Custom > Release Testing** or **Development**). A paid account can share it with others through TestFlight. Sideloading tools that support tvOS can install an `.ipa` signed with your own certificate.

## Remote

| Siri Remote | Action |
|---|---|
| Clickpad / swipe | Move focus. In the player: ◀ ▶ seek ±10 s (presses add up), ▲ audio & subtitles, ▼ episodes |
| Select | OK. In the player: play/pause, or skip intro while the pill shows, or confirm Up Next |
| Play/Pause | Play/pause |
| Back (Menu) | Back: closes sheets, then goes to the previous screen, then the rail, then the exit confirm |

## Optional: TMDB setup

This app uses TMDB to add trending rows, cast, reviews and recommendations. It is off by default, and the app works fully without it.

1. Create a free account at themoviedb.org and copy your **API Read Access Token** (v4) from Settings, API.
2. Copy the example file (the copy is git-ignored):
   ```bash
   cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
   ```
3. Open `Config/Secrets.xcconfig` and paste the token after `TMDB_TOKEN = `.
4. Rebuild and reinstall. **Settings > About** shows "TMDB metadata: Connected" and offers "Clear metadata cache".

Mock mode serves the bundled fixtures in `Resources/Fixtures`, while 30nama itself is still called live. To use it, add the launch argument `-tmdbMock 1` under **Product > Scheme > Edit Scheme > Run > Arguments**.

## Troubleshooting

- **"Untrusted Developer" or the app won't open:** turn on Developer Mode (step 3), then try again.
- **The Apple TV isn't listed in Xcode:** keep the TV on the *Remote App and Devices* screen and check both devices are on the same network. Restarting Xcode and the TV also helps.
- **The app disappeared after a week:** a free Apple ID signature expired. Run it from Xcode again.
- **"No endpoint reachable" on launch:** the API hosts could not be reached from your network. Press Retry. The app tries the discovery URLs and then the fallback hosts.
- **Playback says "Sign in to watch":** streaming needs a signed-in 30nama subscription. Sign in by QR from Settings > Account.

## Structure

```
Sources/App/        entry point, root view (screen stack, Back handling), icon rail, splash, confirm sheet, toast
Sources/Core/       JSON helpers, config + storage, i18n, API (discovery, host/key probing, session), TMDB, app state/router
Sources/UI/         theme tokens + fonts, stage (backdrop), focus-aware buttons, cards, meta line, episode tiles
Sources/Screens/    login (QR), home, details (+ episodes, TMDB extras, review reader), search, archive, settings
Sources/Player/     AVPlayer controller (subtitles, skip, Up Next, progress reporting) and the player controls view
Resources/          Vazirmatn fonts, app icon and Top Shelf assets, TMDB fixtures
Config/             build settings; Secrets.xcconfig (git-ignored) holds the optional TMDB token and team
tools/              make-icons.swift (regenerates the app icon and Top Shelf images: swift tools/make-icons.swift)
project.yml         XcodeGen spec for Nama30TV.xcodeproj
```

## Differences from the Tizen app

- Navigation uses the tvOS focus engine instead of a custom spatial navigator. Rows still line up at the left edge, and the billboard still follows focus.
- The 🎤 key on the search keyboard opens the system keyboard, which also offers dictation.
- Exit confirm sends the app to the background, because tvOS apps are not terminated.

## License

Released under the [MIT License](LICENSE), keeping the original copyright of [30nama-tizenos](https://github.com/msharifi99/30nama-tizenos). The Vazirmatn font in `Resources/Fonts/` is licensed under the SIL Open Font License (see `Resources/Fonts/OFL.txt`).
