module Mlir.Bytecode.AttrType exposing
    ( AttrTypeTable
    , collect
    , attrIndex
    , typeIndex
    , locIndex
    , dictAttrIndex
    , encodeDataAndOffsets
    )

{-| Attribute and Type section encoding for MLIR bytecode.

Uses MLIR's custom bytecode encoding for builtin attrs/types and assembly
format fallback for unregistered dialect types (e.g. !eco.value).

All encoding is deferred to the encode phase so that cross-references
(type indices in FunctionType, attr indices in DictionaryAttr) are resolved.

@docs AttrTypeTable, collect, attrIndex, typeIndex, locIndex, dictAttrIndex
@docs encodeData, encodeOffsets

-}

import Bitwise
import Bytes
import Bytes.Decode as BD
import Bytes.Encode as BE
import Dict exposing (Dict)
import Mlir.Bytecode.DialectSection as DialectSection exposing (DialectRegistry)
import Mlir.Bytecode.StringTable as StringTable exposing (StringTable)
import Mlir.Bytecode.VarInt exposing (encodeSignedVarInt, encodeVarInt)
import Mlir.Loc exposing (Loc(..))
import Mlir.Mlir
    exposing
        ( MlirAttr(..)
        , MlirBlock
        , MlirModule
        , MlirOp
        , MlirRegion(..)
        , MlirType(..)
        , Visibility(..)
        )
import OrderedDict



-- ==== Entry type: represents an attr or type to be encoded ====


type Entry
    = -- Builtin attrs
      EUnknownLoc
    | EFileLineColLoc String Int Int
    | EStringAttr String
    | EIntegerAttr MlirType Int
    | EFloatAttr Float MlirType
    | ETypeAttr MlirType
    | EArrayAttr (List MlirAttr)
    | EDenseArrayAttr MlirType (List Int)
    | ESymbolRefAttr String
    | EDictAttr (Dict String MlirAttr)
      -- Builtin types
    | EIntegerType Int
    | EFloat64Type
    | EFunctionType (List MlirType) (List MlirType)
      -- Unregistered types (assembly fallback)
    | EAsmType String String



-- ==== Table ====


type AttrTypeTable
    = AttrTypeTable
        { attrKeys : Dict String Int
        , typeKeys : Dict String Int
        , attrEntries : List ( String, Entry )
        , typeEntries : List ( String, Entry )
        , numAttrs : Int
        , numTypes : Int
        }


attrIndex : MlirAttr -> AttrTypeTable -> Int
attrIndex attr (AttrTypeTable tbl) =
    Dict.get (attrToKey attr) tbl.attrKeys |> Maybe.withDefault -1


typeIndex : MlirType -> AttrTypeTable -> Int
typeIndex ty (AttrTypeTable tbl) =
    Dict.get (typeToKey ty) tbl.typeKeys |> Maybe.withDefault -1


locIndex : Loc -> AttrTypeTable -> Int
locIndex loc tbl =
    attrIndex (locToAttr loc) tbl


dictAttrIndex : Dict String MlirAttr -> AttrTypeTable -> Int
dictAttrIndex attrs (AttrTypeTable tbl) =
    Dict.get (dictToKey attrs) tbl.attrKeys |> Maybe.withDefault -1



-- ==== Keys ====


attrToKey : MlirAttr -> String
attrToKey attr =
    case attr of
        StringAttr s ->
            if s == "__mlir_unknown_loc__" then
                "loc:unknown"

            else if String.startsWith "__mlir_loc__:" s then
                "loc:" ++ String.dropLeft 13 s

            else
                "s:" ++ s

        BoolAttr b ->
            "i:" ++ typeToKey I1 ++ ":" ++ (if b then "1" else "0")

        IntAttr mt i ->
            "i:" ++ typeToKey (Maybe.withDefault I64 mt) ++ ":" ++ String.fromInt i

        TypedFloatAttr f t ->
            "f:" ++ typeToKey t ++ ":" ++ String.fromFloat f

        TypeAttr t ->
            "ta:" ++ typeToKey t

        ArrayAttr (Just t) items ->
            "da:" ++ typeToKey t ++ ":" ++ String.join "," (List.map (\item -> case item of
                IntAttr _ v -> String.fromInt v
                _ -> "?") items)

        ArrayAttr Nothing items ->
            "aa:" ++ String.join "," (List.map attrToKey items)

        SymbolRefAttr s ->
            "r:" ++ s

        VisibilityAttr Private ->
            "s:private"


