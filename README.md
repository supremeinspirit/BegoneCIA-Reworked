# BegoneCIA Reworked

Control Center toggle that blocks microphone, camera and location system-wide, with a settings pane:

- **Excluded apps**: pick apps that are left alone.
- **Pause during calls**: one switch for phone and call apps (WhatsApp and the like), one for FaceTime. Blocking stops while a call rings or runs and resumes afterwards. Both are off by default, so BegoneCIA stays active during calls until you switch them on.

Based on BegoneCIA by Nepeta and its rootless port by John d_ie. The tweak was rewritten for this version; the blocking hooks are the same as in the rootless port 1.0.0.

## Install

Add the source `https://supremeinspirit.github.io/supremeinspirit/` in Sileo or Zebra, or take a `.deb` from the [releases](https://github.com/supremeinspirit/BegoneCIA-Reworked/releases).

| File | For | Needs |
| --- | --- | --- |
| `BegoneCIAReworked_…_rootless_iphoneos-arm64.deb` | rootless, iOS 15 and later (arm64 and arm64e) | ElleKit, CCSupport, PreferenceLoader, AltList |
| `BegoneCIAReworked_…_legacy-rootful_iphoneos-arm.deb` | rootful, iOS 13 and 14 (arm64 devices) | a Substrate-compatible injector, CCSupport, PreferenceLoader, AltList |

It replaces `com.johndie.begonecia` and `me.nepeta.begonecia`. Respring after installing. The toggle keeps its place in Control Center; the settings are under Settings → BegoneCIA.

## Tested on

| Device | iOS | Jailbreak | Build |
| --- | --- | --- | --- |
| iPhone 15 Pro Max | 17.3 | Dopamine (rootless) | rootless 1.1.3 |
| iPhone 12 | 15.2.1 | rootless | rootless 1.1.3 |
| iPhone X | 13.3 | rootful, Substitute | legacy rootful 1.1.3 |

1.1.3 fixes the Excluded Apps list in Settings (empty on rootless, no switches on rootful). The tweak and the Control Center module are the same binaries as in 1.1.1.

## Limits

- Camera and location are always free for an excluded app. The microphone is muted centrally in the audio daemons, so it is free only while an excluded app is in the foreground, and then for every app.
- A paused call frees microphone, camera and location for everything until the call ends.
- `begonecia on|off|toggle|status` does the same as the toggle from a shell.

## How it works

Only SpringBoard reads the preferences (domain `me.nepeta.begonecia`). It publishes the outcome as notify state, which sandboxed apps can read; every other process only follows that state. See `names.h` for the names and the top of `Tweak.m` for the rest.

## Settings pane

Below iOS 17 the pane is a plain PreferenceLoader plist (`prefs/BegoneCIA.plist`) that opens AltList's app list. On iOS 17 Settings did not load AltList for such a pane, so the rootless package also carries a small settings bundle that links AltList (`prefs/BCPrefs.m`, `prefs/Root.plist`). Both entries have a PreferenceLoader version filter, so only the fitting one shows. iOS 16 gets the plist pane and was not tested. A change to the settings has to be made in both `prefs/BegoneCIA.plist` and `prefs/Root.plist`.

## Build

Built on the device with Procursus clang and the Theos SDKs: `make deb` (rootless) and `make legacy-deb` (rootful). The code creates its classes at runtime and has no `@""` literals, because that compiler does not sign them for arm64e; keep it that way unless you build with Apple's toolchain.

## License

MIT, see `LICENSE`.
