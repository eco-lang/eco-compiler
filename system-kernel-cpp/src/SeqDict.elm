module SeqDict exposing
    ( SeqDict
    , empty, singleton, insert, update, updateIfExists, remove
    , get, isEmpty, member, size, unorderedEquals
    , union, intersect, diff, merge
    , toList, fromList, keys, values
    , foldl, foldr, map, filter, filterMap, partition
    )

{-| A dictionary mapping unique keys to values where insertion order is preserved for functions like foldl and toList.


# Seq Dictionary

@docs SeqDict


# Build

@docs empty, singleton, insert, update, updateIfExists, remove


# Query

@docs get, isEmpty, member, size, unorderedEquals


# Combine

@docs union, intersect, diff, merge


# Lists

@docs toList, fromList, keys, values


# Transform

@docs foldl, foldr, map, filter, filterMap, partition


-}

import Array exposing (Array)
import Bitwise
import FNV
import JsArray2 exposing (JsArray2)


{-| A dictionary of keys and values. So a `(Dict String User)` is a dictionary
that lets you look up a `String` (such as user names) and find the associated
`User`.

This implementation differs from the one in core in that keys don't have to
be comparable, and that operations like foldl and foldr iterates the key-value
pairs in insertion order instead of sorted order.

-}
type
    SeqDict k v
    -- Bitmap (Int): The tree is compressed (empty nodes are not stored), so
    -- this bitmap stores what index each node is actually stored at.
    --
    -- Tree (NodeArray k v): An array of nodes. "Empty" nodes are not
    -- stored in the array, so we need a bitmap to figure out which
    -- index each node is actually stored at.
    --
    -- Int Dict: This datastructure stores each key-value pair in
    -- insertion order. Whenever we iterate over the hash-map, we actually
    -- iterate over this data structure. You can find the Int Dict impl.
    -- at the bottom of this file.
    = SeqDict_elm_builtin Int (NodeArray k v) (IntDict k v)


type alias NodeArray k v =
    JsArray2 (Node k v)


type
    Node k v
    -- Index into Int Dict structure, the key hash, key and value.
    = Leaf Int Int k v
      -- Bitmap for the NodeArray and the actual NodeArray
    | SubTree Int (NodeArray k v)
      -- Hashing different keys can give us the same result. We call this a collision.
      -- The hash for each triplet, and a list of (Int Dict index, key and value)
    | Collision Int (List ( Int, k, v ))


{-| How many bits represents the branching factor. Read Array documentation for
more info.
-}
shiftStep : Int
shiftStep =
    5


{-| A mask which, when used in a bitwise and, reads the first `shiftStep` bits
in a number as a number of its own.
-}
bitMask : Int
bitMask =
    Bitwise.shiftRightZfBy (32 - shiftStep) 0xFFFFFFFF


{-| The empty dictionary.
-}
empty : SeqDict k v
empty =
    SeqDict_elm_builtin 0 JsArray2.empty intDictEmpty


{-| Create a dictionary with one key-value pair.
-}
singleton : k -> v -> SeqDict k v
singleton key val =
    insert key val empty


{-| Determine if a dictionary is empty.

    isEmpty empty == True

-}
isEmpty : SeqDict k v -> Bool
isEmpty (SeqDict_elm_builtin bitmap _ _) =
    bitmap == 0


{-| Determine the number of key-value pairs in the dictionary.
-}
size : SeqDict k v -> Int
size (SeqDict_elm_builtin _ _ triplets) =
    triplets.size


{-| Get the value associated with a key. If the key is not found, return
`Nothing`. This is useful when you are not sure if a key will be in the
dictionary.

    animals = fromList [ ("Tom", Cat), ("Jerry", Mouse) ]

    get "Tom"   animals == Just Cat
    get "Jerry" animals == Just Mouse
    get "Spike" animals == Nothing

-}
get : k -> SeqDict k v -> Maybe v
get key (SeqDict_elm_builtin bitmap nodes _) =
    getHelp 0 (FNV.hash key) key bitmap nodes


