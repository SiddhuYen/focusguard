# FocusGuard

FocusGuard is a native macOS menu bar app that treats the current frontmost app as the focus target.

## MVP Features

- Menu bar status for idle, focusing, escape, and intervention states
- Focus on the current app using its bundle ID
- Active app monitoring with `NSWorkspace`
- Soft intervention when you leave the focus app
- Return to the focus app, leave for one minute, or end focus
- Basic settings and session history stored locally with `UserDefaults`

## Build

To build the proper Xcode app bundle from this folder:

```sh
./scripts/build-xcode-app.sh
```

The app bundle is created at:

```sh
dist/FocusGuard.app
```

You can also open:

```sh
FocusGuard.xcodeproj
```

The older Swift Package build script is kept for reference:

```sh
./scripts/build-app.sh
```

## Run

Open `dist/FocusGuard.app`. It appears in the menu bar only.

The first MVP intentionally avoids global shortcuts, browser tab inspection, strict blocking, and extra permissions.
