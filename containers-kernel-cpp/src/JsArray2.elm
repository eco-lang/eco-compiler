module JsArray2 exposing
    ( JsArray2
    , empty, singleton, initialize
    , length, unsafeGet, unsafeSet, unsafeInsert, removeIndex, push
    , foldl, foldr, map, slice
    , appendN, indexedMap, initializeFromList
    )

{-| This library provides an immutable version of native javascript arrays.

NOTE: All manipulations causes a copy of the entire array, this can be slow.
For general purpose use, try the `Array` module instead.


# Arrays

@docs JsArray2


# Creation

@docs empty, singleton, initialize, listInitialize


# Basics

@docs length, unsafeGet, unsafeSet, unsafeInsert, removeIndex, push


# Transformation

@docs foldl, foldr, map, slice, merge

-}

import Elm.Kernel.JsArray2


{-| Representation of a javascript array.
-}
type JsArray2 a
    = JsArray2 a


{-| Return an empty array.
-}
empty : JsArray2 a
empty =
    Elm.Kernel.JsArray2.empty


{-| Return an array containing a single value.
-}
singleton : a -> JsArray2 a
singleton =
    Elm.Kernel.JsArray2.singleton


{-| Return the length of the array.
-}
length : JsArray2 a -> Int
length =
    Elm.Kernel.JsArray2.length


{-| Initialize an array. `initalize n offset fn` creates an array of length `n`
with the element at index `i` initialized to the result of `(f (i + offset))`.

The offset parameter is there so one can avoid creating a closure for this use
case. This is an optimization that has proved useful in the `Array` module.

    initialize 3 5 identity == [ 5, 6, 7 ]

-}
initialize : Int -> Int -> (Int -> a) -> JsArray2 a
initialize =
    Elm.Kernel.JsArray2.initialize


{-| Initialize an array from a list. `initializeFromList n ls` creates an array of,
at most, `n` elements from the list. The return value is a tuple containing the
created array as well as a list without the first `n` elements.

This function was created specifically for the `Array` module, which never wants
to create `JsArray2`s above a certain size. That being said, because every
manipulation of `JsArray2` results in a copy, users should always try to keep
these as small as possible. The `n` parameter should always be set to a
reasonably small value.

-}
initializeFromList : Int -> List a -> ( JsArray2 a, List a )
initializeFromList =
    Elm.Kernel.JsArray2.initializeFromList


{-| Returns the element at the given index.

WARNING: This function does not perform bounds checking.
Make sure you know the index is within bounds when using this function.

-}
unsafeGet : Int -> JsArray2 a -> a
unsafeGet =
    Elm.Kernel.JsArray2.unsafeGet


{-| Sets the element at the given index.

WARNING: This function does not perform bounds checking.
Make sure you know the index is within bounds when using this function.

-}
unsafeSet : Int -> a -> JsArray2 a -> JsArray2 a
unsafeSet =
    Elm.Kernel.JsArray2.unsafeSet


{-| Inserts element at given index.

WARNING: This function does not perform bounds checking.
Make sure you know the index is within bounds when using this function.

-}
unsafeInsert : Int -> a -> JsArray2 a -> JsArray2 a
unsafeInsert =
    Elm.Kernel.JsArray2.unsafeInsert


{-| Returns an array without the element stored at index n. If index is out of range, a copy
of the same array is returned.
-}
removeIndex : Int -> JsArray2 a -> JsArray2 a
removeIndex =
    Elm.Kernel.JsArray2.removeIndex


{-| Push an element onto the array.
-}
push : a -> JsArray2 a -> JsArray2 a
push =
    Elm.Kernel.JsArray2.push


{-| Reduce the array from the left.
-}
foldl : (a -> b -> b) -> b -> JsArray2 a -> b
foldl =
    Elm.Kernel.JsArray2.foldl


{-| Reduce the array from the right.
-}
foldr : (a -> b -> b) -> b -> JsArray2 a -> b
foldr =
    Elm.Kernel.JsArray2.foldr


{-| Apply a function on every element in an array.
-}
map : (a -> b) -> JsArray2 a -> JsArray2 b
map =
    Elm.Kernel.JsArray2.map


{-| Apply a function on every element and its index in an array.
An offset allows to modify the index passed to the function.

    indexedMap (,) 5 (repeat 3 3) == Array [ ( 5, 3 ), ( 6, 3 ), ( 7, 3 ) ]

-}
indexedMap : (Int -> a -> b) -> Int -> JsArray2 a -> JsArray2 b
indexedMap =
    Elm.Kernel.JsArray2.indexedMap


{-| Get a sub section of an array: `(slice start end array)`.
The `start` is a zero-based index where we will start our slice.
The `end` is a zero-based index that indicates the end of the slice.
The slice extracts up to, but no including, the `end`.

Both `start` and `end` can be negative, indicating an offset from the end
of the array. Popping the last element of the array is therefore:
`slice 0 -1 arr`.

In the case of an impossible slice, the empty array is returned.

-}
slice : Int -> Int -> JsArray2 a -> JsArray2 a
slice =
    Elm.Kernel.JsArray2.slice


{-| Appends `n` elements from array `b` onto array `a`: `(appendN n a b)`.

The `n` parameter is required by the `Array` module, which never wants to
create `JsArray2`s above a certain size, even when appending.

-}
appendN : Int -> JsArray2 a -> JsArray2 a -> JsArray2 a
appendN =
    Elm.Kernel.JsArray2.appendN
