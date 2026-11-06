module EqualityBoolPapTest exposing (main)

{-| `(==)` partially applied to a `Bool` works as an ordinary predicate passed
to `List.map`, `List.filter` and `List.any`.

`isTrue` is `(==) True` and `isFalse` is `(==) False`. Mapped over `[True,
False, True, False]` they give the list itself and its negation; filtering keeps
the two matching elements; and `List.any` is `True` for both, since the list
contains each value.

-}

-- CHECK: isTrueList: [True,False,True,False]
-- CHECK: isFalseList: [False,True,False,True]
-- CHECK: filterTrue: [True,True]
-- CHECK: filterFalse: [False,False]
-- CHECK: anyTrue: True
-- CHECK: anyFalse: True

import Html exposing (text)


main =
    let
        isTrue : Bool -> Bool
        isTrue = (==) True

        isFalse : Bool -> Bool
        isFalse = (==) False

        bs : List Bool
        bs = [ True, False, True, False ]

        _ = Debug.log "isTrueList" (List.map isTrue bs)
        _ = Debug.log "isFalseList" (List.map isFalse bs)
        _ = Debug.log "filterTrue" (List.filter isTrue bs)
        _ = Debug.log "filterFalse" (List.filter isFalse bs)
        _ = Debug.log "anyTrue" (List.any isTrue bs)
        _ = Debug.log "anyFalse" (List.any isFalse bs)
    in
    text "done"
