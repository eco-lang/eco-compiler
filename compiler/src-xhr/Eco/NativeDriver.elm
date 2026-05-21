module Eco.NativeDriver exposing
    ( lowerAndLink
    , lowerAndLinkBytes
    )

{-| XHR-bootstrap stub for `Eco.NativeDriver`.

The native-driver kernel intrinsic is only meaningful in the unified `eco`
binary (which statically links `EcoNativeDriverStatic`). The XHR-based
Stage 1 compiler (`guida.js`) never reaches `Terminal.Make.handleElfOutput`
because it is only invoked with `--output=*.mlir` / `--output=*.js`. These
stubs exist so the front-end source tree compiles uniformly under both
bootstrap paths, and they surface a Task failure if ever invoked.


# Lowering

@docs lowerAndLink, lowerAndLinkBytes

-}

import Bytes exposing (Bytes)
import Task exposing (Task)


lowerAndLink : String -> String -> Task Never ()
lowerAndLink _ _ =
    -- Should never be reached under the XHR bootstrap path.
    Task.succeed ()


lowerAndLinkBytes : Bytes -> String -> Task Never ()
lowerAndLinkBytes _ _ =
    -- Should never be reached under the XHR bootstrap path.
    Task.succeed ()