getHelp : Int -> Int -> k -> Int -> NodeArray k v -> Maybe v
getHelp shift hash key bitmap nodes =
    let
        index =
            -- Read `shift + shiftStep` bits from the hash as a number
            -- of its own.
            Bitwise.and bitMask (Bitwise.shiftRightZfBy shift hash)

        mask =
            -- Create a mask, a number where a specific bit is set. We
            -- can use this to figure out what the actual position of
            -- a node is in the tree.
            Bitwise.shiftLeftBy index 1
    in
    -- is the bit at `index` set?
    if Bitwise.and bitmap mask == mask then
        case JsArray2.unsafeGet (compressedIndex index bitmap) nodes of
            Leaf _ eIdx eKey eVal ->
                if key == eKey then
                    Just eVal

                else
                    Nothing

            SubTree subBitmap subNodes ->
                getHelp (shift + shiftStep) hash key subBitmap subNodes

            Collision _ vals ->
                case listFind (\( _, k, _ ) -> k == key) vals of
                    Just ( _, _, val ) ->
                        Just val

                    Nothing ->
                        Nothing

    else
        Nothing


{-| Given an index and a bitmap, return the compressed index of a Node
in a NodeArray.
-}
compressedIndex : Int -> Int -> Int
compressedIndex index bitmap =
    -- The NodeArray at each level of a tree can be, at most, 32 in size.
    -- A bitmap can contain 32 bits. 1 bit represents a stored value.
    -- The compressed index is the number of elements to the left of the
    -- idx bit.
    let
        -- eco's Bitwise works on 64 bits, not 32 as JavaScript's does, so the
        -- bits shifted past bit 31 are masked off here, and the byte that holds
        -- the count is masked off at the end.
        relevantBits =
            Bitwise.and 0xFFFFFFFF (Bitwise.shiftLeftBy 1 (Bitwise.shiftLeftBy (31 - index) bitmap))

        -- Count the number of set bits (1 bits) in an Int.
        -- See: <https://graphics.stanford.edu/~seander/bithacks.html#CountBitsSetParallel>
        b1 =
            relevantBits - Bitwise.and (Bitwise.shiftRightZfBy 1 relevantBits) 0x55555555

        b2 =
            Bitwise.and b1 0x33333333 + Bitwise.and (Bitwise.shiftRightZfBy 2 b1) 0x33333333
    in
    Bitwise.and 0xFF (Bitwise.shiftRightZfBy 24 (Bitwise.and (b2 + Bitwise.shiftRightZfBy 4 b2) 0x0F0F0F0F * 0x01010101))


{-| Determine if a key is in a dictionary.
-}
member : k -> SeqDict k v -> Bool
member key (SeqDict_elm_builtin bitmap nodes _) =
    case getHelp 0 (FNV.hash key) key bitmap nodes of
        Just _ ->
            True

        Nothing ->
            False


{-| Insert a key-value pair into the dictionary. Replaces value when there is
a collision.
-}
insert : k -> v -> SeqDict k v -> SeqDict k v
insert key value (SeqDict_elm_builtin bitmap nodes triplets) =
    insertHelp 0 (FNV.hash key) key value bitmap nodes triplets


{-| At some point we will run out of order indices, so we'll have to compress
the int dict by rebuilding the it
-}
rebuildOnOverflow : SeqDict k v -> SeqDict k v
rebuildOnOverflow ((SeqDict_elm_builtin _ _ rootTriplets) as dict) =
    if (toFloat rootTriplets.size / toFloat (Array.length rootTriplets.array)) < 0.8 then
        let
            helper : ( Int, k, v ) -> SeqDict k v -> SeqDict k v
            helper ( hash, key, value ) (SeqDict_elm_builtin bitmap nodes triplets) =
                insertHelp 0 hash key value bitmap nodes triplets
        in
        intDictFoldl helper empty rootTriplets

    else
        dict


insertHelp :
    Int
    -> Int
    -> k
    -> v
    -> Int
    -> NodeArray k v
    -> IntDict k v
    -> SeqDict k v
