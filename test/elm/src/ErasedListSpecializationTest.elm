module ErasedListSpecializationTest exposing (main)

{-| A self-recursive function at `List Int` and at a list of an erased type
variable keeps two specializations (REP_BOUNDARY_003).

The `List Int` use binds the annotation variable to a number. That binding used
to leak into the solver's global super table, and the erased specialization was
then closed to `List Int`. An erased element type only arises for a list nothing
constrains (here `[]`), so this program checks behaviour across both
specializations; the layout itself is checked by the elm-test
`ProjectionHeapLayoutConsistencyTest`.
-}

-- CHECK: n: 2
-- CHECK: m: 3

import Html exposing (text)


count : List a -> Int
count xs =
    case xs of
        [] ->
            0

        _ :: rest ->
            1 + count rest


main =
    let
        _ =
            Debug.log "n" (count [ 1, 2 ] + count [])

        _ =
            Debug.log "m" (count [ 1, 2, 3 ] + count [] + count [])
    in
    text "done"
