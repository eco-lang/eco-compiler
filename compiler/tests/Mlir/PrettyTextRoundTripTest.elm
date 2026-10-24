module Mlir.PrettyTextRoundTripTest exposing (suite)

{-| SD-9 review list item: the debug TEXT form of MLIR (`Mlir.Pretty`) is lossy.

`Mlir.Pretty.ppAttr` spells a `TypedFloatAttr` with `String.fromFloat`, and
when that text has no `.` re-formats it with exactly one decimal place. So:

  - NaN and the infinities print as nothing (`value =  : f64`), which ecoc
    rejects ("expected attribute value"); MLIR spells them as hexadecimal bit
    patterns (`0x7FF8000000000000 : f64`).
  - A value `String.fromFloat` writes in exponent form without a `.`
    (`1e-7`, `5e-324`) is rounded to one decimal place (`0.0`), a different
    value.

`escapeForMlir` turns a `\uXXXX` escape into the character it names and
writes it raw, so a vertical tab or a newline lands raw inside the MLIR
string literal (ecoc's lexer rejects both), and a backslash named that way
starts a bogus escape.

Each test pretty-prints one `arith.constant` (generic form) with
`Mlir.Pretty.ppTopLevelOp` and checks that the attribute text reads back as
the value it was built from. Nine FAIL against the current printer and pass
once it spells these values losslessly. The default bytecode output does not
go through this printer and is unaffected. Three are controls that already
pass: `0.1 + 0.2` (17 significant digits), the largest finite float, and the
plain `\n \t \" \\ \r` escapes.

-}

import Dict
import Expect exposing (Expectation)
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))
import Mlir.Pretty as Pretty
import Test exposing (Test)


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


{-| The text between `value = ` and the closing `}` of the printed op.
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


{-| The float literal of a printed `TypedFloatAttr`, without its `: f64`.
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


{-| MLIR lexes a decimal float literal only when it contains a `.`; it must
then read back as exactly `f`.
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


{-| `stored` is the `StringAttr` text (escape sequences written out, as
`Mlir.Mlir` describes); `expected` is the string it denotes. The printed
literal must be a valid MLIR string literal (no raw control characters) that
decodes to `expected`.
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


isRawForbidden : Char -> Bool
isRawForbidden c =
    let
        code =
            Char.toCode c
    in
    code == 0 || code == 10 || code == 11 || code == 12


{-| Decode an MLIR string literal body (`\n`, `\t`, `\"`, `\\` and two-digit
hex escapes `\XX`). `Nothing` for an escape MLIR does not accept or an
unescaped `"`.
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
