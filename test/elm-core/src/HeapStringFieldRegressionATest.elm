module HeapStringFieldRegressionATest exposing (main)

{-| Category A — heap string passed through a record field.

Bug observed in stage-7 bootstrap: `D.fromByteString` reports
`Start row=1 col=1` on a runtime-built JSON string, even though the
underlying primitives (String.length / String.uncons / String.dropLeft)
return the right values when called directly on the same string.

These tests exercise the record-field indirection used by the parser's
State record.
-}

-- CHECK: a1_litLen: 3
-- CHECK: a1_rtLen: 3
-- CHECK: a2_litIdx0: 34
-- CHECK: a2_rtIdx0: 34
-- CHECK: a2_rtIdx1: 120
-- CHECK: a2_rtIdx2: 34
-- CHECK: a3_litFstCode: 34
-- CHECK: a3_litRest: "x\""
-- CHECK: a3_rtFstCode: 34
-- CHECK: a3_rtRest: "x\""
-- CHECK: a4_litEqRt: True

import Html exposing (text)


type State
    = State { src : String, pos : Int, end : Int }


unsafeIndex : String -> Int -> Char
unsafeIndex str index =
    case String.uncons (String.dropLeft index str) of
        Just ( c, _ ) ->
            c

        Nothing ->
            '?'


srcOf : State -> String
srcOf (State st) =
    st.src


unconsFstCode : String -> Int
unconsFstCode s =
    case String.uncons s of
        Just ( c, _ ) ->
            Char.toCode c

        Nothing ->
            -1


unconsRest : String -> String
unconsRest s =
    case String.uncons s of
        Just ( _, rest ) ->
            rest

        Nothing ->
            ""


main =
    let
        litStr =
            "\"x\""

        rtStr =
            "\"" ++ "x" ++ "\""

        litState =
            State { src = litStr, pos = 0, end = 3 }

        rtState =
            State { src = rtStr, pos = 0, end = 3 }

        -- A1: String.length via field
        _ =
            Debug.log "a1_litLen" (String.length (srcOf litState))

        _ =
            Debug.log "a1_rtLen" (String.length (srcOf rtState))

        -- A2: unsafeIndex via field
        _ =
            Debug.log "a2_litIdx0" (Char.toCode (unsafeIndex (srcOf litState) 0))

        _ =
            Debug.log "a2_rtIdx0" (Char.toCode (unsafeIndex (srcOf rtState) 0))

        _ =
            Debug.log "a2_rtIdx1" (Char.toCode (unsafeIndex (srcOf rtState) 1))

        _ =
            Debug.log "a2_rtIdx2" (Char.toCode (unsafeIndex (srcOf rtState) 2))

        -- A3: String.uncons via field — split into separate scalar checks
        _ =
            Debug.log "a3_litFstCode" (unconsFstCode (srcOf litState))

        _ =
            Debug.log "a3_litRest" (unconsRest (srcOf litState))

        _ =
            Debug.log "a3_rtFstCode" (unconsFstCode (srcOf rtState))

        _ =
            Debug.log "a3_rtRest" (unconsRest (srcOf rtState))

        -- A4: literal vs runtime equality via field
        _ =
            Debug.log "a4_litEqRt" (srcOf litState == srcOf rtState)
    in
    text "done"
