#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
fixture_root="/private/tmp/GesturePilot-ActionTest"
fixture_app="$fixture_root/GesturePilotActionTest.app"
mkdir -p "$fixture_app/Contents/MacOS"
clang -fobjc-arc -Wall -Wextra -Werror -framework AppKit \
    "$project_root/Tests/ActionFixture.m" \
    -o "$fixture_app/Contents/MacOS/GesturePilotActionTest"
python3 - "$fixture_app/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "com.arun.GesturePilot.ActionTest",
    "CFBundleExecutable": "GesturePilotActionTest",
    "CFBundleName": "GesturePilotActionTest",
    "CFBundlePackageType": "APPL",
    "NSPrincipalClass": "NSApplication",
}))
PY
codesign --force --sign - "$fixture_app"
print "$fixture_app"
