cmake_minimum_required(VERSION 3.13)

set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)

set(EXECUTABLE_NAME vaultos)

# VaultOS is an iOS application: the launcher and both engines ship in one app.
# Configure it with the iOS toolchain; there is no desktop or Android target.
if(NOT IOS)
    message(FATAL_ERROR "VaultOS is built for iOS only: pass -D CMAKE_TOOLCHAIN_FILE=cmake/toolchain/ios.toolchain.cmake -D PLATFORM=OS64.")
endif()

# SwiftUI requires iOS 14 (SwiftUI is 13, file importers are 14). The ios-cmake
# toolchain reads DEPLOYMENT_TARGET and otherwise defaults to iOS 11, so set
# both that and CMake's own deployment target.
set(DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum iOS deployment target")
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "")
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "")

project(${EXECUTABLE_NAME})

# The launcher UI is written in Swift.
set(CMAKE_Swift_LANGUAGE_VERSION 5.0)
enable_language(Swift)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED YES)
set(CMAKE_CXX_EXTENSIONS NO)

option(ASAN "Enable address sanitizer" OFF)
option(UBSAN "Enable undefined behaviour sanitizer" OFF)

add_executable(${EXECUTABLE_NAME} MACOSX_BUNDLE)

if(ASAN)
    target_compile_options(${EXECUTABLE_NAME} PUBLIC "-fsanitize=address;-fsanitize-recover=address")
    target_link_options(${EXECUTABLE_NAME} PUBLIC "-fsanitize=address;-fsanitize-recover=address")
endif()
if(UBSAN)
    target_compile_options(${EXECUTABLE_NAME} PUBLIC "-fsanitize=undefined")
    target_link_options(${EXECUTABLE_NAME} PUBLIC "-fsanitize=undefined")
endif()

target_include_directories(${EXECUTABLE_NAME} PUBLIC src)