insertHelp shift hash key value bitmap nodes triplets =
    let
        uncompressedIdx =
            Bitwise.and bitMask (Bitwise.shiftRightZfBy shift hash)

        comIdx =
            compressedIndex uncompressedIdx bitmap

        newShift =
            shift + shiftStep

        mask =
            Bitwise.shiftLeftBy uncompressedIdx 1

        hasValue =
            Bitwise.and bitmap mask == mask
    in
    if hasValue then
        case JsArray2.unsafeGet comIdx nodes of
            (Leaf xHash xIdx xKey xVal) as node ->
                if xHash == hash then
                    if xKey == key then
                        SeqDict_elm_builtin
                            bitmap
                            (JsArray2.unsafeSet comIdx (Leaf xHash xIdx xKey value) nodes)
                            (intDictSet xIdx hash key value triplets)

                    else
                        let
                            element =
                                Collision hash
                                    [ ( Array.length triplets.array, key, value )
                                    , ( xIdx, xKey, xVal )
                                    ]
                        in
                        SeqDict_elm_builtin
                            bitmap
                            (JsArray2.unsafeSet comIdx element nodes)
                            (intDictPush hash key value triplets)

                else
                    let
                        subIdx =
                            Bitwise.and bitMask (Bitwise.shiftRightZfBy newShift xHash)

                        (SeqDict_elm_builtin secondBitmap secondNodes newTriplets) =
                            insertHelp
                                newShift
                                hash
                                key
                                value
                                (Bitwise.shiftLeftBy subIdx 1)
                                (JsArray2.singleton node)
                                triplets

                        subTree =
                            SubTree secondBitmap secondNodes
                    in
                    SeqDict_elm_builtin
                        bitmap
                        (JsArray2.unsafeSet comIdx subTree nodes)
                        newTriplets

            SubTree subBitmap subNodes ->
                let
                    (SeqDict_elm_builtin newSubBitmap newSubNodes newTriplets) =
                        insertHelp newShift hash key value subBitmap subNodes triplets

                    newSub =
                        SubTree newSubBitmap newSubNodes
                in
                SeqDict_elm_builtin
                    bitmap
                    (JsArray2.unsafeSet comIdx newSub nodes)
                    newTriplets

            (Collision xHash pairs) as currValue ->
                if xHash == hash then
                    let
                        keyFinder ( _, k, _ ) =
                            k == key
                    in
                    case listFind keyFinder pairs of
                        Just ( existingIdx, _, _ ) ->
                            let
                                whenRemoved =
                                    List.filter (\pair -> not (keyFinder pair)) pairs

                                updated =
                                    ( existingIdx, key, value ) :: whenRemoved
                            in
                            SeqDict_elm_builtin
                                bitmap
                                (JsArray2.unsafeSet comIdx (Collision xHash updated) nodes)
                                (intDictSet existingIdx hash key value triplets)

                        Nothing ->
                            let
                                updated =
                                    ( Array.length triplets.array, key, value ) :: pairs
                            in
                            SeqDict_elm_builtin
                                bitmap
                                (JsArray2.unsafeSet comIdx (Collision xHash updated) nodes)
                                (intDictPush hash key value triplets)

                else
                    let
                        subIdx =
                            Bitwise.and bitMask (Bitwise.shiftRightZfBy newShift xHash)

                        (SeqDict_elm_builtin secondBitmap secondNodes newTriplets) =
                            insertHelp
                                newShift
                                hash
                                key
                                value
                                (Bitwise.shiftLeftBy subIdx 1)
                                (JsArray2.singleton currValue)
                                triplets

                        subTree =
                            SubTree secondBitmap secondNodes
                    in
                    SeqDict_elm_builtin
                        bitmap
                        (JsArray2.unsafeSet comIdx subTree nodes)
                        newTriplets
        --let
        --    subIdx =
        --        Bitwise.and bitMask (Bitwise.shiftRightZfBy newShift xHash)
        --
        --    (SeqDict_elm_builtin secondBitmap secondNodes newTriplets) =
        --        insertHelp
        --            newShift
        --            hash
        --            key
        --            value
        --            (Bitwise.shiftLeftBy subIdx 1)
        --            (JsArray2.singleton node)
        --            triplets
        --
        --    subTree =
        --        SubTree secondBitmap secondNodes
        --in
        --SeqDict_elm_builtin
        --    bitmap
        --    (JsArray2.unsafeSet comIdx subTree nodes)
        --    newTriplets

    else
        SeqDict_elm_builtin
            (Bitwise.or bitmap mask)
            (JsArray2.unsafeInsert comIdx (Leaf hash (Array.length triplets.array) key value) nodes)
            (intDictPush hash key value triplets)


{-| Remove a key-value pair from a dictionary. If the key is not found,
no changes are made.
-}
remove : k -> SeqDict k v -> SeqDict k v
remove key dict =
    let
        (SeqDict_elm_builtin bitmap nodes triplets) =
            rebuildOnOverflow dict
    in
    removeHelp 0 (FNV.hash key) key bitmap nodes triplets


