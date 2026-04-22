module ArrayEqAfterPushTest exposing (main)

{-| Building an `Array` by repeated `Array.push` from empty must produce
    a value equal to the same-sized `Array.initialize`. Regression guard
    for the canonical-shape requirement on RRB arrays.
-}

-- CHECK: push96: True
-- CHECK: push128: True
-- CHECK: push160: True

import Array
import Html exposing (text)


pushBuild : Int -> Array.Array Int
pushBuild n =
    List.foldl Array.push Array.empty (List.range 0 (n - 1))


main =
    let
        _ = Debug.log "push96"  (Array.initialize 96  identity == pushBuild 96)
        _ = Debug.log "push128" (Array.initialize 128 identity == pushBuild 128)
        _ = Debug.log "push160" (Array.initialize 160 identity == pushBuild 160)
    in
    text "done"
