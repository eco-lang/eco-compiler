module LetRecClosureTest exposing (main)

{-| A recursive function defined in a `let` block captures a parameter of the
enclosing function and is used by an earlier binding of the same `let`.

`processItems` binds `collected = takeMore rest` before `takeMore` is defined;
`takeMore` reads the enclosing `threshold` and collects the leading `Num` values
above it, stopping at the first value that is not or at a `Blank`. On `[ Num 1, Num 2, Num 3, Blank, Num 99 ]` with
threshold 0 the result is `[1,2,3]`.

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
