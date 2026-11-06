module CaseCustomType4Test exposing (main)

{-| A case on a custom type with four constructors and no arguments, with one branch per constructor, selects the right branch for each.
-}

-- CHECK: dir1: "up"
-- CHECK: dir2: "down"
-- CHECK: dir3: "left"
-- CHECK: dir4: "right"

import Html exposing (text)


type Direction
    = Up
    | Down
    | Left
    | Right


dirToStr dir =
    case dir of
        Up -> "up"
        Down -> "down"
        Left -> "left"
        Right -> "right"


main =
    let
        _ = Debug.log "dir1" (dirToStr Up)
        _ = Debug.log "dir2" (dirToStr Down)
        _ = Debug.log "dir3" (dirToStr Left)
        _ = Debug.log "dir4" (dirToStr Right)
    in
    text "done"
