module Compiler.Parse.VariableUnicodeExtraTest exposing (suite)

{-| Edge cases of the Unicode identifier classes in `Compiler.Parse.Variable`,
beyond those in `Compiler.Parse.VariableNonAsciiTest`: the first character of
an upper-case name may be any upper-case letter, a letter above U+FFFF counts
as one character (width 2, one column), an `Lo` letter such as a CJK ideograph
may continue a name but not start one, a non-ASCII digit is not an inner
character, and a lone surrogate is not an identifier character.

The bad-end errors give the row and column where the identifier stopped, so
they also pin that a character advances the column by one whatever its width.

-}

import Compiler.Parse.Primitives as P
import Compiler.Parse.Variable as Var
import Expect
import Test exposing (Test)


run : P.Parser String a -> String -> Result String a
run p src =
    P.fromByteString p (\r c -> "bad end at " ++ String.fromInt r ++ ":" ++ String.fromInt c) src


lowerP : P.Parser String String
lowerP =
    Var.lower (\_ _ -> "not lower")


upperP : P.Parser String String
upperP =
    Var.upper (\_ _ -> "not upper")


suite : Test
suite =
    Test.describe "Variable Unicode identifiers"
        [ Test.test "a non-ASCII upper-case letter starts a type name" <|
            \_ ->
                run upperP "Été"
                    |> Expect.equal (Ok "Été")
        , Test.test "a letter above U+FFFF inside an identifier" <|
            \_ ->
                run lowerP "x𝒜y"
                    |> Expect.equal (Ok "x𝒜y")
        , Test.test "an upper-case letter above U+FFFF starts a type name" <|
            \_ ->
                run upperP "𝒜b"
                    |> Expect.equal (Ok "𝒜b")
        , Test.test "x, A-tilde, $ stops before the $ (one column per character)" <|
            \_ ->
                run lowerP "xÃ$"
                    |> Expect.equal (Err "bad end at 1:3")
        , Test.test "a letter above U+FFFF takes one column" <|
            \_ ->
                run lowerP "x𝒜$"
                    |> Expect.equal (Err "bad end at 1:3")
        , Test.test "an Lo letter cannot start a lower-case name" <|
            \_ ->
                run lowerP "中"
                    |> Expect.notEqual (Ok "中")
        , Test.test "an Lo letter may continue a name" <|
            \_ ->
                run lowerP "x中"
                    |> Expect.equal (Ok "x中")
        , Test.test "Greek lower-case letters form a name" <|
            \_ ->
                run lowerP "αβ"
                    |> Expect.equal (Ok "αβ")
        , Test.test "a non-ASCII digit is not an inner character" <|
            \_ ->
                run lowerP "x٣"
                    |> Expect.equal (Err "bad end at 1:2")
        , Test.test "a lone high surrogate is not an identifier character" <|
            \_ ->
                run lowerP "x\u{D800}"
                    |> Expect.notEqual (Ok "x\u{D800}")
        , Test.test "the inner width of a letter above U+FFFF is 2" <|
            \_ ->
                Var.getInnerWidth "𝒜" 0 2
                    |> Expect.equal 2
        , Test.test "a letter above U+FFFF cut in two by the end is not an inner character" <|
            \_ ->
                Var.getInnerWidth "𝒜" 0 1
                    |> Expect.equal 0
        ]
