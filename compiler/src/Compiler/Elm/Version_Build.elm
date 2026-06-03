module Compiler.Elm.Version_Build exposing (userFacing)

{-| Build-time-injected user-facing version string.

This file is **checked into the repository** so the Elm sources are
complete for IDE, `elm-test-rs`, and any stock-Elm consumer that does not
go through CMake. The hardcoded value below mirrors `/work/version.txt`.

At CMake configure time the same file is overwritten in place from
`compiler/cmake/Version_Build.elm.in` — typically producing
`<baseline>-dev-<git-describe>` for dev builds, or
`-DECO_VERSION_OVERRIDE=...`'s value for tagged releases. That generated
content will appear as an uncommitted diff after configure runs; resist
the urge to commit it. Keep only the bare baseline value here.

When bumping the marketing version, update `version.txt` and the
hardcoded value below in the same commit. The two are kept in sync by
convention, not by tooling, since this file must compile standalone
without the CMake configure step.
-}


userFacing : String
userFacing =
    "0.1.0"
