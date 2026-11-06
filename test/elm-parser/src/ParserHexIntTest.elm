module ParserHexIntTest exposing (main)

{-| `Parser.number` configured for hexadecimal parses `0x` literals with hexadecimal digits in either letter case.

`"0xFF"` gives `Ok 255` and `"0xdeadbeef"` gives `Ok 3735928559`, a value
above the largest 32-bit signed integer.

Among what is not tested: the other number formats being rejected, and
`Parser.int` on hexadecimal input.
-}

-- CHECK: hex_ff: Ok 255
-- CHECK: hex_deadbeef: Ok 3735928559

import Html exposing (text)
import Parser


{-| Parses a hexadecimal literal and rejects every other number format.
-}
hexInt : Parser.Parser Int
hexInt =
    Parser.number
        { int = Nothing
        , hex = Just identity
        , octal = Nothing
        , binary = Nothing
        , float = Nothing
        }


main =
    let
        _ = Debug.log "hex_ff" (Parser.run hexInt "0xFF")
        _ = Debug.log "hex_deadbeef" (Parser.run hexInt "0xdeadbeef")
    in
    text "done"
