module NonEntryMainAux exposing (main)

{-| Helper for NonEntryMainEvaluatedOnceTest: a module that is not the
program's entry module but defines a top-level `main`. Run alone it is an
ordinary program.
-}

import Html exposing (Html)


main : Html msg
main =
    Html.text (Debug.log "auxMain" (String.repeat 2 "ab"))
