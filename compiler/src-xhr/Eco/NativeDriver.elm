module Eco.NativeDriver exposing (lowerAndLink, lowerAndLinkBytes)

{-| Turning MLIR into a native executable can only be done by the native build
of the compiler, and this module stands in for that step in the stock-Elm build,
so that the same source tree compiles in both.

The stock-Elm build, also called the XHR or bootstrap build, takes this module
in place of a module of the same name that the native build gets from outside
this source tree, its kernel twin. The two twins expose the same names and
signatures, so code that imports `Eco.NativeDriver` compiles against either.

In a native build that links the native driver, these functions lower an MLIR
program and link the result into a native executable. This twin does none of
that work. Both functions ignore their arguments and return a task that fails
with a message naming the function and saying that it is not available under
the XHR bootstrap path, so asking this build for a native executable fails
visibly instead of appearing to succeed.


# Lowering

@docs lowerAndLink, lowerAndLinkBytes

-}

import Bytes exposing (Bytes)
import Task exposing (Task)


{-| Returns a task that always fails, with a message naming `lowerAndLink`.

In the native build the arguments are the path of an MLIR file, the path of the
executable to write, and the program's root module name. Here all three are
ignored and nothing is read or written.

-}
lowerAndLink : String -> String -> String -> Task String ()
lowerAndLink _ _ _ =
    Task.fail
        "Eco.NativeDriver.lowerAndLink: not available under the XHR bootstrap path"


{-| Returns a task that always fails, with a message naming `lowerAndLinkBytes`.

In the native build this does the work of [`lowerAndLink`](#lowerAndLink) with
the MLIR program given as bytes in memory instead of as a file, and no root
module name. Here both arguments are ignored and nothing is written.

-}
lowerAndLinkBytes : Bytes -> String -> Task String ()
lowerAndLinkBytes _ _ =
    Task.fail
        "Eco.NativeDriver.lowerAndLinkBytes: not available under the XHR bootstrap path"