removeHelp :
    Int
    -> Int
    -> k
    -> Int
    -> NodeArray k v
    -> IntDict k v
    -> SeqDict k v
removeHelp shift hash key bitmap nodes triplets =
    let
        uncompIdx =
            Bitwise.and bitMask (Bitwise.shiftRightZfBy shift hash)

        compIdx =
            compressedIndex uncompIdx bitmap

        mask =
            Bitwise.shiftLeftBy uncompIdx 1

        hasValue =
            Bitwise.and bitmap mask == mask
    in
    if hasValue then
        case JsArray2.unsafeGet compIdx nodes of
            Leaf _ eIdx eKey eVal ->
                if eKey == key then
                    SeqDict_elm_builtin
                        (Bitwise.xor bitmap mask)
                        (JsArray2.removeIndex compIdx nodes)
                        (intDictRemove eIdx triplets)

                else
                    SeqDict_elm_builtin bitmap nodes triplets

            SubTree subBitmap subNodes ->
                let
                    (SeqDict_elm_builtin newSubBitmap newSubNodes newTriplets) =
                        removeHelp
                            (shift + shiftStep)
                            hash
                            key
                            subBitmap
                            subNodes
                            triplets
                in
                if newSubBitmap == 0 then
                    SeqDict_elm_builtin
                        (Bitwise.xor bitmap mask)
                        (JsArray2.removeIndex compIdx nodes)
                        newTriplets

                else
                    SeqDict_elm_builtin
                        bitmap
                        (JsArray2.unsafeSet compIdx (SubTree newSubBitmap newSubNodes) nodes)
                        newTriplets

            Collision xHash vals ->
                let
                    maybeIdx =
                        listFind (\( _, k, _ ) -> k == key) vals
                            |> Maybe.map (\( idx, _, _ ) -> idx)

                    newCollision =
                        case maybeIdx of
                            Just removeIdx ->
                                List.filter (\( _, k, _ ) -> k /= key) vals

                            Nothing ->
                                vals

                    newTriplets =
                        case maybeIdx of
                            Just removeIdx ->
                                intDictRemove removeIdx triplets

                            Nothing ->
                                triplets
                in
                case newCollision of
                    [] ->
                        SeqDict_elm_builtin
                            (Bitwise.xor bitmap mask)
                            (JsArray2.removeIndex compIdx nodes)
                            newTriplets

                    ( eIdx, eKey, eVal ) :: [] ->
                        SeqDict_elm_builtin
                            bitmap
                            (JsArray2.unsafeSet compIdx (Leaf xHash eIdx eKey eVal) nodes)
                            newTriplets

                    _ ->
                        SeqDict_elm_builtin
                            bitmap
                            (JsArray2.unsafeSet compIdx (Collision xHash newCollision) nodes)
                            newTriplets

    else
        SeqDict_elm_builtin
            bitmap
            nodes
            triplets


{-| Update the value of a dictionary for a specific key with a given function.
The given function gets the current value as a parameter and its return value
determines if the value is updated or removed. New key-value pairs can be
inserted too.
-}
update : k -> (Maybe v -> Maybe v) -> SeqDict k v -> SeqDict k v
update key fn ((SeqDict_elm_builtin bitmap nodes triplets) as dict) =
    let
        hash =
            FNV.hash key
    in
    case fn (getHelp 0 hash key bitmap nodes) of
        Nothing ->
            let
                (SeqDict_elm_builtin bitmap2 nodes2 triplets2) =
                    rebuildOnOverflow dict
            in
            removeHelp 0 hash key bitmap2 nodes2 triplets2

        Just value ->
            insertHelp 0 hash key value bitmap nodes triplets


{-| Update the value of a dictionary _only_ if the specified key is present in the dictionary.
-}
updateIfExists : k -> (v -> v) -> SeqDict k v -> SeqDict k v
updateIfExists key fn ((SeqDict_elm_builtin bitmap nodes triplets) as dict) =
    let
        hash =
            FNV.hash key
    in
    case getHelp 0 hash key bitmap nodes of
        Nothing ->
            dict

        Just value ->
            insertHelp 0 hash key (fn value) bitmap nodes triplets



-- LISTS


