module Parse.NumberTests exposing (suite)

{-| Tests for `Compiler.Parse.Number.number`, the parser for Elm numeric
literals. They pin, for a few literals of each kind, the value the parser reads
and the source text it keeps beside it, and the error it gives for a few
literals Elm does not allow, such as ones containing an underscore.

Each test hands one literal, as the whole input, to `singleNumber` and compares
the result. A successful result carries the value and the literal's source text.
A failure carries the parser's `E.Number` error, without its row and column;
input left over after a literal, and input the parser does not take as a number,
are reported as separate failures, so they cannot be mistaken for a parser
error.

What the tests establish:

  - Int: `1000`, `42` and `0` read as `Int` with that value and the literal as
    its source text.
  - Float: `1000.42`, `6.022e23`, `6000.022e+36` and `3.14` read as `Float`
    with that value and the literal as its source text. `6000.022e+36` checks a
    signed exponent and a value of `6.000022e39`.
  - Hexadecimal: `0xDEADBEEF`, `0x002B` and `0xFF` read as `Int` 3735928559,
    43 and 255, with the literal, `0x` included, as source text.
  - Invalid numbers: `1_000`, `111_000.602`, `1000.4_205` and `0b1010` fail
    with the parser's own `NumberEnd` error, and `0xDE_AD_BE_EF` with its
    `NumberHexDigit` error; a parser that stopped before the `_` or the `b` and
    succeeded would leave input over and fail these tests.
  - 64-bit: a literal's value is its digits modulo 2^64 read as two's
    complement, so `0xFFFFFFFFC0000000` is -2^30 and `0xFFFFFFFFFFFFFFFF` and
    `18446744073709551615` are -1; `5000000000` is read exactly. `0x` alone and
    `0xFG` are `NumberHexDigit` errors. `0x7FFFFFFFFFFFFFFF` needs 63
    significant bits, which the JavaScript-hosted compiler (the one these tests
    run on) cannot hold, so it is a `NumberInexactOnHost` error; natively it
    would read exactly.

Among what is not tested: lower-case hexadecimal digits, a leading zero
(`NumberNoLeadingZero`), a `.` with no digit after it (`NumberDot`), an
exponent with no digits, and `precedence`.

-}

import Compiler.Parse.Number as N
import Compiler.Parse.Primitives as P
import Compiler.Reporting.Error.Syntax as E
import Expect
import Test exposing (Test)


