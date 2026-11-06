module LssGapRecordField exposing (main)

{-| A function stored in a record field, whose type is a `type alias`, is called through that field.

`ops` holds `double` in its `transform` field, and `useOps ops 7` calls `o.transform 7`,
logging 14.

## eco

A lambda-set specialization (LSS) probe: a record field is a different
container path from a list (test/eco-elm/src/LssGapListOfFns.elm), and the
field's arrow is a position the analysis must carry a lambda set through. Its
control is test/eco-elm/src/LssGapRecordNoFn.elm.

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
