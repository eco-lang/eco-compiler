module EmbeddedUnitCaptureTest exposing (main)

{-| A local function returns a tuple containing a unit value bound in the
enclosing `let`, and the tuple is destructured by a pattern.

`f` takes `()` and returns `( u, 42 )`, where `u` is the `let`-bound `()`.
Destructuring `f ()` gives `first` as `()` and `second` as 42.

-}

-- CHECK: first: ()
-- CHECK: second: 42

import Html exposing (text)


main =
    let
        u =
            ()

        f () =
            ( u, 42 )

        ( first, second ) =
            f ()

        _ = Debug.log "first" first
        _ = Debug.log "second" second
    in
    text "done"
