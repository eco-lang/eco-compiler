module Parse.NumberTests exposing (suite)

import Compiler.Parse.Number as N
import Compiler.Parse.Primitives as P
import Compiler.Reporting.Error.Syntax as E
import Expect
import Test exposing (Test)


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
                    |> Expect.equal (Err E.NumberEnd)
              )
                |> Test.test "Underscores not allowed in integers 1_000"
            , (\_ ->
                singleNumber "111_000.602"
                    |> Expect.equal (Err E.NumberEnd)
              )
                |> Test.test "Underscores not allowed before decimal point 111_000.602"
            , (\_ ->
                singleNumber "1000.4_205"
                    |> Expect.equal (Err E.NumberEnd)
              )
                |> Test.test "Underscores not allowed after decimal point 1000.4_205"
            , (\_ ->
                singleNumber "0xDE_AD_BE_EF"
                    |> Expect.equal (Err E.NumberHexDigit)
              )
                |> Test.test "Underscores not allowed in hex 0xDE_AD_BE_EF"
            , (\_ ->
                singleNumber "0b1010"
                    |> Expect.equal (Err E.NumberEnd)
              )
                |> Test.test "Binary literals not supported 0b1010"
            ]
        ]


singleNumber : String -> Result E.Number N.Number
singleNumber =
    P.fromByteString (N.number (\_ _ -> E.NumberEnd) (\x _ _ -> x)) (\_ _ -> E.NumberEnd)
