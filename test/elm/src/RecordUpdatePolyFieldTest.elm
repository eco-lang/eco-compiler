module RecordUpdatePolyFieldTest exposing (main)

{-| A record updated through a let-polymorphic binding: `r` holds an identity
function, and `{ r | f = ... }` uses `r` at the type of the new function.

The update has exactly its record's type, so the use of `r` inside it must be
typed at `Int -> Int` too (MONO_006); the solver used to leave it at an erased
type variable.
-}

-- CHECK: f: 6
-- CHECK: g: 0

import Html exposing (text)


main =
    let
        r =
            { f = \x -> x, g = 0 }

        r2 =
            { r | f = \y -> y + 1 }

        _ =
            Debug.log "f" (r2.f 5)

        _ =
            Debug.log "g" r2.g
    in
    text "done"
