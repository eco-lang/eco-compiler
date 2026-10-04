module Compiler.Elm.Version_Build exposing (userFacing)

{-| The version of Eco that a build reports to its users, kept in a module of
its own so that the build system can stamp it in.

This file is generated. The CMake configure step in `compiler/CMakeLists.txt`
rewrites it from the template `compiler/cmake/Version_Build.elm.in`, so a change
made here by hand, comments included, is lost at the next configure. The string
the configure step writes is:

  - the value of `ECO_VERSION_OVERRIDE`, when that CMake variable is set;
  - otherwise the contents of `version.txt`, then `-dev-`, then the output of
    `git describe --tags --dirty --always`;
  - otherwise, when `git describe` prints nothing, the contents of
    `version.txt` alone.

The checked-in copy is what a build sees when the configure step has not run.

This is not `Compiler.Elm.Version.compiler`, which is the artifact-format
version that names the cache directories. The two change independently.

@docs userFacing

-}


{-| The version of this build as presented to users, such as `0.1.1` or
`0.1.1-dev-` followed by a `git describe` result.
-}
userFacing : String
userFacing =
    "0.1.1"
