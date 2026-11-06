module PolyTailRecReverseTest exposing (main)

{-| An unannotated, polymorphic, tail-recursive list reverse gives the right
result at both `Int` and `String` element types.

`myReverse` calls the accumulator-passing `reverseHelper`, which calls itself
in tail position.

-}

-- CHECK: intRev: [3,2,1]
-- CHECK: strRev: ["c","b","a"]

import Html exposing (text)


reverseHelper acc xs =
    case xs of
        [] -> acc
        x :: rest -> reverseHelper (x :: acc) rest


myReverse xs = reverseHelper [] xs


main =
    let
        _ = Debug.log "intRev" (myReverse [1, 2, 3])
        _ = Debug.log "strRev" (myReverse ["a", "b", "c"])
    in
    text "done"