{-| Convert an association list into a dictionary.
-}
fromList : List ( k, v ) -> SeqDict k v
fromList list =
    List.foldl (\( key, value ) acc -> insert key value acc) empty list


{-| Convert a dictionary into an association list of key-value pairs.
-}
toList : SeqDict k v -> List ( k, v )
toList (SeqDict_elm_builtin _ _ triplets) =
    let
        helper : ( Int, k, v ) -> List ( k, v ) -> List ( k, v )
        helper ( _, key, value ) acc =
            ( key, value ) :: acc
    in
    intDictFoldr helper [] triplets


{-| Get all of the keys in a dictionary.

       keys (fromList [(0,"Alice"),(1,"Bob")]) == [0,1]

-}
keys : SeqDict k v -> List k
keys (SeqDict_elm_builtin _ _ triplets) =
    let
        helper : ( Int, k, v ) -> List k -> List k
        helper ( _, key, _ ) acc =
            key :: acc
    in
    intDictFoldr helper [] triplets


{-| Get all of the values in a dictionary as a List.

       values (fromList [(0,"Alice"),(1,"Bob")]) == ["Alice", "Bob"]

-}
values : SeqDict k v -> List v
values (SeqDict_elm_builtin _ _ triplets) =
    let
        helper : ( Int, k, v ) -> List v -> List v
        helper ( _, _, value ) acc =
            value :: acc
    in
    intDictFoldr helper [] triplets



-- TRANSFORM


{-| Fold over the key-value pairs in a dictionary in the order the key was
first inserted.
-}
foldl : (k -> v -> b -> b) -> b -> SeqDict k v -> b
foldl fn acc (SeqDict_elm_builtin _ _ triplets) =
    let
        helper : ( Int, k, v ) -> b -> b
        helper ( _, key, value ) acc2 =
            fn key value acc2
    in
    intDictFoldl helper acc triplets


{-| Fold over the key-value pairs in a dictionary in the reverse order the key
was first inserted.
-}
foldr : (k -> v -> b -> b) -> b -> SeqDict k v -> b
foldr fn acc (SeqDict_elm_builtin _ _ triplets) =
    let
        helper : ( Int, k, v ) -> b -> b
        helper ( _, key, value ) acc2 =
            fn key value acc2
    in
    intDictFoldr helper acc triplets


{-| Apply a function to all values in a dictionary.
-}
map : (k -> a -> b) -> SeqDict k a -> SeqDict k b
map fn (SeqDict_elm_builtin rootBitmap rootNodes rootTriplets) =
    let
        valueHelper : ( Int, k, a ) -> ( Int, k, b )
        valueHelper ( i, k, v ) =
            ( i, k, fn k v )

        dictHelper : Node k a -> Node k b
        dictHelper node =
            case node of
                Leaf idx h k v ->
                    Leaf idx h k <| fn k v

                SubTree bitmap nodes ->
                    SubTree bitmap <| JsArray2.map dictHelper nodes

                Collision h triplets ->
                    Collision h <| List.map valueHelper triplets
    in
    SeqDict_elm_builtin
        rootBitmap
        (JsArray2.map dictHelper rootNodes)
        { size = rootTriplets.size
        , array = Array.map (Maybe.map valueHelper) rootTriplets.array
        }


{-| Keep a key-value pair when it satisfies a predicate.
-}
filter : (k -> v -> Bool) -> SeqDict k v -> SeqDict k v
filter predicate (SeqDict_elm_builtin _ _ rootTriplets) =
    let
        helper : ( Int, k, v ) -> SeqDict k v -> SeqDict k v
        helper ( hash, key, value ) ((SeqDict_elm_builtin bitmap nodes triplets) as dict) =
            if predicate key value then
                insertHelp 0 hash key value bitmap nodes triplets

            else
                dict
    in
    intDictFoldl helper empty rootTriplets


{-| Filter out certain key-value pairs while also mapping over the values.
-}
filterMap : (k -> v -> Maybe v2) -> SeqDict k v -> SeqDict k v2
filterMap mapFunc (SeqDict_elm_builtin _ _ intDict) =
    let
        helper : ( Int, k, v ) -> SeqDict k v2 -> SeqDict k v2
        helper ( hash, key, value ) ((SeqDict_elm_builtin bitmap nodes triplets) as dict2) =
            case mapFunc key value of
                Just value2 ->
                    insertHelp 0 hash key value2 bitmap nodes triplets

                Nothing ->
                    dict2
    in
    intDictFoldl helper empty intDict


