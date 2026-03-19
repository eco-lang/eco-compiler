module PolyEscapeRecordTest exposing (main)

{-| Test polymorphic values escaping through records. -}

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
