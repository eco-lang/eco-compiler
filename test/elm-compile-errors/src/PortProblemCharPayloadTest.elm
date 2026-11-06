port module PortProblemCharPayloadTest exposing (..)

{-| A port whose payload type is `Char` is rejected with a PORT ERROR naming the port and the `Char` type.

Ports can carry `Int`, `Float`, `Bool`, `String`, `Json.Encode.Value`, `()`, and
`List`, `Maybe`, `Array`, tuples and records built from those, but not `Char`. Here the
outgoing port `charOut : Char -> Cmd msg` is declared.

-}

-- COMPILE-ERROR: PORT ERROR
-- CHECK: -- PORT ERROR -
-- CHECK: The `charOut` port is trying to transmit a `Char` value:

import Platform


port charOut : Char -> Cmd msg
