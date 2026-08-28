module LssGapRecordField exposing (main)

{-| LSS gap probe — a function value in a RECORD FIELD, called through the field.

Record fields are a different container path from lists, and the field's arrow
is a position the analysis must carry a set through.
-}

-- CHECK: recordField: 14

import Html exposing (text)


type alias Ops =
    { transform : Int -> Int }


double : Int -> Int
double n =
    n * 2


ops : Ops
ops =
    { transform = double }


useOps : Ops -> Int -> Int
useOps o x =
    o.transform x


main =
    let
        _ =
            Debug.log "recordField" (useOps ops 7)
    in
    text "hello"
