module FloatSpecialValuesTest exposing (main)

{-| Test encoding/decoding special float values.
-}

-- CHECK: FloatSpecialValuesTest: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        -- Test positive infinity
        posInf =
            1 / 0

        posInfRoundtrip =
            D.decode (D.float64 BE) (E.encode (E.float64 BE posInf))
                |> Maybe.map (\x -> x == posInf)
                |> Maybe.withDefault False

        -- Test negative infinity
        negInf =
            -1 / 0

        negInfRoundtrip =
            D.decode (D.float64 BE) (E.encode (E.float64 BE negInf))
                |> Maybe.map (\x -> x == negInf)
                |> Maybe.withDefault False

        -- Test zero
        zeroRoundtrip =
            D.decode (D.float64 BE) (E.encode (E.float64 BE 0))
                == Just 0

        result =
            posInfRoundtrip && negInfRoundtrip && zeroRoundtrip

        _ =
            Debug.log "FloatSpecialValuesTest" result
    in
    text (if result then "True" else "False")
