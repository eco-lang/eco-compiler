module HeapStringFieldRegressionATest exposing (main)

{-| A string read back out of a record field inside a custom type behaves the same whether it was written as a literal or built at run time with `++`.

Both strings are `"x"` with its quotes, three characters, stored in the `src` field of a `State` record. Through that field the test checks:

  - `String.length` gives 3 for each string.
  - Indexing with `String.dropLeft` and `String.uncons` gives code 34 (`"`) at position 0 of the literal, and codes 34, 120 and 34 at positions 0 to 2 of the built string.
  - `String.uncons` splits each string into code 34 and the rest `x"`.
  - The two strings compare equal with `==`.

## eco

The first of a set of regression probes (A to G) for a stage-7 bootstrap failure: the self-compiled compiler's JSON decoder (compiler/src/Compiler/Json/Decode.elm) reported an error at row 1 column 1 on a JSON string built at run time, even though `String.length`, `String.uncons` and `String.dropLeft` gave the right answers called directly on the same string. These checks exercise the record-field indirection the parser uses for its state record (compiler/src/Compiler/Lexer/Primitives.elm). The other probes are test/eco-elm-core/src/CharThroughFunctionRegressionBTest.elm, test/eco-elm-core/src/InlineJsonStringParserRegressionCTest.elm, test/eco-elm-core/src/ParseLengthSweepRegressionDTest.elm and test/eco-elm-core/src/StateRecordOneOfRegressionGTest.elm.

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

        -- A3: String.uncons via field
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
