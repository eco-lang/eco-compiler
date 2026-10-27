module Mlir.PrettyTextRoundTripTest exposing (suite)

{-| Tests that the MLIR text `Mlir.Pretty` prints for a constant reads back
as the value the constant was built from.

Without them, a float or string attribute could print as text that MLIR's
parser rejects, or that it accepts as a different value, and nothing would
notice until a compiled program carried the wrong constant.

Each test builds one generic-form `arith.constant` op whose `value` attribute
is either a `TypedFloatAttr` of type `f64` or a `StringAttr`, prints it with
`Mlir.Pretty.ppTopLevelOp`, and takes the text after `value =`.

  - NaN, +Infinity and -Infinity: the literal, ignoring case, is the
    hexadecimal bit pattern `0x7FF8000000000000`, `0x7FF0000000000000` and
    `0xFFF0000000000000` respectively.
  - `1e-7`, `5e-324`, `0.1 + 0.2` and `1.7976931348623157e308`: the literal
    contains a `.` (MLIR lexes a decimal float only when it does) and
    `String.toFloat` reads it back as exactly the original value.
  - The stored escapes `\u000B`, `\u000A` and `\u0000`: the literal holds no
    raw NUL, newline, vertical tab or form feed, and decodes to the string with
    that character.
  - The stored escape `\u005C` followed by `n`: the literal decodes to a
    backslash and an `n`, not a newline.
  - The stored escapes `\"`, `\n`, `\t`, `\\` and `\r`: the literal decodes to
    the quote, newline, tab, backslash and carriage return they name.

Among what is not tested: `f32` and other float types, integer, array and
other attribute kinds, negative zero, `\uXXXX` escapes for characters above
U+00FF, surrogate pairs, and the parsing of the printed text by MLIR itself;
the decoding here is this module's own reading of MLIR's escapes.

-}

import Dict
import Expect exposing (Expectation)
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))
import Mlir.Pretty as Pretty
import Test exposing (Test)


{-| The float and string constant round-trip tests.
-}
suite : Test
suite =
    Test.describe "SD-9: Mlir.Pretty text form round-trips constants"
        [ Test.describe "float constants"
            [ Test.test "NaN prints as a valid MLIR float literal (0x7FF8000000000000)" <|
                \_ -> expectHexFloat "0x7FF8000000000000" (0 / 0)
            , Test.test "+Infinity prints as a valid MLIR float literal (0x7FF0000000000000)" <|
                \_ -> expectHexFloat "0x7FF0000000000000" (1 / 0)
            , Test.test "-Infinity prints as a valid MLIR float literal (0xFFF0000000000000)" <|
                \_ -> expectHexFloat "0xFFF0000000000000" (-1 / 0)
            , Test.test "1e-7 is not rounded to 0.0" <|
                \_ -> expectDecimalRoundTrip 1.0e-7
            , Test.test "5e-324 (smallest subnormal) is not rounded to 0.0" <|
                \_ -> expectDecimalRoundTrip 5.0e-324
            , Test.test "0.1 + 0.2 keeps all 17 significant digits" <|
                \_ -> expectDecimalRoundTrip (0.1 + 0.2)
            , Test.test "1.7976931348623157e308 (max finite) round-trips" <|
                \_ -> expectDecimalRoundTrip 1.7976931348623157e308
            ]
        , Test.describe "string constants"
            [ Test.test "\\u000B (vertical tab) is escaped, not written raw" <|
                \_ -> expectStringRoundTrip "a\\u000Bb" "a\u{000B}b"
            , Test.test "\\u000A (newline) is escaped, not written raw" <|
                \_ -> expectStringRoundTrip "a\\u000Ab" "a\nb"
            , Test.test "\\u005C (backslash) followed by n stays a backslash and an n" <|
                \_ -> expectStringRoundTrip "a\\u005Cnb" "a\\nb"
            , Test.test "\\u0000 (NUL) is escaped, not written raw" <|
                \_ -> expectStringRoundTrip "a\\u0000b" "a\u{0000}b"
            , Test.test "plain escapes round-trip (control)" <|
                \_ -> expectStringRoundTrip "q\\\"x\\ny\\tz\\\\w\\r" "q\"x\ny\tz\\w\u{000D}"
            ]
        ]



