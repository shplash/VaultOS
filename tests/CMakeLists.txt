# The host tests: the launcher is portable C++ and needs neither the iOS SDK
# nor either engine, so it is tested natively. The archive reader it carries
# needs libarchive, which is built here from the same pinned release the
# application uses, for this machine instead of the device.
cmake_minimum_required(VERSION 3.20 FATAL_ERROR)

project(vaultos_tests C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED YES)
set(CMAKE_CXX_EXTENSIONS NO)

# The tests write their own 7z fixtures, which the LZMA encoders do.
set(VAULTOS_ARCHIVE_FIXTURES ON CACHE BOOL "" FORCE)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libarchive" libarchive)

add_executable(launcher-tests
    launcher_validation_test.cc
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/launcher/launcher_archive.cc"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/launcher/launcher_core.cc"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/launcher/launcher_disc.cc"
)
target_include_directories(launcher-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_compile_options(launcher-tests PRIVATE -Wall -Wextra)
target_link_libraries(launcher-tests archive::archive z)

add_executable(movie-subtitle-tests movie_subtitle_test.cc)
target_include_directories(movie-subtitle-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_compile_options(movie-subtitle-tests PRIVATE -Wall -Wextra)
