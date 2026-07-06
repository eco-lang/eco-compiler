module Data.Map exposing
    ( Dict
    , empty, singleton, insert
    , isEmpty, member, get, size
    , keys, values, toList, fromList
    , map, foldl, foldr, filter
    , union, diff
    )

{-| A dictionary implementation backed by association lists, supporting keys of any type with custom comparison functions.

This module wraps Elm's standard Dict to provide a dictionary where keys don't need to be comparable types.
Instead, you provide a function to convert keys to comparable values or to compare keys directly.
Initial implementation from `pzp1997/assoc-list/1.0.0`.

All functions in this module are stack safe and won't crash from recursing over large dictionaries.


# Dictionaries

@docs Dict


# Build

@docs empty, singleton, insert


# Query

@docs isEmpty, member, get, size


# Lists

@docs keys, values, toList, fromList


# Transform

@docs map, foldl, foldr, filter


# Combine

@docs union, diff

-}

import Dict


{-| A dictionary of keys and values. So a `Dict String User` is a dictionary
that lets you look up a `String` (such as user names) and find the associated
`User`.

    import Data.Map as Dict exposing (Dict)

    users : Dict String User
    users =
        Dict.fromList
            [ ( "Alice", User "Alice" 28 1.65 )
            , ( "Bob", User "Bob" 19 1.82 )
            , ( "Chuck", User "Chuck" 33 1.75 )
            ]

    type alias User =
        { name : String
        , age : Int
        , height : Float
        }

-}
type Dict c k v
    = D (Dict.Dict c ( k, v ))


{-| Create an empty dictionary.

    isEmpty empty
    --> True

-}
empty : Dict c k v
empty =
    D Dict.empty


{-| Get the value associated with a key. If the key is not found, return
`Nothing`. This is useful when you are not sure if a key will be in the
dictionary.

    type Animal
        = Cat
        | Mouse

    animals : Dict String Animal
    animals = fromList [ ("Tom", Cat), ("Jerry", Mouse) ]

    get "Tom" animals
    --> Just Cat

    get "Jerry" animals
    --> Just Mouse

    get "Spike" animals
    --> Nothing

-}
get : (k -> comparable) -> k -> Dict comparable k v -> Maybe v
get toComparable targetKey (D dict) =
    Dict.get (toComparable targetKey) dict
        |> Maybe.map Tuple.second


{-| Determine if a key is in a dictionary.
-}
member : (k -> comparable) -> k -> Dict comparable k v -> Bool
member toComparable targetKey (D dict) =
    Dict.member (toComparable targetKey) dict


{-| Determine the number of key-value pairs in the dictionary.

    size (fromList [ ( "a", 1 ), ( "b", 2 ), ( "c", 3 ) ])
    --> 3

    size (insert 1 "b" (singleton 1 "a"))
    --> 1

-}
size : Dict c k v -> Int
size (D dict) =
    Dict.size dict


{-| Determine if a dictionary is empty.

    isEmpty empty
    --> True

-}
isEmpty : Dict c k v -> Bool
isEmpty (D dict) =
    Dict.isEmpty dict


{-| Insert a key-value pair into a dictionary. Replaces value when there is
a collision.
-}
insert : (k -> comparable) -> k -> v -> Dict comparable k v -> Dict comparable k v
insert toComparable key value (D dict) =
    D (Dict.insert (toComparable key) ( key, value ) dict)


{-| Create a dictionary with one key-value pair.

    singleton identity "key" 42
        |> get identity "key"
    --> Just 42

-}
singleton : (k -> comparable) -> k -> v -> Dict comparable k v
singleton toComparable key value =
    D (Dict.singleton (toComparable key) ( key, value ))



-- ====== COMBINE ======


{-| Combine two dictionaries. If there is a collision, preference is given
to the first dictionary.

If you are using this module as an ordered dictionary, the ordering of the
output dictionary will be all the entries of the first dictionary (from most
recently inserted to least recently inserted) followed by all the entries of
the second dictionary (from most recently inserted to least recently inserted).

-}
union : Dict comparable k v -> Dict comparable k v -> Dict comparable k v
union (D leftDict) (D rightDict) =
    D (Dict.union leftDict rightDict)


{-| Keep a key-value pair when its key does not appear in the second dictionary.
-}
diff : Dict comparable k a -> Dict comparable k b -> Dict comparable k a
diff (D leftDict) (D rightDict) =
    D (Dict.diff leftDict rightDict)



-- ====== TRANSFORM ======


{-| Apply a function to all values in a dictionary.
-}
map : (k -> a -> b) -> Dict c k a -> Dict c k b
map alter (D dict) =
    D (Dict.map (\_ ( key, value ) -> ( key, alter key value )) dict)


{-| Fold over the key-value pairs in a dictionary from most recently inserted
to least recently inserted.

    users : Dict String Int
    users =
        empty
            |> insert "Alice" 28
            |> insert "Bob" 19
            |> insert "Chuck" 33

    foldl (\name age result -> age :: result) [] users
    --> [28,19,33]

-}
foldl : (k -> k -> Order) -> (k -> v -> b -> b) -> b -> Dict c k v -> b
foldl _ func initialResult (D dict) =
    Dict.foldl (\_ ( key, value ) result -> func key value result) initialResult dict


{-| Fold over the key-value pairs in a dictionary from least recently inserted
to most recently insered.

    users : Dict String Int
    users =
        empty
            |> insert "Alice" 28
            |> insert "Bob" 19
            |> insert "Chuck" 33

    foldr (\name age result -> age :: result) [] users
    --> [33,19,28]

-}
foldr : (k -> k -> Order) -> (k -> v -> b -> b) -> b -> Dict c k v -> b
foldr _ func initialResult (D dict) =
    Dict.foldr (\_ ( key, value ) result -> func key value result) initialResult dict


{-| Keep only the key-value pairs that pass the given test.
-}
filter : (k -> v -> Bool) -> Dict comparable k v -> Dict comparable k v
filter isGood (D dict) =
    D (Dict.filter (\_ ( key, value ) -> isGood key value) dict)



-- ====== LISTS ======


{-| Get all of the keys in a dictionary, in the order that they were inserted
with the most recently inserted key at the head of the list.

    keys (fromList [ ( 0, "Alice" ), ( 1, "Bob" ) ])
    --> [ 1, 0 ]

-}
keys : (k -> k -> Order) -> Dict c k v -> List k
keys _ (D dict) =
    Dict.values dict
        |> List.map Tuple.first


{-| Get all of the values in a dictionary, in the order that they were inserted
with the most recently inserted value at the head of the list.

    values (fromList [ ( 0, "Alice" ), ( 1, "Bob" ) ])
    --> [ "Bob", "Alice" ]

-}
values : (k -> k -> Order) -> Dict c k v -> List v
values _ (D dict) =
    Dict.values dict
        |> List.map Tuple.second


{-| Convert a dictionary into an association list of key-value pairs, in the
order that they were inserted with the most recently inserted entry at the
head of the list.
-}
toList : (k -> k -> Order) -> Dict c k v -> List ( k, v )
toList _ (D dict) =
    Dict.values dict


{-| Convert an association list into a dictionary. The elements are inserted
from left to right. (If you want to insert the elements from right to left, you
can simply call `List.reverse` on the input before passing it to `fromList`.)
-}
fromList : (k -> comparable) -> List ( k, v ) -> Dict comparable k v
fromList toComparable =
    List.foldl (\( key, value ) -> Dict.insert (toComparable key) ( key, value )) Dict.empty
        >> D
