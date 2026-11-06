port module PortProblemCharPayloadTest exposing (..)

{-| PORT ERROR: a `Char` port payload. Ports carry `Int`, `Float`, `Bool`, `String`,
`Json.Encode.Value`, `()`, `List`/`Maybe`/`Array`, tuples and records of those (and `Bytes`,
an Eco extension), but not `Char`: Elm rejects it and so must Eco
(`Compiler.Canonicalize.Effects.checkPayload`).

-}

-- COMPILE-ERROR: PORT ERROR
-- CHECK: -- PORT ERROR -
-- CHECK: The `charOut` port is trying to transmit a `Char` value:

import Platform


port charOut : Char -> Cmd msg
