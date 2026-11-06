module FlagsBytesNativeTest exposing (main)

{-| BAD FLAGS (native only): `Bytes` in a program's flags.

A native program gets its flags as JSON text, which cannot carry `Bytes`
(PORT_007, PORT_008, plans/native-bytes-ports.md), so a native build rejects
flags that contain `Bytes`; the JS backend accepts them.

-}

-- DIVERGENCE: eco's native target rejects Bytes in flags; eco's JS target accepts them, and Elm 0.19.1 rejects them
-- COMPILE-ERROR: BAD FLAGS, Bytes in the flags
-- CHECK: -- BAD FLAGS -
-- CHECK: Your `main` program wants `Bytes` in its flags.

import Bytes exposing (Bytes)
import Platform


main : Program { name : String, blob : Bytes } () ()
main =
    Platform.worker
        { init = \_ -> ( (), Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
