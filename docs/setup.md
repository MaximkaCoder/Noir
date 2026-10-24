# Development setup

Verified on Windows 11 (2026-10-24).

| Tool | Version | Notes |
|---|---|---|
| Flutter | 3.47.8 stable (Dart 3.13.7) | Install to a path **without spaces**, e.g. `D:\dev\flutter` |
| Visual Studio | 2026 Community, "Desktop development with C++" + **C++ ATL** | ATL is needed by `flutter_secure_storage` (Phase 5) |
| JDK | 17 (Microsoft OpenJDK) | `flutter config --jdk-dir <path>`; Java 8 does not work |
| Android SDK | cmdline-tools, platform-tools, platforms 36 and 37.0, build-tools 36.0.0 | New sdkmanager uses `/` package names: `platforms/android-36` |

Recommended environment (user scope):

```
PATH        += D:\dev\flutter\bin
PUB_CACHE    = D:\dev\pub-cache
ANDROID_HOME = D:\dev\android-sdk
```

Windows Developer Mode must be on (plugin symlinks).

## Code generation

Freezed, json_serializable and Drift:

```
dart run build_runner build
```

## Run and build

```
flutter run -d windows
flutter build windows --release      # build\windows\x64\runner\Release\
flutter build apk --release          # Android (not yet verified, see limitations)
```

The Windows release folder (`noir.exe` + `data/` + DLLs, including libmpv) is
self-contained and can be zipped as-is.

## Where NOIR keeps data (Windows)

`%APPDATA%\NOIR\NOIR\` — `noir.sqlite` and `artwork\`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| A file shows "can't be played" | It is damaged or not audio; NOIR reads MP3, M4A, AAC, FLAC, OGG, Opus, WAV |
| Songs missing after moving files | Settings → Library → Rescan |
| UI feels heavy on integrated graphics | Settings → Effects → Performance mode, or turn off Liquid Glass |
| Build error "Failed to find target with hash string 'android-37'" | Install `platforms/android-37.0` and use AGP ≥ 9.4 |
