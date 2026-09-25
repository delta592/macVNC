cmake_minimum_required(VERSION 3.18)
project(macVNC VERSION 0.1.0 LANGUAGES C OBJC)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(CMAKE_GENERATOR MATCHES "Unix Makefiles|Ninja")
  add_custom_target(
      macvnc-copy-compile-commands ALL
      ${CMAKE_COMMAND} -E copy_if_different
          ${CMAKE_BINARY_DIR}/compile_commands.json
          ${CMAKE_CURRENT_SOURCE_DIR}
      )
endif()

#
# Speed: ccache is required (override with -DMACVNC_USE_CCACHE=OFF)
#
option(MACVNC_USE_CCACHE "Require ccache as the C/ObjC compiler launcher" ON)
if(MACVNC_USE_CCACHE)
  find_program(MACVNC_CCACHE_PROGRAM ccache)
  if(NOT MACVNC_CCACHE_PROGRAM)
    message(FATAL_ERROR
      "ccache was not found on PATH, but is required for building macVNC.\n"
      "  Install it, then re-run cmake, for example:\n"
      "    brew install ccache\n"
      "    # or: sudo port install ccache\n"
      "    # or: https://ccache.dev/download.html\n"
      "  To bypass (not recommended): -DMACVNC_USE_CCACHE=OFF")
  endif()
  message(STATUS "Using ccache: ${MACVNC_CCACHE_PROGRAM}")
  set(CMAKE_C_COMPILER_LAUNCHER "${MACVNC_CCACHE_PROGRAM}")
  set(CMAKE_OBJC_COMPILER_LAUNCHER "${MACVNC_CCACHE_PROGRAM}")
endif()

#
# Code coverage (Apple Clang / LLVM instrumentation)
#
option(MACVNC_ENABLE_COVERAGE "Build with LLVM source-based coverage" OFF)
if(MACVNC_ENABLE_COVERAGE)
  message(STATUS "Coverage instrumentation enabled")
  add_compile_options(-fprofile-instr-generate -fcoverage-mapping -O0 -g)
  add_link_options(-fprofile-instr-generate)
endif()

#
# Platform targets
#
# Default: universal (arm64 + x86_64) for a single .app that runs on Apple
# Silicon and Intel. Requires fat/universal dependency libraries built via
# scripts/build-deps.sh (see README).
# Override with -DMACVNC_UNIVERSAL=OFF or -DCMAKE_OSX_ARCHITECTURES=arm64.
#
option(MACVNC_UNIVERSAL "Build a universal (arm64;x86_64) binary" ON)
if(APPLE)
  if(NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET OR CMAKE_OSX_DEPLOYMENT_TARGET STREQUAL "")
    set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "Minimum macOS version" FORCE)
  endif()
  if(MACVNC_UNIVERSAL AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "macOS architectures" FORCE)
  endif()
endif()

#
# From-source dependency prefix (scripts/build-deps.sh)
#
# Prefer an explicit -DCMAKE_PREFIX_PATH / MACVNC_DEPS_PREFIX, otherwise look
# for deps/prefix/universal then the host-arch prefix. Package-manager paths
# (/opt/homebrew, /opt/local) are intentionally ignored.
#
list(APPEND CMAKE_IGNORE_PREFIX_PATH /opt/homebrew /opt/local /usr/local)
list(APPEND CMAKE_IGNORE_PATH
  /opt/homebrew /opt/homebrew/bin /opt/homebrew/lib /opt/homebrew/include
  /opt/local /opt/local/bin /opt/local/lib /opt/local/include
  /usr/local /usr/local/bin /usr/local/lib /usr/local/include)

set(MACVNC_DEPS_PREFIX "" CACHE PATH "Prefix from scripts/build-deps.sh")
if(DEFINED ENV{MACVNC_DEPS_PREFIX} AND NOT "$ENV{MACVNC_DEPS_PREFIX}" STREQUAL "")
  set(MACVNC_DEPS_PREFIX "$ENV{MACVNC_DEPS_PREFIX}" CACHE PATH "Prefix from scripts/build-deps.sh" FORCE)
endif()
if(NOT MACVNC_DEPS_PREFIX)
  set(_macvnc_deps_candidates
    "${CMAKE_SOURCE_DIR}/deps/prefix/universal"
    "${CMAKE_SOURCE_DIR}/deps/prefix/arm64"
    "${CMAKE_SOURCE_DIR}/deps/prefix/x86_64"
  )
  foreach(_cand IN LISTS _macvnc_deps_candidates)
    if(EXISTS "${_cand}/lib/libvncserver.a" OR EXISTS "${_cand}/lib/libvncserver.dylib")
      set(MACVNC_DEPS_PREFIX "${_cand}" CACHE PATH "Prefix from scripts/build-deps.sh" FORCE)
      break()
    endif()
  endforeach()
