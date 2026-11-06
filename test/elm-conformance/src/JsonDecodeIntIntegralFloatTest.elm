module JsonDecodeIntIntegralFloatTest exposing (main)

{-| `Json.Decode.int` accepts a JSON number with a fraction or exponent when its value is a whole
number, and rejects one that is not.

  - `1.0`, `1e3`, `1E2` and `-0.0` decode to 1, 1000, 100 and 0.
  - `list`: `D.list D.int` on `[2.0,3]` gives `[2,3]`.
  - `value float 1`: `decodeValue D.int` of `Json.Encode.float 1` gives 1.
  - `1.5` and `value float 1.5`: 1.5 fails, from a string and from a `Value`.

Among what is not tested: whole numbers too large for a 64-bit integer, such as `1e300`.
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
