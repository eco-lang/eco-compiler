module Compiler.AST.TypeTable exposing
    ( Builder, empty, add, size, collectStrings
    , TypeTable, freeze, ref, refMaybe, encoder
    , Decoded, decoder, refDecoder, decodedTypes
    )

{-| A typed artifact repeats the same types many times over, and this
module lets its encoding store each distinct type once and refer to it by
number.

Each expression of a typed artifact carries a whole `Can.Type Name`, so the
same types occur again and again in an encoding of it.
A _type table_ is the list of the distinct types of one encoding, each
identified by its position, its _id_. An encoding that uses one writes the
table ahead of its body, and the body writes each type as its id, which is
called a _reference_.

Two types share an entry exactly when they are equal under Elm's `==`, which
compares the data a type carries. The arrow slot of a `TLambda`, a record
field's index, a record's extension variable, an alias's argument names and
whether an alias body is `Holey` or `Filled` all keep types apart. A record's
fields are a `Dict`, which `==` compares by its contents, so the order the
fields were inserted in does not matter.

The table is filled in a `Builder` before encoding begins, by a walk over
everything the encoding will write, here called the _pre-pass_. It must intern
every type the body will reference. Interning a type that is not yet present
interns its children first and then gives the type the next id, so a row
refers only to rows with smaller ids, and ids follow the order in which the
pre-pass first finishes each type. `freeze` turns the builder into a
`TypeTable`, against which `ref` writes references. A type the pre-pass missed
makes `ref` crash rather than write an id that belongs to another type.

The rows write their strings through a `Compiler.AST.StringTable`, and
`collectStrings` gives those strings to the string collector.

On the wire the table is one byte giving the _reference width_, the number of
bytes each reference takes; an unsigned 32-bit big-endian count of rows; and
the rows in id order. The width is 1, 2 or 4 bytes, by the rule
`Compiler.AST.StringTable` uses for its index width. `decoder` reads the table
back into a `Decoded` in one forward pass, and `refDecoder` reads a reference
against it.

`hashType` chooses the bucket a type is filed under while the table is built.
It never decides whether two types are the same or which id a type gets, so
the bytes written do not depend on it.


# Building

@docs Builder, empty, add, size, collectStrings


# Encoding

@docs TypeTable, freeze, ref, refMaybe, encoder


# Decoding

@docs Decoded, decoder, refDecoder, decodedTypes


# Hashing

-}

import Array exposing (Array)
import Bytes
import Bytes.Decode as BD
import Bytes.Encode as BE
import Compiler.AST.Canonical as Can
import Compiler.AST.StringTable as StringTable exposing (StringTable)
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Data.HashMap as HashMap exposing (HashMap)
import Dict
import Eco.Hash
import Utils.Bytes.Decode as UBD
import Utils.Bytes.Encode as UBE
import Utils.Crash



-- ENTRIES


{-| One row of the table: a `Can.Type` constructor with each child type
replaced by the child's id.

`ELambda` carries the arrow slot as `Can.arrowSlotToInt` gives it, then the
ids of the argument and the result.

`ERecord` carries each field as its name, its field index and its type's id,
in field-name order, followed by the extension variable.

`ETuple` carries the ids of the first two elements, then those of the rest.

`EAlias` carries the home module and the alias name, each argument's name with
its type's id, `True` for a `Filled` body and `False` for a `Holey` one, and
the body's id.

`EVar`, `EType` and `EUnit` mirror their `Can.Type` constructors.

-}
type Entry
    = ELambda Int Int Int
    | EVar Name
    | EType ModuleName.Canonical Name (List Int)
    | ERecord (List ( Name, Int, Int )) (Maybe Name)
    | EUnit
    | ETuple Int Int (List Int)
    | EAlias ModuleName.Canonical Name (List ( Name, Int )) Bool Int



-- BUILDER


{-| A type table being filled: the distinct types interned so far, each with
its id.

A builder starts as `empty` and grows by `add` and `intern`. It holds each
`==`-distinct type once, its ids run from 0 upward without gaps, and every type
has a larger id than each of its children.

-}
type Builder
    = Builder
        { ids : HashMap (Can.Type Name) Int
        , rev : List Entry
        , count : Int
        }


{-| The builder with no types in it.
-}
empty : Builder
empty =
    Builder { ids = HashMap.empty, rev = [], count = 0 }


{-| Returns the number of distinct types interned so far.
-}
size : Builder -> Int
size (Builder r) =
    r.count