endif()
if(NOT MACVNC_DEPS_PREFIX)
  message(FATAL_ERROR
    "From-source dependencies not found. Run ./scripts/build-deps.sh first "
    "(or pass -DMACVNC_DEPS_PREFIX=/path/to/deps/prefix/<arch>).")
endif()
# Resolve symlinks (universal → arm64) for clearer logs and find paths.
get_filename_component(MACVNC_DEPS_PREFIX "${MACVNC_DEPS_PREFIX}" REALPATH)
list(PREPEND CMAKE_PREFIX_PATH "${MACVNC_DEPS_PREFIX}")
set(OPENSSL_ROOT_DIR "${MACVNC_DEPS_PREFIX}" CACHE PATH "OpenSSL root from macVNC deps" FORCE)
set(OPENSSL_USE_STATIC_LIBS TRUE CACHE BOOL "Prefer static OpenSSL from deps" FORCE)
set(LibVNCServer_DIR "${MACVNC_DEPS_PREFIX}/lib/cmake/LibVNCServer" CACHE PATH
  "LibVNCServer CMake package dir" FORCE)
# Drop stale Homebrew/MacPorts results from prior configures.
unset(OPENSSL_CRYPTO_LIBRARY CACHE)
unset(OPENSSL_SSL_LIBRARY CACHE)
unset(OPENSSL_INCLUDE_DIR CACHE)
unset(OPENSSL_LIBRARIES CACHE)
message(STATUS "Using from-source deps prefix: ${MACVNC_DEPS_PREFIX}")

#
# Dependencies
#
# LibVNCServer MUST provide TLS via OpenSSL (LIBVNCSERVER_HAVE_LIBSSL) and
# WebSockets (LIBVNCSERVER_WITH_WEBSOCKETS) for the sslctx I/O path.
# OpenSSL is also required for certificate generation (cert_manager.c).
# Build both with: ./scripts/build-deps.sh
#
find_package(OpenSSL REQUIRED)
find_package(Threads REQUIRED)
find_library(CARBON_LIBRARY Carbon REQUIRED)
find_library(IOKIT_LIBRARY IOKit REQUIRED)
find_library(SCREEN_CAPTURE_KIT ScreenCaptureKit REQUIRED)
find_library(CORE_MEDIA CoreMedia)
find_library(CORE_VIDEO CoreVideo)
find_library(FOUNDATION Foundation)
find_library(ZLIB_LIBRARY z REQUIRED)
find_library(SASL2_LIBRARY sasl2)

find_package(LibVNCServer REQUIRED)
get_target_property(LIBVNCSERVER_LIBRARY LibVNCServer::vncserver IMPORTED_LOCATION)
if(NOT LIBVNCSERVER_LIBRARY)
  get_target_property(LIBVNCSERVER_LIBRARY LibVNCServer::vncserver IMPORTED_LOCATION_RELEASE)
endif()
if(NOT LIBVNCSERVER_LIBRARY)
  message(FATAL_ERROR "LibVNCServer::vncserver has no IMPORTED_LOCATION")
endif()
# Refuse accidentally-selected package-manager dylibs.
if(LIBVNCSERVER_LIBRARY MATCHES "/opt/homebrew/|/opt/local/|/usr/local/")
  message(FATAL_ERROR
    "LibVNCServer resolved to a package-manager library (${LIBVNCSERVER_LIBRARY}). "
    "Expected a from-source archive under deps/prefix. Re-run scripts/build-deps.sh "
    "and reconfigure in a clean build directory.")
endif()
message(STATUS "LibVNCServer: ${LIBVNCSERVER_LIBRARY}")
message(STATUS "OpenSSL include: ${OPENSSL_INCLUDE_DIR}")

# Static LibVNCServer needs zlib (+ OpenSSL, already linked below). SASL if present.
if(LIBVNCSERVER_LIBRARY MATCHES "\\.(a)$")
  set_property(TARGET LibVNCServer::vncserver APPEND PROPERTY
    INTERFACE_LINK_LIBRARIES "${ZLIB_LIBRARY}")
  if(SASL2_LIBRARY)
    set_property(TARGET LibVNCServer::vncserver APPEND PROPERTY
      INTERFACE_LINK_LIBRARIES "${SASL2_LIBRARY}")
  endif()
endif()

