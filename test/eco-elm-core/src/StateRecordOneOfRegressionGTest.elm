module StateRecordOneOfRegressionGTest exposing (main)

{-| A small parser-combinator library, built from a record of parser state and a
custom type of step results, parses `{}` both alone and as one alternative of
a `oneOf`.

A parser is a function from a `State` record (the source, position, end, row
and column) to a `PStep`, which records whether it succeeded or failed and
whether it consumed input. `oneOf` tries the next alternative only when one
fails without consuming input. Each parse runs on a literal `"{}"` and on one
built with `++`, and every parse is expected to print `Ok`:

  - `word1 '{'` alone;
  - `word1 '{'` followed by `word1 '}'` with `andThen`;
  - a `oneOf` whose first alternative expects `[` and fails without consuming
    input, so the second, the `{}` parser, succeeds.

## eco

Regression probe G for the stage-7 bootstrap failure described in test/eco-elm-core/src/HeapStringFieldRegressionATest.elm, where the self-compiled compiler failed to parse `elm.json`. It copies the full parser-combinator machinery of compiler/src/Compiler/Lexer/Primitives.elm (state record, `PStep` with consumed/empty ok/error, `andThen`, `oneOf`, `word1`), without importing compiler internals, as the closest stand-alone reproducer of that failure.

-}

-- CHECK: g_word1_lit: "Ok"
-- CHECK: g_word1_rt: "Ok"
-- CHECK: g_oneOf_lit: "Ok"
-- CHECK: g_oneOf_rt: "Ok"
-- CHECK: g_object_lit: "Ok"
-- CHECK: g_object_rt: "Ok"

import Html exposing (text)


type alias State =
    { src : String, pos : Int, end : Int, row : Int, col : Int }


type PStep a
    = Cok a State
    | Eok a State
    | Cerr Int Int
    | Eerr Int Int


type Parser a
    = Parser (State -> PStep a)


unsafeIndex : String -> Int -> Char
unsafeIndex str index =
    case String.uncons (String.dropLeft index str) of
        Just ( c, _ ) ->
            c

        Nothing ->
            '\u{0000}'


word1 : Char -> Parser ()
word1 word =
    Parser
        (\st ->
            if st.pos < st.end && unsafeIndex st.src st.pos == word then
                Cok () { st | pos = st.pos + 1, col = st.col + 1 }

            else
                Eerr st.row st.col
        )


andThen : (a -> Parser b) -> Parser a -> Parser b
andThen f (Parser p) =
    Parser
        (\st ->
            case p st of
                Cok a st1 ->
                    let
                        (Parser q) =
                            f a
                    in
                    case q st1 of
                        Cok b st2 ->
                            Cok b st2

                        Eok b st2 ->
                            Cok b st2

                        Cerr r c ->
                            Cerr r c

                        Eerr r c ->
                            Cerr r c

                Eok a st1 ->
                    let
                        (Parser q) =
                            f a
                    in
                    q st1

                Cerr r c ->
                    Cerr r c

                Eerr r c ->
                    Eerr r c
        )


oneOfHelp : State -> List (Parser a) -> PStep a
oneOfHelp st parsers =
    case parsers of
        (Parser p) :: rest ->
            case p st of
                Eerr _ _ ->
                    oneOfHelp st rest

                result ->
                    result

        [] ->
            Eerr st.row st.col


oneOf : List (Parser a) -> Parser a
oneOf parsers =
    Parser (\st -> oneOfHelp st parsers)


succeed : a -> Parser a
succeed v =
    Parser (\st -> Eok v st)


run : Parser a -> String -> Result ( Int, Int ) a
run (Parser p) src =
    let
        st0 =
            { src = src, pos = 0, end = String.length src, row = 1, col = 1 }
    in
    case p st0 of
        Cok a _ ->
            Ok a

        Eok a _ ->
            Ok a

        Cerr r c ->
            Err ( r, c )

        Eerr r c ->
            Err ( r, c )


showRes : Result ( Int, Int ) a -> String
showRes r =
    case r of
        Ok _ ->
            "Ok"

        Err ( row, col ) ->
            "Err(" ++ String.fromInt row ++ "," ++ String.fromInt col ++ ")"


{-| A parser for an empty object: `{` followed by `}`.
-}
parseEmptyObject : Parser ()
parseEmptyObject =
    word1 '{'
        |> andThen (\_ -> word1 '}')


{-| A parser for either an empty array, `[]`, or an empty object, `{}`.
-}
parseValue : Parser ()
parseValue =
    oneOf
        [ word1 '['
            |> andThen (\_ -> word1 ']')
        , parseEmptyObject
        ]


main =
    let
        litObj =
            "{}"

        rtObj =
            "{" ++ "}"

        litArrayThenObj =
            "{}"

        rtArrayThenObj =
            "{" ++ "" ++ "}"

        -- G: word1 alone
        _ =
            Debug.log "g_word1_lit" (showRes (run (word1 '{') litObj))

        _ =
            Debug.log "g_word1_rt" (showRes (run (word1 '{') rtObj))

        -- G: andThen chain
        _ =
            Debug.log "g_object_lit" (showRes (run parseEmptyObject litObj))

        _ =
            Debug.log "g_object_rt" (showRes (run parseEmptyObject rtObj))

        -- G: oneOf chain
        _ =
            Debug.log "g_oneOf_lit" (showRes (run parseValue litArrayThenObj))

        _ =
            Debug.log "g_oneOf_rt" (showRes (run parseValue rtArrayThenObj))
    in
    text "done"
