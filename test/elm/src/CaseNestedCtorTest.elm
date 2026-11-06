module CaseNestedCtorTest exposing (main)

{-| Checks that constructor patterns can nest: a constructor pattern inside
another (`Container (Wrap n)`), and a tuple pattern inside a constructor
(`Box ( a, x )`).
-}

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
