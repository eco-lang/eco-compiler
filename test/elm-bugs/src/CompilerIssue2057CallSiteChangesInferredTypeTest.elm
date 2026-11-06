module CompilerIssue2057CallSiteChangesInferredTypeTest exposing (..)

{-| Call sites with rigid type variables break the type of a function inferred from local recursion.

<https://github.com/elm/compiler/issues/2057>

Each function is well-typed on its own. Elm 0.19.1 rejects the program ("This `sortWith` call
produces: List asd / But the type annotation on `sortBy` says it should be: List x"), unifying the
rigid variables of different functions. It should compile.

-}

-- CHECK: sort: []

import Html exposing (text)


sort : List cm -> List cm
sort xs =
    let
        f : cm -> cm -> Order
        f a b =
            LT
    in
    sortWith f xs


sortBy : (x -> cmpl) -> List x -> List x
sortBy f list =
    let
        cmp : x -> x -> Order
        cmp a b =
            LT
    in
    sortWith cmp list


sortWith : (asd -> asd -> Order) -> List asd -> List asd
sortWith cmp list =
    let
        f arg =
            g arg

        g bs =
            case bs of
                [] ->
                    []

                _ :: rest ->
                    f rest
    in
    always [] (f list)


main =
    let
        _ =
            Debug.log "sort" (sort [ 3, 1, 2 ])
    in
    text "done"
