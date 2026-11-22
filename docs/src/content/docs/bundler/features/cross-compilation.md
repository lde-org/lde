---
title: Cross Compilation
order: 4
---

You can cross compile your lde package to other platforms by specifying the `--target` flag when running `lde compile`.

This is desirable when you don't care about running the binary and want fast builds for continuous deployment release builds.

> [!WARNING]
> Support for cross compilation is **best effort** and **experimental**.

## Valid Targets

- `linux-x86-64`
- `linux-aarch64`
- `windows-x86-64`
- `windows-aarch64`
- `macos-x86-64`
- `macos-aarch64`
- `freebsd-x86-64`
- `freebsd-aarch64`
- `android-aarch64`
- `android-aarch64-apk`
- `android-x86-64`
- `android-x86-64-apk`

> [!NOTE]
> You will likely require some additional setup or dependencies on your system such as Windows libraries when targeting that platform.

## Android APK

`android-aarch64-apk` and `android-x86-64-apk` package the program as a
NativeActivity app rather than a standalone binary. The x86-64 APK runs in the
Android emulator:

```sh
lde compile --target android-aarch64-apk --outfile app.apk
```

The build needs the Android SDK (`aapt2`, `apksigner`, `zipalign`), an Android
NDK (`ANDROID_NDK_HOME`), and a JDK's `keytool`/`jar`. It produces a signed,
installable APK; `adb install -r app.apk` runs it.

The manifest carries the application identity and any shared libraries the app
brings itself:

```json
{
  "android": {
    "package": "dev.example.app",
    "label": "Example",
    "versionCode": 1,
    "icon": "assets/icon.png",
    "fullscreen": false,
    "permissions": ["android.permission.READ_MEDIA_AUDIO"],
    "libs": ["libs/libfreetype.so", "libs/libharfbuzz.so"]
  }
}
```

`libs` are copied into the APK's `lib/arm64-v8a` directory, where Android's
loader finds them by `SONAME`, the same way it finds `libvulkan.so`. The app has
no Java code and no console: it runs the bundled Lua program from a
NativeActivity.

`permissions` are written to the manifest as `uses-permission` entries. A
runtime permission is still the user's to grant: the app asks for it, or it is
granted from the system settings (`adb shell pm grant <package> <permission>`).

`icon` is a PNG, relative to the package, shown in the launcher and the recent
apps list. It is packaged as the app's one mipmap, so give it at least 192×192.

The app is laid out edge to edge: it draws under the status bar and the
navigation bar, which stay visible, so it should pad its UI by their heights.
`fullscreen: true` hides the status bar instead, for a game or a video player
that wants the whole screen.

## Using another compiler

If you have an alternate compiler on your system, you can override the default compiler lde uses (clang) with the `SEA_CC` env var.

```sh
SEA_CC=clang lde compile
```

> [!WARNING]
> You should rarely, if ever, need to use this.

This is used by lde to forcibly compile on windows with the llvm-mingw clang in CI, where the toolchain download is not an option.
