module JsonDecodeErrorTest exposing (main)

{-| `Json.Decode` failures produce the right `Json.Decode.Error` value and the right
`Json.Decode.errorToString` text.

Each `Row` decodes one JSON string with one decoder; every row is expected to fail. For each
failure the test logs two lines: `shape`, the error rendered by a `case` over all four
constructors with each `Failure`'s value re-encoded as JSON, and `text`, the `errorToString`
message. The rows cover `int`, `string`, `bool` and `float` given the wrong JSON type, `null`, a missing or
mistyped field, `at`, `index` out of range or on an object, the first failing element of a
`list`, `array` and `dict`, `keyValuePairs` on an array, `oneOf` with two, nested and no
alternatives, `fail` and `andThen` into `fail`, the second field of `map2`, `nullable`, and
three inputs that are not valid JSON. A final row checks `errorToString` for a `decodeValue`
failure.

For input that is not valid JSON, the message continues with the JSON parser's own description
of the problem, which differs between platforms, so those rows log only the text before
"This is not valid JSON! " and replace the message in `shape` with `<parse error>`.
-}

-- CHECK: int on string shape: "Failure Expecting an INT \"x\""
-- CHECK: int on string text: "Problem with the given value:\n\n\"x\"\n\nExpecting an INT"
-- CHECK: int on float shape: "Failure Expecting an INT 1.5"
-- CHECK: int on float text: "Problem with the given value:\n\n1.5\n\nExpecting an INT"
-- CHECK: string on null shape: "Failure Expecting a STRING null"
-- CHECK: string on null text: "Problem with the given value:\n\nnull\n\nExpecting a STRING"
-- CHECK: bool on int shape: "Failure Expecting a BOOL 1"
-- CHECK: bool on int text: "Problem with the given value:\n\n1\n\nExpecting a BOOL"
-- CHECK: float on bool shape: "Failure Expecting a FLOAT true"
-- CHECK: float on bool text: "Problem with the given value:\n\ntrue\n\nExpecting a FLOAT"
-- CHECK: null shape: "Failure Expecting null 0"
-- CHECK: null text: "Problem with the given value:\n\n0\n\nExpecting null"
-- CHECK: field type shape: "Field a (Failure Expecting an INT \"x\")"
-- CHECK: field type text: "Problem with the value at json.a:\n\n    \"x\"\n\nExpecting an INT"
-- CHECK: field missing shape: "Failure Expecting an OBJECT with a field named `a` {\"b\":1}"
-- CHECK: field missing text: "Problem with the given value:\n\n{\n        \"b\": 1\n    }\n\nExpecting an OBJECT with a field named `a`"
-- CHECK: field on array shape: "Failure Expecting an OBJECT with a field named `a` [1]"
-- CHECK: field on array text: "Problem with the given value:\n\n[\n        1\n    ]\n\nExpecting an OBJECT with a field named `a`"
-- CHECK: at nested shape: "Field a (Field b (Failure Expecting an INT \"x\"))"
-- CHECK: at nested text: "Problem with the value at json.a.b:\n\n    \"x\"\n\nExpecting an INT"
-- CHECK: index short shape: "Failure Expecting a LONGER array. Need index 1 but only see 1 entries [1]"
-- CHECK: index short text: "Problem with the given value:\n\n[\n        1\n    ]\n\nExpecting a LONGER array. Need index 1 but only see 1 entries"
-- CHECK: index type shape: "Index 1 (Failure Expecting an INT \"x\")"
-- CHECK: index type text: "Problem with the value at json[1]:\n\n    \"x\"\n\nExpecting an INT"
-- CHECK: index on object shape: "Failure Expecting an ARRAY {}"
-- CHECK: index on object text: "Problem with the given value:\n\n{}\n\nExpecting an ARRAY"
-- CHECK: list first failure shape: "Index 1 (Failure Expecting a STRING 1)"
-- CHECK: list first failure text: "Problem with the value at json[1]:\n\n    1\n\nExpecting a STRING"
-- CHECK: list on object shape: "Failure Expecting a LIST {}"
-- CHECK: list on object text: "Problem with the given value:\n\n{}\n\nExpecting a LIST"
-- CHECK: array first failure shape: "Index 1 (Failure Expecting an INT \"x\")"
-- CHECK: array first failure text: "Problem with the value at json[1]:\n\n    \"x\"\n\nExpecting an INT"
-- CHECK: dict first failure shape: "Field b (Failure Expecting an INT \"x\")"
-- CHECK: dict first failure text: "Problem with the value at json.b:\n\n    \"x\"\n\nExpecting an INT"
-- CHECK: keyValuePairs on array shape: "Failure Expecting an OBJECT [1]"
-- CHECK: keyValuePairs on array text: "Problem with the given value:\n\n[\n        1\n    ]\n\nExpecting an OBJECT"
-- CHECK: oneOf shape: "OneOf [Failure Expecting a STRING true, Failure Expecting an INT true]"
-- CHECK: oneOf text: "Json.Decode.oneOf failed in the following 2 ways:\n\n\n\n(1) Problem with the given value:\n    \n    true\n    \n    Expecting a STRING\n\n\n\n(2) Problem with the given value:\n    \n    true\n    \n    Expecting an INT"
-- CHECK: oneOf nested shape: "OneOf [Failure Expecting an OBJECT with a field named `a` [1], Index 0 (Failure Expecting a STRING 1)]"
-- CHECK: oneOf nested text: "Json.Decode.oneOf failed in the following 2 ways:\n\n\n\n(1) Problem with the given value:\n    \n    [\n            1\n        ]\n    \n    Expecting an OBJECT with a field named `a`\n\n\n\n(2) Problem with the value at json[0]:\n    \n        1\n    \n    Expecting a STRING"
-- CHECK: oneOf empty shape: "OneOf []"
-- CHECK: oneOf empty text: "Ran into a Json.Decode.oneOf with no possibilities!"
-- CHECK: fail shape: "Failure custom message {\"k\":[1,2]}"
-- CHECK: fail text: "Problem with the given value:\n\n{\n        \"k\": [\n            1,\n            2\n        ]\n    }\n\ncustom message"
-- CHECK: andThen fail shape: "Failure bad tag z {\"t\":\"z\"}"
-- CHECK: andThen fail text: "Problem with the given value:\n\n{\n        \"t\": \"z\"\n    }\n\nbad tag z"
-- CHECK: map2 second shape: "Field b (Failure Expecting a STRING 2)"
-- CHECK: map2 second text: "Problem with the value at json.b:\n\n    2\n\nExpecting a STRING"
-- CHECK: nullable shape: "OneOf [Failure Expecting null 3, Failure Expecting a STRING 3]"
-- CHECK: nullable text: "Json.Decode.oneOf failed in the following 2 ways:\n\n\n\n(1) Problem with the given value:\n    \n    3\n    \n    Expecting null\n\n\n\n(2) Problem with the given value:\n    \n    3\n    \n    Expecting a STRING"
-- CHECK: parse garbage shape: "Failure <parse error> \"not json\""
-- CHECK: parse garbage text: "Just \"Problem with the given value:\\n\\n\\\"not json\\\"\\n\\n\""
-- CHECK: parse truncated object shape: "Failure <parse error> \"{\\\"a\\\":\""
-- CHECK: parse truncated object text: "Just \"Problem with the given value:\\n\\n\\\"{\\\\\\\"a\\\\\\\":\\\"\\n\\n\""
-- CHECK: parse truncated array shape: "Failure <parse error> \"[1,2\""
-- CHECK: parse truncated array text: "Just \"Problem with the given value:\\n\\n\\\"[1,2\\\"\\n\\n\""
-- CHECK: decodeValue text: "Problem with the value at json.x:\n\n    1\n\nExpecting a STRING"

