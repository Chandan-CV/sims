#!/usr/bin/env bash
# Breaks down what's actually using space in SIMS's app data on a connected
# Android device/emulator, and (if sqlite3 is installed locally) further
# breaks down the sqlite/libsql db by table so index bloat is visible
# without having to pull+inspect the file by hand.
set -euo pipefail

PKG="com.example.sims"
DATA_DIR="/data/data/$PKG"

if ! adb shell run-as "$PKG" true 2>/dev/null; then
  echo "Can't run-as $PKG — is the app installed and debuggable, and a device connected?" >&2
  exit 1
fi

echo "== Top-level app data dirs =="
for d in app_flutter cache code_cache databases files no_backup shared_prefs; do
  size=$(adb shell run-as "$PKG" du -sh "$DATA_DIR/$d" 2>/dev/null | cut -f1)
  printf '%-8s %s\n' "$size" "$d"
done

echo
echo "== Files directly under app_flutter (models, db) =="
adb shell run-as "$PKG" ls -la "$DATA_DIR/app_flutter/"

DB_PATH="$DATA_DIR/app_flutter/sims.db"
if adb shell run-as "$PKG" test -f "$DB_PATH" 2>/dev/null; then
  echo
  echo "== sims.db table breakdown =="
  if command -v sqlite3 >/dev/null; then
    TMP=$(mktemp)
    adb shell run-as "$PKG" cat "$DB_PATH" > "$TMP"
    sqlite3 "$TMP" "SELECT name, SUM(pgsize) AS bytes, ROUND(100.0*SUM(pgsize)/(SELECT SUM(pgsize) FROM dbstat),1) AS pct FROM dbstat GROUP BY name ORDER BY bytes DESC;"
    rm -f "$TMP"
  else
    echo "(sqlite3 not installed locally — install it to see the per-table breakdown, e.g. \`idx_vec_shadow\` = vector index graph overhead vs \`images\` = actual embeddings)"
  fi
fi