dictToKey : Dict String MlirAttr -> String
dictToKey d =
    "d:{" ++ (Dict.toList d |> List.map (\( k, v ) -> k ++ "=" ++ attrToKey v) |> String.join ",") ++ "}"


typeToKey : MlirType -> String
typeToKey ty =
    case ty of
        I1 -> "i1"
        I16 -> "i16"
        I32 -> "i32"
        I64 -> "i64"
        F64 -> "f64"
        NamedStruct s -> "!" ++ s
        FunctionType sig ->
            "fn(" ++ String.join "," (List.map typeToKey sig.inputs) ++ ")->(" ++ String.join "," (List.map typeToKey sig.results) ++ ")"


locToAttr : Loc -> MlirAttr
locToAttr (Loc loc) =
    if loc.name == "unknown" && loc.start.row == 0 && loc.start.col == 0 then
        StringAttr "__mlir_unknown_loc__"
    else
        StringAttr ("__mlir_loc__:" ++ loc.name ++ ":" ++ String.fromInt loc.start.row ++ ":" ++ String.fromInt loc.start.col)



-- ==== Collection ====


type alias Accum =
    { attrKeys : Dict String Int
    , typeKeys : Dict String Int
    , attrEntries : List ( String, Entry )
    , typeEntries : List ( String, Entry )
    , nextAttr : Int
    , nextType : Int
    }


emptyAccum : Accum
emptyAccum =
    { attrKeys = Dict.empty, typeKeys = Dict.empty
    , attrEntries = [], typeEntries = []
    , nextAttr = 0, nextType = 0
    }


collect : MlirModule -> AttrTypeTable
collect mod =
    let
        result =
            emptyAccum
                |> addAttrEntry (locToAttr Mlir.Loc.unknown)
                |> (\acc -> List.foldl collectOp acc mod.body)

        -- All attrs are builtin, no reordering needed
        attrEntries =
            List.reverse result.attrEntries

        -- Types need to be grouped by dialect: builtin first, then others
        allTypeEntries =
            List.reverse result.typeEntries

        ( builtinTypes, otherTypes ) =
            List.partition (\( d, _ ) -> d == "builtin") allTypeEntries

        orderedTypeEntries =
            builtinTypes ++ otherTypes

        -- Rebuild type index map based on the grouped order
        reindexedTypeKeys =
            orderedTypeEntries
                |> List.indexedMap (\i ( _, entry ) -> ( typeEntryToKey entry, i ))
                |> Dict.fromList
    in
    AttrTypeTable
        { attrKeys = result.attrKeys
        , typeKeys = reindexedTypeKeys
        , attrEntries = attrEntries
        , typeEntries = orderedTypeEntries
        , numAttrs = result.nextAttr
        , numTypes = result.nextType
        }


addAttrEntry : MlirAttr -> Accum -> Accum
addAttrEntry attr acc =
    let
        key = attrToKey attr
    in
    case Dict.get key acc.attrKeys of
        Just _ -> acc
        Nothing ->
            let
                entry = attrToEntry attr
                dialect = entryDialect entry
            in
            { acc
                | attrKeys = Dict.insert key acc.nextAttr acc.attrKeys
                , attrEntries = ( dialect, entry ) :: acc.attrEntries
                , nextAttr = acc.nextAttr + 1
            }


addDictAttrEntry : Dict String MlirAttr -> Accum -> Accum
addDictAttrEntry attrs acc =
    let
        key = dictToKey attrs
    in
    case Dict.get key acc.attrKeys of
        Just _ -> acc
        Nothing ->
            { acc
                | attrKeys = Dict.insert key acc.nextAttr acc.attrKeys
                , attrEntries = ( "builtin", EDictAttr attrs ) :: acc.attrEntries
                , nextAttr = acc.nextAttr + 1
            }


