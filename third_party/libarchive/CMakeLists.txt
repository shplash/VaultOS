# libarchive reads the 7z and RAR archives the importer unpacks. It is built
# static, with the readers only and without any external compression library
# except the iOS SDK's zlib, so the application carries nothing the importer
# does not use.
#
# The 7z reader decodes LZMA and LZMA2 through liblzma, and iOS ships no such
# library, so xz's liblzma is built here too: its decoders only, without the
# xz tool, its scripts or its tests.
include(FetchContent)

find_package(Git QUIET)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

# The host tests write their own 7z fixtures, which needs the LZMA encoders as
# well. The application never writes an archive, so it leaves them out.
option(VAULTOS_ARCHIVE_FIXTURES "Build the LZMA encoders too, for the tests" OFF)

# ---------------------------------------------------------------------------
# liblzma: the LZMA1 and LZMA2 decoder the 7z and RAR readers need
# ---------------------------------------------------------------------------

set(XZ_THREADS no CACHE STRING "" FORCE)
set(XZ_SMALL OFF CACHE BOOL "" FORCE)
set(XZ_CHECKS crc32 CACHE STRING "" FORCE)
set(XZ_DECODERS "lzma1;lzma2;delta;x86" CACHE STRING "" FORCE)
if(VAULTOS_ARCHIVE_FIXTURES)
    set(XZ_ENCODERS "lzma1;lzma2" CACHE STRING "" FORCE)
    set(XZ_MATCH_FINDERS "bt4" CACHE STRING "" FORCE)
else()
    set(XZ_ENCODERS "" CACHE STRING "" FORCE)
    set(XZ_MATCH_FINDERS "" CACHE STRING "" FORCE)
endif()
set(XZ_MICROLZMA_ENCODER OFF CACHE BOOL "" FORCE)
set(XZ_MICROLZMA_DECODER OFF CACHE BOOL "" FORCE)
set(XZ_LZIP_DECODER OFF CACHE BOOL "" FORCE)
set(XZ_NLS OFF CACHE BOOL "" FORCE)
set(XZ_SYMBOL_VERSIONING no CACHE STRING "" FORCE)
set(XZ_CLMUL_CRC OFF CACHE BOOL "" FORCE)
set(XZ_ARM64_CRC32 OFF CACHE BOOL "" FORCE)
set(XZ_LOONGARCH_CRC32 OFF CACHE BOOL "" FORCE)
set(XZ_ASM_I386 OFF CACHE BOOL "" FORCE)
set(XZ_SANDBOX no CACHE STRING "" FORCE)
set(XZ_TOOL_XZ OFF CACHE BOOL "" FORCE)
set(XZ_TOOL_XZDEC OFF CACHE BOOL "" FORCE)
set(XZ_TOOL_LZMADEC OFF CACHE BOOL "" FORCE)
set(XZ_TOOL_LZMAINFO OFF CACHE BOOL "" FORCE)
set(XZ_TOOL_SYMLINKS OFF CACHE BOOL "" FORCE)
set(XZ_TOOL_SYMLINKS_LZMA OFF CACHE BOOL "" FORCE)
set(XZ_TOOL_SCRIPTS OFF CACHE BOOL "" FORCE)
set(XZ_DOC OFF CACHE BOOL "" FORCE)
set(XZ_DOXYGEN OFF CACHE BOOL "" FORCE)

FetchContent_Declare(xz
    URL "https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.xz"
    URL_HASH SHA256=4ce24038fd4221e0d13bc1a2de7a4db56e90b92b3bf75321f6c14be73f65de4b
)

FetchContent_GetProperties(xz)
if(NOT xz_POPULATED)
    # Populate rather than MakeAvailable: xz's own project options are set
    # above, and the single-argument form has to keep working on future CMake.
    if(POLICY CMP0169)
        cmake_policy(SET CMP0169 OLD)
    endif()
    FetchContent_Populate(xz)
endif()

add_subdirectory(${xz_SOURCE_DIR} ${xz_BINARY_DIR} EXCLUDE_FROM_ALL)

# ---------------------------------------------------------------------------
# libarchive: the 7z and RAR readers, and nothing else
# ---------------------------------------------------------------------------

