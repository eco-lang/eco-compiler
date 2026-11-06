module CaseNestedRecordAccessTest exposing (main)

{-| Checks a function that destructures a constructor in its argument and then
cases on a looked-up value, calling another function that also destructures a
constructor argument and cases on a record field.

`isIrrelevantTo` takes `(Branch _ pathPatterns)`, looks a key up in the list of
pairs, and returns `True` when the key is missing. When it is found it returns
the negation of `needsCheck`, which takes `(At _ info)` and cases on the
eleven-constructor `info.node`.

- `test1` and `test4` look up absent keys and expect `True`.
- `test2` finds a `Circle`, for which `needsCheck` is `True`, and expects `False`.
- `test3` finds a `Diamond`, for which `needsCheck` is `False`, and expects `True`.

-}

-- CHECK: test1: True
-- CHECK: test2: False
-- CHECK: test3: True
-- CHECK: test4: True

import Html exposing (text)


type Shape
    = Circle
    | Square
    | Triangle
    | Diamond
    | Pentagon
    | Hexagon
    | Heptagon
    | Octagon
    | Star
    | Cross
    | Arrow


type alias Pos =
    { line : Int
    , col : Int
    }


type alias Info =
    { name : String
    , node : Shape
    , size : Int
    }


type Located a
    = At Pos a


type Branch
    = Branch Int (List ( String, Located Info ))


listLookup : a -> List ( a, b ) -> Maybe b
listLookup target list =
    case list of
        [] ->
            Nothing

        ( key, value ) :: rest ->
            if key == target then
                Just value

            else
                listLookup target rest


{-| Returns `True` for `Circle`, `Square` and `Triangle` and `False` for every
other shape, unwrapping the `At` constructor in its argument pattern.
-}
needsCheck : Located Info -> Bool
needsCheck (At _ info) =
    case info.node of
        Circle ->
            True

        Square ->
            True

        Triangle ->
            True

        Diamond ->
            False

        Pentagon ->
            False

        Hexagon ->
            False

        Heptagon ->
            False

        Octagon ->
            False

        Star ->
            False

        Cross ->
            False

        Arrow ->
            False


{-| Returns `True` when the path is absent from the branch's list, and otherwise
the negation of `needsCheck` for the value found under it.
-}
isIrrelevantTo : String -> Branch -> Bool
isIrrelevantTo selectedPath (Branch _ pathPatterns) =
    case listLookup selectedPath pathPatterns of
        Nothing ->
            True

        Just val ->
            not (needsCheck val)


main =
    let
        pos =
            { line = 1, col = 1 }

        pairs =
            Branch 0
                [ ( "a", At pos { name = "alpha", node = Diamond, size = 10 } )
                , ( "b", At pos { name = "beta", node = Circle, size = 5 } )
                ]

        _ = Debug.log "test1" (isIrrelevantTo "missing" pairs)
        _ = Debug.log "test2" (isIrrelevantTo "b" pairs)
        _ = Debug.log "test3" (isIrrelevantTo "a" pairs)
        _ = Debug.log "test4" (isIrrelevantTo "nonexistent" pairs)
    in
    text "done"
