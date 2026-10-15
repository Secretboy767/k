# Minecraft iOS JavaScript loader prototype

This prototype adds a native floating menu button to the Minecraft 1.26.33 app and runs local JavaScript files through JavaScriptCore. It does **not** modify 3105 or use a Behavior Pack, Resource Pack, Script API, or world experiments.

## Important limitations

- Swift source cannot be interpreted from Documents. Swift must be compiled into signed native code before iOS can load it.
- The loader only exposes `ClientMenu.registerAction(title, callback)` and `ClientMenu.notify(message)` to JavaScript. It does not expose Minecraft's renderer, inventory, input, or game state. Therefore zoom, quick drop, and FPS optimizations are not implemented by this prototype.
- The dylib must be included in the signed app bundle and loaded by the executable. A `.3105` patch cannot do that; it can install JavaScript files in the app's Documents container after the modified IPA is installed.
- The final IPA must be re-signed with the same certificate used for the injected dylib. The original app signature becomes invalid when the executable is modified.

## Build without owning a Mac

The repository includes a GitHub Actions workflow that builds the iOS arm64 dylib on a hosted macOS/Xcode runner. No Minecraft files are uploaded to GitHub by this workflow.

1. Commit and push only the loader source, 3105 sample script, and `.github/workflows/build-ios-client-loader.yml` to a GitHub repository where Actions are enabled. Do not add the supplied Minecraft IPA or `Payload/` to Git.
2. In GitHub, open **Actions → Build iOS Client Loader → Run workflow** (or wait for the workflow to run after pushing those files).
3. When the run succeeds, download the `minecraft-client-loader-ios-arm64` artifact. It contains `ClientLoader.dylib` and its SHA-256 checksum.
4. Put the downloaded dylib in this workspace, then package the local Minecraft app as described below. This keeps the game IPA off GitHub.

The workflow is in `.github/workflows/build-ios-client-loader.yml`. This workspace currently has no GitHub CLI authentication, so it cannot push or start the workflow on your behalf.

## Package and sign

After downloading `ClientLoader.dylib`, run from the repository root:

```sh
python3 ClientLoader/package_ipa.py \
  --app Payload/minecraftpe.app \
  --loader ClientLoader/ClientLoader.dylib \
  --output Minecraft-ClientLoader-unsigned.ipa
```

The packager copies the app; it does not edit the supplied `.app`. It adds a Mach-O load command for `@executable_path/Frameworks/ClientLoader.dylib` and includes the dylib in the app's `Frameworks` directory. Import the unsigned IPA into eSign, re-sign all embedded code with your certificate, then install that signed IPA. Do not install the unsigned output. Keep an untouched copy of the original IPA so you can reinstall it if the modified app does not launch.

## Install scripts with 3105

Place `.js` files in Minecraft's Documents container at:

```text
Documents/ClientLoader/scripts/
```

The included `scripts/client.js` is a harmless loader-status action. The matching 3105 patch workspace path is `3105/Patches/Minecraft/Application/com.mojang.minecraftpe/Documents/ClientLoader/scripts/`.

Scripts are loaded alphabetically on app launch. They can register menu actions:

```js
ClientMenu.registerAction("Example", function () {
    ClientMenu.notify("JavaScript action ran.");
});
```

Because this runs JavaScript inside the game process, only install scripts you trust. This is an experimental native injection, not a supported Minecraft extension interface.
