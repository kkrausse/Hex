#!/bin/bash
# Run the HexCore test suite using Command Line Tools only (no Xcode required).
#
# Why this wrapper exists: with CLT, Swift Testing is installed but is not on the
# default search paths, so a plain `swift test` fails three different ways in
# sequence — first "no such module 'Testing'" at compile time, then a dyld miss on
# Testing.framework, then a dyld miss on its own lib_TestingInterop.dylib
# dependency, which lives in a *different* directory than the framework.
# DYLD_FRAMEWORK_PATH does not help: SIP strips DYLD_* from swiftpm-testing-helper,
# which is a protected system binary. Baking both rpaths into the test bundle at
# link time is what actually works.
#
# Once full Xcode is installed, plain `swift test` should work and this can go away.
set -euo pipefail

CLT_ROOT="$(xcode-select -p)"
FRAMEWORKS="${CLT_ROOT}/Library/Developer/Frameworks"
INTEROP_LIB="${CLT_ROOT}/Library/Developer/usr/lib"

if [ ! -d "$FRAMEWORKS/Testing.framework" ]; then
  echo "error: Testing.framework not found under $FRAMEWORKS" >&2
  echo "Active developer dir is: $CLT_ROOT" >&2
  exit 1
fi

cd "$(dirname "$0")"

exec swift test \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xlinker -F -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$INTEROP_LIB" \
  "$@"
