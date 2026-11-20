module EraseWrapperFunctionTest exposing (main)

{-| A parser-style wrapper around a function, `type Parser a = Parser (String
-> Maybe ( a, String ))`, combined with `map`, `andThen` and a first-class use
of the constructor, as monadic library code does. `EraseWrappers`
(plans/constructor-representation-levels.md E1a) represents each `Parser` as
the closure itself.

-}

-- CHECK: digit: Just (7,"x")
-- CHECK: two: Just (35,"")
-- CHECK: fail: Nothing
-- CHECK: many: Just ([1,2,3],"!")
-- CHECK: mapped: Just ("8","y")

import Html exposing (text)


type Parser a
    = Parser (String -> Maybe ( a, String ))


run : Parser a -> String -> Maybe ( a, String )
run (Parser p) s =
    p s


digit : Parser Int
digit =
    Parser
        (\s ->
            case String.uncons s of
                Just ( c, rest ) ->
                    if Char.isDigit c then
                        Just ( Char.toCode c - 48, rest )

                    else
                        Nothing

                Nothing ->
                    Nothing
        )


map : (a -> b) -> Parser a -> Parser b
map f (Parser p) =
    Parser (\s -> Maybe.map (\( a, r ) -> ( f a, r )) (p s))


andThen : (a -> Parser b) -> Parser a -> Parser b
andThen f (Parser p) =
    Parser
        (\s ->
            case p s of
                Just ( a, r ) ->
                    run (f a) r

                Nothing ->
                    Nothing
        )


succeed : a -> Parser a
succeed a =
    Parser (\s -> Just ( a, s ))


many : Parser a -> Parser (List a)
many p =
    Parser
        (\s ->
            case run p s of
                Just ( a, r ) ->
                    Maybe.map (\( rest, r2 ) -> ( a :: rest, r2 )) (run (many p) r)

                Nothing ->
                    Just ( [], s )
        )


main =
    let
        _ =
            Debug.log "digit" (run digit "7x")

        _ =
            Debug.log "two" (run (digit |> andThen (\a -> map (\b -> a * 10 + b) digit)) "35")

        _ =
            Debug.log "fail" (run digit "x")

        _ =
            Debug.log "many" (run (many digit) "123!")

        wrap =
            List.map Parser [ \s -> Just ( 8, s ) ]

        _ =
            Debug.log "mapped" (List.head wrap |> Maybe.andThen (\p -> run (map String.fromInt p) "y"))
    in
    text "done"
