module TypeAliasCtorTest exposing (main)

{-| Checks that the name of a record type alias can be used as a function that
builds the record, taking the fields in the order the alias declares them.

`Style True 42` builds `{ bold = True, count = 42 }`, which `Debug.log` prints.

-}

-- CHECK: result: { bold = True, count = 42 }

import Html exposing (text)


type alias Style =
    { bold : Bool
    , count : Int
    }


main =
    let
        s =
            Style True 42

        _ =
            Debug.log "result" s
    in
    text "done"
