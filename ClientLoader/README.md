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

The original app signature is invalidated by changing the executable. eSign must sign the modified executable and embedded dylib together. The floating button, dragging, and opening the panel are confirmed on-device. The current loader also writes diagnostic logs; a new dylib build is required to include any later native-code changes.

No custom behavior pack or resource pack is part of this client. The supplied Minecraft app bundle's original built-in game data is left untouched.

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

These are actual UI/preferences, not Minecraft gameplay features. There is currently **no connection to the game engine's entity list, inventory, camera, renderer, or input system**. Mob ESP, zoom, quick drop, offhand transfer, FPS controls, and auto-totem are not implemented. Static inspection of the 1.26.33 executable found internal Script API entity-query and camera bindings, but they belong to Minecraft's own script runtime, not the loader's separate JavaScriptCore context; they are not currently callable by these scripts. A no-pack native ESP would require a verified in-process entity feed and camera projection path, then testing against a running iOS game. The loader's existing scripts cannot provide that data on their own. A script can add a toggle or button, but it only has an effect on the game if its callback has a real supported action; a UI toggle by itself cannot mark entities, move items, or change rendering. The quick buttons are touch buttons, not hardware keyboard keybinds.

## ESP and data diagnostics

The optional `scripts/esp_test.js` sample adds **Synthetic ESP test boxes**, **Live mob ESP**, and **Export chunk data diagnostic**. Synthetic boxes remain a fixed UI-only test fixture and are always labelled not live. The live toggle uses a separate overlay that only renders valid `CLWorldEntitySnapshot` records and projects their 3D bounds through a published camera matrix. It does not substitute sample cows when no snapshots are available.

The code now has a working snapshot contract, validation and a 256-snapshot retention cap in `providers/CLEntityProvider.*`, a column-major matrix projection implementation in `providers/CLCameraProvider.*`, a snapshot-driven renderer in `providers/CLESPOverlay.*`, and a JSON report writer in `providers/CLDiagnostics.*`. `build.sh` compiles all of those source files. The loader refreshes the live overlay at up to 15 FPS and exports actual provider status/counters, up to 32 captured records, camera source/matrix status, app version/build, recent native/JavaScript exceptions, and explicit limitations.

**Important: the producer side is still not connected to Minecraft.** The target binary contains Script API method-name strings and renderer uniform names, but this inspection has not found a callable entity query, a live camera matrix accessor, or a safe update hook. Therefore the new live toggle currently renders no boxes until a verified native adapter publishes snapshots and camera state. That is a measurable implementation step, not a claim that live entity capture already works. Do not use fabricated addresses or Android offsets as a provider.

The app payload's `server_library` shim imports `@minecraft/server-bindings` and re-exports API types including `Entity`, `Dimension`, and `EntityQueryOptions`. This makes a Minecraft-hosted behavior-pack script a plausible separate way to query world entities when a script-enabled pack is installed and enabled. It is not a verified data source for this loader: the bundled files are API shims, vanilla behavior-pack manifests do not declare script modules, and no supported channel has been identified from the game script runtime into this loader's JavaScriptCore context or native overlay. A behavior-pack route would also need a separately verified camera/projection path for screen-space boxes.

The export action writes `Documents/ClientLoader/exports/ChunkCaptureDiagnostic.json`. The native `ClientMenu.exportDiagnostics` route emits a schema-2 report marked with its `producer` and `exportRoute`; the separate `ClientMenu.exportJSON` bridge writes caller-supplied JSON unchanged and logs its schema version. Do not infer the native report producer from a JSON `source` field alone. Each evaluated script is logged by filename and UTF-8 byte count so additional Documents scripts can be distinguished. The report distinguishes unavailable providers from successful empty queries; chunk/block data is not claimed. The 3105 script copy at `3105/Patches/Minecraft/Application/com.mojang.minecraftpe/Documents/ClientLoader/scripts/esp_test.js` matches the repository script. A new dylib build is required after native changes.

### Vanilla entity type registry

`research/generate_vanilla_entity_registry.py` recursively parses the bundled vanilla entity JSONC definitions and generates `generated/entity_registry.json`. The checked-in registry contains entity **type metadata**, not spawned entities; it does not register, create, or discover any runtime entity. The current payload scan found 96 JSON files, parsed all 96, extracted 96 explicit identifiers, and found no missing identifiers, malformed files, or duplicate IDs. Each definition retains its source file and explicit unknown values (for example, collision-box depth is `null` when the JSON does not define it).

The same generated registry is included in the 3105 patch at `Application/com.mojang.minecraftpe/Documents/ClientLoader/entity_registry.json`. At startup, the native loader reads it into `CLEntityTypeRegistry`; the live overlay may use verified type-family metadata for classification/color only. Diagnostic exports include registry load status and extraction counts. A missing or invalid registry is logged and reported rather than replaced with inferred or fabricated definitions. This registry does **not** provide runtime entity IDs, positions, dimensions of spawned entities, or camera projection, and does not make the live ESP functional without the separately verified runtime feed.

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

### 3105 / Minecraft Script API diagnostic

The ClientLoader-side 3105 patch includes `scripts/minecraft_api_3105_diagnostic.js`. On loader startup it reports that the ClientLoader bridge/script ran and calls the native `ClientMenu.reportRuntimeStatus(json, fileName)` bridge. It deliberately does **not** test `world.getDimension("overworld").getEntities()`: this standalone JavaScriptCore context has no Bedrock module resolver. The report marks the Minecraft Script API `not_tested` and the entity query `not_run`, then ClientLoader writes it atomically to `Documents/ClientLoader/diagnostics/MinecraftAPIDiagnostic.json` and shows a notification. The native bridge accepts only a JSON basename matching `[A-Za-z0-9_-]{1,64}.json` and reports up to 1 MiB.

The Minecraft `@minecraft/server` module is imported by scripts running inside Minecraft's script host. ClientLoader evaluates 3105 scripts in its own JavaScriptCore context, which does not implement that module resolver. This project intentionally does not install or require a behavior pack or resource pack. No supported, verified no-pack path from the Minecraft Script API runtime into ClientLoader has been established. A no-pack live ESP therefore still requires a verified native entity/camera adapter; this diagnostic is only a ClientLoader bridge check, not a Minecraft API or live-entity probe.

“3105 script executed” means the patch-delivered ClientLoader script was evaluated; it does not independently verify the 3105 application or make Minecraft gameplay APIs available to the script. Rebuild the iOS dylib on the existing macOS/GitHub Actions workflow after native source changes; JavaScript and 3105 patch changes alone do not need a dylib rebuild.

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
