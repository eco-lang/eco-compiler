module LetDestructFuncTupleTest exposing (main)

{-| A `let` destructures a pair of functions chosen by a `case`: a field accessor and
a record-update lambda for the same field.

For `First`, `choose` gets the pair `( .a, \x m -> { m | a = x } )`, reads field `a`
of `{ a = 10, b = 20 }` (10), and sets it to 99 (99).

-}

-- CHECK: get: 10
-- CHECK: set: 99

import Html exposing (text)


type Loc
    = First
    | Second


choose : Loc -> { a : Int, b : Int } -> ( Int, { a : Int, b : Int } )
choose loc rec =
    let
        ( getter, setter ) =
            case loc of
                First ->
                    ( .a, \x m -> { m | a = x } )

                Second ->
                    ( .b, \x m -> { m | b = x } )
    in
    ( getter rec, setter 99 rec )


main =
    let
        ( v, r ) =
            choose First { a = 10, b = 20 }

        _ =
            Debug.log "get" v

        _ =
            Debug.log "set" r.a
    in
    text "done"
