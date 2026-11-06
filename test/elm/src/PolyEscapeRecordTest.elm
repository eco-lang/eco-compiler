module PolyEscapeRecordTest exposing (main)

{-| A record field holding a polymorphic identity function can be called, and a
record update that replaces it with an increment function gives a record whose
field calls the new function.

`r.fn 42` logs 42, and `r2.fn 5`, where `r2 = { r | fn = \y -> y + 1 }`, logs 6.

-}

-- CHECK: result: 42
-- CHECK: narrowed: 6

import Html exposing (text)


main =
    let
        r =
            { fn = \x -> x }

        _ =
            Debug.log "result" (r.fn 42)

        r2 =
            { r | fn = \y -> y + 1 }

        _ =
            Debug.log "narrowed" (r2.fn 5)
    in
    text "done"
