module StateRecordOneOfRegressionGTest exposing (main)

{-| Category G — replicate the FULL parser-combinator machinery used by
`Compiler.Parse.Primitives`: State record, PStep ADT (Cok/Eok/Cerr/Eerr),
Parser newtype, andThen, oneOf, word1.

This is the closest reproducer of the stage-7 elm.json failure that
doesn't import the compiler internals.
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


-- Mirror of pObject from Compiler.Json.Decode: word1 '{', then word1 '}'
parseEmptyObject : Parser ()
parseEmptyObject =
    word1 '{'
        |> andThen (\_ -> word1 '}')


-- Mirror of pValue: oneOf [pObject, pSomeOther]
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
