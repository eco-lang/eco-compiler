module CaseCharManyBranchTest exposing (main)

{-| Test case on Char with many literal patterns (digit detection). -}

-- CHECK: d0: 0
-- CHECK: d5: 5
-- CHECK: d9: 9
-- CHECK: other: -1

import Html exposing (text)


digitToInt c =
    case c of
        '0' -> 0
        '1' -> 1
        '2' -> 2
        '3' -> 3
        '4' -> 4
        '5' -> 5
        '6' -> 6
        '7' -> 7
        '8' -> 8
        '9' -> 9
        _ -> -1


main =
    let
        _ = Debug.log "d0" (digitToInt '0')
        _ = Debug.log "d5" (digitToInt '5')
        _ = Debug.log "d9" (digitToInt '9')
        _ = Debug.log "other" (digitToInt 'x')
    in
    text "done"
