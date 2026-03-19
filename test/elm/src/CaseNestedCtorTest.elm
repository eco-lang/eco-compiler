module CaseNestedCtorTest exposing (main)

{-| Test nested constructor patterns (Container (Wrap n)). -}

-- CHECK: single: 42
-- CHECK: double: 3

import Html exposing (text)


type Wrapper
    = Wrap Int


type Container
    = Container Wrapper


extract : Container -> Int
extract c =
    case c of
        Container (Wrap n) ->
            n


type Box
    = Box ( Int, Int )


sumBox : Box -> Int
sumBox b =
    case b of
        Box ( a, x ) ->
            a + x


main =
    let
        _ =
            Debug.log "single" (extract (Container (Wrap 42)))

        _ =
            Debug.log "double" (sumBox (Box ( 1, 2 )))
    in
    text "done"
