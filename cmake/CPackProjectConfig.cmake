# Per-generator CPack overrides.
#
# CPack `include`s this file once per generator in CPACK_GENERATOR with
# ${CPACK_GENERATOR} set, letting us branch on the format. The TGZ/ZIP
# generators stay relocatable (no prefix → archive root); the DEB
# generator installs under /usr/local so a `dpkg -i` lands files at
# /usr/local/{bin,lib,share}/... — matching where archive users extract
# manually.
#
# See plans/release-bundle-v0.1.0.md (Implementation step 3).

if(CPACK_GENERATOR STREQUAL "DEB")
    # /usr/local is correct for hand-built .debs not coming through apt —
    # Debian policy reserves /usr for the distro's package manager.
    # Upstreaming to Debian/Ubuntu (future-problem) would switch to /usr.
    set(CPACK_PACKAGING_INSTALL_PREFIX "/usr/local")

    # Debian filename convention: <name>_<version>_<arch>.deb (underscores,
    # not dashes). Overrides the default CPACK_PACKAGE_FILE_NAME used by
    # TGZ/ZIP. CPACK_PACKAGE_VERSION is injected by CPack from the top-level
    # CMakeLists.txt (derived from version.txt / -DECO_VERSION_OVERRIDE).
    set(CPACK_PACKAGE_FILE_NAME "eco_${CPACK_PACKAGE_VERSION}_amd64")
endif()
