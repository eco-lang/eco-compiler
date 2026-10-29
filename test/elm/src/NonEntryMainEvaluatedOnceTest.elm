module NonEntryMainEvaluatedOnceTest exposing (main)

{-| A top-level `main` of an imported, non-entry module is an ordinary
top-level value and is evaluated once, like any other: its `Debug.log` prints
a single line however many times it is referenced.

`Compiler.Generate.MLIR.Functions.generateNode` treats every global named
`main`, in whichever module, as the program entry: it removes the CAF
memoisation of `NonEntryMainAux.main`, so each reference re-evaluates the body
and `auxMain` is printed once per use (twice here) before `uses`. The CHECK-NOT
rejects a second `auxMain` line: the CHECK-NEXT pair alone also matches the
second of two.

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
