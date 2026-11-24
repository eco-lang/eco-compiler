module SeqDict exposing
    ( SeqDict
    , empty, singleton, insert, update, updateIfExists, remove
    , get, isEmpty, member, size, unorderedEquals
    , union, intersect, diff, merge
    , toList, fromList, keys, values
    , foldl, foldr, map, filter, filterMap, partition
    )

{-| A dictionary mapping unique keys to values where insertion order is preserved for functions like foldl and toList.

`Debug.toString` of a `SeqDict` shows its internal structure, which is not specified and may change;
print `toList` instead.


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
import Bitmap
import Bitwise
import FNV
import JsArray2 exposing (JsArray2)
import SeqDictTrie


{-| A dictionary of keys and values. So a `(Dict String User)` is a dictionary
that lets you look up a `String` (such as user names) and find the associated
`User`.

This implementation differs from the one in core in that keys don't have to
be comparable, and that operations like foldl and foldr iterates the key-value
pairs in insertion order instead of sorted order.

-}
type
    SeqDict k v
    -- The root of the hash trie, always a `Branch`, and the entries in insertion order. Every entry
    -- object is shared by the two: the trie finds a key, the order array iterates.
    -- plans/seq-data-structures-performance.md §4 describes the layout and its invariants, and
    -- runtime/src/allocator/SeqDictLayout.hpp and src/Eco/Kernel/FNV.js read the order array.
    = SeqDict_elm_builtin (Node k v) (IntDict k v)


{-| One key-value pair: the key's hash, the pair's index in the order array, the key and the value.
-}
type Entry k v
    = Entry Int Int k v


{-| A node of the hash trie.

A `Branch` holds a 32-bit bitmap of the 5-bit hash chunks present at its level and their slots, in
bit order (`Bitmap.index` finds a slot). A `Collision` holds two or more entries whose 32-bit hashes
are equal, in ascending index order.

The trie is canonical: a branch other than the root never holds no slot, a single `Data` or a
single `Sub (Collision …)` (removal hoists those into the parent), and a collision sits at the
shallowest level where its bucket holds only its own hash. So the shape depends only on the keys
and their indices, not on the operations that built it.

-}
type Node k v
    = Branch Int (JsArray2 (Slot k v))
    | Collision Int (List (Entry k v))


{-| A slot of a `Branch`: an entry, or a node one level down.
-}
type Slot k v
    = Data (Entry k v)
    | Sub (Node k v)


{-| How many hash bits each level of the trie consumes.
-}
shiftStep : Int
shiftStep =
    5


{-| The mask of one level's bits: 31.
-}
bitMask : Int
bitMask =
    31


{-| The 5-bit chunk of `hash` at `shift`.
-}
chunkAt : Int -> Int -> Int
chunkAt shift hash =
    Bitwise.and bitMask (Bitwise.shiftRightZfBy shift hash)


entryHash : Entry k v -> Int
entryHash (Entry hash _ _ _) =
    hash


{-| The empty dictionary.
-}
empty : SeqDict k v
empty =
    SeqDict_elm_builtin emptyRoot intDictEmpty


emptyRoot : Node k v
emptyRoot =
    Branch 0 JsArray2.empty


{-| Create a dictionary with one key-value pair.
-}
singleton : k -> v -> SeqDict k v
singleton key val =
    insert key val empty


{-| Determine if a dictionary is empty.

    isEmpty empty == True

-}
isEmpty : SeqDict k v -> Bool
isEmpty (SeqDict_elm_builtin _ order) =
    order.size == 0


{-| Determine the number of key-value pairs in the dictionary.
-}
size : SeqDict k v -> Int
size (SeqDict_elm_builtin _ order) =
    order.size


{-| Get the value associated with a key. If the key is not found, return
`Nothing`. This is useful when you are not sure if a key will be in the
dictionary.

    animals = fromList [ ("Tom", Cat), ("Jerry", Mouse) ]

    get "Tom"   animals == Just Cat
    get "Jerry" animals == Just Mouse
    get "Spike" animals == Nothing

-}
get : k -> SeqDict k v -> Maybe v
get key (SeqDict_elm_builtin root _) =
    case getEntry (FNV.hash key) key root of
        Just (Entry _ _ _ value) ->
            Just value

        Nothing ->
            Nothing


{-| The entry of `key`, whose hash is `hash`, under the root `root`.
-}
getEntry : Int -> k -> Node k v -> Maybe (Entry k v)
getEntry hash key root =
    case root of
        Branch bitmap slots ->
            getHelp 0 hash key bitmap slots

        Collision h entries ->
            if h == hash then
                collisionFind key entries

            else
                Nothing


getHelp : Int -> Int -> k -> Int -> JsArray2 (Slot k v) -> Maybe (Entry k v)
getHelp shift hash key bitmap slots =
    let
        chunk =
            chunkAt shift hash
    in
    if Bitwise.and bitmap (Bitwise.shiftLeftBy chunk 1) == 0 then
        Nothing

    else
        case JsArray2.unsafeGet (Bitmap.index bitmap chunk) slots of
            Data ((Entry h _ k _) as entry) ->
                -- The stored hash first: almost every mismatch costs one integer comparison.
                if h == hash && k == key then
                    Just entry

                else
                    Nothing

            Sub (Branch subBitmap subSlots) ->
                getHelp (shift + shiftStep) hash key subBitmap subSlots

            Sub (Collision h entries) ->
                if h == hash then
                    collisionFind key entries

                else
                    Nothing


collisionFind : k -> List (Entry k v) -> Maybe (Entry k v)
collisionFind key entries =
    case entries of
        [] ->
            Nothing

        ((Entry _ _ k _) as entry) :: rest ->
            if k == key then
                Just entry

            else
                collisionFind key rest


{-| Determine if a key is in a dictionary.
-}
member : k -> SeqDict k v -> Bool
member key (SeqDict_elm_builtin root _) =
    case getEntry (FNV.hash key) key root of
        Just _ ->
            True

        Nothing ->
            False


{-| Insert a key-value pair into the dictionary. Replaces value when there is
a collision.
-}
insert : k -> v -> SeqDict k v -> SeqDict k v
insert key value (SeqDict_elm_builtin root order) =
    insertWithHash (FNV.hash key) key value root order


{-| Inserts `key`, whose hash is `hash`. A present key keeps its index and gets the new key object
and value; a new key is pushed onto the order array.
-}
insertWithHash : Int -> k -> v -> Node k v -> IntDict k v -> SeqDict k v
insertWithHash hash key value root order =
    case root of
        Branch bitmap slots ->
            let
                ( newBitmap, newSlots, newOrder ) =
                    insertHelp 0 hash key value bitmap slots order
            in
            SeqDict_elm_builtin (Branch newBitmap newSlots) newOrder

        Collision _ _ ->
            -- The root is always a Branch.
            SeqDict_elm_builtin root order


insertHelp : Int -> Int -> k -> v -> Int -> JsArray2 (Slot k v) -> IntDict k v -> ( Int, JsArray2 (Slot k v), IntDict k v )
insertHelp shift hash key value bitmap slots order =
    let
        chunk =
            chunkAt shift hash

        bit =
            Bitwise.shiftLeftBy chunk 1

        pos =
            Bitmap.index bitmap chunk
    in
    if Bitwise.and bitmap bit == 0 then
        let
            entry =
                Entry hash (Array.length order.array) key value
        in
        ( Bitwise.or bitmap bit, JsArray2.unsafeInsert pos (Data entry) slots, intDictPush entry order )

    else
        case JsArray2.unsafeGet pos slots of
            Data ((Entry h i k _) as existing) ->
                if h == hash then
                    if k == key then
                        let
                            entry =
                                Entry hash i key value
                        in
                        ( bitmap, JsArray2.unsafeSet pos (Data entry) slots, intDictSet entry order )

                    else
                        let
                            entry =
                                Entry hash (Array.length order.array) key value
                        in
                        ( bitmap, JsArray2.unsafeSet pos (Sub (Collision hash [ existing, entry ])) slots, intDictPush entry order )

                else
                    let
                        entry =
                            Entry hash (Array.length order.array) key value
                    in
                    ( bitmap, JsArray2.unsafeSet pos (Sub (pairNode (shift + shiftStep) existing entry)) slots, intDictPush entry order )

            Sub (Branch subBitmap subSlots) ->
                let
                    ( newSubBitmap, newSubSlots, newOrder ) =
                        insertHelp (shift + shiftStep) hash key value subBitmap subSlots order
                in
                ( bitmap, JsArray2.unsafeSet pos (Sub (Branch newSubBitmap newSubSlots)) slots, newOrder )

            Sub (Collision h entries) ->
                if h == hash then
                    let
                        ( newEntries, newOrder ) =
                            collisionInsert hash key value entries order
                    in
                    ( bitmap, JsArray2.unsafeSet pos (Sub (Collision h newEntries)) slots, newOrder )

                else
                    let
                        entry =
                            Entry hash (Array.length order.array) key value
                    in
                    ( bitmap, JsArray2.unsafeSet pos (Sub (collisionAndEntry (shift + shiftStep) h entries entry)) slots, intDictPush entry order )


{-| Replaces `key`'s entry in a collision list, keeping its index and place, or appends a new entry
(it has the highest index, so the list stays in index order).
-}
collisionInsert : Int -> k -> v -> List (Entry k v) -> IntDict k v -> ( List (Entry k v), IntDict k v )
collisionInsert hash key value entries order =
    case collisionFind key entries of
        Just (Entry _ i _ _) ->
            let
                entry =
                    Entry hash i key value
            in
            ( List.map
                (\((Entry _ j _ _) as other) ->
                    if j == i then
                        entry

                    else
                        other
                )
                entries
            , intDictSet entry order
            )

        Nothing ->
            let
                entry =
                    Entry hash (Array.length order.array) key value
            in
            ( entries ++ [ entry ], intDictPush entry order )


{-| A branch at `shift` holding two entries with different hashes, nested while their chunks agree.
-}
pairNode : Int -> Entry k v -> Entry k v -> Node k v
pairNode shift a b =
    let
        ca =
            chunkAt shift (entryHash a)

        cb =
            chunkAt shift (entryHash b)
    in
    if ca == cb then
        Branch (Bitwise.shiftLeftBy ca 1) (JsArray2.singleton (Sub (pairNode (shift + shiftStep) a b)))

    else
        twoSlots ca (Data a) cb (Data b)


{-| A branch at `shift` holding the collision of hash `h` and an entry with another hash, nested while
their chunks agree.
-}
collisionAndEntry : Int -> Int -> List (Entry k v) -> Entry k v -> Node k v
collisionAndEntry shift h entries entry =
    let
        cc =
            chunkAt shift h

        ce =
            chunkAt shift (entryHash entry)
    in
    if cc == ce then
        Branch (Bitwise.shiftLeftBy cc 1) (JsArray2.singleton (Sub (collisionAndEntry (shift + shiftStep) h entries entry)))

    else
        twoSlots cc (Sub (Collision h entries)) ce (Data entry)


twoSlots : Int -> Slot k v -> Int -> Slot k v -> Node k v
twoSlots ca a cb b =
    let
        bitmap =
            Bitwise.or (Bitwise.shiftLeftBy ca 1) (Bitwise.shiftLeftBy cb 1)
    in
    if ca < cb then
        Branch bitmap (JsArray2.push b (JsArray2.singleton a))

    else
        Branch bitmap (JsArray2.push a (JsArray2.singleton b))


{-| Compacts the order array when, before a removal, fewer than half of its slots are live:
renumbers the live entries and rebuilds the trie structurally (`rebuildWith`).
-}
rebuildOnOverflow : SeqDict k v -> SeqDict k v
rebuildOnOverflow ((SeqDict_elm_builtin root order) as dict) =
    if (toFloat order.size / toFloat (Array.length order.array)) < 0.5 then
        rebuildWith (\(Entry _ _ _ value) -> Just value) root order

    else
        dict


insertEntry : Int -> k -> v -> SeqDict k v -> SeqDict k v
insertEntry hash key value (SeqDict_elm_builtin root order) =
    insertWithHash hash key value root order


{-| Remove a key-value pair from a dictionary. If the key is not found,
no changes are made.
-}
remove : k -> SeqDict k v -> SeqDict k v
remove key dict =
    removeWithHash (FNV.hash key) key (rebuildOnOverflow dict)


{-| Removes `key`, whose hash is `hash`; an absent key leaves the dict as it is, with nothing copied.
-}
removeWithHash : Int -> k -> SeqDict k v -> SeqDict k v
removeWithHash hash key ((SeqDict_elm_builtin root order) as dict) =
    case root of
        Branch bitmap slots ->
            case removeHelp 0 hash key bitmap slots of
                Just ( index, newBitmap, newSlots ) ->
                    SeqDict_elm_builtin (Branch newBitmap newSlots) (intDictRemove index order)

                Nothing ->
                    dict

        Collision _ _ ->
            dict


{-| Returns the removed entry's index and the branch's new bitmap and slots, or `Nothing` when the
key is absent. Every branch below the root is put back in canonical form (`normalize`).
-}
removeHelp : Int -> Int -> k -> Int -> JsArray2 (Slot k v) -> Maybe ( Int, Int, JsArray2 (Slot k v) )
removeHelp shift hash key bitmap slots =
    let
        chunk =
            chunkAt shift hash

        bit =
            Bitwise.shiftLeftBy chunk 1

        pos =
            Bitmap.index bitmap chunk
    in
    if Bitwise.and bitmap bit == 0 then
        Nothing

    else
        case JsArray2.unsafeGet pos slots of
            Data (Entry h i k _) ->
                if h == hash && k == key then
                    Just ( i, Bitwise.xor bitmap bit, JsArray2.removeIndex pos slots )

                else
                    Nothing

            Sub (Branch subBitmap subSlots) ->
                case removeHelp (shift + shiftStep) hash key subBitmap subSlots of
                    Just ( i, newSubBitmap, newSubSlots ) ->
                        Just ( i, bitmap, JsArray2.unsafeSet pos (normalize newSubBitmap newSubSlots) slots )

                    Nothing ->
                        Nothing

            Sub (Collision h entries) ->
                if h == hash then
                    case collisionFind key entries of
                        Just (Entry _ i _ _) ->
                            let
                                rest =
                                    List.filter (\(Entry _ j _ _) -> j /= i) entries
                            in
                            Just ( i, bitmap, JsArray2.unsafeSet pos (collisionSlot h rest) slots )

                        Nothing ->
                            Nothing

                else
                    Nothing


{-| The slot for a branch below the root after a removal: a branch left with a single `Data` or a
single `Sub (Collision …)` is replaced by that slot.
-}
normalize : Int -> JsArray2 (Slot k v) -> Slot k v
normalize bitmap slots =
    if JsArray2.length slots == 1 then
        case JsArray2.unsafeGet 0 slots of
            Sub (Branch _ _) ->
                Sub (Branch bitmap slots)

            single ->
                single

    else
        Sub (Branch bitmap slots)


{-| The slot for a collision after a removal: one entry left becomes `Data`.
-}
collisionSlot : Int -> List (Entry k v) -> Slot k v
collisionSlot h entries =
    case entries of
        [ entry ] ->
            Data entry

        _ ->
            Sub (Collision h entries)


{-| Update the value of a dictionary for a specific key with a given function.
The given function gets the current value as a parameter and its return value
determines if the value is updated or removed. New key-value pairs can be
inserted too.
-}
update : k -> (Maybe v -> Maybe v) -> SeqDict k v -> SeqDict k v
update key fn ((SeqDict_elm_builtin root order) as dict) =
    let
        hash =
            FNV.hash key

        current =
            case getEntry hash key root of
                Just (Entry _ _ _ value) ->
                    Just value

                Nothing ->
                    Nothing
    in
    case fn current of
        Nothing ->
            removeWithHash hash key (rebuildOnOverflow dict)

        Just value ->
            insertWithHash hash key value root order


{-| Update the value of a dictionary _only_ if the specified key is present in the dictionary.
-}
updateIfExists : k -> (v -> v) -> SeqDict k v -> SeqDict k v
updateIfExists key fn ((SeqDict_elm_builtin root order) as dict) =
    let
        hash =
            FNV.hash key
    in
    case getEntry hash key root of
        Just (Entry _ _ _ value) ->
            insertWithHash hash key (fn value) root order

        Nothing ->
            dict



-- STRUCTURAL REBUILD


{-| The dictionary of the entries `pick` keeps, renumbered 0, 1, 2… in insertion order: `pick` is
called once per entry, in insertion order, and `Just value` keeps the entry with that value. The
trie is rebuilt structurally (`remapNode`): one pass over the old trie, each node copied once,
dropped entries left out and the canonical form restored, with no hashing and no path copying.
Compaction, `filter`, `filterMap`, `partition`, `intersect` and bulk `diff` use it.
-}
rebuildWith : (Entry k a -> Maybe b) -> Node k a -> IntDict k a -> SeqDict k b
rebuildWith pick root order =
    let
        ( count, remapRev, keptRev ) =
            Array.foldl
                (\slot ( next, remapAcc, keptAcc ) ->
                    case slot of
                        Just ((Entry hash _ key _) as entry) ->
                            case pick entry of
                                Just value ->
                                    let
                                        kept =
                                            Just (Entry hash next key value)
                                    in
                                    ( next + 1, kept :: remapAcc, kept :: keptAcc )

                                Nothing ->
                                    ( next, Nothing :: remapAcc, keptAcc )

                        Nothing ->
                            ( next, Nothing :: remapAcc, keptAcc )
                )
                ( 0, [], [] )
                order.array
    in
    SeqDict_elm_builtin
        (remapRoot (flatArray (Array.length order.array) (List.reverse remapRev)) root)
        { size = count, array = Array.fromList (List.reverse keptRev) }


{-| The root with every entry replaced by `remap` (a flat array) at its old index (`Nothing` drops it). The root
stays a `Branch`, whatever it holds.
-}
remapRoot : JsArray2 (Maybe (Entry k b)) -> Node k a -> Node k b
remapRoot remap root =
    case root of
        Branch bitmap slots ->
            let
                ( newBitmap, newSlots ) =
                    remapSlots remap bitmap slots 0 0 0 []
            in
            Branch newBitmap (slotArray newSlots)

        Collision _ _ ->
            emptyRoot


slotArray : List (Slot k v) -> JsArray2 (Slot k v)
slotArray slots =
    Tuple.first (JsArray2.initializeFromList 32 slots)


{-| Walks the chunks 0-31 of a branch, `j` being the index of the next slot, and collects the
remapped slots that remain, with their bitmap.
-}
remapSlots : JsArray2 (Maybe (Entry k b)) -> Int -> JsArray2 (Slot k a) -> Int -> Int -> Int -> List (Slot k b) -> ( Int, List (Slot k b) )
remapSlots remap bitmap slots chunk j newBitmap acc =
    if chunk > 31 then
        ( newBitmap, List.reverse acc )

    else
        let
            bit =
                Bitwise.shiftLeftBy chunk 1
        in
        if Bitwise.and bitmap bit == 0 then
            remapSlots remap bitmap slots (chunk + 1) j newBitmap acc

        else
            case remapSlot remap (JsArray2.unsafeGet j slots) of
                Sub (Branch 0 _) ->
                    -- nothing remains of the slot (`gone`)
                    remapSlots remap bitmap slots (chunk + 1) (j + 1) newBitmap acc

                slot ->
                    remapSlots remap bitmap slots (chunk + 1) (j + 1) (Bitwise.or newBitmap bit) (slot :: acc)


{-| A slot below the root after remapping, in canonical form, or `gone` when nothing in it remains:
a branch left with one `Data` or one collision is replaced by it, a collision left with one entry
becomes `Data`. (It returns a `Slot`, not a `Maybe Slot`: a nullable `Maybe (Slot k v)` would make
`Slot` a nullable payload, which the tagged-union pass excludes, MONO_035.)
-}
remapSlot : JsArray2 (Maybe (Entry k b)) -> Slot k a -> Slot k b
remapSlot remap slot =
    case slot of
        Data entry ->
            case remapEntry remap entry of
                Just kept ->
                    Data kept

                Nothing ->
                    gone

        Sub (Branch bitmap slots) ->
            case remapSlots remap bitmap slots 0 0 0 [] of
                ( _, [] ) ->
                    gone

                ( _, [ (Data _) as single ] ) ->
                    single

                ( _, [ (Sub (Collision _ _)) as single ] ) ->
                    single

                ( newBitmap, newSlots ) ->
                    Sub (Branch newBitmap (slotArray newSlots))

        Sub (Collision h entries) ->
            case List.filterMap (remapEntry remap) entries of
                [] ->
                    gone

                [ entry ] ->
                    Data entry

                kept ->
                    Sub (Collision h kept)


{-| The slot `remapSlot` gives when nothing remains: an empty branch, which never otherwise appears
below the root.
-}
gone : Slot k v
gone =
    Sub emptyRoot


remapEntry : JsArray2 (Maybe (Entry k b)) -> Entry k a -> Maybe (Entry k b)
remapEntry remap (Entry _ index _ _) =
    JsArray2.unsafeGet index remap


{-| A flat array of `list`, which has `length` elements: indexed in one step, unlike an `Array`.
-}
flatArray : Int -> List a -> JsArray2 a
flatArray length list =
    Tuple.first (JsArray2.initializeFromList length list)

-- LISTS


{-| Convert an association list into a dictionary.
-}
fromList : List ( k, v ) -> SeqDict k v
fromList list =
    List.foldl (\( key, value ) acc -> insert key value acc) empty list


{-| Convert a dictionary into an association list of key-value pairs.
-}
toList : SeqDict k v -> List ( k, v )
toList (SeqDict_elm_builtin _ order) =
    intDictFoldr (\(Entry _ _ key value) acc -> ( key, value ) :: acc) [] order


{-| Get all of the keys in a dictionary.

       keys (fromList [(0,"Alice"),(1,"Bob")]) == [0,1]

-}
keys : SeqDict k v -> List k
keys (SeqDict_elm_builtin _ order) =
    intDictFoldr (\(Entry _ _ key _) acc -> key :: acc) [] order


{-| Get all of the values in a dictionary as a List.

       values (fromList [(0,"Alice"),(1,"Bob")]) == ["Alice", "Bob"]

-}
values : SeqDict k v -> List v
values (SeqDict_elm_builtin _ order) =
    intDictFoldr (\(Entry _ _ _ value) acc -> value :: acc) [] order



-- TRANSFORM


{-| Fold over the key-value pairs in a dictionary in the order the key was
first inserted.
-}
foldl : (k -> v -> b -> b) -> b -> SeqDict k v -> b
foldl fn acc (SeqDict_elm_builtin _ order) =
    intDictFoldl (\(Entry _ _ key value) acc2 -> fn key value acc2) acc order


{-| Fold over the key-value pairs in a dictionary in the reverse order the key
was first inserted.
-}
foldr : (k -> v -> b -> b) -> b -> SeqDict k v -> b
foldr fn acc (SeqDict_elm_builtin _ order) =
    intDictFoldr (\(Entry _ _ key value) acc2 -> fn key value acc2) acc order


{-| Apply a function to all values in a dictionary. The function is called once per entry, in
insertion order.
-}
map : (k -> a -> b) -> SeqDict k a -> SeqDict k b
map fn (SeqDict_elm_builtin root order) =
    let
        newArray =
            Array.map (Maybe.map (\(Entry hash i key value) -> Entry hash i key (fn key value))) order.array
    in
    SeqDict_elm_builtin (remapTrie (flatArray (Array.length newArray) (Array.toList newArray)) gone root) { size = order.size, array = newArray }


{-| Copies the trie's shape, replacing every entry by the entry at its index in `newArray`, in the
kernel (`SeqDictTrie.remap`: no closure call per slot). `gone` tells the native kernel how the result's
slots are represented, as `probe`.
-}
remapTrie : JsArray2 (Maybe (Entry k b)) -> Slot k b -> Node k a -> Node k b
remapTrie newArray probe root =
    SeqDictTrie.remap newArray probe root


{-| Keep a key-value pair when it satisfies a predicate.
-}
filter : (k -> v -> Bool) -> SeqDict k v -> SeqDict k v
filter predicate (SeqDict_elm_builtin root order) =
    rebuildWith
        (\(Entry _ _ key value) ->
            if predicate key value then
                Just value

            else
                Nothing
        )
        root
        order


{-| Filter out certain key-value pairs while also mapping over the values.
-}
filterMap : (k -> v -> Maybe v2) -> SeqDict k v -> SeqDict k v2
filterMap mapFunc (SeqDict_elm_builtin root order) =
    rebuildWith (\(Entry _ _ key value) -> mapFunc key value) root order


{-| Partition a dictionary according to a predicate. The first dictionary
contains all key-value pairs which satisfy the predicate, and the second
contains the rest.
-}
partition : (k -> v -> Bool) -> SeqDict k v -> ( SeqDict k v, SeqDict k v )
partition predicate (SeqDict_elm_builtin root order) =
    let
        -- the predicate, once per entry in insertion order
        flags =
            Array.map (Maybe.map (\(Entry _ _ key value) -> predicate key value)) order.array

        side want (Entry _ index _ value) =
            if Array.get index flags == Just (Just want) then
                Just value

            else
                Nothing
    in
    ( rebuildWith (side True) root order, rebuildWith (side False) root order )


-- COMBINE


{-| Combine two dictionaries. If there is a collision, preference is given
to the first dictionary.
-}
union : SeqDict k v -> SeqDict k v -> SeqDict k v
union (SeqDict_elm_builtin _ t1Order) t2 =
    intDictFoldl (\(Entry hash _ key value) acc -> insertEntry hash key value acc) t2 t1Order


{-| Below this size ratio `diff` removes one key at a time; above it, it rebuilds the result
structurally.
-}
bulkRatio : Int
bulkRatio =
    8


{-| Keep a key-value pair when its key appears in the second Dictionary.
Preference is given to values in the first Dictionary.
-}
intersect : SeqDict k v -> SeqDict k v1 -> SeqDict k v
intersect (SeqDict_elm_builtin t1Root t1Order) (SeqDict_elm_builtin t2Root _) =
    rebuildWith
        (\(Entry hash _ key value) ->
            case getEntry hash key t2Root of
                Just _ ->
                    Just value

                Nothing ->
                    Nothing
        )
        t1Root
        t1Order


{-| Check if two dictionaries are equal regardless what order items were inserted.
Note that this is not the same as writing `dict1 == dict2`. Insertion order matters when using `==`.

    dict1 = SeqDict.fromList [ ( "A", 1 ), ( "B", 2 ) ]
    dict2 = SeqDict.fromList [ ( "B", 2 ), ( "A", 1 ) ]

    SeqDict.unorderedEquals dict1 dict2 -- True
    dict1 == dict2 -- False

-}
unorderedEquals : SeqDict k v -> SeqDict k v -> Bool
unorderedEquals ((SeqDict_elm_builtin root1 _) as dict1) ((SeqDict_elm_builtin _ order2) as dict2) =
    if size dict1 == size dict2 then
        arrayAll
            (\slot ->
                case slot of
                    Just (Entry hash _ key value) ->
                        case getEntry hash key root1 of
                            Just (Entry _ _ _ value1) ->
                                value1 == value

                            Nothing ->
                                False

                    Nothing ->
                        True
            )
            order2.array

    else
        False


arrayAll : (a -> Bool) -> Array a -> Bool
arrayAll func array =
    arrayAllHelp (Array.length array - 1) func array


arrayAllHelp : Int -> (a -> Bool) -> Array a -> Bool
arrayAllHelp index func array =
    case Array.get index array of
        Just item ->
            if func item then
                arrayAllHelp (index - 1) func array

            else
                False

        Nothing ->
            True


{-| Keep a key-value pair when its key does not appear in the second Dictionary.
-}
diff : SeqDict k v -> SeqDict k v1 -> SeqDict k v
diff ((SeqDict_elm_builtin t1Root t1Order) as t1) (SeqDict_elm_builtin t2Root t2Order) =
    if t2Order.size * bulkRatio <= t1Order.size then
        intDictFoldl (\(Entry hash _ key _) acc -> removeWithHash hash key (rebuildOnOverflow acc)) t1 t2Order

    else
        rebuildWith
            (\(Entry hash _ key value) ->
                case getEntry hash key t2Root of
                    Just _ ->
                        Nothing

                    Nothing ->
                        Just value
            )
            t1Root
            t1Order


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
merge leftStep bothStep rightStep (SeqDict_elm_builtin _ leftOrder) rightDict initialResult =
    let
        ( acc2, SeqDict_elm_builtin _ rightOrder ) =
            intDictFoldl
                (\(Entry hash _ key value) ( acc, (SeqDict_elm_builtin rightRoot _) as right ) ->
                    case getEntry hash key rightRoot of
                        Just (Entry _ _ _ value2) ->
                            ( bothStep key value value2 acc, removeWithHash hash key right )

                        Nothing ->
                            ( leftStep key value acc, right )
                )
                ( initialResult, rightDict )
                leftOrder
    in
    intDictFoldl (\(Entry _ _ key value) acc -> rightStep key value acc) acc2 rightOrder


{-| INT DICT

The entries in insertion order: an entry's index is its place in `array`, and a removed entry leaves
`Nothing`. `size` counts the entries that are present.

-}
type alias IntDict k v =
    { size : Int
    , array : Array (Maybe (Entry k v))
    }


intDictEmpty : IntDict k v
intDictEmpty =
    { size = 0
    , array = Array.empty
    }


intDictPush : Entry k v -> IntDict k v -> IntDict k v
intDictPush entry dict =
    { size = dict.size + 1
    , array = Array.push (Just entry) dict.array
    }


{-| Replaces the entry at the new entry's own index.
-}
intDictSet : Entry k v -> IntDict k v -> IntDict k v
intDictSet ((Entry _ index _ _) as entry) dict =
    { size = dict.size
    , array = Array.set index (Just entry) dict.array
    }


intDictRemove : Int -> IntDict k v -> IntDict k v
intDictRemove index dict =
    { size = dict.size - 1
    , array = Array.set index Nothing dict.array
    }


intDictFoldl : (Entry k v -> acc -> acc) -> acc -> IntDict k v -> acc
intDictFoldl func baseCase dict =
    Array.foldl
        (\maybe acc ->
            case maybe of
                Just entry ->
                    func entry acc

                Nothing ->
                    acc
        )
        baseCase
        dict.array


intDictFoldr : (Entry k v -> acc -> acc) -> acc -> IntDict k v -> acc
intDictFoldr func baseCase dict =
    Array.foldr
        (\maybe acc ->
            case maybe of
                Just entry ->
                    func entry acc

                Nothing ->
                    acc
        )
        baseCase
        dict.array
