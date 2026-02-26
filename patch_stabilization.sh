#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <original.apk> <patched.apk>"
  exit 1
fi

ORIG="$1"
PATCHED="$2"

for f in "$ORIG" "$PATCHED"; do
  if [[ ! -f "$f" ]]; then
    echo "[ERR] File not found: $f"
    exit 1
  fi
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ORIG_DIR="$TMP_DIR/orig"
PATCH_DIR="$TMP_DIR/patched"
mkdir -p "$ORIG_DIR" "$PATCH_DIR"

unzip -q "$ORIG" -d "$ORIG_DIR"
unzip -q "$PATCHED" -d "$PATCH_DIR"

echo "== Patch stabilization checks =="
echo "Original: $ORIG"
echo "Patched : $PATCHED"

echo
echo "[1] Asset archives diff (assets/*.jar)"
orig_assets="$TMP_DIR/orig_assets.txt"
patch_assets="$TMP_DIR/patch_assets.txt"
(find "$ORIG_DIR/assets" -maxdepth 1 -type f -name '*.jar' -printf '%f\n' 2>/dev/null || true) | sort > "$orig_assets"
(find "$PATCH_DIR/assets" -maxdepth 1 -type f -name '*.jar' -printf '%f\n' 2>/dev/null || true) | sort > "$patch_assets"
diff -u "$orig_assets" "$patch_assets" || true

echo
echo "[2] Native library inventory diff (lib/**/*.so)"
orig_libs="$TMP_DIR/orig_libs.txt"
patch_libs="$TMP_DIR/patch_libs.txt"
(find "$ORIG_DIR/lib" -type f -name '*.so' -printf '%P\n' 2>/dev/null || true) | sort > "$orig_libs"
(find "$PATCH_DIR/lib" -type f -name '*.so' -printf '%P\n' 2>/dev/null || true) | sort > "$patch_libs"
diff -u "$orig_libs" "$patch_libs" || true

echo
echo "[3] JNI export sanity in patched libclient.so/libBlackBox.so"
for so in "$PATCH_DIR/lib"/*/libclient.so "$PATCH_DIR/lib"/*/libBlackBox.so; do
  [[ -f "$so" ]] || continue
  echo "-- $(basename "$(dirname "$so")")/$(basename "$so")"
  if command -v nm >/dev/null 2>&1; then
    nm -D "$so" | rg 'JNI_OnLoad|native_Check|ApiKeyBox|FixCrash|checkDebug|verifyUrlAndReturn|hideXposed' || true
  else
    echo "[WARN] nm is not installed; skipping export check"
  fi
done

echo
echo "[4] Crash trigger string markers in patched libs"
for so in "$PATCH_DIR/lib"/*/libclient.so "$PATCH_DIR/lib"/*/libBlackBox.so; do
  [[ -f "$so" ]] || continue
  echo "-- $(basename "$(dirname "$so")")/$(basename "$so")"
  strings "$so" | rg -i 'verification failed|verified successfully|debugger detected|jni hook error|exiting' || true
done

echo
echo "[5] Signature inspection hints"
if command -v apksigner >/dev/null 2>&1; then
  echo "apksigner detected; print certs with:"
  echo "  apksigner verify --print-certs \"$ORIG\""
  echo "  apksigner verify --print-certs \"$PATCHED\""
else
  echo "[WARN] apksigner not found; verify signing cert outside this container."
fi

echo
echo "[6] Runtime triage command"
echo 'adb logcat | rg -i "kentos|JNI|UnsatisfiedLinkError|verification failed|Debugger detected|FATAL EXCEPTION|SIGSEGV"'

echo
echo "Done."
