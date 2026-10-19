# macOS .app bundle assembly for Ship of Harkinian (soh target).
#
# Builds "Ship of Harkinian.app" directly from the normal build (MACOSX_BUNDLE): compiles the
# Liquid Glass app icon from the Icon Composer package, bundles the runtime resources, relinks
# non-system dylibs (incl. SDL3 for the sdl2-compat shim) into Contents/Frameworks, and ad-hoc
# codesigns the result so it launches without "damaged app" warnings.
#
# Runtime layout (libultraship):
#   * GetAppBundlePath()    -> <App>.app/Contents/Resources  (read-only: soh.o2r, gamecontrollerdb.txt)
#   * GetAppDirectoryPath() -> SHIP_HOME (~/Library/Application Support/com.shipofharkinian.soh):
#                              oot.o2r extracted from the user's ROM on first run, config/saves/logs/mods

set(MACOS_DIR ${CMAKE_SOURCE_DIR}/CMake/macos)
set(ENTITLEMENTS_FILE ${MACOS_DIR}/entitlements.plist)

option(SOH_BUNDLE_DEPS "Relink and bundle dylibs into the .app so it is portable" ON)

# ---------------------------------------------------------------------------
# Liquid Glass app icon (Icon Composer .icon -> Assets.car + icns fallback via actool)
# ---------------------------------------------------------------------------
set(ICON_SOURCE ${CMAKE_SOURCE_DIR}/soh/macosx/sohicon.icon)
set(ICON_COMPILE_DIR ${CMAKE_BINARY_DIR}/AppIconAssets)
set(ASSETS_CAR ${ICON_COMPILE_DIR}/Assets.car)
set(ICNS_FALLBACK ${ICON_COMPILE_DIR}/sohicon.icns)
add_custom_command(
    OUTPUT ${ASSETS_CAR} ${ICNS_FALLBACK}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${ICON_COMPILE_DIR}
    COMMAND xcrun actool ${ICON_SOURCE}
            --compile ${ICON_COMPILE_DIR}
            --app-icon sohicon
            --output-partial-info-plist ${ICON_COMPILE_DIR}/icon-partial.plist
            --platform macosx --target-device mac
            --minimum-deployment-target ${CMAKE_OSX_DEPLOYMENT_TARGET}
            --errors --warnings
    DEPENDS ${ICON_SOURCE}/icon.json
    COMMENT "Compiling Liquid Glass app icon (Icon Composer) with actool"
)
add_custom_target(sohAppIcon DEPENDS ${ASSETS_CAR} ${ICNS_FALLBACK})
add_dependencies(soh sohAppIcon)
set_source_files_properties(${ASSETS_CAR} ${ICNS_FALLBACK} PROPERTIES
    GENERATED TRUE MACOSX_PACKAGE_LOCATION "Resources")
target_sources(soh PRIVATE ${ASSETS_CAR} ${ICNS_FALLBACK})

# ---------------------------------------------------------------------------
# Bundle metadata. OUTPUT_NAME "Ship of Harkinian" -> "Ship of Harkinian.app" with
# Contents/MacOS/"Ship of Harkinian" (matches CFBundleExecutable in the configured Info.plist).
# ---------------------------------------------------------------------------
set_target_properties(soh PROPERTIES
    OUTPUT_NAME "Ship of Harkinian"
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_BINARY_DIR}/macosx/Info.plist
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "-"
    XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS ${ENTITLEMENTS_FILE}
)

# NB: add_dependencies(soh GenerateSohOtr) is added from the root CMakeLists, because GenerateSohOtr
# is defined there (after this file is included from soh/CMakeLists.txt).

