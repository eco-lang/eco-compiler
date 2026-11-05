module ParserIntOverflowTest exposing (main)

{-| PARSE-03 (plans/kernel-lib-bug-fixes.md): `Parser.number` hex, octal and binary literals
too large for 64 bits. Decision D16: such a literal wraps to its low 64 bits as a bit pattern
(`0xFFFFFFFFFFFFFFFF` gives -1), a documented divergence from Elm's doubles. The boundary
`0x7FFFFFFFFFFFFFFF` must stay exact. A decimal literal goes through the same `consumeBase` (base
10), not `String.toInt`, so a too-large decimal `Parser.int` wraps the same way today (Elm on node
gives `Ok 100000000000000020000`); it is pinned at the wrapped value, which unsigned accumulation
keeps.

The defect is C++ signed overflow (UB) in `consumeBase`/`consumeBase16`, which accumulate in
`i64`. At -O2 the compiler happened to wrap, so this program passed even then; it pins the
decided semantics of the fix (unsigned accumulation). Values checked by hand: low 64 bits, two's
complement.
-}

-- DIVERGENCE: Int is 64-bit in eco, so large hex and octal Ints parse exactly; Elm rounds them to doubles
-- CHECK: hex max: "Ok 9223372036854775807"
-- CHECK: hex 64 ones: "Ok -1"
-- CHECK: hex 65 bits: "Ok -1"
-- CHECK: hex 2^64: "Ok 0"
-- CHECK: hex 17 digits: "Ok 2541551405711093505"
-- CHECK: octal 22 sevens: "Ok -1"
-- CHECK: octal 22 digits: "Ok -6399925985471771713"
-- CHECK: binary 65 ones: "Ok -1"
-- CHECK: binary 66 alternating: "Ok -6148914691236517206"
-- CHECK: decimal too large: "Ok 7766279631452241919"

import Html exposing (text)
import Parser


num : Parser.Parser Int
num =
    Parser.number
        { int = Just identity
        , hex = Just identity
        , octal = Just identity
        , binary = Just identity
        , float = Nothing
        }


show : Result x Int -> String
show r =
    case r of
        Ok n ->
            "Ok " ++ String.fromInt n

        Err _ ->
            "Err"


main =
    let
        _ = Debug.log "hex max" (show (Parser.run num "0x7FFFFFFFFFFFFFFF"))
        _ = Debug.log "hex 64 ones" (show (Parser.run num "0xFFFFFFFFFFFFFFFF"))
        _ = Debug.log "hex 65 bits" (show (Parser.run num "0x1FFFFFFFFFFFFFFFF"))
        _ = Debug.log "hex 2^64" (show (Parser.run num "0x10000000000000000"))
        _ = Debug.log "hex 17 digits" (show (Parser.run num "0x123456789abcdef01"))
        _ = Debug.log "octal 22 sevens" (show (Parser.run num ("0o" ++ String.repeat 22 "7")))
        _ = Debug.log "octal 22 digits" (show (Parser.run num ("0o" ++ String.repeat 3 "1234567" ++ "7")))
        _ = Debug.log "binary 65 ones" (show (Parser.run num ("0b" ++ String.repeat 65 "1")))
        _ = Debug.log "binary 66 alternating" (show (Parser.run num ("0b" ++ String.repeat 33 "10")))
        _ = Debug.log "decimal too large" (show (Parser.run Parser.int "99999999999999999999"))
    in
    text "done"