{-| Partition a dictionary according to a predicate. The first dictionary
contains all key-value pairs which satisfy the predicate, and the second
contains the rest.
-}
partition : (k -> v -> Bool) -> SeqDict k v -> ( SeqDict k v, SeqDict k v )
partition predicate (SeqDict_elm_builtin _ _ rootTriplets) =
    let
        helper : ( Int, k, v ) -> ( SeqDict k v, SeqDict k v ) -> ( SeqDict k v, SeqDict k v )
        helper ( hash, key, value ) ( t1, t2 ) =
            let
                (SeqDict_elm_builtin bitmap1 nodes1 triplets1) =
                    t1

                (SeqDict_elm_builtin bitmap2 nodes2 triplets2) =
                    t2
            in
            if predicate key value then
                ( insertHelp 0 hash key value bitmap1 nodes1 triplets1, t2 )

            else
                ( t1, insertHelp 0 hash key value bitmap2 nodes2 triplets2 )
    in
    intDictFoldl helper ( empty, empty ) rootTriplets



-- COMBINE


{-| Combine two dictionaries. If there is a collision, preference is given
to the first dictionary.
-}
union : SeqDict k v -> SeqDict k v -> SeqDict k v
union (SeqDict_elm_builtin _ _ t1Triplets) t2 =
    let
        helper : ( Int, k, v ) -> SeqDict k v -> SeqDict k v
        helper ( hash, key, value ) (SeqDict_elm_builtin bitmap nodes triplets) =
            insertHelp 0 hash key value bitmap nodes triplets
    in
    intDictFoldl helper t2 t1Triplets


{-| Keep a key-value pair when its key appears in the second Dictionary.
Preference is given to values in the first Dictionary.
-}
intersect : SeqDict k v -> SeqDict k v1 -> SeqDict k v
intersect (SeqDict_elm_builtin _ _ t1Triplets) (SeqDict_elm_builtin t2Bitmap t2Nodes _) =
    let
        helper : ( Int, k, v ) -> SeqDict k v -> SeqDict k v
        helper ( hash, key, value ) ((SeqDict_elm_builtin bitmap nodes triplets) as dict) =
            case getHelp 0 hash key t2Bitmap t2Nodes of
                Nothing ->
                    dict

                Just _ ->
                    insertHelp 0 hash key value bitmap nodes triplets
    in
    intDictFoldl helper empty t1Triplets


orderedEquals : SeqDict k v -> SeqDict k v -> Bool
orderedEquals dict1 dict2 =
    if size dict1 == size dict2 then
        toList dict1 == toList dict2

    else
        False


{-| Check if two dictionaries are equal regardless what order items were inserted.
Note that this is not the same as writing `dict1 == dict2`. Insertion order matters when using `==`.

    dict1 = SeqDict.fromList [ ( "A", 1 ), ( "B", 2 ) ]
    dict2 = SeqDict.fromList [ ( "B", 2 ), ( "A", 1 ) ]

    SeqDict.unorderedEquals dict1 dict2 -- True
    dict1 == dict2 -- False

-}
unorderedEquals : SeqDict k v -> SeqDict k v -> Bool
unorderedEquals dict1 ((SeqDict_elm_builtin _ _ triplets2) as dict2) =
    if size dict1 == size dict2 then
        unorderedEqualsHelper dict1 triplets2

    else
        False


unorderedEqualsHelper : SeqDict k v -> IntDict k v -> Bool
unorderedEqualsHelper (SeqDict_elm_builtin bitmap nodes _) dict =
    let
        func : ( Int, k, v ) -> Bool
        func ( hash, key, value ) =
            case getHelp 0 hash key bitmap nodes of
                Just value2 ->
                    value == value2

                Nothing ->
                    False

        helper : Maybe ( Int, k, v ) -> Bool
        helper node =
            case node of
                Just a ->
                    func a

                Nothing ->
                    True
    in
    array2All helper dict.array


array2All : (a -> Bool) -> Array a -> Bool
array2All func array =
    array2AllHelper (Array.length array - 1) func array


