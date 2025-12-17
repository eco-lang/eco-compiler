module Compiler.Data.OneOrMore exposing
    ( OneOrMore(..)
    , one, more
    , map
    , destruct, getFirstTwo
    )

{-| A binary tree structure that guarantees at least one element.

Unlike NonEmptyList which is a linear structure, OneOrMore represents a binary
tree where each node can contain either a single value or two subtrees. This
structure is useful for representing hierarchical data with guaranteed non-emptiness.


# Type

@docs OneOrMore


# Construction

@docs one, more


# Transformations

@docs map


# Extraction

@docs destruct, getFirstTwo

-}

-- ONE OR MORE


{-| A binary tree structure that guarantees at least one element.

Can be either:
- `One a`: A leaf node containing a single value
- `More (OneOrMore a) (OneOrMore a)`: A branch node containing two subtrees
-}
type OneOrMore a
    = One a
    | More (OneOrMore a) (OneOrMore a)


{-| Create a OneOrMore structure containing a single element.
-}
one : a -> OneOrMore a
one =
    One


{-| Combine two OneOrMore structures into a single binary tree node.
-}
more : OneOrMore a -> OneOrMore a -> OneOrMore a
more =
    More



-- MAP


{-| Apply a function to every element in the OneOrMore structure, preserving its shape.
-}
map : (a -> b) -> OneOrMore a -> OneOrMore b
map func oneOrMore =
    case oneOrMore of
        One value ->
            One (func value)

        More left right ->
            More (map func left) (map func right)



-- DESTRUCT


{-| Flatten the OneOrMore structure by applying a function to the leftmost element
and a list of remaining elements (traversed left-to-right, depth-first).
-}
destruct : (a -> List a -> b) -> OneOrMore a -> b
destruct func oneOrMore =
    destructLeft func oneOrMore []


destructLeft : (a -> List a -> b) -> OneOrMore a -> List a -> b
destructLeft func oneOrMore xs =
    case oneOrMore of
        One x ->
            func x xs

        More a b ->
            destructLeft func a (destructRight b xs)


destructRight : OneOrMore a -> List a -> List a
destructRight oneOrMore xs =
    case oneOrMore of
        One x ->
            x :: xs

        More a b ->
            destructRight a (destructRight b xs)



-- GET FIRST TWO


{-| Extract the first element from each of two OneOrMore structures, returning them
as a tuple. Traverses leftmost path to find the first element in each tree.
-}
getFirstTwo : OneOrMore a -> OneOrMore a -> ( a, a )
getFirstTwo left right =
    case left of
        One x ->
            ( x, getFirstOne right )

        More lleft lright ->
            getFirstTwo lleft lright


getFirstOne : OneOrMore a -> a
getFirstOne oneOrMore =
    case oneOrMore of
        One x ->
            x

        More left _ ->
            getFirstOne left