addTypeEntry : MlirType -> Accum -> Accum
addTypeEntry ty acc =
    let
        key = typeToKey ty
    in
    case Dict.get key acc.typeKeys of
        Just _ -> acc
        Nothing ->
            let
                -- For FunctionType, ensure sub-types are added first
                accWithSubTypes =
                    case ty of
                        FunctionType sig ->
                            List.foldl addTypeEntry acc sig.inputs
                                |> (\a -> List.foldl addTypeEntry a sig.results)
                        _ -> acc

                entry = typeToEntry ty
                dialect = typeEntryDialect entry
            in
            { accWithSubTypes
                | typeKeys = Dict.insert key accWithSubTypes.nextType accWithSubTypes.typeKeys
                , typeEntries = ( dialect, entry ) :: accWithSubTypes.typeEntries
                , nextType = accWithSubTypes.nextType + 1
            }


attrToEntry : MlirAttr -> Entry
attrToEntry attr =
    case attr of
        StringAttr s ->
            if s == "__mlir_unknown_loc__" then EUnknownLoc
            else if String.startsWith "__mlir_loc__:" s then
                let rest = String.dropLeft 13 s
                    parts = String.split ":" rest
                in
                case parts of
                    name :: lineStr :: colStr :: _ ->
                        EFileLineColLoc name
                            (String.toInt lineStr |> Maybe.withDefault 0)
                            (String.toInt colStr |> Maybe.withDefault 0)
                    _ -> EUnknownLoc
            else EStringAttr s

        BoolAttr b -> EIntegerAttr I1 (if b then 1 else 0)
        IntAttr mt i -> EIntegerAttr (Maybe.withDefault I64 mt) i
        TypedFloatAttr f t -> EFloatAttr f t
        TypeAttr t -> ETypeAttr t
        ArrayAttr (Just t) items ->
            EDenseArrayAttr t (List.filterMap (\item -> case item of
                IntAttr _ v -> Just v
                _ -> Nothing) items)
        ArrayAttr Nothing items -> EArrayAttr items
        SymbolRefAttr s -> ESymbolRefAttr s
        VisibilityAttr Private -> EStringAttr "private"


typeToEntry : MlirType -> Entry
typeToEntry ty =
    case ty of
        I1 -> EIntegerType 1
        I16 -> EIntegerType 16
        I32 -> EIntegerType 32
        I64 -> EIntegerType 64
        F64 -> EFloat64Type
        NamedStruct s ->
            let dialect = case String.split "." s of
                    d :: _ -> d
                    _ -> "builtin"
            in EAsmType dialect ("!" ++ s)
        FunctionType sig -> EFunctionType sig.inputs sig.results


entryDialect : Entry -> String
entryDialect entry =
    case entry of
        EAsmType d _ -> d
        _ -> "builtin"


typeEntryDialect : Entry -> String
typeEntryDialect entry =
    case entry of
        EAsmType d _ -> d
        _ -> "builtin"


typeEntryToKey : Entry -> String
typeEntryToKey entry =
    case entry of
        EIntegerType w -> "i" ++ String.fromInt w
        EFloat64Type -> "f64"
        EAsmType _ asm -> asm  -- "!eco.value" etc - matches typeToKey's "!" ++ s
        EFunctionType inputs results ->
            "fn(" ++ String.join "," (List.map typeToKey inputs) ++ ")->(" ++ String.join "," (List.map typeToKey results) ++ ")"
        _ -> ""


collectOp : MlirOp -> Accum -> Accum
collectOp op acc =
    let
        acc1 = addAttrEntry (locToAttr op.loc) acc

        acc2 =
            if Dict.isEmpty op.attrs then acc1
            else
                acc1
                    |> addDictAttrEntry op.attrs
                    |> collectDictContents op.attrs

        acc3 = List.foldl (\( _, t ) a -> addTypeEntry t a) acc2 op.results

        acc5 = List.foldl collectRegion acc3 op.regions
    in
    acc5


collectDictContents : Dict String MlirAttr -> Accum -> Accum
collectDictContents attrs acc =
    Dict.foldl (\k v a ->
        -- Add key as StringAttr and value as attr, plus deep collection
        addAttrEntry (StringAttr k) a
            |> addAttrEntry v
            |> collectAttrDeep v
    ) acc attrs


