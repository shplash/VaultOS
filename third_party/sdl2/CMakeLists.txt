# Build static lib only
set(BUILD_SHARED_LIBS OFF)
set(SDL_SHARED OFF)
set(SDL_STATIC ON)

# Fixes _ftol2_sse already defined
set(SDL_LIBC ON)

if (ANDROID)
    set(SDL_STATIC_PIC ON)
endif()

include(FetchContent)

# CMake 4's external-project step looks up a git version before it will decide
# what to do about submodules. Finding git here fills that in, and the two
# options below stop the step from asking at all - SDL has no submodules, so
# there is nothing to recurse into. This is the configure failure the arm64
# image hit: "git version 1.6.5 or later required for --recursive flag with
# 'git submodule ...': Git_VERSION=''".
find_package(Git QUIET)

FetchContent_Declare(sdl2
    GIT_REPOSITORY "https://github.com/libsdl-org/SDL"
    GIT_TAG "release-2.26.1"
    GIT_SUBMODULES ""
    GIT_SUBMODULES_RECURSE FALSE
)

FetchContent_GetProperties(sdl2)
if (NOT sdl2_POPULATED)
    FetchContent_Populate(sdl2)
endif()

add_subdirectory(${sdl2_SOURCE_DIR} ${sdl2_BINARY_DIR} EXCLUDE_FROM_ALL)

set(SDL2_INCLUDE_DIRS ${sdl2_SOURCE_DIR} ${sdl2_BINARY_DIR} PARENT_SCOPE)
set(SDL2_LIBRARIES SDL2-static SDL2::SDL2main PARENT_SCOPE)
