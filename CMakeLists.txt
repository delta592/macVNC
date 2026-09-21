cmake_minimum_required(VERSION 3.18)
project(macVNC VERSION 0.1.0 LANGUAGES C)

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
# Platform targets
#
# Default: universal (arm64 + x86_64) for a single .app that runs on Apple
# Silicon and Intel. Requires fat/universal dependency libraries (see README).
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
# Package-manager prefixes (MacPorts and/or Homebrew)
#
list(APPEND CMAKE_PREFIX_PATH
  /opt/local
  /opt/homebrew
  /usr/local
)
if(DEFINED ENV{PKG_CONFIG_PATH})
  set(ENV{PKG_CONFIG_PATH}
    "/opt/local/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:/usr/local/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}")
else()
  set(ENV{PKG_CONFIG_PATH}
    "/opt/local/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:/usr/local/lib/pkgconfig")
endif()

#
# Dependencies
#
# LibVNCServer MUST provide TLS:
#   Homebrew bottle: OpenSSL (LIBVNCSERVER_HAVE_LIBSSL)
#   MacPorts port:   GnuTLS  (LIBVNCSERVER_HAVE_GNUTLS, WITH_OPENSSL=OFF)
# WebSockets must be enabled (LIBVNCSERVER_WITH_WEBSOCKETS) for the sslctx I/O path.
# OpenSSL is always required here for certificate generation (cert_manager.c).
#
find_package(OpenSSL REQUIRED)
find_package(Threads REQUIRED)
find_package(GnuTLS) # needed when LibVNCServer is the MacPorts/GnuTLS build
find_library(CARBON_LIBRARY Carbon REQUIRED)
find_library(IOKIT_LIBRARY IOKit REQUIRED)
find_library(SCREEN_CAPTURE_KIT ScreenCaptureKit REQUIRED)
find_library(CORE_MEDIA CoreMedia)
find_library(CORE_VIDEO CoreVideo)
find_library(FOUNDATION Foundation)

find_package(LibVNCServer QUIET)
if(NOT LibVNCServer_FOUND)
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(LIBVNCSERVER REQUIRED libvncserver)
  add_library(LibVNCServer::vncserver UNKNOWN IMPORTED)
  find_library(LIBVNCSERVER_DYLIB vncserver
    HINTS ${LIBVNCSERVER_LIBRARY_DIRS} /opt/local/lib /opt/homebrew/lib /usr/local/lib
    REQUIRED)
  set_target_properties(LibVNCServer::vncserver PROPERTIES
    IMPORTED_LOCATION "${LIBVNCSERVER_DYLIB}"
    INTERFACE_INCLUDE_DIRECTORIES "${LIBVNCSERVER_INCLUDE_DIRS}"
  )
  message(STATUS "LibVNCServer via pkg-config: ${LIBVNCSERVER_DYLIB}")
else()
  # Resolve imported location for arch checks below
  get_target_property(LIBVNCSERVER_DYLIB LibVNCServer::vncserver IMPORTED_LOCATION)
  if(NOT LIBVNCSERVER_DYLIB)
    get_target_property(LIBVNCSERVER_DYLIB LibVNCServer::vncserver IMPORTED_LOCATION_RELEASE)
  endif()
endif()

# Universal builds need fat dependency dylibs (MacPorts +universal). Homebrew
# bottles are typically single-arch — fall back to native with a warning.
if(APPLE AND MACVNC_UNIVERSAL AND LIBVNCSERVER_DYLIB)
  execute_process(
    COMMAND lipo -archs "${LIBVNCSERVER_DYLIB}"
    OUTPUT_VARIABLE _vnc_archs
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
  string(REPLACE " " ";" _vnc_arch_list "${_vnc_archs}")
  list(FIND _vnc_arch_list "arm64" _has_arm)
  list(FIND _vnc_arch_list "x86_64" _has_x86)
  if(_has_arm LESS 0 OR _has_x86 LESS 0)
    message(WARNING
      "LibVNCServer at ${LIBVNCSERVER_DYLIB} is not universal (${_vnc_archs}). "
      "Falling back to native architecture. For a fat .app use MacPorts "
      "`+universal` deps, or pass -DMACVNC_UNIVERSAL=OFF. See README.")
    unset(CMAKE_OSX_ARCHITECTURES CACHE)
    set(CMAKE_OSX_ARCHITECTURES "" CACHE STRING "macOS architectures" FORCE)
    set(MACVNC_UNIVERSAL OFF CACHE BOOL "Build a universal (arm64;x86_64) binary" FORCE)
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
set(MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION})
set(MACOSX_BUNDLE_ICON_FILE icon.icns)
set_source_files_properties(src/icon.icns PROPERTIES MACOSX_PACKAGE_LOCATION Resources)

add_executable(${PROJECT_NAME} MACOSX_BUNDLE ${SOURCE_FILES})

target_link_libraries(${PROJECT_NAME} LibVNCServer::vncserver OpenSSL::SSL OpenSSL::Crypto
  ${CMAKE_THREAD_LIBS_INIT} ${CARBON_LIBRARY} ${IOKIT_LIBRARY}
  ${SCREEN_CAPTURE_KIT}
  ${CORE_MEDIA}
  ${CORE_VIDEO}
  ${FOUNDATION})
if(GnuTLS_FOUND)
  target_link_libraries(${PROJECT_NAME} GnuTLS::GnuTLS)
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
INSTALL(FILES README.md DESTINATION ${APP})
