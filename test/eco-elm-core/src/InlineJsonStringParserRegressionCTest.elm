module InlineJsonStringParserRegressionCTest exposing (main)

{-| A small parser for a double-quoted string gives the same result on string literals, on strings built at run time with `++`, and on strings cut with `String.left`.

The direct parser, `parseQuoted`, walks its input with `String.uncons`. It is run on `"x"` and `"hi"` (quotes included), each written both as a literal and with `++`, and on the first four characters of `"hi"abc`, again both as a literal and built with `++`. Each yields the text between the quotes.

The record parser, `parseQuotedSt`, reads the same input through a `State` record holding the source, a position and an end, and advances by record update. It is run on the literal and the built `"x"`.

## eco

Regression probe C for the stage-7 bootstrap failure described in test/eco-elm-core/src/HeapStringFieldRegressionATest.elm. It reproduces the symptom with a self-contained parser instead of the compiler's own; `parseQuotedSt` mirrors the state-record style of compiler/src/Compiler/Lexer/Primitives.elm, reading through `st.src` and `st.pos`.

-}

-- CHECK: c8_literalLen3: "Just x"
-- CHECK: c8_runtimeLen3: "Just x"
-- CHECK: c9_literalLen4: "Just hi"
-- CHECK: c9_runtimeLen4: "Just hi"
-- CHECK: c10_stringLeft: "Just hi"
-- CHECK: c11_stringLeftOfRuntime: "Just hi"
-- CHECK: cState_literalLen3: "Just x"
-- CHECK: cState_runtimeLen3: "Just x"

import Html exposing (text)


type alias State =
    { src : String, pos : Int, end : Int }


initialState : String -> State
initialState src =
    { src = src, pos = 0, end = String.length src }


unsafeIndex : String -> Int -> Char
unsafeIndex str index =
    case String.uncons (String.dropLeft index str) of
        Just ( c, _ ) ->
            c

        Nothing ->
            '\u{0000}'


{-| Returns the text between an opening `"` and the next `"`, or `Nothing` if the string does not start with a quote or the closing quote is missing.
-}
parseQuoted : String -> Maybe String
parseQuoted s =
    case String.uncons s of
        Just ( '"', rest ) ->
            collect rest ""

        _ ->
            Nothing


collect : String -> String -> Maybe String
collect s acc =
    case String.uncons s of
        Nothing ->
            Nothing

        Just ( '"', _ ) ->
            Just acc

        Just ( c, rest ) ->
            collect rest (acc ++ String.fromChar c)


{-| Returns the text between a `"` at `st.pos` and the next `"` before `st.end`, or `Nothing` if there is none.
-}
parseQuotedSt : State -> Maybe String
parseQuotedSt st =
    if st.pos < st.end && unsafeIndex st.src st.pos == '"' then
        collectSt { st | pos = st.pos + 1 } ""

    else
        Nothing


collectSt : State -> String -> Maybe String
collectSt st acc =
    if st.pos >= st.end then
        Nothing

    else
        let
            c =
                unsafeIndex st.src st.pos
        in
        if c == '"' then
            Just acc

        else
            collectSt { st | pos = st.pos + 1 } (acc ++ String.fromChar c)


showResult : Maybe String -> String
showResult m =
    case m of
        Just s ->
            "Just " ++ s

        Nothing ->
            "Nothing"


main =
    let
        rtLen3 =
            "\"" ++ "x" ++ "\""

        rtLen4 =
            "\"" ++ "hi" ++ "\""

        litLen3 =
            "\"x\""

        litLen4 =
            "\"hi\""

        -- C8 / C9: direct parser, literal vs runtime
        _ =
            Debug.log "c8_literalLen3" (showResult (parseQuoted litLen3))

        _ =
            Debug.log "c8_runtimeLen3" (showResult (parseQuoted rtLen3))

        _ =
            Debug.log "c9_literalLen4" (showResult (parseQuoted litLen4))

        _ =
            Debug.log "c9_runtimeLen4" (showResult (parseQuoted rtLen4))

        -- C10: String.left over a literal
        _ =
            Debug.log "c10_stringLeft" (showResult (parseQuoted (String.left 4 "\"hi\"abc")))

        -- C11: String.left over a runtime-built source
        rtMore =
            "\"hi\"" ++ "abc"

        _ =
            Debug.log "c11_stringLeftOfRuntime" (showResult (parseQuoted (String.left 4 rtMore)))

        -- State-record parser, literal vs runtime
        _ =
            Debug.log "cState_literalLen3" (showResult (parseQuotedSt (initialState litLen3)))

        _ =
            Debug.log "cState_runtimeLen3" (showResult (parseQuotedSt (initialState rtLen3)))
    in
    text "done"
