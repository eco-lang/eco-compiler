module JsonDecodeIntIntegralFloatTest exposing (main)

{-| JSON-06 (plans/kernel-lib-bug-fixes.md): `Json.Decode.int` on an integral number written
with a fraction or exponent. Elm accepts any JS number for which `Number.isInteger` holds
(`1.0`, `1e3`, `-0.0`). eco's `runDecoder` `DEC_INT` used to accept only nlohmann integer nodes,
so every "Ok" row below was `Err ... Expecting an INT`. Expected values recorded from Elm on node.
Out-of-i64 integral floats (`1e300`) are a documented divergence (D24) and are tested in
test/elm-json/src/DecodeIntRangeTest.elm instead.

-}

-- CHECK: 1.0: "Ok 1"
-- CHECK: 1e3: "Ok 1000"
-- CHECK: 1E2: "Ok 100"
-- CHECK: -0.0: "Ok 0"
-- CHECK: list: "Ok [2,3]"
-- CHECK: value float 1: "Ok 1"
-- CHECK: 1.5: "Nothing"
-- CHECK: value float 1.5: "Nothing"

import ConformanceHelp exposing (logAll, worker)
import Json.Decode as D
import Json.Encode as E


int : String -> String
int text =
    Debug.toString (D.decodeString D.int text)


report : ()
report =
    logAll
        [ ( "1.0", int "1.0" )
        , ( "1e3", int "1e3" )
        , ( "1E2", int "1E2" )
        , ( "-0.0", int "-0.0" )
        , ( "list", Debug.toString (D.decodeString (D.list D.int) "[2.0,3]") )
        , ( "value float 1", Debug.toString (D.decodeValue D.int (E.float 1)) )
        , ( "1.5", Debug.toString (D.decodeString D.int "1.5" |> Result.toMaybe) )
        , ( "value float 1.5", Debug.toString (D.decodeValue D.int (E.float 1.5) |> Result.toMaybe) )
        ]


main : Program () () ()
main =
    worker report