array2AllHelper : Int -> (a -> Bool) -> Array a -> Bool
array2AllHelper index func array =
    case Array.get index array of
        Just item ->
            if func item then
                array2AllHelper (index - 1) func array

            else
                False

        Nothing ->
            True


{-| Keep a key-value pair when its key does not appear in the second Dictionary.
-}
diff : SeqDict k v -> SeqDict k v1 -> SeqDict k v
diff t1 (SeqDict_elm_builtin _ _ t2Triplets) =
    let
        helper : ( Int, k, v1 ) -> SeqDict k v -> SeqDict k v
        helper ( hash, key, _ ) dict =
            let
                (SeqDict_elm_builtin bitmap2 nodes2 triplets2) =
                    rebuildOnOverflow dict
            in
            removeHelp 0 hash key bitmap2 nodes2 triplets2
    in
    intDictFoldl helper t1 t2Triplets


{-| The most general way of combining two dictionaries. You provide three
accumulators for when a given key appears:

1.  Only in the left dictionary.
2.  In both dictionaries.
3.  Only in the right dictionary.

You then traverse all the keys by insertion order, starting with the left
dictionary and then the right dictionary (keys that appear in both are
skipped for the right dictionary)

-}
merge :
    (k -> a -> result -> result)
    -> (k -> a -> b -> result -> result)
    -> (k -> b -> result -> result)
    -> SeqDict k a
    -> SeqDict k b
    -> result
    -> result
merge leftStep bothStep rightStep (SeqDict_elm_builtin _ _ leftIntDict) rightDict initialResult =
    let
        helper : ( Int, k, a ) -> ( result, SeqDict k b ) -> ( result, SeqDict k b )
        helper ( hash, key, value ) ( acc, (SeqDict_elm_builtin rightBitmap rightNodeArray rightIntDict) as rightDict2 ) =
            case getHelp 0 hash key rightBitmap rightNodeArray of
                Just value2 ->
                    ( bothStep key value value2 acc, removeHelp 0 hash key rightBitmap rightNodeArray rightIntDict )

                Nothing ->
                    ( leftStep key value acc, rightDict2 )

        helper2 : ( Int, k, b ) -> result -> result
        helper2 ( _, key, value ) acc =
            rightStep key value acc

        ( acc2, SeqDict_elm_builtin _ _ rightIntDict2 ) =
            intDictFoldl helper ( initialResult, rightDict ) leftIntDict
    in
    intDictFoldl helper2 acc2 rightIntDict2


{-| INT DICT

This is an internal structure which is only used for remembering the insertion
order of key-value pairs. We store the hash, key and value here as well, so
fold operations become as fast as possible.

-}
type alias IntDict k v =
    { size : Int
    , array : Array (Maybe ( Int, k, v ))
    }


intDictEmpty : IntDict k v
intDictEmpty =
    { size = 0
    , array = Array.empty
    }


intDictPush : Int -> k -> v -> IntDict k v -> IntDict k v
intDictPush hash key value dict =
    { size = dict.size + 1
    , array = Array.push (Just ( hash, key, value )) dict.array
    }


{-| Will only ever be called when we know the index, so we don't need
to do bounds checking.
-}
intDictSet : Int -> Int -> k -> v -> IntDict k v -> IntDict k v
intDictSet index hash key value dict =
    { size = dict.size
    , array = Array.set index (Just ( hash, key, value )) dict.array
    }


intDictRemove : Int -> IntDict k v -> IntDict k v
intDictRemove index dict =
    { size = dict.size - 1
    , array = Array.set index Nothing dict.array
    }


intDictFoldl : (( Int, k, v ) -> acc -> acc) -> acc -> IntDict k v -> acc
intDictFoldl func baseCase dict =
    Array.foldl
        (\maybe acc ->
            case maybe of
                Just a ->
                    func a acc

                Nothing ->
                    acc
        )
        baseCase
        dict.array


intDictFoldr : (( Int, k, v ) -> acc -> acc) -> acc -> IntDict k v -> acc
intDictFoldr func baseCase dict =
    Array.foldr
        (\maybe acc ->
            case maybe of
                Just a ->
                    func a acc

                Nothing ->
                    acc
        )
        baseCase
        dict.array


listFind : (a -> Bool) -> List a -> Maybe a
listFind predicate list =
    case list of
        [] ->
            Nothing

        first :: rest ->
            if predicate first then
                Just first

            else
                listFind predicate rest