-- PRINTING


{-| Produces a generic-form `arith.constant` op with result `%c` of type `ty`
and `value` as its only attribute.
-}
constantOp : MlirAttr -> MlirType -> MlirOp
constantOp value ty =
    { name = "arith.constant"
    , id = "c"
    , operands = []
    , results = [ ( "%c", ty ) ]
    , attrs = Dict.singleton "value" value
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


{-| Returns the text of the printed constant op between the first `value =`
and the last `}`, or `Nothing` if either is missing.
-}
printedValue : MlirAttr -> MlirType -> Maybe String
printedValue value ty =
    let
        text =
            Pretty.ppTopLevelOp (constantOp value ty)
    in
    case String.indexes "value = " text of
        start :: _ ->
            let
                after =
                    String.dropLeft (start + String.length "value = ") text
            in
            case List.reverse (String.indexes "}" after) of
                end :: _ ->
                    Just (String.left end after)

                [] ->
                    Nothing

        [] ->
            Nothing


{-| Returns the literal `f` prints as in an `f64` constant, without its
`: f64` suffix, or `Nothing` if the printed value does not end with that
suffix.
-}
printedFloatLiteral : Float -> Maybe String
printedFloatLiteral f =
    printedValue (TypedFloatAttr f F64) F64
        |> Maybe.andThen
            (\v ->
                if String.endsWith " : f64" v then
                    Just (String.dropRight (String.length " : f64") v)

                else
                    Nothing
            )



-- FLOATS


{-| Passes when the printed `f64` literal for `f` equals `expectedHex`,
ignoring case.
-}
expectHexFloat : String -> Float -> Expectation
expectHexFloat expectedHex f =
    case printedFloatLiteral f of
        Just lit ->
            String.toUpper lit
                |> Expect.equal (String.toUpper expectedHex)
                |> Expect.onFail
                    ("float " ++ String.fromFloat f ++ " printed as `" ++ lit ++ " : f64`, expected `" ++ expectedHex ++ " : f64`")

        Nothing ->
            Expect.fail ("could not find `value = ... : f64` in: " ++ Pretty.ppTopLevelOp (constantOp (TypedFloatAttr f F64) F64))


{-| Passes when the printed `f64` literal for `f` contains a `.`, which MLIR
needs to lex it as a decimal float, and `String.toFloat` reads it back as
exactly `f`.
-}
expectDecimalRoundTrip : Float -> Expectation
expectDecimalRoundTrip f =
    case printedFloatLiteral f of
        Just lit ->
            if not (String.contains "." lit) then
                Expect.fail ("float " ++ String.fromFloat f ++ " printed as `" ++ lit ++ "`, which MLIR does not lex as a float")

            else
                case String.toFloat lit of
                    Just back ->
                        -- (`Expect.equal` refuses Floats; exact equality is the point here.)
                        (back == f)
                            |> Expect.equal True
                            |> Expect.onFail
                                ("float " ++ String.fromFloat f ++ " printed as `" ++ lit ++ "`, which reads back as " ++ String.fromFloat back)

                    Nothing ->
                        Expect.fail ("float " ++ String.fromFloat f ++ " printed as unparseable `" ++ lit ++ "`")

        Nothing ->
            Expect.fail ("could not find `value = ... : f64` in: " ++ Pretty.ppTopLevelOp (constantOp (TypedFloatAttr f F64) F64))



-- STRINGS


{-| Passes when a `StringAttr` holding `stored` prints as a quoted literal
whose body contains no character `isRawForbidden` rejects and decodes, by
`decodeMlirString`, to `expected`.

`stored` is the attribute's text with its escape sequences written out;
`expected` is the string those escapes denote.

-}
expectStringRoundTrip : String -> String -> Expectation
expectStringRoundTrip stored expected =
    case printedValue (StringAttr stored) (NamedStruct "eco.value") of
        Just lit ->
            if not (String.startsWith "\"" lit && String.endsWith "\"" lit && String.length lit >= 2) then
                Expect.fail ("not a quoted literal: " ++ lit)

            else
                let
                    body =
                        String.slice 1 -1 lit
                in
                case String.toList body |> List.filter isRawForbidden of
                    c :: _ ->
                        Expect.fail
                            ("printed literal contains a raw U+"
                                ++ String.fromInt (Char.toCode c)
                                ++ ", which MLIR's lexer rejects inside a string: "
                                ++ escapeVisible lit
                            )

                    [] ->
                        case decodeMlirString body of
                            Just decoded ->
                                decoded
                                    |> Expect.equal expected
                                    |> Expect.onFail
                                        ("stored `" ++ stored ++ "` printed as " ++ escapeVisible lit ++ ", which decodes to " ++ escapeVisible decoded)

                            Nothing ->
                                Expect.fail ("printed literal is not a valid MLIR string: " ++ escapeVisible lit)

        Nothing ->
            Expect.fail "could not find `value = ...`"


{-| Tells whether `c` is NUL, a newline, a vertical tab or a form feed, the
characters this module treats as forbidden raw inside an MLIR string literal.
-}
isRawForbidden : Char -> Bool
isRawForbidden c =
    let
        code =
            Char.toCode c
    in
    code == 0 || code == 10 || code == 11 || code == 12


{-| Returns the string an MLIR string literal body denotes, reading the
escapes `\n`, `\t`, `\"`, `\\` and two-hex-digit `\XX`, or `Nothing` for
any other escape, a trailing backslash or an unescaped `"`.

A `\XX` escape becomes the character with code `XX`, so a multi-byte UTF-8
sequence written as hex escapes decodes to several characters, not one.

-}
decodeMlirString : String -> Maybe String
decodeMlirString body =
    let
        go : List Char -> List Char -> Maybe String
        go acc cs =
            case cs of
                [] ->
                    Just (String.fromList (List.reverse acc))

                '"' :: _ ->
                    Nothing

                '\\' :: rest ->
                    case rest of
                        'n' :: more ->
                            go ('\n' :: acc) more

                        't' :: more ->
                            go ('\t' :: acc) more

                        '"' :: more ->
                            go ('"' :: acc) more

                        '\\' :: more ->
                            go ('\\' :: acc) more

                        h1 :: h2 :: more ->
                            case ( hexDigit h1, hexDigit h2 ) of
                                ( Just a, Just b ) ->
                                    go (Char.fromCode (a * 16 + b) :: acc) more

                                _ ->
                                    Nothing

                        _ ->
                            Nothing

                c :: rest ->
                    go (c :: acc) rest
    in
    go [] (String.toList body)


{-| Returns the value of a hexadecimal digit, in either case, or `Nothing`.
-}
hexDigit : Char -> Maybe Int
hexDigit c =
    let
        code =
            Char.toCode (Char.toUpper c)
    in
    if code >= 48 && code <= 57 then
        Just (code - 48)

    else if code >= 65 && code <= 70 then
        Just (code - 55)

    else
        Nothing


{-| Returns `s` with each character below U+0020 written as `<U+n>`, `n` in
decimal, for failure messages.
-}
escapeVisible : String -> String
escapeVisible s =
    String.toList s
        |> List.map
            (\c ->
                let
                    code =
                        Char.toCode c
                in
                if code < 32 then
                    "<U+" ++ String.fromInt code ++ ">"

                else
                    String.fromChar c
            )
        |> String.concat
