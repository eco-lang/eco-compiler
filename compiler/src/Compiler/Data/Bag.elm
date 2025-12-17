module Compiler.Data.Bag exposing
    ( Bag(..)
    , append
    , empty
    , one
    , toList
    )

{-| An efficient data structure for accumulating elements with constant-time append operations.

A Bag is a binary tree structure that allows O(1) appending of bags and O(n) conversion to a list.
This is useful for collecting results during tree traversals without paying list concatenation costs.

-}


-- BAGS


{-| A bag data structure that can be empty, contain a single element, or combine two bags.
-}
type Bag a
    = Empty
    | One a
    | Two (Bag a) (Bag a)



-- HELPERS


{-| Creates an empty bag.
-}
empty : Bag a
empty =
    Empty


{-| Creates a bag containing a single element.
-}
one : a -> Bag a
one =
    One


{-| Appends two bags together in O(1) time by creating a Two node that combines them.
-}
append : Bag a -> Bag a -> Bag a
append left right =
    case ( left, right ) of
        ( other, Empty ) ->
            other

        ( Empty, other ) ->
            other

        _ ->
            Two left right



-- TO LIST


{-| Converts a bag to a list by flattening the tree structure.
-}
toList : Bag a -> List a
toList bag =
    toListHelp bag []


toListHelp : Bag a -> List a -> List a
toListHelp bag list =
    case bag of
        Empty ->
            list

        One x ->
            x :: list

        Two a b ->
            toListHelp a (toListHelp b list)