{-| Returns the builder with `t` interned, as `intern` does, without its id.
-}
add : Can.Type Name -> Builder -> Builder
add t b =
    Tuple.second (intern t b)


{-| Returns the id of `t` and the builder with `t` in it.

A type already present keeps its id and leaves the builder unchanged. It is
found by looking up the whole type, so its children are not interned again one
by one. A new type has its children interned first, in the order its row
lists them (a record's fields in field-name order), and then gets the next id.

-}
intern : Can.Type Name -> Builder -> ( Int, Builder )
intern t ((Builder r) as b) =
    let
        h : Int
        h =
            hashType t
    in
    case HashMap.getHashed h (==) t r.ids of
        Just id ->
            ( id, b )

        Nothing ->
            let
                ( entry, Builder r1 ) =
                    internChildren t b

                id : Int
                id =
                    r1.count
            in
            ( id
            , Builder
                { ids = HashMap.insertNew h t id r1.ids
                , rev = entry :: r1.rev
                , count = id + 1
                }
            )


{-| Interns each of `ts` in order, and returns their ids in the same order with
the builder after the last.
-}
internList : List (Can.Type Name) -> Builder -> ( List Int, Builder )
internList ts b =
    let
        ( rev, b1 ) =
            List.foldl
                (\t ( acc, bb ) ->
                    let
                        ( id, bb1 ) =
                            intern t bb
                    in
                    ( id :: acc, bb1 )
                )
                ( [], b )
                ts
    in
    ( List.reverse rev, b1 )


{-| Interns the child types of `t` and returns the row for `t`, which refers to
them by id, with the builder after the last child. `t` itself is not added.

The children are interned in the order the row lists them: a record's fields
in field-name order, an alias's arguments before its body.

-}
internChildren : Can.Type Name -> Builder -> ( Entry, Builder )
internChildren t b =
    case t of
        Can.TLambda slot x y ->
            let
                ( ix, b1 ) =
                    intern x b

                ( iy, b2 ) =
                    intern y b1
            in
            ( ELambda (Can.arrowSlotToInt slot) ix iy, b2 )

        Can.TVar n ->
            ( EVar n, b )

        Can.TType home name args ->
            let
                ( is, b1 ) =
                    internList args b
            in
            ( EType home name is, b1 )

        Can.TRecord fields ext ->
            let
                ( rev, b1 ) =
                    Dict.foldl
                        (\k (Can.FieldType i ft) ( acc, bb ) ->
                            let
                                ( id, bb1 ) =
                                    intern ft bb
                            in
                            ( ( k, i, id ) :: acc, bb1 )
                        )
                        ( [], b )
                        fields
            in
            ( ERecord (List.reverse rev) ext, b1 )

        Can.TUnit ->
            ( EUnit, b )

        Can.TTuple x y cs ->
            let
                ( ix, b1 ) =
                    intern x b

                ( iy, b2 ) =
                    intern y b1

                ( ics, b3 ) =
                    internList cs b2
            in
            ( ETuple ix iy ics, b3 )

        Can.TAlias home name args at ->
            let
                ( revArgs, b1 ) =
                    List.foldl
                        (\( n, a ) ( acc, bb ) ->
                            let
                                ( id, bb1 ) =
                                    intern a bb
                            in
                            ( ( n, id ) :: acc, bb1 )
                        )
                        ( [], b )
                        args

                ( filled, body ) =
                    case at of
                        Can.Holey x ->
                            ( False, x )

                        Can.Filled x ->
                            ( True, x )

                ( ib, b2 ) =
                    intern body b1
            in
            ( EAlias home name (List.reverse revArgs) filled ib, b2 )


{-| Returns the collector after giving it the strings the rows of the builder
write: type variable names, the home modules and names of types and aliases,
record field names and extension variables, and alias argument names.

Each distinct type is visited once, however many times it was interned.

-}
collectStrings : Builder -> StringTable.Collector -> StringTable.Collector
collectStrings (Builder r) acc0 =
    List.foldl
        (\entry acc ->
            case entry of
                EVar n ->
                    StringTable.add n acc

                EType home name _ ->
                    acc
                        |> ModuleName.collectStringsFromCanonical home
                        |> StringTable.add name

                ERecord fields ext ->
                    let
                        withFields : StringTable.Collector
                        withFields =
                            List.foldl (\( k, _, _ ) a -> StringTable.add k a) acc fields
                    in
                    case ext of
                        Just e ->
                            StringTable.add e withFields

                        Nothing ->
                            withFields

                EAlias home name args _ _ ->
                    List.foldl (\( n, _ ) a -> StringTable.add n a)
                        (acc
                            |> ModuleName.collectStringsFromCanonical home
                            |> StringTable.add name
                        )
                        args

                ELambda _ _ _ ->
                    acc

                EUnit ->
                    acc

                ETuple _ _ _ ->
                    acc
        )
        acc0
        r.rev



-- FROZEN TABLE


{-| A finished type table, against which the types of a body are written as
references.

It is made by `freeze`, and holds the types of the builder it was made from,
with the same ids.

-}
type TypeTable
    = TypeTable
        { ids : HashMap (Can.Type Name) Int
        , entries : List Entry
        , count : Int
        , width : Int
        }


{-| Returns the finished table for a builder, with the same ids.

Its reference width is the smallest of 1, 2 and 4 bytes that can hold every
id: 1 byte for up to 256 types, 2 bytes for up to 65,536, and 4 bytes beyond
that, the rule `Compiler.AST.StringTable` uses for its index width.

-}
freeze : Builder -> TypeTable
freeze (Builder r) =
    TypeTable
        { ids = r.ids
        , entries = List.reverse r.rev
        , count = r.count
        , width = widthFor r.count
        }


{-| Returns the number of bytes a reference takes in a table of `count` types:
1 for up to 256, 2 for up to 65,536, and 4 beyond that.
-}
widthFor : Int -> Int
widthFor count =
    if count <= 256 then
        1

    else if count <= 65536 then
        2

    else
        4


{-| Returns the id of `t` in the table, or `Nothing` if `t` was never interned.
-}
refMaybe : TypeTable -> Can.Type Name -> Maybe Int
refMaybe (TypeTable r) t =
    HashMap.getHashed (hashType t) (==) t r.ids


{-| Encodes `t` as a reference: its id, as an unsigned big-endian number of
the table's reference width.

A type that was never interned crashes the compiler, rather than being written
as an id that belongs to another type.

-}
ref : TypeTable -> Can.Type Name -> BE.Encoder
ref ((TypeTable r) as tt) t =
    case refMaybe tt t of
        Just id ->
            refEncoder r.width id

        Nothing ->
            Utils.Crash.crash "TypeTable.ref: type not interned by the pre-pass (internTypesFrom*/encoder drift)"


{-| Encodes `id` as an unsigned big-endian number of `width` bytes. A `width`
other than 1 or 2 is taken as 4.
-}
refEncoder : Int -> Int -> BE.Encoder
refEncoder width id =
    if width == 1 then
        BE.unsignedInt8 id

    else if width == 2 then
        BE.unsignedInt16 Bytes.BE id

    else
        BE.unsignedInt32 Bytes.BE id


{-| Encodes the table: one byte giving the reference width, the number of rows
as an unsigned 32-bit big-endian number, and then the rows in id order.

The strings in the rows are written with `StringTable.string` against the
given string table. Unless that table is `disabled`, it must hold every string
`collectStrings` gave the collector: a string it does not hold is written,
without error, as index 0, which belongs to another string or to none.

-}
encoder : StringTable -> TypeTable -> BE.Encoder
encoder st (TypeTable r) =
    BE.sequence
        [ BE.unsignedInt8 r.width
        , BE.unsignedInt32 Bytes.BE r.count
        , BE.sequence (List.map (entryEncoder st r.width) r.entries)
        ]


{-| Encodes one row: a tag byte from 0 to 6, in the order of `Entry`'s
constructors as `ELambda`, `EVar`, `EType`, `ERecord`, `EUnit`, `ETuple`,
`EAlias`, then the row's data in the order the constructor holds it.

Child ids are written as references `width` bytes wide. The arrow slot and a
field index are varints, every list has a 32-bit length prefix, the extension
variable is a `Utils.Bytes.Encode.maybe`, and an alias's `Filled` flag is the
byte 1 and `Holey` the byte 0.

-}
entryEncoder : StringTable -> Int -> Entry -> BE.Encoder
entryEncoder st width entry =
    let
        refE : Int -> BE.Encoder
        refE =
            refEncoder width
    in
    case entry of
        ELambda slot a b ->
            BE.sequence [ BE.unsignedInt8 0, UBE.uintV slot, refE a, refE b ]

        EVar n ->
            BE.sequence [ BE.unsignedInt8 1, StringTable.string st n ]

        EType home name args ->
            BE.sequence
                [ BE.unsignedInt8 2
                , ModuleName.canonicalEncoderS st home
                , StringTable.string st name
                , UBE.list refE args
                ]

        ERecord fields ext ->
            BE.sequence
                [ BE.unsignedInt8 3
                , UBE.list
                    (\( k, i, id ) -> BE.sequence [ StringTable.string st k, UBE.uintV i, refE id ])
                    fields
                , UBE.maybe (StringTable.string st) ext
                ]

        EUnit ->
            BE.unsignedInt8 4

        ETuple a b cs ->
            BE.sequence [ BE.unsignedInt8 5, refE a, refE b, UBE.list refE cs ]

        EAlias home name args filled body ->
            BE.sequence
                [ BE.unsignedInt8 6
                , ModuleName.canonicalEncoderS st home
                , StringTable.string st name
                , UBE.list (\( n, id ) -> BE.sequence [ StringTable.string st n, refE id ]) args
                , BE.unsignedInt8
                    (if filled then
                        1

                     else
                        0
                    )
                , refE body
                ]



-- DECODING


{-| A type table read back from its encoding, against which `refDecoder`
reads references.

It is obtained only from `decoder`, which succeeds only when every row refers
to rows before it, so each of its types is a complete `Can.Type`.

-}
type Decoded
    = Decoded (Array (Can.Type Name)) Int


{-| Returns the types of a decoded table, each at its id.
-}
decodedTypes : Decoded -> Array (Can.Type Name)
decodedTypes (Decoded arr _) =
    arr


{-| Produces a decoder for a table written by `encoder`, reading strings with
`st`, which must be the string table the encoding was written against.

A row refers only to rows before it, so each type is rebuilt from types already
decoded, in one forward pass. The decode fails on a row with an unknown tag and
on a reference to a row not yet read, the row itself included.

-}
decoder : StringTable -> BD.Decoder Decoded
decoder st =
    BD.unsignedInt8
        |> BD.andThen
            (\width ->
                BD.unsignedInt32 Bytes.BE
                    |> BD.andThen
                        (\count ->
                            BD.loop ( count, Array.empty )
                                (\( remaining, arr ) ->
                                    if remaining <= 0 then
                                        BD.succeed (BD.Done (Decoded arr width))

                                    else
                                        entryDecoder st width arr
                                            |> BD.map (\t -> BD.Loop ( remaining - 1, Array.push t arr ))
                                )
                        )
            )


{-| Produces a decoder for an id written as an unsigned big-endian number of
`width` bytes. A `width` other than 1 or 2 is read as 4.
-}
rawRef : Int -> BD.Decoder Int
rawRef width =
    if width == 1 then
        BD.unsignedInt8

    else if width == 2 then
        BD.unsignedInt16 Bytes.BE

    else
        BD.unsignedInt32 Bytes.BE


{-| Produces a decoder that gives the type at `id` in `arr`, and fails if `arr`
has nothing at `id`.
-}
resolve : Array (Can.Type Name) -> Int -> BD.Decoder (Can.Type Name)
resolve arr id =
    case Array.get id arr of
        Just t ->
            BD.succeed t

        Nothing ->
            BD.fail


{-| Produces a decoder for one row written by `entryEncoder`, giving the
`Can.Type` it stands for, with its references resolved against `arr`, the
types of the rows read before it.

The arrow slot is read back with `Can.arrowSlotFromInt`. An alias whose flag
byte is anything other than 1 is read as `Holey`.

-}
entryDecoder : StringTable -> Int -> Array (Can.Type Name) -> BD.Decoder (Can.Type Name)
entryDecoder st width arr =
    let
        refD : BD.Decoder (Can.Type Name)
        refD =
            rawRef width |> BD.andThen (resolve arr)
    in
    BD.unsignedInt8
        |> BD.andThen
            (\tag ->
                case tag of
                    0 ->
                        BD.map3 (\slot a b -> Can.TLambda (Can.arrowSlotFromInt slot) a b) UBD.uintV refD refD

                    1 ->
                        BD.map Can.TVar (StringTable.stringDec st)

                    2 ->
                        BD.map3 Can.TType (ModuleName.canonicalDecoderS st) (StringTable.stringDec st) (UBD.list refD)

                    3 ->
                        BD.map2
                            (\fields ext ->
                                Can.TRecord (Dict.fromList (List.map (\( k, i, t ) -> ( k, Can.FieldType i t )) fields)) ext
                            )
                            (UBD.list (BD.map3 (\k i t -> ( k, i, t )) (StringTable.stringDec st) UBD.uintV refD))
                            (UBD.maybe (StringTable.stringDec st))

                    4 ->
                        BD.succeed Can.TUnit

                    5 ->
                        BD.map3 Can.TTuple refD refD (UBD.list refD)

                    6 ->
                        BD.map5
                            (\home name args filled body ->
                                Can.TAlias home
                                    name
                                    args
                                    (if filled == 1 then
                                        Can.Filled body

                                     else
                                        Can.Holey body
                                    )
                            )
                            (ModuleName.canonicalDecoderS st)
                            (StringTable.stringDec st)
                            (UBD.list (BD.map2 Tuple.pair (StringTable.stringDec st) refD))
                            BD.unsignedInt8
                            refD

                    _ ->
                        BD.fail
            )


{-| Produces a decoder for a reference written by `ref`, giving the type it
names in the decoded table. It fails on an id the table does not have.
-}
refDecoder : Decoded -> BD.Decoder (Can.Type Name)
refDecoder (Decoded arr width) =
    rawRef width |> BD.andThen (resolve arr)



-- HASHING


{-| Returns the hash that chooses the bucket `t` is filed under while a table
is built. It is `hashTypeElm`, so types equal under `==` have equal hashes.
-}
hashType : Can.Type Name -> Int
hashType =
    hashTypeElm


{-| Returns a hash of `t` from 0 to 2^26 - 1. Types equal under `==` have
equal hashes.

A record's fields are folded in in field-name order, so, as with `==`, the
order they were inserted in does not matter. Names are hashed by their
contents with `Eco.Hash.string`.

-}
hashTypeElm : Can.Type Name -> Int
hashTypeElm t =
    hashT 17 t


{-| Returns the hash `h` combined with the number `x`, reduced modulo 2^26.

For an `h` below 2^26, as every hash in this module is, no intermediate value
reaches 2^32, so the arithmetic is exact in JavaScript's floating-point
numbers.

-}
mix : Int -> Int -> Int
mix h x =
    modBy 67108864 (h * 33 + modBy 67108864 x + 7)


{-| Returns the hash `h` combined with the hash of the name `n`.
-}
hashName : Int -> Name -> Int
hashName h n =
    mix h (Eco.Hash.string n)


{-| Returns the hash `h` combined with a home module's author, project and
module name, in that order.
-}
hashHome : Int -> ModuleName.Canonical -> Int
hashHome h (ModuleName.Canonical ( author, project ) name) =
    hashName (hashName (hashName h author) project) name


{-| Returns the hash `h` combined with a hash of `t`: a number from 1 to 7
identifying the constructor, then its data in order, with child types hashed in
turn.

Everything `==` compares is mixed in, except that an arrow slot goes in as
`Can.arrowSlotToInt` gives it, which gives some different slots the same
number, such as an `Arrow` and `NoArrow`.

-}
hashT : Int -> Can.Type Name -> Int
hashT h t =
    case t of
        Can.TLambda slot a b ->
            hashT (hashT (mix (mix h 1) (Can.arrowSlotToInt slot)) a) b

        Can.TVar n ->
            hashName (mix h 2) n

        Can.TType home name args ->
            List.foldl (\a acc -> hashT acc a) (hashName (hashHome (mix h 3) home) name) args

        Can.TRecord fields ext ->
            let
                hf : Int
                hf =
                    Dict.foldl (\k (Can.FieldType i ft) acc -> hashT (mix (hashName acc k) i) ft) (mix h 4) fields
            in
            case ext of
                Just e ->
                    hashName (mix hf 1) e

                Nothing ->
                    mix hf 0

        Can.TUnit ->
            mix h 5

        Can.TTuple a b cs ->
            List.foldl (\c acc -> hashT acc c) (hashT (hashT (mix h 6) a) b) cs

        Can.TAlias home name args at ->
            let
                ha : Int
                ha =
                    List.foldl (\( n, a ) acc -> hashT (hashName acc n) a) (hashName (hashHome (mix h 7) home) name) args
            in
            case at of
                Can.Holey x ->
                    hashT (mix ha 0) x

                Can.Filled x ->
                    hashT (mix ha 1) x
