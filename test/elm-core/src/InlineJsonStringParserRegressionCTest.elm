module InlineJsonStringParserRegressionCTest exposing (main)

{-| Category C — minimal self-contained JSON-string parser run on
literal vs runtime-built inputs, AND through a State-record indirection
similar to the real `Compiler.Parse.Primitives`.

Reproduces the stage-7 symptom without depending on the compiler's
actual parser.
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


-- ============================================================================
-- Inline parser — does NOT depend on Compiler.Parse.Primitives
-- ============================================================================


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


-- Direct (non-State) parser: reads from a String parameter.
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


-- State-record parser: reads via st.src + st.pos, mirroring the real parser.
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
