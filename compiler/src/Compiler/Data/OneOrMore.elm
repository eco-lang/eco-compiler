module Compiler.Data.OneOrMore exposing
    ( OneOrMore(..)
    , one, more
    , destruct, getFirstTwo
    )

{-| A sequence that is never empty and that is cheap to join to another.

Such a sequence is built from single elements with `one` and by joining
sequences together with `more`, which takes constant time whatever the sizes
of the two sequences.

A `OneOrMore` is a binary tree whose leaves are the elements. The shape of the
tree carries no meaning. The order of the leaves read from left to right does:
it is the order of the sequence, so `more a b` holds the elements of `a` before
those of `b`. It can be read with `destruct`, which gives its first element and
the rest, or with `getFirstTwo`, which gives only its first two elements.
Because the constructors are exposed, a caller may also match `One` against
`More` to tell a single element from several.

@docs OneOrMore
@docs one, more
@docs destruct, getFirstTwo

-}


{-| A sequence of at least one element.

`One` is the sequence of just its element. `More` is the elements of its first
argument followed by those of its second; since each argument holds at least
one element, a `More` always holds at least two.

-}
type OneOrMore a
    = One a
    | More (OneOrMore a) (OneOrMore a)


{-| Creates the sequence holding only the given element.
-}
one : a -> OneOrMore a
one =
    One


{-| Joins two sequences into one holding the elements of the first followed by
those of the second.
-}
more : OneOrMore a -> OneOrMore a -> OneOrMore a
more =
    More


{-| Applies `func` to the first element of the sequence and a list of the
remaining elements, in order.
-}
destruct : (a -> List a -> b) -> OneOrMore a -> b
destruct func oneOrMore =
    destructLeft func oneOrMore []


{-| Applies `func` to the first element of `oneOrMore` and the list of its
remaining elements followed by `xs`.
-}
destructLeft : (a -> List a -> b) -> OneOrMore a -> List a -> b
destructLeft func oneOrMore xs =
    case oneOrMore of
        One x ->
            func x xs

        More a b ->
            destructLeft func a (destructRight b xs)


{-| Returns the elements of `oneOrMore`, in order, in front of `xs`.
-}
destructRight : OneOrMore a -> List a -> List a
destructRight oneOrMore xs =
    case oneOrMore of
        One x ->
            x :: xs

        More a b ->
            destructRight a (destructRight b xs)


{-| Returns the first two elements of the sequence `left` followed by `right`.

This is not the first element of each argument. When `left` holds two or more
elements, both come from `left` and `right` is not looked at.

-}
getFirstTwo : OneOrMore a -> OneOrMore a -> ( a, a )
getFirstTwo left right =
    case left of
        One x ->
            ( x, getFirstOne right )

        More lleft lright ->
            getFirstTwo lleft lright


{-| Returns the first element of the sequence.
-}
getFirstOne : OneOrMore a -> a
getFirstOne oneOrMore =
    case oneOrMore of
        One x ->
            x

        More left _ ->
            getFirstOne left
