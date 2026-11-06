module PolyLetTailRecTwoTypesTest exposing (main)

{-| A let-bound, polymorphic, tail-recursive local `foldl` used at two different
types in the same expression gives the right result for each.

One use sums a `List Int` (6); the other counts the elements of a `List String`
(2), so the logged pair is `(6,2)`.

-}

-- CHECK: r: (6,2)

import Html exposing (text)


main =
    let
        foldl f acc xs =
            case xs of
                [] ->
                    acc

                x :: rest ->
                    foldl f (f x acc) rest

        _ =
            Debug.log "r" ( foldl (\x acc -> x + acc) 0 [ 1, 2, 3 ], foldl (\_ acc -> acc + 1) 0 [ "a", "b" ] )
    in
    text "done"
