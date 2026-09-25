#!/usr/bin/env bash
# Installs the APK on the running emulator, grants the two permissions, opens the app, starts the
# presence and checks the app is still alive with no crash in the log.
set -u
APK=$1
PKG=io.github.noice912.richpresence
fail() { echo "::error title=android smoke::$1 $(adb logcat -d -b crash | tail -c 2500 | tr '\n' ' ')"; exit 1; }

adb install -r "$APK" || fail "install failed"
adb shell appops set $PKG GET_USAGE_STATS allow
adb shell cmd notification allow_listener $PKG/$PKG.MediaListener
adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS || true
adb logcat -c
adb shell am start -W -n $PKG/.MainActivity || fail "could not open the app"
sleep 5
adb shell pidof $PKG > /dev/null || fail "the app closed right after opening"
adb shell uiautomator dump /sdcard/ui.xml > /dev/null
adb shell cat /sdcard/ui.xml > ui.xml
grep -q '✓  Usage access' ui.xml || fail "usage access not shown as granted"
grep -q '✓  Notification access' ui.xml || fail "notification access not shown as granted"
# press the Start button (found by its text in the screen dump)
B=$(grep -o 'content-desc="presence-toggle"[^>]*bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' ui.xml | grep -o '\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]' | head -1)
[ -n "$B" ] || fail "Start button not found"
read X1 Y1 X2 Y2 <<< "$(echo "$B" | tr -c '0-9' ' ')"
adb shell input tap $(( (X1 + X2) / 2 )) $(( (Y1 + Y2) / 2 ))
sleep 12
adb shell pidof $PKG > /dev/null || fail "the app died after starting the presence"
adb shell dumpsys activity services $PKG | grep -q PresenceService || fail "the presence service is not running"
if adb logcat -d -b crash | grep -q "$PKG"; then fail "crash in the log"; fi
echo "Android smoke test passed"