collectAttrDeep : MlirAttr -> Accum -> Accum
collectAttrDeep attr acc =
    case attr of
        ArrayAttr (Just t) _ ->
            addTypeEntry t acc
        ArrayAttr Nothing items ->
            List.foldl (\item a -> addAttrEntry item a |> collectAttrDeep item) acc items
        TypeAttr t -> addTypeEntry t acc
        TypedFloatAttr _ t -> addTypeEntry t acc
        IntAttr (Just t) _ -> addTypeEntry t acc
        IntAttr Nothing _ -> addTypeEntry I64 acc
        BoolAttr _ -> addTypeEntry I1 acc
        SymbolRefAttr s ->
            -- FlatSymbolRefAttr references a StringAttr, ensure it's in the table
            addAttrEntry (StringAttr s) acc
        _ -> acc


collectRegion : MlirRegion -> Accum -> Accum
collectRegion (MlirRegion r) acc =
    let acc1 = collectBlock r.entry acc
    in OrderedDict.foldl (\_ blk a -> collectBlock blk a) acc1 r.blocks


collectBlock : MlirBlock -> Accum -> Accum
collectBlock blk acc =
    let
        acc1 = List.foldl (\( _, t ) a -> addTypeEntry t a) acc blk.args
        acc2 = List.foldl (\_ a -> addAttrEntry (locToAttr Mlir.Loc.unknown) a) acc1 blk.args
        acc3 = List.foldl collectOp acc2 blk.body
    in
    collectOp blk.terminator acc3



-- ==== Encoding ====


{-| A pre-encoded entry with its dialect, encoded bytes, size, and custom flag.
Computed once and used for both data and offset sections.
-}
type alias EncodedEntry =
    { dialect : String
    , encoded : Bytes.Bytes
    , size : Int
    , hasCustom : Bool
    }


{-| Compute grouped, pre-encoded entries. This is the single source of truth
for both encodeData and encodeOffsets. Each entry is encoded once and its
size cached, avoiding redundant encoding.
-}
computeEncodedGroups : StringTable -> AttrTypeTable -> List (List EncodedEntry)
computeEncodedGroups st ((AttrTypeTable tbl) as table) =
    let
        encodeOne ( dialect, entry ) =
            let
                enc =
                    encodeEntry st table entry

                bytes =
                    BE.encode enc
            in
            { dialect = dialect
            , encoded = bytes
            , size = Bytes.width bytes
            , hasCustom =
                case entry of
                    EAsmType _ _ ->
                        False

                    _ ->
                        True
            }

        -- Encode all entries
        encodedAttrs =
            List.map encodeOne tbl.attrEntries

        encodedTypes =
            List.map encodeOne tbl.typeEntries

        -- Group by dialect using Dict (O(N) instead of O(N²))
        groupByDialect items =
            let
                -- Build Dict String (List EncodedEntry) — entries in reverse order
                dict =
                    List.foldl
                        (\item acc ->
                            Dict.update item.dialect
                                (\existing ->
                                    case existing of
                                        Just list ->
                                            Just (item :: list)

                                        Nothing ->
                                            Just [ item ]
                                )
                                acc
                        )
                        Dict.empty
                        items

                -- Collect dialect keys in insertion order
                dialectOrder =
                    List.foldl
                        (\item acc ->
                            if List.member item.dialect acc then
                                acc

                            else
                                acc ++ [ item.dialect ]
                        )
                        []
                        items
            in
            dialectOrder
                |> List.map
                    (\d ->
                        Dict.get d dict
                            |> Maybe.withDefault []
                            |> List.reverse
                    )

        attrGroups =
            groupByDialect encodedAttrs

        typeGroups =
            groupByDialect encodedTypes
    in
    attrGroups ++ typeGroups


