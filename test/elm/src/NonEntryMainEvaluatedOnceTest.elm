module NonEntryMainEvaluatedOnceTest exposing (main)

{-| A top-level `main` of an imported, non-entry module is an ordinary
top-level value and is evaluated once, like any other: its `Debug.log` prints
a single line however many times it is referenced.

The test references `NonEntryMainAux.main` twice in a list and logs the
list's length, so `auxMain` must appear once, before `uses: 2`. The CHECK-NOT
rejects a second `auxMain` line, which the CHECK-NEXT pair alone would accept.

-}

-- CHECK: auxMain: "abab"
-- CHECK-NEXT: uses: 2
-- CHECK-NOT: {{auxMain[^\n]*\n[^\n]*auxMain}}

import Html exposing (text)
import NonEntryMainAux


main =
    let
        _ =
            Debug.log "uses" (List.length [ NonEntryMainAux.main, NonEntryMainAux.main ])
    in
    text "done"
