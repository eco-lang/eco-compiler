module JsonLargeUnsignedTest exposing (main)

{-| JSON-05 (plans/kernel-lib-bug-fixes.md): JSON integers above INT64_MAX. nlohmann parses them
as `number_unsigned`; eco's `jsonToHeap` used to convert that through the i64 branch, so 2^63
and 2^64-1 wrapped (2^63 became -9223372036854775808). Elm reads every JSON number as a JS
double, and eco's parser now keeps an integer above INT64_MAX as a double too.
Expected values recorded from Elm on node. The `value` row also needs JS number formatting
(JSON-NEW-1): nlohmann would print 9.223372036854776e+18.

-}

-- CHECK: float 2^63: "9223372036854776000"
-- CHECK: float 2^64-1: "18446744073709552000"
-- CHECK: value 2^63: "9223372036854776000"
-- CHECK: float int max: "9223372036854776000"

import ConformanceHelp exposing (logAll, worker)
import Json.Decode as D
import Json.Encode as E


showResult : Result D.Error String -> String
showResult r =
    case r of
        Ok s ->
            s

        Err e ->
            "Err " ++ D.errorToString e


asFloat : String -> String
asFloat text =
    showResult (D.decodeString D.float text |> Result.map String.fromFloat)


report : ()
report =
    logAll
        [ ( "float 2^63", asFloat "9223372036854775808" )
        , ( "float 2^64-1", asFloat "18446744073709551615" )
        , ( "value 2^63", showResult (D.decodeString D.value "9223372036854775808" |> Result.map (E.encode 0)) )
        , ( "float int max", asFloat "9223372036854775807" )
        ]


main : Program () () ()
main =
    worker report
