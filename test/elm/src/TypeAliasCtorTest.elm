module TypeAliasCtorTest exposing (main)

{-| Test using a type alias name as a record constructor.

The monomorphizer must recognize alias-derived constructors (e.g. Style)
that are not custom type constructors but record constructors generated
from type aliases.

-}

-- CHECK: result: { count = 42, bold = True }

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
