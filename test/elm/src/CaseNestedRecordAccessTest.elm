module CaseNestedRecordAccessTest exposing (main)

{-| Test case where function A calls function B, both have destructuring args
AND case expressions. After MonoInlineSimplify inlines B, the case root
variable names collide because both functions consumed the same number of
Names.generate calls before their case expressions.

This triggers the SSA redefinition bug when addPlaceholderMappings reuses
an existing varMapping entry instead of allocating a fresh var.
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


{-| Small function with a destructuring arg AND a case on a record field.
The destructuring arg (At _ info) consumes _v0 for the wrapper, making
the case root _v1, matching the pattern in the caller.
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


{-| Function with a destructuring arg AND a case expression.
The destructuring arg (Branch _ pathPatterns) consumes _v0, making
the case root _v1 - same as needsCheck's case root after its destructuring.
After inlining needsCheck, both _v1 names exist in the same scope.
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
