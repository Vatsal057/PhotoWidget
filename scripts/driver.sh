#!/usr/bin/env bash
# PhotoWidget driver — build, launch, screenshot, stop the macOS app + widget.
# Run from repo root:  scripts/driver.sh <cmd>
#   build   regen project + xcodebuild (signed with your Apple Development team)
#   run     launch the built .app
#   shot    bring window frontmost, capture it to shots/app.png
#   reload  kill + relaunch the widgetd cache so a rebuilt widget shows
#   stop    quit the app
#   all     build + run + shot
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
SCRIPTS="scripts"
APP="build/Build/Products/Debug/PhotoWidget.app"

team() {
  # Team ID = the OU field of your Apple Development cert. No hardcoding.
  security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | grep -oE 'OU=[A-Z0-9]+' | head -1 | cut -d= -f2
}

case "${1:-all}" in
  build)
    ruby "$SCRIPTS/gen_project.rb"
    T=$(team); [ -n "$T" ] || { echo "No Apple Development cert found"; exit 1; }
    xcodebuild -project PhotoWidget.xcodeproj -scheme PhotoWidget -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath build \
      DEVELOPMENT_TEAM="$T" -allowProvisioningUpdates build \
      | grep -E "error:|warning: .*(deprecated|unused)|BUILD (SUCCEEDED|FAILED)" || true
    ;;
  run)
    killall PhotoWidget 2>/dev/null || true
    open "$APP"
    ;;
  shot)
    osascript -e 'tell application "PhotoWidget" to activate' 2>/dev/null || true
    sleep 2
    mkdir -p "$SCRIPTS/shots"
    WID=$(python3 - <<'PY'
import Quartz
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID):
    if w.get('kCGWindowOwnerName') == 'PhotoWidget' and w.get('kCGWindowLayer') == 0:
        print(w['kCGWindowNumber']); break
PY
)
    if [ -n "$WID" ]; then
      screencapture -o -l"$WID" "$SCRIPTS/shots/app.png"
    else
      screencapture -o -x "$SCRIPTS/shots/app.png"   # fallback: full display
    fi
    echo "wrote $SCRIPTS/shots/app.png"
    ;;
  reload)
    # WidgetKit caches the old extension; nuke widgetd so a rebuilt widget re-registers.
    killall chronod widgetd 2>/dev/null || true
    pluginkit -m -p com.apple.widgetkit-extension 2>/dev/null || true
    ;;
  stop) killall PhotoWidget 2>/dev/null || true ;;
  dist)
    # Release build -> dist/PhotoWidget.dmg, ready to attach to a GitHub release.
    ruby "$SCRIPTS/gen_project.rb"
    T=$(team); [ -n "$T" ] || { echo "No Apple Development cert found"; exit 1; }
    xcodebuild -project PhotoWidget.xcodeproj -scheme PhotoWidget -configuration Release \
      -destination 'platform=macOS' -derivedDataPath build \
      DEVELOPMENT_TEAM="$T" -allowProvisioningUpdates build \
      | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
    RAPP="build/Build/Products/Release/PhotoWidget.app"
    [ -d "$RAPP" ] || { echo "Release build missing"; exit 1; }
    # Development provisioning profiles are device-locked to this Mac; strip
    # them so other Macs don't trip over them (team-prefixed App Group needs
    # no profile). Re-sign inside-out after the edit.
    rm -f "$RAPP/Contents/embedded.provisionprofile" \
          "$RAPP/Contents/PlugIns/PhotoWidgetExtension.appex/Contents/embedded.provisionprofile"
    codesign --force --options runtime --timestamp=none \
      --entitlements PhotoWidgetExtension/PhotoWidgetExtension.entitlements \
      --sign "Apple Development" "$RAPP/Contents/PlugIns/PhotoWidgetExtension.appex"
    codesign --force --options runtime --timestamp=none \
      --entitlements PhotoWidget/PhotoWidget.entitlements \
      --sign "Apple Development" "$RAPP"
    codesign --verify --deep --strict "$RAPP" && echo "codesign OK"
    mkdir -p dist/stage && rm -rf dist/stage/* dist/PhotoWidget.dmg
    cp -R "$RAPP" dist/stage/
    ln -s /Applications dist/stage/Applications
    hdiutil create -volname PhotoWidget -srcfolder dist/stage -ov -format UDZO \
      dist/PhotoWidget.dmg >/dev/null
    rm -rf dist/stage
    echo "wrote dist/PhotoWidget.dmg"
    ;;
  all) "$0" build && "$0" run && sleep 3 && "$0" shot ;;
  *) echo "usage: driver.sh {build|run|shot|reload|stop|dist|all}"; exit 2 ;;
esac
