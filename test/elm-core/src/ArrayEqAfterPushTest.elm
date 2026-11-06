module ArrayEqAfterPushTest exposing (main)

{-| An `Array` built by `Array.push` from empty is equal under `==` to `Array.initialize` of the
same elements, for lengths 96, 128 and 160.
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
