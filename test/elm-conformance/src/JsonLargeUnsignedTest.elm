module JsonLargeUnsignedTest exposing (main)

{-| JSON integers above 2^63 - 1 decode as the nearest Float rather than wrapping around to a
negative number.

  - `float 2^63`, `float 2^64-1` and `float int max`: `Json.Decode.float` reads 2^63, 2^64 - 1
    and 2^63 - 1, and `String.fromFloat` prints the nearest Float, so 2^63 - 1 and 2^63 both give
    `9223372036854776000`.
  - `value 2^63`: 2^63 decoded as a `Value` and re-encoded with `Json.Encode.encode` gives the
    same digits.
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
