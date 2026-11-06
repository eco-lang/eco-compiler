module CaseGuardLikeTest exposing (main)

{-| Checks that nested `case` expressions on `Bool` comparisons, used in place
of guards, pick the right branch at each threshold.

`letterGrade` tests `score >= 90`, then `>= 80`, then `>= 70`, each in the
`False` branch of the previous one. Scores 95, 85, 75 and 50 reach each of the
four results `"A"`, `"B"`, `"C"` and `"F"` once.

-}

-- CHECK: grade1: "A"
-- CHECK: grade2: "B"
-- CHECK: grade3: "C"
-- CHECK: grade4: "F"

import Html exposing (text)


letterGrade score =
    case score >= 90 of
        True -> "A"
        False ->
            case score >= 80 of
                True -> "B"
                False ->
                    case score >= 70 of
                        True -> "C"
                        False -> "F"


main =
    let
        _ = Debug.log "grade1" (letterGrade 95)
        _ = Debug.log "grade2" (letterGrade 85)
        _ = Debug.log "grade3" (letterGrade 75)
        _ = Debug.log "grade4" (letterGrade 50)
    in
    text "done"
