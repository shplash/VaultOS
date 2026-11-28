#!/usr/bin/env bash
#
# Verifies the packaged iOS IPA: that it holds both engines in separate images
# with their entry points, the right ARM64/iOS architecture, and a Fallout 2
# framework that resolves its SDL symbols from the application. It covers the
# build up to packaging, not whether either game boots on a device.

set -euo pipefail

IPA="${1:-}"
if [ -z "$IPA" ] || [ ! -f "$IPA" ]; then
    echo "usage: $0 <path-to-ipa>" >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    echo "verify-ipa: $*" >&2
    exit 1
}

note() {
    echo "verify-ipa: $*"
}

defined_symbols() {
    # Field 2 is the nm type letter for defined symbols; an undefined entry has
    # the U in field 1. This works with both cctools nm and llvm-nm.
    nm -g "$1" 2>/dev/null | awk '$2 ~ /^[A-Z]$/ { print $NF }' | sort -u
}

undefined_symbols() {
    nm -u "$1" 2>/dev/null | awk 'NF > 0 { print $NF }' | sort -u
}

symbols_text() {
    # Mangled names are kept as a fallback: the engine function names appear
    # literally in both mangled and demangled output.
    nm "$1" 2>/dev/null | c++filt
}

# Symbols actually reachable by a dlopen'ed image, taken from the export trie
# rather than the symbol table. Falls back to the symbol table only when no
# tool can read the trie.
exported_symbols() {
    local binary="$1"
    local output=""

    if command -v dyld_info >/dev/null 2>&1; then
        output="$(dyld_info -exports "$binary" 2>/dev/null \
            | awk '$NF ~ /^_/ { print $NF }' | sort -u || true)"
        if [ -n "$output" ]; then
            printf '%s\n' "$output"
            return 0
        fi
    fi

    if xcrun --find llvm-objdump >/dev/null 2>&1; then
        output="$(xcrun llvm-objdump --macho --exports-trie "$binary" 2>/dev/null \
            | awk '$NF ~ /^_/ { print $NF }' | sort -u || true)"
        if [ -n "$output" ]; then
            printf '%s\n' "$output"
            return 0
        fi
    fi

    defined_symbols "$binary"
}

check_platform() {
    local binary="$1"
    local label="$2"

    local archs
    archs="$(lipo -archs "$binary")"
    case " $archs " in
        *" arm64 "*) : ;;
        *) fail "$label is not ARM64 (architectures: $archs)" ;;
    esac

    vtool -show-build "$binary" > "$work/vtool.txt"
    grep -q 'platform IOS' "$work/vtool.txt" \
        || fail "$label is not built for iOS"

    local minos
    minos="$(awk '/minos/ { print $2; exit }' "$work/vtool.txt")"
    [ -n "$minos" ] || fail "$label has no minimum OS version"
    awk -v have="$minos" -v want="14.0" 'BEGIN { exit (have + 0 < want + 0) }' \
        || fail "$label targets iOS $minos, below the launcher's iOS 14.0"

    echo "$minos"
}

# --- Unpack and locate the single application -------------------------------

unzip -q "$IPA" -d "$work"

[ -d "$work/Payload" ] || fail "the IPA has no Payload folder"

app_count="$(find "$work" -name '*.app' -type d | wc -l | tr -d ' ')"
[ "$app_count" = "1" ] || fail "expected one application bundle, found $app_count"
app="$(find "$work" -name '*.app' -type d -print -quit)"

# -print -quit instead of piping find into grep/head: an early exit there makes
# find write to a closed pipe, which pipefail would report as a real failure.
if [ -n "$(find "$work" -name '*.dSYM' -print -quit)" ]; then
    fail "the IPA contains debug symbols"
fi

exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
[ -n "$exe_name" ] || fail "the application Info.plist has no CFBundleExecutable"

# The two keys that put the app's Documents folder in the Files app and let a
# document picker hand over a file: without them the folder never appears and
# the picker delivers nothing outside LiveContainer.
[ "$(/usr/libexec/PlistBuddy -c 'Print :UIFileSharingEnabled' "$app/Info.plist")" = "true" ] \
    || fail "the application does not expose its Documents folder (UIFileSharingEnabled missing)"
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSSupportsOpeningDocumentsInPlace' "$app/Info.plist")" = "true" ] \
    || fail "the application cannot open picked files (LSSupportsOpeningDocumentsInPlace missing)"

