module Compiler.Data.Bag exposing (Bag, append, empty, one, toList)

{-| A way to gather results from many places and join them cheaply, deferring
the cost of building a list until the end.

Joining two lists with `++` copies the first of them, so a computation that
combines partial results again and again, such as a recursive walk that merges
what each branch found, pays for the same elements many times. A `Bag`
holds elements in order like a list, but joining two bags with `append` takes
constant time whatever their sizes. `toList` turns a bag into a list once, in a
single pass over it.

A bag is not a set: `append` keeps every element, duplicates included, and
`toList` gives the elements of the first bag passed to `append` before those of
the second.

@docs Bag, append, empty, one, toList

-}

-- ====== BAGS ======


{-| An ordered collection of elements that can be joined to another in
constant time.

`Empty` holds no elements and `One` holds a single element.

`Two` joins two bags, and `toList` gives the elements of the first before those
of the second. `append` never builds a `Two` with an `Empty` side, but the
constructors are exposed, so one can be built directly; `toList` then gives the
elements of the other side alone.

-}
type Bag a
    = Empty
    | One a
    | Two (Bag a) (Bag a)



-- ====== HELPERS ======


{-| A bag with no elements.
-}
empty : Bag a
empty =
    Empty


{-| Creates a bag containing a single element.
-}
one : a -> Bag a
one =
    One


{-| Returns a bag holding the elements of `left` followed by those of `right`,
in constant time. When either side is `Empty`, the other is returned unchanged.
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



-- ====== TO LIST ======


{-| Returns the elements of `bag` as a list, in order: for a bag built by
`append left right`, the elements of `left` come before those of `right`.
-}
toList : Bag a -> List a
toList bag =
    toListHelp bag []


{-| Returns the elements of `bag`, in order, followed by `list`.
-}
toListHelp : Bag a -> List a -> List a
toListHelp bag list =
    case bag of
        Empty ->
            list

        One x ->
            x :: list

        Two a b ->
            toListHelp a (toListHelp b list)
