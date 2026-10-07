module Compiler.Elm.Version_Build exposing (userFacing)

{-| The user-facing version string (`eco --version`, the welcome banner).

This checked-in copy is the baseline that plain compiles of `compiler/elm.json` use; it must
match `version.txt` (the CMake configure step checks). CMake builds never read or rewrite it:
they compile a stamped copy generated from `compiler/cmake/Version_Build.elm.in` into the build
tree (`build/compiler/version/`), which carries a `-dev-<git hash>` suffix on dev builds or the
`-DECO_VERSION_OVERRIDE=...` value for a tagged release.

When bumping the marketing version, update `version.txt` and this baseline together.

@docs userFacing

-}


{-| The user-facing version string for this build.
-}
userFacing : String
userFacing =
    "0.1.1"
