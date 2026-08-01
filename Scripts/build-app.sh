#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"

case "$configuration" in
    debug)
        swift_configuration="debug"
        ;;
    release)
        swift_configuration="release"
        ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

cd "$project_root"
swift_arguments=(build -c "$swift_configuration")
if [[ "${MAJOR_TOM_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
    swift_arguments+=(--disable-sandbox)
fi
swift "${swift_arguments[@]}"

app="$project_root/.build/Major Tom.app"
contents="$app/Contents"
executable="$project_root/.build/$swift_configuration/MajorTom"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$executable" "$contents/MacOS/MajorTom"
cp "$project_root/Resources/Info.plist" "$contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"

echo "$app"
