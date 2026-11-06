module NonEntryMainAux exposing (main)

{-| Supplies `NonEntryMainEvaluatedOnceTest` with a `main` that belongs to an
imported module rather than the entry module, so that the test can check it
is evaluated like any other top-level value.

Evaluating this `main` logs `auxMain: "abab"`, which lets the importing test
count how many times it was evaluated. Compiled on its own, this module is an
ordinary program.

-}

import Html exposing (Html)


{-| Logs `auxMain: "abab"` and shows the text "abab".
-}
main : Html msg
main =
    Html.text (Debug.log "auxMain" (String.repeat 2 "ab"))
