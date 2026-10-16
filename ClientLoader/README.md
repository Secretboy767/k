# Minecraft iOS Client Loader

This project modifies a copy of Minecraft Bedrock for iOS to load a native iOS dynamic library at app startup. The library creates the in-game floating **C** button and a Roblox-style client panel, then runs trusted local JavaScript files using JavaScriptCore.

It does not modify 3105, use a Behavior Pack or Resource Pack, call Minecraft Script API, or require world experiments.

## How the modified IPA works

The IPA build has two related changes inside `Payload/minecraftpe.app`:

1. `Frameworks/ClientLoader.dylib` contains the native Objective-C/UIKit loader and menu.
2. The arm64 `minecraftpe` Mach-O executable has an `LC_LOAD_DYLIB` command referencing `@executable_path/Frameworks/ClientLoader.dylib`.

At launch, iOS loads that library as part of Minecraft's process. A constructor waits for Minecraft's active window, creates the floating button, and reads JavaScript files from the app's Documents container:

```text
Documents/ClientLoader/scripts/*.js
```

The loader does not evaluate JavaScript placed arbitrarily in Documents: scripts in that specific directory are explicitly enumerated and passed to JavaScriptCore. The `.js` files are content interpreted by the bundled JavaScriptCore framework; they are not native code.

The original app signature is invalidated by changing the executable. eSign must sign the modified executable and embedded dylib together. The floating button and dragging are confirmed on-device. The previous build crashed when opening the panel; the updated source fixes the panel's constraint hierarchy and adds diagnostics, but needs a new dylib build and on-device test.

## Diagnostics

The loader writes startup, menu open/close, script-loading, JavaScript exception, and UI error details to:

```text
Documents/ClientLoader/ClientLoader.log
```

It also installs an Objective-C uncaught-exception handler that records the exception reason and call stack. This does not guarantee a log for every native crash, such as a forced termination or low-level memory fault. The messages are also sent to the iOS system log with `NSLog`. 3105's own console is not directly connected to Minecraft's native process logs; use its file browser to retrieve the log if it can access Minecraft's Documents container.

## Current client panel

The floating purple **C** button uses direct touch handling: a short touch opens the panel; moving it by at least 8 points drags it and saves its normalized screen position. The panel is explicitly added above the active game window. Tapping it opens a dark rounded panel with:

- **Features**: native toggles for the quick-button bar and haptic feedback, plus persistent Boolean features registered by local scripts.
- **Buttons**: add or remove floating on-screen buttons for script actions.
- A short status action and example script preference are included to demonstrate the UI-to-JavaScript callbacks.

These are actual UI/preferences, not Minecraft gameplay features. There is currently **no connection to the game engine's inventory, camera, renderer, or input system**. Zoom, quick drop, offhand transfer, FPS controls, and auto-totem are not implemented. A script can add a toggle or button, but it only has an effect on the game if its callback has a real supported action; a UI toggle by itself cannot move items or change rendering. The quick buttons are touch buttons, not hardware keyboard keybinds.

## Connection to 3105

3105 is optional and is only the **data/script installer**, not the native code loader. The built-in floating C button, panel, native switches and native custom-action-button UI do not depend on a 3105 patch; that is why they remain visible when the patch is disabled. 3105 is only needed when you want to add or update JavaScript features/actions without rebuilding the dylib:

- The modified IPA installs the native loader in Minecraft's app bundle. eSign signs and installs this IPA.
- Once installed, 3105 applies a data-only `.3105` patch to Minecraft's Application container.
- This project's matching patch workspace folder is:

  ```text
  3105/Patches/Minecraft/Application/com.mojang.minecraftpe/Documents/ClientLoader/scripts/
  ```

- Files under that path are copied to Minecraft's:

  ```text
  Documents/ClientLoader/scripts/
  ```

- On Minecraft startup, the native loader finds those `.js` files and evaluates them.

Therefore the pairing is: **eSign installs the modified executable + native dylib; 3105 installs JavaScript into the data folder the loader reads.** A `.3105` by itself cannot inject or load the dylib.

Example script APIs:

```js
ClientMenu.registerFeature("My preference", false, function (enabled) {
    console.log("My preference is now", enabled);
});

ClientMenu.registerAction("My action", function () {
    ClientMenu.notify("The action callback ran.");
});
```

Feature values are saved by name on-device and restored when the script registers them again. Actions appear in the Buttons tab and can be added to the on-screen button bar. Only install scripts you trust: they execute inside the game process.

## Build without owning a Mac

The repository includes a GitHub Actions workflow that builds only the iOS arm64 dylib on a hosted macOS/Xcode runner. No Minecraft IPA or app bundle is uploaded to GitHub.

1. Commit and push only the loader source, 3105 sample script, and `.github/workflows/build-ios-client-loader.yml` to a GitHub repository where Actions are enabled. Do not add the supplied Minecraft IPA or `Payload/` to Git.
2. In GitHub, open **Actions → Build iOS Client Loader → Run workflow** (or wait for the workflow to run after pushing those files).
3. When the run succeeds, download the `minecraft-client-loader-ios-arm64` artifact. It contains `ClientLoader.dylib` and its SHA-256 checksum.
4. Download `ClientLoader.dylib` from the artifact. If you only want the dylib, stop here; no IPA packaging step is required.

The workflow is in `.github/workflows/build-ios-client-loader.yml`. A new dylib build is required after changing `ClientLoader.m`; editing JavaScript files alone does not require rebuilding the dylib.

## Package and sign

After downloading `ClientLoader.dylib`, run from the repository root:

```sh
python3 ClientLoader/package_ipa.py \
  --app Payload/minecraftpe.app \
  --loader ClientLoader/ClientLoader.dylib \
  --output Minecraft-ClientLoader-unsigned.ipa
```

The packager copies the app; it does not edit the supplied `.app`. It adds a Mach-O load command for `@executable_path/Frameworks/ClientLoader.dylib` and includes the dylib in the app's `Frameworks` directory. Import the unsigned IPA into eSign, re-sign all embedded code with your certificate, then install that signed IPA. Do not install the unsigned output. Keep an untouched copy of the original IPA so you can reinstall it if the modified app does not launch.

## Install and update

To update native UI/loader code, build a new dylib, package a fresh copy of the Minecraft app, then re-sign and install the complete IPA with eSign. Updating only a JavaScript file does not require rebuilding the IPA: place it in the 3105 workspace path above and apply the patch, then restart Minecraft (scripts are loaded at app launch).

Keep the original Minecraft IPA available as a recovery copy. If a modified build crashes or will not install, remove it and reinstall the original app.