# Both engine adapters have to reject the (Object*)-1 the interface parks in the
# hand slots. The Fallout 1 one was missed once and it cost a crash on the main
# menu; this keeps it from being removed again by accident.
grep -q 'reinterpret_cast<fallout::Object\*>(-1)' os/ios/engine/engine_fallout1.cc \
    || fail "the Fallout 1 adapter does not guard the interface's -1 hand slot"
grep -q 'reinterpret_cast<fallout::Object\*>(-1)' os/ios/engine/engine_fallout2.cc \
    || fail "the Fallout 2 adapter does not guard the interface's -1 hand slot"

binary="$app/$exe_name"
[ -f "$binary" ] || fail "the application executable is missing"
note "application: $(basename "$app") ($exe_name)"

app_minos="$(check_platform "$binary" "the application executable")"
note "application minimum iOS: $app_minos"

# --- Launcher and Fallout 1 engine (inside the executable) ------------------

defined_symbols "$binary" > "$work/app-defined.txt"

grep -q '^_fallout_ios_present_launcher$' "$work/app-defined.txt" \
    || fail "the launcher entry point is not in the application"
grep -q '^_fallout_engine_api$' "$work/app-defined.txt" \
    || fail "the Fallout 1 engine adapter is not in the application"

symbols_text "$binary" > "$work/app-demangled.txt"
grep -q 'gnw_main' "$work/app-demangled.txt" \
    || fail "the Fallout 1 engine is not linked into the application"

# Write strings to a file first: `strings | grep -q` makes grep close the pipe
# and strings fail while flushing, which pipefail turns into a false failure.
strings -a "$binary" > "$work/app-strings.txt"
grep -qx 'fallout1' "$work/app-strings.txt" \
    || fail "the Fallout 1 engine does not identify itself"
note "Fallout 1 engine: present in the application executable"

# The executable must export SDL: the Fallout 2 framework resolves SDL from it.
exported_symbols "$binary" > "$work/app-exported.txt"
grep -q '^_SDL_Init$' "$work/app-exported.txt" \
    || fail "the application does not export SDL_Init for the Fallout 2 engine"

# --- Fallout 2 engine (embedded framework) ----------------------------------

framework="$app/Frameworks/Fallout2Engine.framework"
framework_binary="$framework/Fallout2Engine"
[ -d "$framework" ] || fail "the Fallout 2 framework is not embedded"

# A shallow framework keeps its binary and Info.plist at the top; tolerate the
# versioned layout as well in case the toolchain produces one.
if [ ! -f "$framework_binary" ]; then
    framework_binary="$(find "$framework" -type f -name 'Fallout2Engine' -print -quit)"
fi
[ -f "$framework_binary" ] || fail "the Fallout 2 framework has no binary"

framework_info="$framework/Info.plist"
if [ ! -f "$framework_info" ]; then
    framework_info="$(find "$framework" -type f -name 'Info.plist' -print -quit)"
fi
[ -f "$framework_info" ] || fail "the Fallout 2 framework has no Info.plist"

[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$framework_info")" = "Fallout2Engine" ] \
    || fail "the Fallout 2 framework Info.plist has the wrong CFBundleExecutable"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$framework_info")" = "FMWK" ] \
    || fail "the Fallout 2 framework is not packaged as a framework"

framework_minos="$(check_platform "$framework_binary" "the Fallout 2 framework")"
note "framework minimum iOS: $framework_minos"

defined_symbols "$framework_binary" > "$work/f2-defined.txt"
exported_symbols "$framework_binary" > "$work/f2-exported.txt"
grep -q '^_fallout_engine_api$' "$work/f2-exported.txt" \
    || fail "the Fallout 2 framework does not export its engine adapter"

# The framework must not carry its own SDL: it has to resolve SDL from the
# application so the process keeps one event pump and one set of UIKit classes.
if grep -q '^_SDL_Init$' "$work/f2-defined.txt"; then
    fail "the Fallout 2 framework contains its own SDL instead of using the application's"
fi

symbols_text "$framework_binary" > "$work/f2-demangled.txt"
grep -q 'falloutMain' "$work/f2-demangled.txt" \
    || fail "the Fallout 2 engine is not linked into the framework"
strings -a "$framework_binary" > "$work/f2-strings.txt"
grep -qx 'fallout2' "$work/f2-strings.txt" \
    || fail "the Fallout 2 engine does not identify itself"
note "Fallout 2 engine: present in Fallout2Engine.framework"

