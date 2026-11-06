module CaseStringManyBranchTest exposing (main)

{-| A case expression on a `String` with seven literal patterns (three-letter day
abbreviations) and a wildcard selects the matching branch.

The test checks the first, fourth and last literals, and a string that matches
none of them.

-}

-- CHECK: d1: "Monday"
-- CHECK: d4: "Thursday"
-- CHECK: d7: "Sunday"
-- CHECK: other: "unknown"

import Html exposing (text)


dayName day =
    case day of
        "Mon" -> "Monday"
        "Tue" -> "Tuesday"
        "Wed" -> "Wednesday"
        "Thu" -> "Thursday"
        "Fri" -> "Friday"
        "Sat" -> "Saturday"
        "Sun" -> "Sunday"
        _ -> "unknown"


main =
    let
        _ = Debug.log "d1" (dayName "Mon")
        _ = Debug.log "d4" (dayName "Thu")
        _ = Debug.log "d7" (dayName "Sun")
        _ = Debug.log "other" (dayName "xyz")
    in
    text "done"
