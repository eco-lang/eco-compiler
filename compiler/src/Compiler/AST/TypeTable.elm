module Compiler.AST.TypeTable exposing
    ( Builder, empty, add, intern, size, collectStrings
    , TypeTable, freeze, ref, refMaybe, encoder
    , Decoded, decoder, refDecoder, decodedTypes
    , hashType, hashTypeElm
    )

{-| Per-file TYPE TABLE for the typed artifacts (`.ecot`, `typed-artifacts.dat`;
`typedGraphFormatVersion` 2, ECOT\_003; cache-serialization plan S3).

Every typed expression carries its own fully expanded `Can.Type`. On the
self-compile that is 25.6 M type nodes, of which ~150 k are distinct per file.
The table stores each `==`-distinct type ONCE, children first, and the body
refers to types by id.

  - **Key** = the whole `Can.Type Name`, **equality** = `(==)`. That covers the
    arrow slot, field index, Holey/Filled, record extension and alias argument
    names, which are all constructor data.
  - **Lossless:** `==`-equal types have identical v1 encodings (records go through
    `Dict.toList`, strings by content).
  - **Deterministic:** ids are assigned in first-occurrence order of the caller's
    pre-pass (`TOpt.internTypesFrom*`), children first. The hash only picks a
    `Data.HashMap` bucket and never decides equality or order, so the bytes do
    not depend on which hash implementation runs (JS == native, gate G7).
  - **Strings:** `collectStrings` adds the strings of the DISTINCT entries only;
    with the body strings that is exactly the v1 string set (ECOT\_002).


# Building

@docs Builder, empty, add, intern, size, collectStrings


# Encoding

@docs TypeTable, freeze, ref, refMaybe, encoder


# Decoding

@docs Decoded, decoder, refDecoder, decodedTypes


# Hashing

@docs hashType, hashTypeElm

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


{-| One table row. Child references are ids smaller than the row's own id.
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


{-| A table under construction.
-}
type Builder
    = Builder
        { ids : HashMap (Can.Type Name) Int
        , rev : List Entry
        , count : Int
        }


{-| The empty builder.
-}
empty : Builder
empty =
    Builder { ids = HashMap.empty, rev = [], count = 0 }


{-| Number of distinct types interned so far.
-}
size : Builder -> Int
size (Builder r) =
    r.count


{-| Intern a type, discarding its id.
-}
add : Can.Type Name -> Builder -> Builder
add t b =
    Tuple.second (intern t b)


{-| Intern a type: look the WHOLE subtree up first, and descend into its
children only on a miss, so a repeated type costs one hash and one `==`.
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


{-| Add the strings of the DISTINCT entries to a string collector.
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


{-| A finished table, ready to encode the body against.
-}
type TypeTable
    = TypeTable
        { ids : HashMap (Can.Type Name) Int
        , entries : List Entry
        , count : Int
        , width : Int
        }


{-| Finish a builder. The reference width follows `StringTable`'s rule.
-}
freeze : Builder -> TypeTable
freeze (Builder r) =
    TypeTable
        { ids = r.ids
        , entries = List.reverse r.rev
        , count = r.count
        , width = widthFor r.count
        }


widthFor : Int -> Int
widthFor count =
    if count <= 256 then
        1

    else if count <= 65536 then
        2

    else
        4


{-| The id of an interned type, or `Nothing` if the pre-pass missed it.
-}
refMaybe : TypeTable -> Can.Type Name -> Maybe Int
refMaybe (TypeTable r) t =
    HashMap.getHashed (hashType t) (==) t r.ids


{-| Encode a type as a reference into the table. A type the pre-pass never
interned is pre-pass/encoder drift and crashes (never a wrong id).
-}
ref : TypeTable -> Can.Type Name -> BE.Encoder
ref ((TypeTable r) as tt) t =
    case refMaybe tt t of
        Just id ->
            refEncoder r.width id

        Nothing ->
            Utils.Crash.crash "TypeTable.ref: type not interned by the pre-pass (internTypesFrom*/encoder drift)"


refEncoder : Int -> Int -> BE.Encoder
refEncoder width id =
    if width == 1 then
        BE.unsignedInt8 id

    else if width == 2 then
        BE.unsignedInt16 Bytes.BE id

    else
        BE.unsignedInt32 Bytes.BE id


{-| Encode the table: `u8 width, u32 count, entries in id order`.
-}
encoder : StringTable -> TypeTable -> BE.Encoder
encoder st (TypeTable r) =
    BE.sequence
        [ BE.unsignedInt8 r.width
        , BE.unsignedInt32 Bytes.BE r.count
        , BE.sequence (List.map (entryEncoder st r.width) r.entries)
        ]


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


{-| A decoded table: the types by id, plus the reference width.
-}
type Decoded
    = Decoded (Array (Can.Type Name)) Int


{-| The decoded types, by id (tests).
-}
decodedTypes : Decoded -> Array (Can.Type Name)
decodedTypes (Decoded arr _) =
    arr


{-| Decode a table written by `encoder`. Rows may refer only to earlier rows,
so the array is built in one forward pass. A bad reference fails the decode.
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


rawRef : Int -> BD.Decoder Int
rawRef width =
    if width == 1 then
        BD.unsignedInt8

    else if width == 2 then
        BD.unsignedInt16 Bytes.BE

    else
        BD.unsignedInt32 Bytes.BE


resolve : Array (Can.Type Name) -> Int -> BD.Decoder (Can.Type Name)
resolve arr id =
    case Array.get id arr of
        Just t ->
            BD.succeed t

        Nothing ->
            BD.fail


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


{-| Decode a type reference written by `ref`.
-}
refDecoder : Decoded -> BD.Decoder (Can.Type Name)
refDecoder (Decoded arr width) =
    rawRef width |> BD.andThen (resolve arr)



-- HASHING


{-| The bucket hash for the table. Consistent with `==`.
-}
hashType : Can.Type Name -> Int
hashType =
    hashTypeElm


{-| Pure-Elm structural hash of a `Can.Type`, consistent with `==`. Records
fold in key order (content, not tree shape); names hash by content. Same mix as
`MonoSolver.Store.groundHash`, exact in JS doubles.
-}
hashTypeElm : Can.Type Name -> Int
hashTypeElm t =
    hashT 17 t


mix : Int -> Int -> Int
mix h x =
    modBy 67108864 (h * 33 + modBy 67108864 x + 7)


hashName : Int -> Name -> Int
hashName h n =
    mix h (Eco.Hash.string n)


hashHome : Int -> ModuleName.Canonical -> Int
hashHome h (ModuleName.Canonical ( author, project ) name) =
    hashName (hashName (hashName h author) project) name


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
