#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path)

xcrun --sdk iphoneos clang \
  -arch arm64 \
  -isysroot "$SDKROOT" \
  -miphoneos-version-min=15.0 \
  -fobjc-arc \
  -dynamiclib \
  "$ROOT/ClientLoader.m" \
  "$ROOT/providers/CLProjection.c" \
  "$ROOT/providers/CLEntityProvider.m" \
  "$ROOT/providers/CLEntityTypeRegistry.m" \
  "$ROOT/providers/CLCameraProvider.m" \
  "$ROOT/providers/CLESPOverlay.m" \
  "$ROOT/providers/CLDiagnostics.m" \
  -framework Foundation \
  -framework CoreGraphics \
  -framework UIKit \
  -framework JavaScriptCore \
  -Wl,-install_name,@executable_path/Frameworks/ClientLoader.dylib \
  -o "$ROOT/ClientLoader.dylib"

printf 'Built %s\n' "$ROOT/ClientLoader.dylib"
