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


{-| Lower an `.mlir` file at the first path and link the result into the ELF
binary at the second path.

Only meaningful in the unified `eco` binary; the XHR-bootstrap variant always
returns a `Task.fail` so that any accidental invocation (e.g. via
`Terminal.Make.handleElfOutput` under `guida.js`) surfaces immediately.

-}
lowerAndLink : String -> String -> Task String ()
lowerAndLink _ _ =
    -- Should never be reached under the XHR bootstrap path. If it is, we
    -- surface a typed Task failure rather than silently succeeding so a
    -- regression (e.g. Terminal.Make.handleElfOutput firing under guida.js)
    -- is immediately visible.
    Task.fail
        "Eco.NativeDriver.lowerAndLink: not available under the XHR bootstrap path"


{-| Same as [`lowerAndLink`](#lowerAndLink) but takes the MLIR module as an
in-memory `Bytes` value rather than reading it from disk.

The XHR-bootstrap stub always fails for the same reason as `lowerAndLink`.

-}
lowerAndLinkBytes : Bytes -> String -> Task String ()
lowerAndLinkBytes _ _ =
    Task.fail
        "Eco.NativeDriver.lowerAndLinkBytes: not available under the XHR bootstrap path"