{-| Encode both the data and offset sections in a single pass.
The groups are computed once and reused for both sections.
Returns (dataSectionBody, offsetSectionBody).
-}
encodeDataAndOffsets : StringTable -> DialectRegistry -> AttrTypeTable -> ( BE.Encoder, BE.Encoder )
encodeDataAndOffsets st dialectRegistry ((AttrTypeTable tbl) as table) =
    let
        groups =
            computeEncodedGroups st table

        -- Data section: concatenated encoded bytes
        dataEncoder =
            BE.sequence
                (groups |> List.concatMap (List.map (\e -> BE.bytes e.encoded)))

        -- Offset section: dialect groups with sizes
        groupEncoders =
            groups
                |> List.filterMap
                    (\groupEntries ->
                        case groupEntries of
                            [] ->
                                Nothing

                            first :: _ ->
                                let
                                    dialectIdx =
                                        DialectSection.dialectIndex first.dialect dialectRegistry

                                    numElements =
                                        List.length groupEntries

                                    offsetEncoders =
                                        groupEntries
                                            |> List.map
                                                (\e ->
                                                    encodeVarInt (e.size * 2 + (if e.hasCustom then 1 else 0))
                                                )
                                in
                                Just (BE.sequence (encodeVarInt dialectIdx :: encodeVarInt numElements :: offsetEncoders))
                    )

        offsetEncoder =
            BE.sequence (encodeVarInt tbl.numAttrs :: encodeVarInt tbl.numTypes :: groupEncoders)
    in
    ( dataEncoder, offsetEncoder )


encodeEntry : StringTable -> AttrTypeTable -> Entry -> BE.Encoder
encodeEntry st tbl entry =
    case entry of
        EUnknownLoc ->
            encodeVarInt 15

        EFileLineColLoc name line col ->
            let filenameIdx = attrIndex (StringAttr name) tbl
            in BE.sequence [ encodeVarInt 11, encodeVarInt filenameIdx, encodeVarInt line, encodeVarInt col ]

        EStringAttr s ->
            BE.sequence [ encodeVarInt 2, encodeOwnedString st s ]



        EIntegerAttr ty val ->
            let
                tyIdx = typeIndex ty tbl
                width = typeWidth ty
                apintEnc =
                    if width <= 8 then
                        BE.unsignedInt8 val

                    else
                        encodeSignedVarInt val
            in
            BE.sequence [ encodeVarInt 8, encodeVarInt tyIdx, apintEnc ]

        EFloatAttr f ty ->
            let tyIdx = typeIndex ty tbl
            in BE.sequence [ encodeVarInt 9, encodeVarInt tyIdx, encodeAPFloat f ]

        ETypeAttr ty ->
            let tyIdx = typeIndex ty tbl
            in BE.sequence [ encodeVarInt 6, encodeVarInt tyIdx ]

        EArrayAttr items ->
            let encodedItems = items |> List.map (\item -> encodeVarInt (attrIndex item tbl))
            in BE.sequence (encodeVarInt 0 :: encodeVarInt (List.length items) :: encodedItems)

        EDenseArrayAttr ty vals ->
            let
                tyIdx = typeIndex ty tbl
                numElements = List.length vals
                blob = BE.encode (BE.sequence (List.map (\v ->
                    BE.sequence
                        [ BE.unsignedInt8 (Bitwise.and v 0xFF)
                        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 8 v) 0xFF)
                        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 16 v) 0xFF)
                        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 24 v) 0xFF)
                        , BE.unsignedInt8 0
                        , BE.unsignedInt8 0
                        , BE.unsignedInt8 0
                        , BE.unsignedInt8 0
                        ]) vals))
            in
            BE.sequence
                [ encodeVarInt 17, encodeVarInt tyIdx
                , encodeVarInt numElements, encodeVarInt (Bytes.width blob), BE.bytes blob ]

        ESymbolRefAttr s ->
            let strAttrIdx = attrIndex (StringAttr s) tbl
            in BE.sequence [ encodeVarInt 4, encodeVarInt strAttrIdx ]

        EDictAttr attrs ->
            let
                entries = Dict.toList attrs
                encodedEntries = entries |> List.map (\( key, val ) ->
                    -- NamedAttribute: attr ref for name (StringAttr), attr ref for value
                    BE.sequence
                        [ encodeVarInt (attrIndex (StringAttr key) tbl)
                        , encodeVarInt (attrIndex val tbl)
                        ])
            in
            BE.sequence (encodeVarInt 1 :: encodeVarInt (List.length entries) :: encodedEntries)

        EIntegerType width ->
            BE.sequence [ encodeVarInt 0, encodeVarInt (Bitwise.shiftLeftBy 2 width) ]

        EFloat64Type ->
            encodeVarInt 6

        EFunctionType inputs results ->
            let
                inputEncoders = inputs |> List.map (\t -> encodeVarInt (typeIndex t tbl))
                resultEncoders = results |> List.map (\t -> encodeVarInt (typeIndex t tbl))
            in
            BE.sequence
                (encodeVarInt 2
                    :: encodeVarInt (List.length inputs) :: inputEncoders
                    ++ encodeVarInt (List.length results) :: resultEncoders)

        EAsmType _ asm ->
            BE.sequence [ BE.string asm, BE.unsignedInt8 0x00 ]


