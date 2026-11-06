module LetNumberListCaseTest exposing (main)

{-| A `number` computed by a `case` over a let-bound list can be used both as an
`Int` and as a `Float`, because Elm generalizes the type of a `let` binding.

`xs = [ 1, 2, 3 ]` and `prod` is the product of its first two elements, matched
by `a :: b :: _`.

  - `prod + 0` is used as an `Int` and logs 2.
  - `round (prod * 1.5)` uses `prod` as a `Float`: 3.0, logged as 3.

-}

-- CHECK: list-case-int: 2
-- CHECK: list-case-float: 3

import Html exposing (text)


main =
    let
        xs =
            [ 1, 2, 3 ]

        prod =
            case xs of
                a :: b :: _ ->
                    a * b

                _ ->
                    0

        _ =
            Debug.log "list-case-int" (prod + 0)

        _ =
            Debug.log "list-case-float" (round (prod * 1.5))
    in
    text "done"
