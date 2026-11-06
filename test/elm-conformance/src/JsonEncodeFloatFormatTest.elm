module JsonEncodeFloatFormatTest exposing (main)

{-| `Json.Encode.encode` writes a whole Float without a decimal point, uses exponent notation only
for very large and very small magnitudes, and writes NaN and infinity as `null`.

  - Whole Floats have no decimal point (`0`, `3`, `123456789`), and negative zero is `0`.
  - Exponent notation is used from 1e21 (`1e+21`) and below 1e-6 (`1.5e-7`), but not at 1e-6
    (`0.000001`).
  - `0.1 + 0.2` gives `0.30000000000000004`.
  - NaN and positive infinity encode as `null`.
  - `list`: `Json.Encode.list Json.Encode.float` gives `[1,2.5]`.
  - `value 1.0`: the JSON text `1.0` decoded as a `Value` and re-encoded gives `1`.
  - `int round trip`: `Json.Encode.float 3` encodes to text that `Json.Decode.int` reads as 3.
-}

-- CHECK: float 0: "0"
-- CHECK: float 3: "3"
-- CHECK: float -0: "0"
-- CHECK: float 123456789: "123456789"
-- CHECK: float 1e21: "1e+21"
-- CHECK: float 1.5e-7: "1.5e-7"
-- CHECK: float 1e-6: "0.000001"
-- CHECK: float 0.1+0.2: "0.30000000000000004"
-- CHECK: float nan: "null"
-- CHECK: float inf: "null"
-- CHECK: list: "[1,2.5]"
-- CHECK: value 1.0: "Ok \"1\""
-- CHECK: int round trip: "Ok 3"

import ConformanceHelp exposing (logAll, worker)
import Json.Decode as D
import Json.Encode as E


f : Float -> String
f x =
    E.encode 0 (E.float x)


report : ()
report =
    logAll
        [ ( "float 0", f 0 )
        , ( "float 3", f 3 )
        , ( "float -0", f -0 )
        , ( "float 123456789", f 123456789 )
        , ( "float 1e21", f 1.0e21 )
        , ( "float 1.5e-7", f 1.5e-7 )
        , ( "float 1e-6", f 1.0e-6 )
        , ( "float 0.1+0.2", f (0.1 + 0.2) )
        , ( "float nan", f (0 / 0) )
        , ( "float inf", f (1 / 0) )
        , ( "list", E.encode 0 (E.list E.float [ 1, 2.5 ]) )
        , ( "value 1.0", Debug.toString (D.decodeString D.value "1.0" |> Result.map (E.encode 0)) )
        , ( "int round trip", Debug.toString (D.decodeString D.int (E.encode 0 (E.float 3))) )
        ]


main : Program () () ()
main =
    worker report