# libarchive looks for a liblzma of its own, which neither iOS nor macOS has;
# LZMA is turned off here and the library built above is handed to the readers
# below, so their LZMA support is compiled in.
set(ENABLE_LZMA OFF CACHE BOOL "" FORCE)
set(ENABLE_ZLIB ON CACHE BOOL "" FORCE)
set(ENABLE_OPENSSL OFF CACHE BOOL "" FORCE)
set(ENABLE_MBEDTLS OFF CACHE BOOL "" FORCE)
set(ENABLE_NETTLE OFF CACHE BOOL "" FORCE)
set(ENABLE_MD OFF CACHE BOOL "" FORCE)
set(ENABLE_CNG OFF CACHE BOOL "" FORCE)
set(ENABLE_LIBB2 OFF CACHE BOOL "" FORCE)
set(ENABLE_LZ4 OFF CACHE BOOL "" FORCE)
set(ENABLE_LZO OFF CACHE BOOL "" FORCE)
set(ENABLE_ZSTD OFF CACHE BOOL "" FORCE)
set(ENABLE_BZip2 OFF CACHE BOOL "" FORCE)
set(ENABLE_LIBXML2 OFF CACHE BOOL "" FORCE)
set(ENABLE_BSDXML OFF CACHE BOOL "" FORCE)
set(ENABLE_EXPAT OFF CACHE BOOL "" FORCE)
set(ENABLE_WIN32_XMLLITE OFF CACHE BOOL "" FORCE)
set(ENABLE_PCREPOSIX OFF CACHE BOOL "" FORCE)
set(ENABLE_PCRE2POSIX OFF CACHE BOOL "" FORCE)
set(ENABLE_LIBGCC OFF CACHE BOOL "" FORCE)
set(POSIX_REGEX_LIB "NONE" CACHE STRING "" FORCE)
# No iconv: the archive readers convert the names they meet with their own
# tables, and iOS ships no libiconv.
set(ENABLE_ICONV OFF CACHE BOOL "" FORCE)
# The importer writes the files itself, so the disk helpers are not needed.
set(ENABLE_ACL OFF CACHE BOOL "" FORCE)
set(ENABLE_XATTR OFF CACHE BOOL "" FORCE)
set(ENABLE_TAR OFF CACHE BOOL "" FORCE)
set(ENABLE_CPIO OFF CACHE BOOL "" FORCE)
set(ENABLE_CAT OFF CACHE BOOL "" FORCE)
set(ENABLE_UNZIP OFF CACHE BOOL "" FORCE)
set(ENABLE_TEST OFF CACHE BOOL "" FORCE)
set(ENABLE_COVERAGE OFF CACHE BOOL "" FORCE)
set(ENABLE_CLANG_TIDY OFF CACHE BOOL "" FORCE)
set(ENABLE_WERROR OFF CACHE BOOL "" FORCE)
set(ENABLE_INSTALL OFF CACHE BOOL "" FORCE)

FetchContent_Declare(libarchive
    URL "https://github.com/libarchive/libarchive/releases/download/v3.8.11/libarchive-3.8.11.tar.xz"
    URL_HASH SHA256=a3dc0872b1b39da34dc18ef1b944f0f11ffd37425d70ae04be679279f1cf43d2
)

FetchContent_GetProperties(libarchive)
if(NOT libarchive_POPULATED)
    if(POLICY CMP0169)
        cmake_policy(SET CMP0169 OLD)
    endif()
    FetchContent_Populate(libarchive)
endif()

# A cross-compiled check cannot tell whether these exist: the probe compiles a
# call to a function libSystem has but iOS declares nowhere, and a warning is
# not an error there, so the reader would be compiled calling it with no
# prototype, which modern clang refuses. Say once, for every platform, that
# they are not there.
set(HAVE__FSEEKI64 0 CACHE INTERNAL "")
set(HAVE__FTELLI64 0 CACHE INTERNAL "")
set(HAVE_FUTIMESAT 0 CACHE INTERNAL "")

add_subdirectory(${libarchive_SOURCE_DIR} ${libarchive_BINARY_DIR} EXCLUDE_FROM_ALL)

# The readers compile their LZMA support when HAVE_LZMA_H is set: libarchive's
# own check looks for a system liblzma, so it is given the one built here
# instead, and links it.
target_include_directories(archive_static PRIVATE "${xz_SOURCE_DIR}/src/liblzma/api")
target_compile_definitions(archive_static PRIVATE HAVE_LZMA_H=1 HAVE_LIBLZMA=1)
# Plain rather than a keyword signature: libarchive's own CMakeLists links this
# target without one, and a target cannot be given both.
target_link_libraries(archive_static liblzma)

# One interface target for both builds: the application and the host tests add
# this folder and link archive::archive.
add_library(archive INTERFACE)
add_library(archive::archive ALIAS archive)
target_link_libraries(archive INTERFACE archive_static)
target_include_directories(archive INTERFACE "${libarchive_SOURCE_DIR}/libarchive")
