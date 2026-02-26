#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <original.apk> <patched.apk> [output_report.md]"
  exit 1
fi

ORIG="$1"
PATCHED="$2"
OUT="${3:-APK_PATCH_AUDIT.md}"

for f in "$ORIG" "$PATCHED"; do
  [[ -f "$f" ]] || { echo "[ERR] File not found: $f"; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ORIG_DIR="$TMP/orig"
PATCH_DIR="$TMP/patched"
mkdir -p "$ORIG_DIR" "$PATCH_DIR"
unzip -q "$ORIG" -d "$ORIG_DIR"
unzip -q "$PATCHED" -d "$PATCH_DIR"

sha_or=$(sha256sum "$ORIG" | awk '{print $1}')
sha_pa=$(sha256sum "$PATCHED" | awk '{print $1}')

list_section() {
  local dir="$1" pattern="$2"
  find "$dir" -type f | sed "s#^$dir/##" | rg "$pattern" | sort || true
}

{
  echo "# APK Patch Audit"
  echo
  echo "- Original APK: \
\`$ORIG\`"
  echo "- Patched APK: \
\`$PATCHED\`"
  echo "- Original SHA256: \`$sha_or\`"
  echo "- Patched SHA256: \`$sha_pa\`"
  echo

  echo "## 1) Inventory diff"
  echo
  echo "### assets/*.jar"
  diff -u <(list_section "$ORIG_DIR" '^assets/.*\\.jar$') <(list_section "$PATCH_DIR" '^assets/.*\\.jar$') || true
  echo

  echo "### lib/**/*.so"
  diff -u <(list_section "$ORIG_DIR" '^lib/.+\\.so$') <(list_section "$PATCH_DIR" '^lib/.+\\.so$') || true
  echo

  echo "### classes*.dex"
  diff -u <(list_section "$ORIG_DIR" '^classes[0-9]*\\.dex$') <(list_section "$PATCH_DIR" '^classes[0-9]*\\.dex$') || true
  echo

  echo "## 2) Size changes (critical files)"
  echo
  printf "| File | Original bytes | Patched bytes |\n"
  printf "|---|---:|---:|\n"

  while IFS= read -r rel; do
    osz="-"; psz="-"
    [[ -f "$ORIG_DIR/$rel" ]] && osz=$(wc -c < "$ORIG_DIR/$rel")
    [[ -f "$PATCH_DIR/$rel" ]] && psz=$(wc -c < "$PATCH_DIR/$rel")
    printf "| %s | %s | %s |\n" "$rel" "$osz" "$psz"
  done < <(
    {
      list_section "$ORIG_DIR" '^classes[0-9]*\\.dex$'
      list_section "$ORIG_DIR" '^lib/.+\\.so$'
      list_section "$ORIG_DIR" '^assets/.*\\.jar$'
      list_section "$PATCH_DIR" '^classes[0-9]*\\.dex$'
      list_section "$PATCH_DIR" '^lib/.+\\.so$'
      list_section "$PATCH_DIR" '^assets/.*\\.jar$'
    } | sort -u
  )

  echo
  echo "## 3) Patched native checks"
  for so in "$PATCH_DIR"/lib/*/libclient.so "$PATCH_DIR"/lib/*/libBlackBox.so; do
    [[ -f "$so" ]] || continue
    abi="$(basename "$(dirname "$so")")"
    base="$(basename "$so")"
    echo
    echo "### $abi/$base"
    echo
    echo "**JNI exports**"
    if command -v nm >/dev/null 2>&1; then
      nm -D "$so" | rg 'JNI_OnLoad|native_Check|ApiKeyBox|FixCrash|checkDebug|verifyUrlAndReturn|hideXposed' || true
    else
      echo "nm not available"
    fi
    echo
    echo "**Crash markers**"
    strings "$so" | rg -i 'verification failed|verified successfully|debugger detected|jni hook error|exiting' || true
  done

  echo
  echo "## 4) Manual signature verification"
  if command -v apksigner >/dev/null 2>&1; then
    echo "Run:"
    echo "- \`apksigner verify --print-certs \"$ORIG\"\`"
    echo "- \`apksigner verify --print-certs \"$PATCHED\"\`"
  else
    echo "apksigner not found in this environment."
  fi

  echo
  echo "## 5) Runtime triage"
  echo "- \`adb logcat | rg -i \"kentos|JNI|UnsatisfiedLinkError|verification failed|Debugger detected|FATAL EXCEPTION|SIGSEGV\"\`"
} > "$OUT"

echo "[OK] Report written: $OUT"
