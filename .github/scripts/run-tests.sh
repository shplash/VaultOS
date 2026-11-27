#!/usr/bin/env bash
#
# Builds and runs the host-side tests: they need neither the iOS SDK, SDL nor
# either engine, so they run natively with the system compiler. Both workflows
# that produce a binary call this, so the two cannot drift apart.

set -euo pipefail

cd "$(dirname "$0")/../.."

work="${1:-build-tests}"
mkdir -p "$work"

# The launcher core is portable C++, and the archive reader it carries needs
# libarchive: tests/CMakeLists.txt builds it, and liblzma, from the same pinned
# releases the application uses, for this machine instead of the device. The
# tests read the translation table out of os/ios/launcher, which is why the
# script runs from the repository root.
cmake -S tests -B "$work" -D CMAKE_BUILD_TYPE=RelWithDebInfo > "$work/configure.log" 2>&1 || {
    tail -40 "$work/configure.log"
    exit 1
}

if ! cmake --build "$work" --config RelWithDebInfo --parallel 3 > "$work/build.log" 2>&1; then
    tail -60 "$work/build.log"
    exit 1
fi

"./$work/launcher-tests"

# Every size the launcher can hand the games is checked here instead of on a
# device with what it takes to play the intro.
"./$work/movie-subtitle-tests"