{-| The number parser tests, in five groups: integer, float, hexadecimal,
invalid and 64-bit literals.
-}
suite : Test
suite =
    Test.describe "Parse.Number"
        [ Test.describe "Int"
            [ (\_ ->
                singleNumber "1000"
                    |> Expect.equal (Ok (N.Int 1000 "1000"))
              )
                |> Test.test "Int with no underscores 1000"
            , (\_ ->
                singleNumber "42"
                    |> Expect.equal (Ok (N.Int 42 "42"))
              )
                |> Test.test "Simple int 42"
            , (\_ ->
                singleNumber "0"
                    |> Expect.equal (Ok (N.Int 0 "0"))
              )
                |> Test.test "Zero"
            ]
        , Test.describe "Float"
            [ (\_ ->
                singleNumber "1000.42"
                    |> Expect.equal (Ok (N.Float 1000.42 "1000.42"))
              )
                |> Test.test "Simple Float with no underscores 1000.42"
            , (\_ ->
                singleNumber "6.022e23"
                    |> Expect.equal (Ok (N.Float 6.022e23 "6.022e23"))
              )
                |> Test.test "Float with exponent and no underscores 6.022e23"
            , (\_ ->
                singleNumber "6000.022e+36"
                    |> Expect.equal (Ok (N.Float 6.000022e39 "6000.022e+36"))
              )
                |> Test.test "Float with exponent and +/- and no underscores 6000.022e+36"
            , (\_ ->
                singleNumber "3.14"
                    |> Expect.equal (Ok (N.Float 3.14 "3.14"))
              )
                |> Test.test "Pi approximation 3.14"
            ]
        , Test.describe "Hexadecimal"
            [ (\_ ->
                singleNumber "0xDEADBEEF"
                    |> Expect.equal (Ok (N.Int 3735928559 "0xDEADBEEF"))
              )
                |> Test.test "0xDEADBEEF"
            , (\_ ->
                singleNumber "0x002B"
                    |> Expect.equal (Ok (N.Int 43 "0x002B"))
              )
                |> Test.test "0x002B"
            , (\_ ->
                singleNumber "0xFF"
                    |> Expect.equal (Ok (N.Int 255 "0xFF"))
              )
                |> Test.test "0xFF"
            ]
        , Test.describe "Invalid numbers"
            [ (\_ ->
                singleNumber "1_000"
                    |> Expect.equal (Err (NumberError E.NumberEnd))
              )
                |> Test.test "Underscores not allowed in integers 1_000"
            , (\_ ->
                singleNumber "111_000.602"
                    |> Expect.equal (Err (NumberError E.NumberEnd))
              )
                |> Test.test "Underscores not allowed before decimal point 111_000.602"
            , (\_ ->
                singleNumber "1000.4_205"
                    |> Expect.equal (Err (NumberError E.NumberEnd))
              )
                |> Test.test "Underscores not allowed after decimal point 1000.4_205"
            , (\_ ->
                singleNumber "0xDE_AD_BE_EF"
                    |> Expect.equal (Err (NumberError E.NumberHexDigit))
              )
                |> Test.test "Underscores not allowed in hex 0xDE_AD_BE_EF"
            , (\_ ->
                singleNumber "0b1010"
                    |> Expect.equal (Err (NumberError E.NumberEnd))
              )
                |> Test.test "Binary literals not supported 0b1010"
            ]
        , Test.describe "64-bit"
            [ (\_ ->
                singleNumber "0xFFFFFFFFC0000000"
                    |> Expect.equal (Ok (N.Int -1073741824 "0xFFFFFFFFC0000000"))
              )
                |> Test.test "Sign-extended mask 0xFFFFFFFFC0000000 is -2^30"
            , (\_ ->
                singleNumber "0xFFFFFFFFFFFFFFFF"
                    |> Expect.equal (Ok (N.Int -1 "0xFFFFFFFFFFFFFFFF"))
              )
                |> Test.test "All ones 0xFFFFFFFFFFFFFFFF is -1"
            , (\_ ->
                singleNumber "18446744073709551615"
                    |> Expect.equal (Ok (N.Int -1 "18446744073709551615"))
              )
                |> Test.test "Decimal 2^64-1 is -1"
            , (\_ ->
                singleNumber "5000000000"
                    |> Expect.equal (Ok (N.Int 5000000000 "5000000000"))
              )
                |> Test.test "Above 2^32 5000000000"
            , (\_ ->
                singleNumber "0x7FFFFFFFFFFFFFFF"
                    |> Expect.equal (Err (NumberError E.NumberInexactOnHost))
              )
                |> Test.test "63 significant bits on the JS host 0x7FFFFFFFFFFFFFFF"
            , (\_ ->
                singleNumber "0x"
                    |> Expect.equal (Err (NumberError E.NumberHexDigit))
              )
                |> Test.test "No hex digits 0x"
            , (\_ ->
                singleNumber "0xFG"
                    |> Expect.equal (Err (NumberError E.NumberHexDigit))
              )
                |> Test.test "Hex digits then a name character 0xFG"
            ]
        ]


{-| Why `singleNumber` failed: the parser's own `E.Number` error, input the
parser does not take as a number at all, or input left over after a literal
the parser read successfully. Keeping the three apart means a parser that
stopped early and succeeded cannot pass for one that rejected the literal.
-}
type SingleError
    = NumberError E.Number
    | NotANumber
    | LeftOver


{-| Runs `number` over the whole of the given source and returns the literal it
reads, or why it failed. The row and column of every error are dropped.
-}
singleNumber : String -> Result SingleError N.Number
singleNumber =
    P.fromByteString (N.number (\_ _ -> NotANumber) (\x _ _ -> NumberError x)) (\_ _ -> LeftOver)
