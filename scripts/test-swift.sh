#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
# CLT 6.2 ships Testing but omits the optional _Testing_Foundation module.
swift test --disable-xctest -Xswiftc -F -Xswiftc "$frameworks" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$frameworks" "$@"
