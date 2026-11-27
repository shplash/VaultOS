#!/usr/bin/env bash
#
# Builds and runs the host-side tests: they need neither the iOS SDK, SDL nor
# either engine, so they run natively with the system compiler. Both workflows
# that produce a binary call this, so the two cannot drift apart.

set -euo pipefail

cd "$(dirname "$0")/../.."

work="${1:-build-tests}"
mkdir -p "$work"

# The launcher core is portable C++ and needs no SDL or engine code, so it can be
# tested natively instead of through the iOS build. It reads the translation
# table out of os/ios/launcher, which is why this runs from the repository root.
c++ -std=c++17 -Wall -Wextra -I src \
    tests/launcher_validation_test.cc \
    src/launcher/launcher_core.cc \
    src/launcher/launcher_disc.cc \
    -lz \
    -o "$work/launcher-tests"
"./$work/launcher-tests"

# Every size the launcher can hand the games is checked here instead of on a
# device with what it takes to play the intro.
c++ -std=c++17 -Wall -Wextra -I src \
    tests/movie_subtitle_test.cc \
    -o "$work/movie-subtitle-tests"
"./$work/movie-subtitle-tests"
