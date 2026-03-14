module LetRecClosureTest exposing (main)

{-| Test for local recursive closure in let-binding.
Reproduces the takeListItems pattern from Cheapskate/Parse.elm:
a local recursive function defined in a let block that captures
a variable from an outer scope and is used before its definition.
-}

-- CHECK: LetRecClosureTest: [1,2,3]

import Html exposing (text)


type Item
    = Num Int
    | Blank


main =
    let
        items =
            [ Num 1, Num 2, Num 3, Blank, Num 99 ]

        result =
            processItems 0 items

        _ =
            Debug.log "LetRecClosureTest" result
    in
    text "hello"


processItems : Int -> List Item -> List Int
processItems threshold items =
    case items of
        [] ->
            []

        (Num n) :: rest ->
            let
                collected =
                    takeMore rest

                takeMore : List Item -> List Int
                takeMore xs =
                    case xs of
                        (Num m) :: ys ->
                            if m > threshold then
                                m :: takeMore ys

                            else
                                []

                        _ ->
                            []
            in
            n :: collected

        Blank :: rest ->
            processItems threshold rest
