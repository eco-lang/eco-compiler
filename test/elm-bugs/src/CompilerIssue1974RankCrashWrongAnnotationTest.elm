module CompilerIssue1974RankCrashWrongAnnotationTest exposing (..)

{-| A wrong argument annotation on a recursive function called from another crashes the type checker.

<https://github.com/elm/compiler/issues/1974>

`removeFromRow` annotates `toRemove` as `String` but compares it with `head`, an element of type
`a` from the `Row a`. `equalRows` calls it with an element of type `a`. Elm 0.19.1 crashes ("You
ran into a compiler bug"); it should report a type mismatch.

-}

-- COMPILE-ERROR: String vs a
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: compiler bug

import Html


type Row a
    = Ext a (Row a)


equalRows : Row a -> Row a -> Bool
equalRows row1 row2 =
    case ( row1, row2 ) of
        ( Ext head1 tail1, _ ) ->
            case removeFromRow head1 row2 of
                Nothing ->
                    False

                Just tail2 ->
                    equalRows tail1 tail2


removeFromRow : String -> Row a -> Maybe (Row a)
removeFromRow toRemove row =
    case row of
        Ext head tail ->
            if head == toRemove then
                Just tail

            else
                case removeFromRow toRemove tail of
                    Nothing ->
                        Nothing

                    Just remaining ->
                        Just (Ext head remaining)


main =
    Html.text ""
