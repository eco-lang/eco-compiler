module Data.NonEmptyList exposing
    ( Nonempty(..)
    , singleton, snoc
    , toList
    , map, indexedMap, mapAccuml, foldr, sortBy
    )

{-| A list type for values that always have at least one element, so that code
holding one has no empty case to handle.

A `Nonempty` is a first element, the head, together with a list of the rest,
the tail, which may be empty. Because the head is a separate field rather than
the first entry of a `List`, an empty value cannot be written, and taking the
first element needs no `Maybe`.


# Type

@docs Nonempty


# Construction

@docs singleton, snoc


# Conversion

@docs toList


# Transformations

@docs map, indexedMap, mapAccuml, foldr, sortBy

-}

-- ====== LIST ======


{-| A list with at least one element: the head, then the tail.

The constructor is exposed, so a value can be built directly from a head and a
tail as well as with `singleton`. A head must always be supplied, so the list
is never empty.

-}
type Nonempty a
    = Nonempty a (List a)


{-| Creates a list whose only element is the one given.
-}
singleton : a -> Nonempty a
singleton a =
    Nonempty a []


{-| Returns the list with `a` added after its last element.

This copies the tail, so it takes time proportional to the length of the list.

-}
snoc : a -> Nonempty a -> Nonempty a
snoc a (Nonempty b bs) =
    Nonempty b (bs ++ [ a ])


{-| Returns the elements as an ordinary `List`, head first. The result is never
empty.
-}
toList : Nonempty a -> List a
toList (Nonempty x xs) =
    x :: xs



-- ====== INSTANCES ======


{-| Returns the list with `func` applied to every element, head included, in
the same order.
-}
map : (a -> b) -> Nonempty a -> Nonempty b
map func (Nonempty x xs) =
    Nonempty (func x) (List.map func xs)


{-| Returns the list with `func` applied to every element and its zero-based
position, the head's being 0, in the same order.
-}
indexedMap : (Int -> a -> b) -> Nonempty a -> Nonempty b
indexedMap func (Nonempty x xs) =
    Nonempty (func 0 x) (List.indexedMap (\i -> func (i + 1)) xs)


{-| Returns the list with `func` applied to every element, head first, while
threading an accumulator through the calls: each call gets the accumulator the
previous one returned, starting from `acc`. Returns the last accumulator and
the new elements, in the same order.
-}
mapAccuml : (acc -> a -> ( acc, b )) -> acc -> Nonempty a -> ( acc, Nonempty b )
mapAccuml func acc (Nonempty x xs) =
    let
        ( acc1, y ) =
            func acc x

        ( accN, ysReversed ) =
            List.foldl
                (\a ( accI, ys ) ->
                    let
                        ( accJ, b ) =
                            func accI a
                    in
                    ( accJ, b :: ys )
                )
                ( acc1, [] )
                xs
    in
    ( accN, Nonempty y (List.reverse ysReversed) )


{-| Returns `List.foldr step state` applied to the elements, head first. The
last element is combined with `state` first, and the head last.
-}
foldr : (a -> b -> b) -> b -> Nonempty a -> b
foldr step state (Nonempty x xs) =
    List.foldr step state (x :: xs)



-- ====== SORT BY ======


{-| Returns the elements sorted in ascending order of the rank `toRank` gives
each.

Elements of equal rank, the head included, keep their original order as long
as `List.sortWith` is stable.

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
