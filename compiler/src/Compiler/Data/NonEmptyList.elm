module Compiler.Data.NonEmptyList exposing
    ( Nonempty(..)
    , singleton, cons
    , toList
    , map, foldr, sortBy
    )

{-| A list that is guaranteed to contain at least one element.

This type provides compile-time guarantees that operations on the list
will never fail due to emptiness, eliminating the need for Maybe wrappers
in many scenarios.


# Type

@docs Nonempty


# Construction

@docs singleton, cons


# Conversion

@docs toList


# Transformations

@docs map, foldr, sortBy

-}

-- LIST


{-| A non-empty list containing a head element and a (possibly empty) tail.
-}
type Nonempty a
    = Nonempty a (List a)


{-| Create a non-empty list containing a single element.
-}
singleton : a -> Nonempty a
singleton a =
    Nonempty a []


{-| Add an element to the end of a non-empty list.
-}
cons : a -> Nonempty a -> Nonempty a
cons a (Nonempty b bs) =
    Nonempty b (bs ++ [ a ])


{-| Convert a non-empty list to a standard list.
-}
toList : Nonempty a -> List a
toList (Nonempty x xs) =
    x :: xs



-- INSTANCES


{-| Apply a function to every element in a non-empty list.
-}
map : (a -> b) -> Nonempty a -> Nonempty b
map func (Nonempty x xs) =
    Nonempty (func x) (List.map func xs)


{-| Reduce a non-empty list from the right, combining elements with a function.
-}
foldr : (a -> b -> b) -> b -> Nonempty a -> b
foldr step state (Nonempty x xs) =
    List.foldr step state (x :: xs)



-- SORT BY


{-| Sort a non-empty list by a function that produces a comparable value for each element.
-}
sortBy : (a -> comparable) -> Nonempty a -> Nonempty a
sortBy toRank (Nonempty x xs) =
    let
        comparison : a -> a -> Order
        comparison a b =
            compare (toRank a) (toRank b)
    in
    case List.sortWith comparison xs of
        [] ->
            Nonempty x []

        y :: ys ->
            case comparison x y of
                LT ->
                    Nonempty x (y :: ys)

                EQ ->
                    Nonempty x (y :: ys)

                GT ->
                    Nonempty y (List.sortWith comparison (x :: ys))