import ConformanceHelp exposing (logAll, worker)
import Json.Decode as D exposing (Decoder)
import Json.Encode as E


{-| Renders `error` by its constructors, writing each `Failure`'s value as JSON and a parse
error's message as `<parse error>`.
-}
shape : D.Error -> String
shape error =
    case error of
        D.Field f e ->
            "Field " ++ f ++ " (" ++ shape e ++ ")"

        D.Index i e ->
            "Index " ++ String.fromInt i ++ " (" ++ shape e ++ ")"

        D.OneOf es ->
            "OneOf [" ++ String.join ", " (List.map shape es) ++ "]"

        D.Failure msg value ->
            if String.startsWith "This is not valid JSON! " msg then
                "Failure <parse error> " ++ E.encode 0 value

            else
                "Failure " ++ msg ++ " " ++ E.encode 0 value


{-| One decoding case: the label its log lines start with, the decoder, and the JSON text.
-}
type alias Row =
    { label : String
    , decoder : Decoder String
    , input : String
    }


rows : List Row
rows =
    [ Row "int on string" (D.map String.fromInt D.int) "\"x\""
    , Row "int on float" (D.map String.fromInt D.int) "1.5"
    , Row "string on null" D.string "null"
    , Row "bool on int" (D.map Debug.toString D.bool) "1"
    , Row "float on bool" (D.map String.fromFloat D.float) "true"
    , Row "null" (D.null "n") "0"
    , Row "field type" (D.field "a" (D.map String.fromInt D.int)) "{\"a\":\"x\"}"
    , Row "field missing" (D.field "a" D.string) "{\"b\":1}"
    , Row "field on array" (D.field "a" D.string) "[1]"
    , Row "at nested" (D.at [ "a", "b" ] (D.map String.fromInt D.int)) "{\"a\":{\"b\":\"x\"}}"
    , Row "index short" (D.index 1 (D.map String.fromInt D.int)) "[1]"
    , Row "index type" (D.index 1 (D.map String.fromInt D.int)) "[1,\"x\"]"
    , Row "index on object" (D.index 0 D.string) "{}"
    , Row "list first failure" (D.map (String.join ",") (D.list D.string)) "[\"a\",1,\"b\",2]"
    , Row "list on object" (D.map (String.join ",") (D.list D.string)) "{}"
    , Row "array first failure" (D.map (\_ -> "") (D.array D.int)) "[1,\"x\",3,\"y\"]"
    , Row "dict first failure" (D.map (\_ -> "") (D.dict D.int)) "{\"a\":1,\"b\":\"x\",\"c\":\"y\"}"
    , Row "keyValuePairs on array" (D.map (\_ -> "") (D.keyValuePairs D.int)) "[1]"
    , Row "oneOf" (D.oneOf [ D.string, D.map String.fromInt D.int ]) "true"
    , Row "oneOf nested" (D.oneOf [ D.field "a" D.string, D.index 0 D.string ]) "[1]"
    , Row "oneOf empty" (D.oneOf []) "1"
    , Row "fail" (D.fail "custom message") "{\"k\":[1,2]}"
    , Row "andThen fail" (D.field "t" D.string |> D.andThen (\t -> D.fail ("bad tag " ++ t))) "{\"t\":\"z\"}"
    , Row "map2 second" (D.map2 (++) (D.field "a" D.string) (D.field "b" D.string)) "{\"a\":\"x\",\"b\":2}"
    , Row "nullable" (D.map (Maybe.withDefault "none") (D.nullable D.string)) "3"
    , Row "parse garbage" D.string "not json"
    , Row "parse truncated object" D.string "{\"a\":"
    , Row "parse truncated array" D.string "[1,2"
    ]


{-| Decodes `row.input` and returns its `shape` and `text` log lines, or one `ok` line if
decoding succeeds. For a row whose label starts with `parse`, the text is cut before
"This is not valid JSON! ".
-}
run : Row -> List ( String, String )
run row =
    case D.decodeString row.decoder row.input of
        Ok v ->
            [ ( row.label ++ " ok", v ) ]

        Err e ->
            [ ( row.label ++ " shape", shape e )
            , ( row.label ++ " text"
              , if String.startsWith "parse" row.label then
                    Debug.toString (List.head (String.split "This is not valid JSON! " (D.errorToString e)))

                else
                    D.errorToString e
              )
            ]


report : ()
report =
    logAll
        (List.concatMap run rows
            ++ [ ( "decodeValue text", unwrap (D.decodeValue (D.field "x" D.string) (E.object [ ( "x", E.int 1 ) ])) )
               ]
        )


unwrap : Result D.Error String -> String
unwrap r =
    case r of
        Ok v ->
            "ok " ++ v

        Err e ->
            D.errorToString e


main : Program () () ()
main =
    worker report
