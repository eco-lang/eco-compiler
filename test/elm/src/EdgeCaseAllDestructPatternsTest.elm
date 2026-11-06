module EdgeCaseAllDestructPatternsTest exposing (..)

{-| `let` bindings destructure a tuple, a record, a tuple returned by a `case`,
and an `as` pattern, and each bound name has the expected value.

`( a, b )` binds 1, `{ x }` binds 3, `( h, t )` binds the head 4 of `[ 4, 5 ]`,
and `(v as w)` binds 6, so the result `[ a, x, h, v ]` is `[1,3,4,6]`.

-}

-- CHECK: testValue: [1,3,4,6]

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        ( a, b ) =
            ( 1, 2 )

        { x } =
            { x = 3 }

        ( h, t ) =
            case [ 4, 5 ] of
                y :: ys ->
                    ( y, ys )

                [] ->
                    ( 0, [] )

        (v as w) =
            6
    in
    [ a, x, h, v ]


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