# ---------------------------------------------------------------------------
# Copy runtime resources into Contents/Resources after the app links
# ---------------------------------------------------------------------------
set(RES_DIR "$<TARGET_BUNDLE_DIR:soh>/Contents/Resources")
add_custom_command(TARGET soh POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${RES_DIR}"
    # CMake's MACOSX_BUNDLE doesn't reliably emit Contents/Info.plist here (the spaces in the
    # "Ship of Harkinian" OUTPUT_NAME trip it up), so copy the configured plist in explicitly.
    COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_BINARY_DIR}/macosx/Info.plist" "$<TARGET_BUNDLE_DIR:soh>/Contents/Info.plist"
    COMMAND bash -c "[ -f '${CMAKE_BINARY_DIR}/soh/soh.o2r' ] && cp '${CMAKE_BINARY_DIR}/soh/soh.o2r' '${RES_DIR}/soh.o2r' || echo 'note: soh.o2r not found - build GenerateSohOtr'"
    COMMAND bash -c "[ -f '${CMAKE_BINARY_DIR}/gamecontrollerdb.txt' ] && cp '${CMAKE_BINARY_DIR}/gamecontrollerdb.txt' '${RES_DIR}/gamecontrollerdb.txt' || true"
    # The first-run Torch extractor needs the asset definitions at GetAppBundlePath()/assets
    # (OTRGlobals::RunExtract checks Contents/Resources/assets). Mirror upstream's install:
    # soh/assets/yml/ -> Resources/assets/.
    COMMAND ${CMAKE_COMMAND} -E make_directory "${RES_DIR}/assets"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_SOURCE_DIR}/soh/assets/yml" "${RES_DIR}/assets"
    # Upstream's POST_BUILD (soh/CMakeLists.txt) also copies the extractor assets next to the binary
    # for non-bundle runs, which lands them in Contents/MacOS/. In a bundle that copy is never read,
    # and its loose files can only be codesigned via extended attributes, which release zips drop or
    # mangle ("damaged" app). Remove it; this runs after upstream's copy (included later).
    COMMAND ${CMAKE_COMMAND} -E rm -rf "$<TARGET_FILE_DIR:soh>/assets"
    COMMENT "Bundling Ship of Harkinian resources into the .app"
    VERBATIM
)

# ---------------------------------------------------------------------------
# Relink dylibs into Contents/Frameworks (portable .app) + SDL3, then codesign
# ---------------------------------------------------------------------------
# SDL3 to bundle next to the sdl2-compat shim: prefer the CMAKE_PREFIX_PATH dependency set (e.g. libraries
# built for an older macOS), then fall back to Homebrew.
execute_process(COMMAND brew --prefix sdl3 OUTPUT_VARIABLE SOH_BREW_SDL3 OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
find_library(SOH_SDL3_DYLIB NAMES SDL3.0 SDL3 PATHS ${CMAKE_PREFIX_PATH} PATH_SUFFIXES lib NO_DEFAULT_PATH)
if (NOT SOH_SDL3_DYLIB AND SOH_BREW_SDL3)
    set(SOH_SDL3_DYLIB "${SOH_BREW_SDL3}/lib/libSDL3.0.dylib")
endif()
message(STATUS "Bundling SDL3 from: ${SOH_SDL3_DYLIB}")

if (SOH_BUNDLE_DEPS)
    add_custom_command(TARGET soh POST_BUILD
        COMMAND ${CMAKE_COMMAND}
            -DAPP_BUNDLE=$<TARGET_BUNDLE_DIR:soh>
            "-DEXECUTABLE_NAME=Ship of Harkinian"
            -P ${MACOS_DIR}/fixup_bundle.cmake
        COMMAND bash -c "install_name_tool -add_rpath '@executable_path/../Frameworks/' '$<TARGET_BUNDLE_DIR:soh>/Contents/MacOS/Ship of Harkinian' 2>/dev/null || true"
        # Homebrew's sdl2 is sdl2-compat, a shim that dlopen()s libSDL3.dylib from @loader_path at
        # runtime; fixup_bundle can't follow a dlopen, so copy SDL3 in next to the bundled libSDL2.
        COMMAND bash -c "if [ -f '${SOH_SDL3_DYLIB}' ]; then cp '${SOH_SDL3_DYLIB}' '$<TARGET_BUNDLE_DIR:soh>/Contents/Frameworks/libSDL3.dylib' && chmod u+w '$<TARGET_BUNDLE_DIR:soh>/Contents/Frameworks/libSDL3.dylib'; fi"
        COMMENT "Relinking dylibs into the .app bundle (incl. SDL3 for sdl2-compat)"
        VERBATIM
    )
endif()

add_custom_command(TARGET soh POST_BUILD
    COMMAND codesign --force --deep --sign - --options runtime --entitlements ${ENTITLEMENTS_FILE} "$<TARGET_BUNDLE_DIR:soh>"
    COMMENT "Ad-hoc codesigning Ship of Harkinian.app"
    VERBATIM
)
