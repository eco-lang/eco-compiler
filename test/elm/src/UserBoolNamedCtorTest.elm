module UserBoolNamedCtorTest exposing (main)

{-| A custom type may name its own constructors `True` and `False`, and they behave
as ordinary constructors, distinct from each other and from `Unknown`.

In this module the unqualified names `True` and `False` refer to the local type
`Tri`, not to `Bool`. The test checks:

  - `pick` maps `True`, `False` and `Unknown` to 1, 2 and 3.
  - `name`, mapped over the list `[ True, False, Unknown ]`, gives
    `["T","F","U"]`.

-}

-- CHECK: pickTrue: 1
-- CHECK: pickFalse: 2
-- CHECK: pickUnknown: 3
-- CHECK: names: ["T","F","U"]

import Html exposing (text)


type Tri
    = True
    | False
    | Unknown


pick : Tri -> Int
pick t =
    case t of
        True ->
            1

        False ->
            2

        Unknown ->
            3


name : Tri -> String
name t =
    case t of
        True ->
            "T"

        False ->
            "F"

        Unknown ->
            "U"


tris : List Tri
tris =
    [ True, False, Unknown ]


main =
    let
        _ =
            Debug.log "pickTrue" (pick True)

        _ =
            Debug.log "pickFalse" (pick False)

        _ =
            Debug.log "pickUnknown" (pick Unknown)

        _ =
            Debug.log "names" (List.map name tris)
    in
    text "done"
