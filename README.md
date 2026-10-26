# Longarm

**Your Mac, from your phone.** Longarm shows your Mac's screen live on an Android phone and turns
the phone's touches, keys and voice into the Mac's mouse and keyboard. A small menu bar app on the
Mac, an Android app on the phone, paired with a QR code, talking directly over your network.

<img src="mac/icon/AppIcon-1024.png" width="128" alt="Longarm icon: a fingertip on a phone reaching across to a Mac pointer">

## What it does

- **Live screen:** the whole Mac display at up to 60 fps, hardware H.264 on both ends (usually
  1–3 KB a frame), full screen and landscape on the phone. Pinch to zoom, drag to look around.
- **Touch is the mouse:**

  | On the phone | On the Mac |
  |---|---|
  | Tap (quick or slow) | click |
  | Tap twice | double-click |
  | Two-finger tap | right-click there |
  | **R** button | right-click where the Mac's pointer is |
  | Long-press, then drag | click-and-drag (select text, move windows) |
  | One-finger drag | scroll (moves the view instead when zoomed in) |
  | Two fingers moving together | scroll |
  | Pinch | zoom the picture |
  | Three fingers up / down / sideways | Mission Control / app windows / next Space |

- **Keyboard:** a see-through keyboard over the picture (drag it up or down, adjust its blur),
  keys sent as you tap with a buzz and a flash. ⌘ ⌥ ⌃ ⇧ on the side turn the next key into a
  shortcut; buttons for ⌘+ / ⌘− / ⌘0, esc, tab, arrows, ⌘⇥, ⌘␣, Mission Control, Spaces and
  leaving full screen.
- **Dictation:** 🎤 on the keyboard streams the phone's microphone to the Mac, which runs it
  through a speech-to-text service (Deepgram); the words collect in a box on the keyboard and ↵
  types them on the Mac.

## At home or over the internet

You choose how the phone connects, on both ends; it never falls back from one to the other.

- **At home:** phone and Mac on the same Wi-Fi (or USB with `adb reverse`). Switched on in the
  Mac's menu under *Connect from → Home Wi-Fi*, and picked on the phone with **At home**.
- **Over the internet:** through [Tailscale](https://tailscale.com), a free private network
  between your own devices, so the Mac is never open to the whole internet. Install it on the
  Mac and the phone, signed in to the same account. On the Mac, turn on *Connect from → Internet,
  over Tailscale* and choose a **join code** (6–12 digits). On the phone, pick **Over the
  internet**; it asks for the code each time you open remote control. Off Wi-Fi, the picture
  drops to 30 fps and a lower resolution to spare your data.

The phone learns the Mac's Tailscale address once it connects at home (or from a fresh pairing
code). To try internet connections without Tailscale, point them at another address with
`defaults write dev.longarm.mac internetHost <address>`.

## Safety

- Remote control is **off until you allow it** in the Mac's menu (Allow Remote Control).
- Only a phone that scanned the Mac's QR code can connect: a random token, and the phone pins the
  Mac's self-signed TLS certificate. Reset Pairing in the menu revokes every phone.
- Over the internet, the phone also needs the join code. The Mac keeps only a salted PBKDF2 hash
  of it in the Keychain; five wrong codes in a row lock internet joins for 15 minutes. The internet
  listener runs only on the Tailscale address, and the home one turns away Tailscale connections.
- While a phone is in control, the Mac's menu bar shows an orange **Remote** (Stop is in its
  menu), and a notice appears on screen when it starts.
- It stops when the phone disconnects and after 10 minutes without input. The Mac's display and
  the phone's screen stay awake only while it's on.

## Build and run

Requirements: macOS 15 or later on Apple silicon (Xcode command line tools for `swiftc`), an
Android 8+ phone, and Android Studio (or a JDK 17 with the Android SDK).

**Mac**

```bash
mac/build.sh --run
```

Builds `mac/build/Longarm.app` and opens it in the menu bar. On first use macOS asks for:

- **Accessibility** (System Settings → Privacy & Security → Accessibility → Longarm): to click
  and type for the phone.
- **Screen & System Audio Recording**: to show the screen. macOS may ask you to quit and reopen.

The build is signed with your Apple Development identity if you have one, so these permissions
survive rebuilds (set `LONGARM_SIGN_IDENTITY` to choose; ad-hoc signing works but asks again on
every build). For dictation, add a Deepgram API key from the menu; it's kept in your Keychain.

**Phone**

```bash
android/deploy.sh
```

Builds and installs over `adb` (USB or Wireless debugging), or open `android/` in Android Studio.
Then on the Mac choose **Pair a Phone…**, scan the code with the app, allow remote control in
the Mac's menu, and tap **Control your Mac**.

## How it works

```
Phone (Kotlin, Compose)                          Mac (Swift, menu bar)
  RemoteUi  — gestures, keyboard ──JSON──▶  LinkServer ─▶ RemoteControl ─▶ InputInjector (CGEvent)
  VideoDecoder (MediaCodec) ◀── H.264 ────  ScreenShare ◀ ScreenCapture (ScreenCaptureKit)
                                                          ◀ VideoEncoder (VideoToolbox)
  PhoneMic ──────────── PCM ────────────▶  PhoneDictation ─▶ SpeechEngine (Deepgram)
```

One TLS WebSocket (port 47900 at home, found over Bonjour as `_longarm._tcp`; 47901 on the
Tailscale address) carries JSON messages and
binary frames; the full list is at the top of `mac/Sources/RemoteControl.swift`. Video keeps the
latency low: the encoder never reorders frames, a busy link skips ahead to the next key frame
instead of queueing, and a still screen is re-sent a few times so text sharpens.

The parts are behind small interfaces so they can be swapped: `InputInjector` (how input is
delivered), `StreamingTranscriber` / `SpeechEngine` (speech-to-text).

## Roadmap

- An AI agent on the phone that operates the Mac through named actions ("open Terminal and run…"),
  with screen reading for the rest.

## License

MIT, see [LICENSE](LICENSE).