# The commit this build came from, so the engine log can name the source it was
# made from. Passed by CI as -D VAULTOS_BUILD_SHA=<sha>; empty in a local build.
configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/os/ios/engine/vaultos_build_sha.h.in"
    "${CMAKE_CURRENT_BINARY_DIR}/vaultos_build_sha.h"
    @ONLY
)
target_include_directories(${EXECUTABLE_NAME} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")

# ---------------------------------------------------------------------------
# Fallout 1 CE engine
#
# The launcher is the executable and the Fallout 1 engine is linked into it,
# entered through os/ios/engine/engine_fallout1.cc. SDL_main lives in
# os/ios/host/HostMain.mm: the launcher runs first, then the chosen engine.
# ---------------------------------------------------------------------------

set(FALLOUT1_ENGINE_SOURCES
    "src/game/actions.cc"
    "src/game/actions.h"
    "src/game/amutex.cc"
    "src/game/amutex.h"
    "src/game/anim.cc"
    "src/game/anim.h"
    "src/game/art.cc"
    "src/game/art.h"
    "src/game/automap.cc"
    "src/game/automap.h"
    "src/game/bmpdlog.cc"
    "src/game/bmpdlog.h"
    "src/game/cache.cc"
    "src/game/cache.h"
    "src/game/combat_defs.h"
    "src/game/combat.cc"
    "src/game/combat.h"
    "src/game/combatai.cc"
    "src/game/combatai.h"
    "src/game/config.cc"
    "src/game/config.h"
    "src/game/credits.cc"
    "src/game/credits.h"
    "src/game/critter.cc"
    "src/game/critter.h"
    "src/game/cycle.cc"
    "src/game/cycle.h"
    "src/game/display.cc"
    "src/game/display.h"
    "src/game/editor.cc"
    "src/game/editor.h"
    "src/game/elevator.cc"
    "src/game/elevator.h"
    "src/game/endgame.cc"
    "src/game/endgame.h"
    "src/game/fontmgr.cc"
    "src/game/fontmgr.h"
    "src/game/game_vars.h"
    "src/game/game.cc"
    "src/game/game.h"
    "src/game/gconfig.cc"
    "src/game/gconfig.h"
    "src/game/gdebug.cc"
    "src/game/gdebug.h"
    "src/game/gdialog.cc"
    "src/game/gdialog.h"
    "src/game/gmemory.cc"
    "src/game/gmemory.h"
    "src/game/gmouse.cc"
    "src/game/gmouse.h"
    "src/game/gmovie.cc"
    "src/game/gmovie.h"
    "src/game/graphlib.cc"
    "src/game/graphlib.h"
    "src/game/gsound.cc"
    "src/game/gsound.h"
    "src/game/heap.cc"
    "src/game/heap.h"
    "src/game/intface.cc"
    "src/game/intface.h"
    "src/game/inventry.cc"
    "src/game/inventry.h"
    "src/game/item.cc"
    "src/game/item.h"
    "src/game/light.cc"
    "src/game/light.h"
    "src/game/lip_sync.cc"
    "src/game/lip_sync.h"
    "src/game/loadsave.cc"
    "src/game/loadsave.h"
    "src/game/main.cc"
    "src/game/main.h"
    "src/game/mainmenu.cc"
    "src/game/mainmenu.h"
    "src/game/map_defs.h"
    "src/game/map.cc"
    "src/game/map.h"
    "src/game/message.cc"
    "src/game/message.h"
    "src/game/moviefx.cc"
    "src/game/moviefx.h"
    "src/game/object_types.h"
    "src/game/object.cc"
    "src/game/object.h"
    "src/game/options.cc"
    "src/game/options.h"
    "src/game/palette.cc"
    "src/game/palette.h"
    "src/game/party.cc"
    "src/game/party.h"
    "src/game/perk_defs.h"
    "src/game/perk.cc"
    "src/game/perk.h"
    "src/game/pipboy.cc"
    "src/game/pipboy.h"
    "src/game/protinst.cc"
    "src/game/protinst.h"
    "src/game/proto_types.h"
    "src/game/proto.cc"
    "src/game/proto.h"
    "src/game/queue.cc"
    "src/game/queue.h"
    "src/game/reaction.cc"
    "src/game/reaction.h"
    "src/game/roll.cc"
    "src/game/roll.h"
    "src/game/scripts.cc"
    "src/game/scripts.h"
    "src/game/select.cc"
    "src/game/select.h"
    "src/game/selfrun.cc"
    "src/game/selfrun.h"
    "src/game/sfxcache.cc"
    "src/game/sfxcache.h"
    "src/game/sfxlist.cc"
    "src/game/sfxlist.h"
    "src/game/skill_defs.h"
    "src/game/skill.cc"
    "src/game/skill.h"
    "src/game/skilldex.cc"
    "src/game/skilldex.h"
    "src/game/stat_defs.h"
    "src/game/stat.cc"
    "src/game/stat.h"
    "src/game/textobj.cc"
    "src/game/textobj.h"
    "src/game/tile.cc"
    "src/game/tile.h"
    "src/game/trait.cc"
    "src/game/trait.h"
    "src/game/version.cc"
    "src/game/version.h"
    "src/game/wordwrap.cc"
    "src/game/wordwrap.h"
    "src/game/worldmap_walkmask.cc"
    "src/game/worldmap_walkmask.h"
    "src/game/worldmap.cc"
    "src/game/worldmap.h"
    "src/int/audio.cc"
    "src/int/audio.h"
    "src/int/audiof.cc"
    "src/int/audiof.h"
    "src/int/datafile.cc"
    "src/int/datafile.h"
    "src/int/dialog.cc"
    "src/int/dialog.h"
    "src/int/export.cc"
    "src/int/export.h"
    "src/int/intlib.cc"
    "src/int/intlib.h"
    "src/int/intrpret.cc"
    "src/int/intrpret.h"
    "src/int/memdbg.cc"
    "src/int/memdbg.h"
    "src/int/mousemgr.cc"
    "src/int/mousemgr.h"
    "src/int/movie.cc"
    "src/int/movie.h"
    "src/int/nevs.cc"
    "src/int/nevs.h"
    "src/int/pcx.cc"
    "src/int/pcx.h"
    "src/int/region.cc"
    "src/int/region.h"
    "src/int/share1.cc"
    "src/int/share1.h"
    "src/int/sound.cc"
    "src/int/sound.h"
    "src/int/support/intextra.cc"
    "src/int/support/intextra.h"
    "src/int/widget.cc"
    "src/int/widget.h"
    "src/int/window.cc"
    "src/int/window.h"
    "src/plib/assoc/assoc.cc"
    "src/plib/assoc/assoc.h"
    "src/plib/color/color.cc"
    "src/plib/color/color.h"
    "src/plib/db/db.cc"
    "src/plib/db/db.h"
    "src/plib/db/lzss.cc"
    "src/plib/db/lzss.h"
    "src/plib/gnw/button.cc"
    "src/plib/gnw/button.h"
    "src/plib/gnw/debug.cc"
    "src/plib/gnw/debug.h"
    "src/plib/gnw/dxinput.cc"
    "src/plib/gnw/dxinput.h"
    "src/plib/gnw/grbuf.cc"
    "src/plib/gnw/grbuf.h"
    "src/plib/gnw/input.cc"
    "src/plib/gnw/input.h"
    "src/plib/gnw/gnw_types.h"
    "src/plib/gnw/gnw.cc"
    "src/plib/gnw/gnw.h"
    "src/plib/gnw/intrface.cc"
    "src/plib/gnw/intrface.h"
    "src/plib/gnw/kb.cc"
    "src/plib/gnw/kb.h"
    "src/plib/gnw/memory.cc"
    "src/plib/gnw/memory.h"
    "src/plib/gnw/mouse.cc"
    "src/plib/gnw/mouse.h"
    "src/plib/gnw/rect.cc"
    "src/plib/gnw/rect.h"
    "src/plib/gnw/svga_types.h"
    "src/plib/gnw/svga.cc"
    "src/plib/gnw/svga.h"
    "src/plib/gnw/text.cc"
    "src/plib/gnw/text.h"
    "src/plib/gnw/vcr.cc"
    "src/plib/gnw/vcr.h"
    "src/plib/gnw/winmain.h"
    "src/movie_lib.cc"
    "src/movie_lib.h"
)

set(FALLOUT1_RUNTIME_SOURCES
    "src/audio_engine.cc"
    "src/audio_engine.h"
    "src/fps_limiter.cc"
    "src/fps_limiter.h"
    "src/platform_compat.cc"
    "src/platform_compat.h"
    "src/pointer_registry.cc"
    "src/pointer_registry.h"
    "src/plib/gnw/touch.cc"
    "src/plib/gnw/touch.h"
)

target_sources(${EXECUTABLE_NAME} PUBLIC
    ${FALLOUT1_ENGINE_SOURCES}
    ${FALLOUT1_RUNTIME_SOURCES}
)

if(IOS)
    # The launcher application owns the process entry point (os/ios/host) and
    # links the Fallout 1 engine through its adapter. src/platform/ios/paths.mm
    # is replaced by engine_paths.cc, which returns the installation the
    # launcher selected instead of always using the Documents folder.
    target_sources(${EXECUTABLE_NAME} PUBLIC
        "src/platform/ios/paths.h"
        "src/launcher/launcher.h"
        "src/launcher/launcher_core.cc"
        "os/ios/host/HostMain.mm"
        "os/ios/host/host.h"
        "os/ios/engine/engine_glue.cc"
        "os/ios/engine/engine_glue.h"
        "os/ios/engine/engine_paths.cc"
        "os/ios/engine/engine_present.h"
        "os/ios/engine/engine_present.mm"
        "os/ios/engine/engine_fallout1.cc"
        "os/ios/engine/engine_fallout1_globals.cc"
        "os/ios/engine/fallout_engine.h"
        "os/ios/launcher/LauncherBridge.mm"
        "os/ios/launcher/LauncherHost.swift"
        "os/ios/launcher/LauncherModel.swift"
        "os/ios/launcher/LauncherText.swift"
        "os/ios/launcher/LauncherView.swift"
        "os/ios/launcher/VaultTheme.swift"
    )

    target_include_directories(${EXECUTABLE_NAME} PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/os/ios"
        "${CMAKE_CURRENT_SOURCE_DIR}/os/ios/engine"
    )

    target_link_libraries(${EXECUTABLE_NAME} z)
    target_link_libraries(${EXECUTABLE_NAME} "-framework Metal" "-framework QuartzCore" "-framework UIKit")
endif()

if(APPLE)
    if(IOS)
        # Any MP3 in assets/audio is bundled as a theme track, so a song can be
        # dropped in without editing this list. The launcher looks for "maybe"
        # for Fallout, "blue moon" for Fallout 2, and "intro music" as the shared
        # fallback used by any game without a theme of its own.
        file(GLOB MUSIC_RESOURCES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/assets/audio/*.mp3")
        file(GLOB FONT_RESOURCES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/assets/fonts/*")

        set(RESOURCES
            "os/ios/AppIcon.xcassets"
            "os/ios/LaunchScreen.storyboard"
            # The home screen artwork for each game, bundled so the launcher
            # needs no network to show it. These names are the ones
            # LauncherView.heroImage asks the bundle for.
            "${CMAKE_SOURCE_DIR}/assets/artwork/fallout1.webp"
            "${CMAKE_SOURCE_DIR}/assets/artwork/fallout2.jpeg"
            ${MUSIC_RESOURCES}
            ${FONT_RESOURCES}
        )

        target_sources(${EXECUTABLE_NAME} PUBLIC ${RESOURCES})
        set_source_files_properties(${RESOURCES} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")

        set_target_properties(${EXECUTABLE_NAME} PROPERTIES
            MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/os/ios/Info.plist"
            XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon"
            XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.shplash.vaultos"
            XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
            # The Fallout 2 framework resolves SDL through the executable's
            # exported symbols, so those symbols must survive into the IPA.
            XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT "NO"
            Swift_MODULE_NAME "VaultOS"
            XCODE_ATTRIBUTE_PRODUCT_MODULE_NAME "VaultOS"
            XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
            XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_SOURCE_DIR}/src/launcher/launcher.h"
            # Shown in Settings and under the home screen icon.
            XCODE_ATTRIBUTE_MARKETING_VERSION "1.0"
            XCODE_ATTRIBUTE_CURRENT_PROJECT_VERSION "109"
        )

        set(MACOSX_BUNDLE_BUNDLE_NAME "VaultOS")
        set(MACOSX_BUNDLE_DISPLAY_NAME "VaultOS")
    endif()

    set(MACOSX_BUNDLE_GUI_IDENTIFIER "com.shplash.vaultos")
    set(MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0")
    set(MACOSX_BUNDLE_BUNDLE_VERSION "109")
endif()

# The CI run number becomes the build number, so two IPAs from two runs are
# told apart by Settings and by the About page instead of both saying 109.
if(VAULTOS_BUILD)
    set(MACOSX_BUNDLE_BUNDLE_VERSION "${VAULTOS_BUILD}")
    set_target_properties(${EXECUTABLE_NAME} PROPERTIES
        XCODE_ATTRIBUTE_CURRENT_PROJECT_VERSION "${VAULTOS_BUILD}")
endif()

add_subdirectory("third_party/sdl2")

add_subdirectory("third_party/adecode")
target_link_libraries(${EXECUTABLE_NAME} adecode::adecode)

add_subdirectory("third_party/fpattern")
target_link_libraries(${EXECUTABLE_NAME} fpattern::fpattern)

target_link_libraries(${EXECUTABLE_NAME} ${SDL2_LIBRARIES})
target_include_directories(${EXECUTABLE_NAME} PRIVATE ${SDL2_INCLUDE_DIRS})

if(IOS)
    # Fallout 2 CE is built as Fallout2Engine.framework and loaded with dlopen
    # only when the player selects Fallout 2. Both engines define thousands of
    # identical C++ symbols (namespace fallout, global state, SDL entry points),
    # so a single executable cannot contain both. A framework gives the second
    # engine its own image, its own globals and its own shutdown path, while
    # still shipping inside this one application.
    #
    # SDL is deliberately NOT duplicated: the launcher executable already owns
    # the one SDL instance and the UIKit classes it installs. Exporting the
    # executable's symbols (and force-loading all of SDL so none of it is
    # dropped by the linker) lets the framework bind to that same SDL, so only
    # one event pump and one set of SDL globals exist in the process.
    set_target_properties(${EXECUTABLE_NAME} PROPERTIES ENABLE_EXPORTS TRUE)
    target_link_options(${EXECUTABLE_NAME} PRIVATE
        "-Wl,-export_dynamic"
        "-Wl,-force_load,$<TARGET_FILE:SDL2-static>"
    )

    include(FetchContent)

    # Pinned upstream revision:
    #   alexbatalov/fallout2-ce e97087b9582f37075db347a89898887320753f8b
    #     "Remove pause window", 2025-02-16
    FetchContent_Declare(fallout2_ce
        GIT_REPOSITORY "https://github.com/alexbatalov/fallout2-ce"
        GIT_TAG "e97087b9582f37075db347a89898887320753f8b"
        GIT_PROGRESS TRUE
    )

    FetchContent_GetProperties(fallout2_ce)
    if(NOT fallout2_ce_POPULATED)
        # Populate rather than MakeAvailable: upstream's CMakeLists builds a
        # second application bundle with its own SDL, which is the last thing
        # wanted here. CMP0169 turns the single-argument form into an error in
        # future CMake; keep it working on purpose.
        if(POLICY CMP0169)
            cmake_policy(SET CMP0169 OLD)
        endif()
        FetchContent_Populate(fallout2_ce)
    endif()

    if(NOT EXISTS "${fallout2_ce_SOURCE_DIR}/src/main.cc")
        message(FATAL_ERROR "Fallout 2 CE sources are missing from ${fallout2_ce_SOURCE_DIR}.")
    endif()

    # Upstream's own CMakeLists builds a second application bundle with its own
    # copies of SDL, zlib and fpattern. Only its engine sources are wanted here,
    # so every translation unit under src/ is compiled. win32.cc is excluded
    # because it owns the standalone entry point and gProgramIsActive, both
    # provided by the adapter; platform/ios/paths.mm is a .mm file and is
    # provided by engine_paths.cc.
    file(GLOB FALLOUT2_CE_SOURCES CONFIGURE_DEPENDS
        "${fallout2_ce_SOURCE_DIR}/src/*.cc"
    )
    list(REMOVE_ITEM FALLOUT2_CE_SOURCES
        "${fallout2_ce_SOURCE_DIR}/src/win32.cc"
        "${fallout2_ce_SOURCE_DIR}/src/movie.cc"
        "${fallout2_ce_SOURCE_DIR}/src/game_movie.cc"
        "${fallout2_ce_SOURCE_DIR}/src/combat.cc"
        "${fallout2_ce_SOURCE_DIR}/src/input.cc"
        "${fallout2_ce_SOURCE_DIR}/src/mouse.cc"
        "${fallout2_ce_SOURCE_DIR}/src/touch.cc"
        "${fallout2_ce_SOURCE_DIR}/src/loadsave.cc"
        "${fallout2_ce_SOURCE_DIR}/src/svga.cc"
    )

    if(NOT FALLOUT2_CE_SOURCES)
        message(FATAL_ERROR "Fallout 2 CE source files were not found.")
    endif()

    add_library(Fallout2Engine SHARED
        ${FALLOUT2_CE_SOURCES}
        "os/ios/engine/engine_fallout2_game_movie.cc"
        "os/ios/engine/engine_fallout2_movie.cc"
        "os/ios/engine/engine_fallout2_combat.cc"
        "os/ios/engine/engine_fallout2_input.cc"
        "os/ios/engine/engine_fallout2_loadsave.cc"
        "os/ios/engine/engine_fallout2_mouse.cc"
        "os/ios/engine/engine_fallout2_touch.cc"
        "os/ios/engine/engine_fallout2_svga.cc"
        "os/ios/engine/engine_glue.cc"
        "os/ios/engine/engine_paths.cc"
        "os/ios/engine/engine_fallout2.cc"
        "os/ios/engine/engine_fallout2_globals.cc"
    )

    # The framework does not link SDL (it resolves SDL from the application at
    # load time), so it cannot inherit SDL's include directories from the
    # SDL2-static target. SDL 2.26 generates its headers into the build tree
    # (include/ plus include-config-<config>/), and ${SDL2_INCLUDE_DIRS} only
    # names the source and build roots, so take the target's include interface
    # explicitly instead of guessing at the generated layout.
    target_include_directories(Fallout2Engine PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/os/ios/engine"
        "${fallout2_ce_SOURCE_DIR}/src"
        "$<TARGET_PROPERTY:SDL2-static,INTERFACE_INCLUDE_DIRECTORIES>"
    )

    # zlib comes from the iOS SDK; fpattern is shared with the engine already in
    # the executable (static, so each image gets its own copy).
    target_link_libraries(Fallout2Engine fpattern::fpattern z)

    # SDL symbols intentionally remain undefined in the framework; they are
    # resolved from the launcher executable when the framework is loaded. Every
    # other dependency must be linked normally above.
    target_link_options(Fallout2Engine PRIVATE "-Wl,-undefined,dynamic_lookup")

    set_target_properties(Fallout2Engine PROPERTIES
        FRAMEWORK TRUE
        MACOSX_FRAMEWORK_IDENTIFIER "com.shplash.vaultos.Fallout2Engine"
        MACOSX_FRAMEWORK_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/os/ios/engine/FrameworkInfo.plist.in"
        INSTALL_NAME_DIR "@rpath"
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.shplash.vaultos.Fallout2Engine"
        XCODE_ATTRIBUTE_SKIP_INSTALL YES
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
        XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO
    )

    add_dependencies(${EXECUTABLE_NAME} Fallout2Engine)
endif()

if(APPLE)
    if(IOS)
        install(TARGETS ${EXECUTABLE_NAME} DESTINATION "Payload")

        # The framework has to live in the application's Frameworks directory.
        # Installing it after the application bundle puts it inside the bundle
        # CPack packages. A POST_BUILD copy cannot be used here: the Xcode
        # generator leaves ${EFFECTIVE_PLATFORM_NAME} unexpanded in the shell
        # command, so the source path would not exist.
        install(TARGETS Fallout2Engine
            FRAMEWORK
            DESTINATION "Payload/${EXECUTABLE_NAME}.app/Frameworks"
        )

        set(CPACK_GENERATOR "ZIP")
        set(CPACK_INCLUDE_TOPLEVEL_DIRECTORY OFF)
        set(CPACK_PACKAGE_FILE_NAME "vaultos")
        set(CPACK_ARCHIVE_FILE_EXTENSION "ipa")
    endif()

    include(CPack)
endif()