encodeOwnedString : StringTable -> String -> BE.Encoder
encodeOwnedString st s =
    encodeVarInt (StringTable.indexOf s st)


encodeAPInt : Int -> Int -> BE.Encoder
encodeAPInt width value =
    -- For width <= 8, MLIR expects a single raw byte.
    -- For 8 < width <= 64, MLIR expects a signed varint (zigzag).
    -- For width > 64, MLIR expects numActiveWords + array of signed varints.
    -- We always have width <= 64 in practice.
    if width <= 8 then
        BE.unsignedInt8 value

    else
        encodeSignedVarInt value


encodeAPFloat : Float -> BE.Encoder
encodeAPFloat f =
    -- MLIR reads floats via readAPIntWithKnownWidth(64), which reads a signed varint.
    -- The signed varint is zigzag-decoded to get the raw IEEE 754 bit pattern.
    --
    -- Since JS can't represent 64-bit integers precisely, we encode the float's
    -- raw bytes directly using zigzag at the byte level:
    -- 1. Write the float as 8 LE bytes to get the IEEE 754 representation
    -- 2. Apply zigzag encoding to the bytes (shifting left by 1, with sign in low bit)
    -- 3. Write as a PrefixVarInt
    --
    -- For positive floats (high bit 0), zigzag just shifts left by 1.
    -- We use the 9-byte varint encoding to preserve all 64 bits exactly.
    let
        rawBytes =
            BE.encode (BE.float64 Bytes.LE f)

        -- Read as two 32-bit unsigned ints (low, high)
        decoder =
            BD.map2 Tuple.pair
                (BD.unsignedInt32 Bytes.LE)
                (BD.unsignedInt32 Bytes.LE)

        ( lo, hi ) =
            BD.decode decoder rawBytes
                |> Maybe.withDefault ( 0, 0 )

        -- Zigzag encode: for the 64-bit value (hi:lo), compute (value << 1) ^ (value >> 63)
        -- value >> 63 = sign bit = hi >> 31
        signExtend =
            if Bitwise.and hi 0x80000000 /= 0 then
                0xFFFFFFFF
            else
                0

        -- value << 1: shift the 64-bit pair left by 1
        shiftedLo =
            Bitwise.shiftLeftBy 1 lo

        shiftedHi =
            Bitwise.or (Bitwise.shiftLeftBy 1 hi) (Bitwise.shiftRightZfBy 31 lo)

        -- XOR with sign extension
        zigLo =
            Bitwise.xor shiftedLo signExtend

        zigHi =
            Bitwise.xor shiftedHi signExtend
    in
    -- Write as 9-byte PrefixVarInt (first byte 0x00, then 8 bytes LE)
    BE.sequence
        [ BE.unsignedInt8 0x00
        , BE.unsignedInt8 (Bitwise.and zigLo 0xFF)
        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 8 zigLo) 0xFF)
        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 16 zigLo) 0xFF)
        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 24 zigLo) 0xFF)
        , BE.unsignedInt8 (Bitwise.and zigHi 0xFF)
        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 8 zigHi) 0xFF)
        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 16 zigHi) 0xFF)
        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 24 zigHi) 0xFF)
        ]


typeWidth : MlirType -> Int
typeWidth ty =
    case ty of
        I1 -> 1
        I16 -> 16
        I32 -> 32
        I64 -> 64
        F64 -> 64
        _ -> 64



-- ==== Offset section ====


