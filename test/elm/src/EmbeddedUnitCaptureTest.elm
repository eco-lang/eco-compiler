module EmbeddedUnitCaptureTest exposing (main)

{-| Test Unit captured by a closure and returned through a tuple.
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