# --- The two engines must stay in separate images ---------------------------

if grep -q 'falloutMain' "$work/app-demangled.txt"; then
    fail "the Fallout 2 engine is linked into the application executable"
fi
if grep -q 'gnw_main' "$work/f2-demangled.txt"; then
    fail "the Fallout 1 engine is linked into the Fallout 2 framework"
fi
note "engine separation: Fallout 1 and Fallout 2 are in different images"

# Because the framework is linked with -undefined dynamic_lookup, an engine
# symbol missing from its own sources would silently resolve to the identically
# named Fallout 1 function exported by the application. That would mix two
# engines with different structures at runtime, so no Fallout symbol may remain
# undefined in the framework.
engine_undefined="$(undefined_symbols "$framework_binary" \
    | grep -E '^(__ZN7fallout|_iOSGetDocumentsPath$)' || true)"
if [ -n "$engine_undefined" ]; then
    echo "$engine_undefined" | sed -n '1,40p' >&2
    fail "the Fallout 2 framework has undefined engine symbols"
fi
note "engine symbols: the Fallout 2 framework is self-contained"

# --- Unresolved symbols -----------------------------------------------------
#
# The framework is linked with -undefined dynamic_lookup, so a missing SDL
# symbol only appears when it is loaded. Every SDL and SDL Objective-C class
# symbol the framework needs must be exported by the application.

undefined_symbols "$framework_binary" \
    | grep -E '^_(SDL_[A-Za-z0-9_]+|OBJC_CLASS_\$_SDL[A-Za-z0-9_]+)$' \
    | sort -u > "$work/f2-sdl-undefined.txt" || true

if [ -s "$work/f2-sdl-undefined.txt" ]; then
    comm -23 "$work/f2-sdl-undefined.txt" "$work/app-exported.txt" > "$work/f2-sdl-missing.txt"
    if [ -s "$work/f2-sdl-missing.txt" ]; then
        echo "missing SDL symbols:" >&2
        sed -n '1,40p' "$work/f2-sdl-missing.txt" >&2
        fail "$(wc -l < "$work/f2-sdl-missing.txt" | tr -d ' ') SDL symbol(s) are not provided by the application"
    fi
    note "SDL linkage: $(wc -l < "$work/f2-sdl-undefined.txt" | tr -d ' ') framework SDL symbols resolve to the application"
else
    note "SDL linkage: the framework has no undefined SDL symbols"
fi

# Non-SDL undefined symbols must come from the linked or system libraries; list
# them so a change in the engine's dependencies is visible in the log.
undefined_symbols "$framework_binary" \
    | grep -v -E '^_(SDL_[A-Za-z0-9_]+|OBJC_CLASS_\$_SDL[A-Za-z0-9_]+)$' \
    | grep -v -E '^$' > "$work/f2-other-undefined.txt" || true
if [ -s "$work/f2-other-undefined.txt" ]; then
    note "non-SDL undefined symbols in the framework: $(wc -l < "$work/f2-other-undefined.txt" | tr -d ' ') (resolved from libSystem, libc++ and zlib)"
fi

# --- IPA structure ----------------------------------------------------------

if [ -n "$(find "$work/Payload" -mindepth 1 -maxdepth 1 ! -name '*.app' -print -quit)" ]; then
    fail "Payload contains entries other than the application"
fi

# --- Bundled artwork --------------------------------------------------------

for artwork in fallout1.webp fallout2.jpeg; do
    if [ ! -f "$app/$artwork" ]; then
        fail "the application bundle is missing $artwork"
    fi
done
note "artwork: both game stills are bundled"

# --- Bundled notices --------------------------------------------------------

# The licences the app carries ask for their text to travel with it, so every
# notice in the repository's Notices folder has to be inside the bundle. A
# packaging change that stops copying them would otherwise ship silently.
notices="$app/Notices"
[ -d "$notices" ] || fail "the application bundle has no Notices folder"

notice_count=0
for source in os/ios/Notices/*; do
    [ -f "$source" ] || continue
    name="$(basename "$source")"
    [ -f "$notices/$name" ] || fail "the application bundle is missing the notice $name"
    notice_count=$((notice_count + 1))
done
[ "$notice_count" -gt 0 ] || fail "the repository holds no notices to check"
note "notices: $notice_count licence files are bundled in Notices/"

note "IPA structure: Payload/$(basename "$app") with Frameworks/Fallout2Engine.framework"
note "all checks passed"
