module CaseManyBranchesTest exposing (main)

{-| Test case with many branches.
-}

-- CHECK: day1: "Monday"
-- CHECK: day5: "Friday"
-- CHECK: day7: "Sunday"

import Html exposing (text)


dayName n =
    case n of
        1 -> "Monday"
        2 -> "Tuesday"
        3 -> "Wednesday"
        4 -> "Thursday"
        5 -> "Friday"
        6 -> "Saturday"
        7 -> "Sunday"
        _ -> "Unknown"


main =
    let
        _ = Debug.log "day1" (dayName 1)
        _ = Debug.log "day5" (dayName 5)
        _ = Debug.log "day7" (dayName 7)
    in
    text "done"
