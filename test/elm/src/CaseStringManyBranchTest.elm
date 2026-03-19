module CaseStringManyBranchTest exposing (main)

{-| Test case on String with many literal patterns (day names). -}

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