# Universal builds need fat dependency archives/dylibs from build-deps.sh.
if(APPLE AND MACVNC_UNIVERSAL AND LIBVNCSERVER_LIBRARY)
  execute_process(
    COMMAND lipo -archs "${LIBVNCSERVER_LIBRARY}"
    OUTPUT_VARIABLE _vnc_archs
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
  string(REPLACE " " ";" _vnc_arch_list "${_vnc_archs}")
  list(FIND _vnc_arch_list "arm64" _has_arm)
  list(FIND _vnc_arch_list "x86_64" _has_x86)
  if(_has_arm LESS 0 OR _has_x86 LESS 0)
    message(FATAL_ERROR
      "LibVNCServer at ${LIBVNCSERVER_LIBRARY} is not universal (${_vnc_archs}). "
      "Run ./scripts/build-deps.sh (both arches) or pass -DMACVNC_UNIVERSAL=OFF. "
      "See README.")
  endif()
endif()

if(APPLE)
  message(STATUS "macOS deployment target: ${CMAKE_OSX_DEPLOYMENT_TARGET}")
  if(CMAKE_OSX_ARCHITECTURES)
    message(STATUS "macOS architectures: ${CMAKE_OSX_ARCHITECTURES}")
  else()
    message(STATUS "macOS architectures: (native)")
  endif()
endif()

#
# Sources
#
set(SOURCE_FILES
    src/ScreenCapturer.h
    src/ScreenCapturer.m
    src/cert_manager.h
    src/cert_manager.c
    src/vencrypt.h
    src/vencrypt.c
    src/mac.m
    src/icon.icns
)

#
# Build bundle
#
set(MACOSX_BUNDLE_COPYRIGHT "© 2024 Christian Beier (macvnc@christianbeier.net)")
set(MACOSX_BUNDLE_GUI_IDENTIFIER "net.macvnc.app")
set(MACOSX_BUNDLE_BUNDLE_NAME ${PROJECT_NAME})
set(MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION})
set(MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION})
set(MACOSX_BUNDLE_ICON_FILE icon.icns)
set_source_files_properties(src/icon.icns PROPERTIES MACOSX_PACKAGE_LOCATION Resources)

add_executable(${PROJECT_NAME} MACOSX_BUNDLE ${SOURCE_FILES})

target_link_libraries(${PROJECT_NAME} LibVNCServer::vncserver OpenSSL::SSL OpenSSL::Crypto
  ${CMAKE_THREAD_LIBS_INIT} ${ZLIB_LIBRARY} ${CARBON_LIBRARY} ${IOKIT_LIBRARY}
  ${SCREEN_CAPTURE_KIT}
  ${CORE_MEDIA}
  ${CORE_VIDEO}
  ${FOUNDATION})

#
# Unit tests (CTest always; optional XCTest when using the Xcode generator)
#
option(MACVNC_BUILD_TESTS "Build CTest unit tests" ON)
option(MACVNC_BUILD_XCTEST "Build XCTest bundle (Xcode generator)" OFF)

if(MACVNC_BUILD_TESTS)
  enable_testing()

  add_executable(test_cert_manager
    tests/test_cert_manager.c
    src/cert_manager.c
  )
  target_include_directories(test_cert_manager PRIVATE src tests)
  target_link_libraries(test_cert_manager
    LibVNCServer::vncserver OpenSSL::SSL OpenSSL::Crypto ${ZLIB_LIBRARY})
  add_test(NAME cert_manager COMMAND test_cert_manager)
  set_tests_properties(cert_manager PROPERTIES
    ENVIRONMENT "LLVM_PROFILE_FILE=${CMAKE_BINARY_DIR}/test_cert_manager-%p.profraw")

  add_executable(test_security_mode tests/test_security_mode.c)
  target_include_directories(test_security_mode PRIVATE src tests)
  # Header-only under test; still need rfb/rfb.h from LibVNCServer for the enum header.
  target_link_libraries(test_security_mode LibVNCServer::vncserver ${ZLIB_LIBRARY})
  add_test(NAME security_mode COMMAND test_security_mode)
  set_tests_properties(security_mode PROPERTIES
    ENVIRONMENT "LLVM_PROFILE_FILE=${CMAKE_BINARY_DIR}/test_security_mode-%p.profraw")
endif()

if(MACVNC_BUILD_XCTEST)
  if(NOT CMAKE_GENERATOR MATCHES "Xcode")
    message(WARNING "MACVNC_BUILD_XCTEST is most useful with -G Xcode")
  endif()
  find_package(XCTest REQUIRED)
  xctest_add_bundle(MacVNCTests ${PROJECT_NAME}
    tests/MacVNCTests.m
    src/cert_manager.c
  )
  target_include_directories(MacVNCTests PRIVATE src)
  target_link_libraries(MacVNCTests
    LibVNCServer::vncserver OpenSSL::SSL OpenSSL::Crypto ${ZLIB_LIBRARY})
  xctest_add_test(XCTest.MacVNC MacVNCTests)
endif()

#
# Install, i.e. finalise bundle
#
set(APP ${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}.app)
set(DIRS "")
INSTALL(CODE "
set(BU_CHMOD_BUNDLE_ITEMS ON)
include(BundleUtilities)
fixup_bundle(\"${APP}\"   \"\"   \"${DIRS}\")
   " COMPONENT Runtime)
INSTALL(FILES README.md DESTINATION ${APP}/Contents/Resources)
