module Compiler.Data.Int64Test exposing (suite)

{-| Tests for `Compiler.Data.Int64`, run under the JavaScript backend that
elm-test runs on, where an `Int` is a double.

`fromLiteral` reads decimal and `0x` literal text modulo 2^64 as two's
complement: sign-extended masks, all ones (-1), -2^63, and a wrap past 2^64
(to 0) are exact, and so is 2^53. A value needing more than 53 significant
bits (2^63 - 1, 2^53 + 1) cannot be held by a double, so it is `Nothing`.
`toWords` splits a value into unsigned 32-bit words, and `fromWords` inverts
it. `hostIs64` is `False` here.

-}

import Compiler.Data.Int64 as Int64
import Expect
import Test exposing (Test)


lit : String -> Maybe Int -> Test
lit text expected =
    Test.test ("fromLiteral " ++ text) <|
        \_ -> Int64.fromLiteral text |> Expect.equal expected


suite : Test
suite =
    Test.describe "Compiler.Data.Int64"
        [ lit "0xFFFFFFFFC0000000" (Just -1073741824)
        , lit "0xFFFFFFFF80000000" (Just -2147483648)
        , lit "0xFFFFFFFF00000000" (Just -4294967296)
        , lit "0xFFFFFFFFFFFFFFFF" (Just -1)
        , lit "0x8000000000000000" (Just (-4611686018427387904 * 2))
        , lit "0x10000000000000000" (Just 0)
        , lit "0x7FFFFFFFFFFFFFFF" Nothing
        , lit "9223372036854775807" Nothing
        , lit "18446744073709551615" (Just -1)
        , lit "5000000000" (Just 5000000000)
        , lit "0x1F" (Just 31)
        , lit "0xdeadBEEF" (Just 3735928559)
        , lit "9007199254740993" Nothing
        , lit "9007199254740992" (Just 9007199254740992)
        , Test.test "toWords of -1 is all ones" <|
            \_ -> Int64.toWords -1 |> Expect.equal ( 0xFFFFFFFF, 0xFFFFFFFF )
        , Test.test "toWords of -2^63" <|
            \_ -> Int64.toWords (-4611686018427387904 * 2) |> Expect.equal ( 0x80000000, 0 )
        , Test.test "toWords of 5000000000" <|
            \_ -> Int64.toWords 5000000000 |> Expect.equal ( 1, 705032704 )
        , Test.test "fromWords inverts toWords for -2^30" <|
            \_ -> Int64.fromWords 0xFFFFFFFF 0xC0000000 |> Expect.equal (Just -1073741824)
        , Test.test "fromWords of 2^63 - 1 is Nothing on the JS host" <|
            \_ -> Int64.fromWords 0x7FFFFFFF 0xFFFFFFFF |> Expect.equal Nothing
        , Test.test "the host is JavaScript here" <|
            \_ -> Int64.hostIs64 |> Expect.equal False
        ]
