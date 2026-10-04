module Mlir.Bytecode.AttrType exposing
    ( AttrTypeTable, collect, typeIndex, locIndex, dictAttrIndex, bytecodeAttrs
    , StreamAccum, encodeDataAndOffsets, finalizeStreamAccum, initStreamAccum, streamAccumEncodingView, streamCollectOp
    )

{-| MLIR bytecode writes each distinct attribute and type once, in a section of
its own, and everywhere else refers to it by its index there. This module
numbers the attributes and types an MLIR program uses, and writes that section
and the offset section that goes with it.

An _attribute_ is a constant value an operation carries, such as an integer or
a string (`Mlir.Mlir.MlirAttr`). MLIR also treats a source location as an
attribute, and an operation's whole attribute dictionary as one attribute, so
locations and dictionaries are numbered in the attribute list too. Types are
numbered in a list of their own. Each list counts from 0.

Entries refer to one another by index. A function type refers to its input and
result types, an integer attribute to its type, and a dictionary to the string
attributes that hold its names and to its values. So no entry is encoded while
the table is built. Collection first gives an index to the entries an
operation refers to, and `encodeDataAndOffsets` encodes the entries
afterwards, looking up the indices they need in the finished table. A file
location also refers to the string attribute holding its name, which
collection does not add, so that reference is written as -1 unless the same
text was collected as a string attribute for another reason.

Collection tells values apart by an _entry key_, a string made from the value,
and a value whose key is already in the table is not added again. Some
different values share a key because they are encoded the same way: a
`BoolAttr` and the `i1` integer of the same value, an untyped `IntAttr` and
the `i64` one, and `VisibilityAttr Private` and the string attribute
`"private"`. A location named `"unknown"` that starts at 0:0 is MLIR's unknown
location, whatever its end. Any other location becomes a file, line and column
location made from its name and its start; its end is not kept.

A lookup (`typeIndex`, `locIndex`, `dictAttrIndex`) works out the key again,
and is not checked. A value that was never collected gets -1, which
`Mlir.Bytecode.VarInt.encodeVarInt` writes like any other number, so a missed
value makes a corrupt file rather than an error.

There are two ways to build a table. `collect` takes a whole module at once. A
`StreamAccum` takes one operation at a time, and its indices never change once
given, so an operation can be encoded as soon as it has been collected.

In the data section, attributes and builtin types are written in the binary
form of MLIR's builtin dialect. A `NamedStruct`, such as `!eco.value`, is
written instead as its assembly text, the way it is spelt in an MLIR text file,
with the text before its first `.` as its dialect. The offset section gives the
length of each entry and the dialect it belongs to, in _dialect groups_: runs
of consecutive entries of one dialect. String attributes are written as indices
into a `Mlir.Bytecode.StringTable`, and dialects as indices into a
`Mlir.Bytecode.DialectSection` registry. This module adds nothing to either,
and a string or dialect missing from them is written as -1 too.

@docs AttrTypeTable, collect, typeIndex, locIndex, dictAttrIndex, bytecodeAttrs
@docs StreamAccum, encodeDataAndOffsets, finalizeStreamAccum, initStreamAccum, streamAccumEncodingView, streamCollectOp

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



-- ==== Entries ====


{-| One entry of the attribute list or the type list, in the form it is encoded
from.

The constructors up to `EUnitAttr` are attributes and the rest are types. Every
one except `EAsmType` is written in the builtin dialect's binary form.

`EUnknownLoc` is MLIR's unknown location. `EFileLineColLoc` carries a file
name, a line and a column.

`EStringAttr` carries text, which is written as its index in the string table.

`EIntegerAttr` carries the integer's type, then its value. `EFloatAttr` carries
the value, then its type.

`ETypeAttr` is a type used as an attribute.

`EArrayAttr` is a list of attributes, written as their indices.
`EDenseArrayAttr` carries an element type and the integers, which are written
as raw bytes.

`ESymbolRefAttr` refers to a symbol by name, and is written as the index of the
string attribute holding that name.

`EDictAttr` is an operation's whole attribute dictionary. Each name is written
as the index of the string attribute holding it, and each value as its index.

`EUnitAttr` carries nothing.

`EIntegerType` carries a width in bits. `EFloat64Type` is the 64-bit float
type. `EFunctionType` carries input and result types, written as their
indices.

`EAsmType` is the entry for a `NamedStruct`. It carries the text before the
name's first `.` as its dialect, and the type's assembly text, such as
`!eco.value`, which is written in place of a binary form.

-}
type Entry
    = EUnknownLoc
    | EFileLineColLoc String Int Int
    | EStringAttr String
    | EIntegerAttr MlirType Int
    | EFloatAttr Float MlirType
    | ETypeAttr MlirType
    | EArrayAttr (List MlirAttr)
    | EDenseArrayAttr MlirType (List Int)
    | ESymbolRefAttr String
    | EDictAttr (Dict String MlirAttr)
    | EUnitAttr
    | EIntegerType Int
    | EFloat64Type
    | EFunctionType (List MlirType) (List MlirType)
    | EAsmType String String



-- ==== Table ====


{-| The numbering of the attributes and types an MLIR program refers to, and,
for a table made by `collect` or `finalizeStreamAccum`, the entries
themselves, ready for `encodeDataAndOffsets` to write.

Attributes, locations and dictionaries share one numbering and types have
another, each from 0. `typeIndex`, `locIndex` and `dictAttrIndex` look an index
up, and return -1 for a value the table does not hold. A table made by
`streamAccumEncodingView` answers those lookups but holds no entries.

-}
type AttrTypeTable
    = AttrTypeTable
        { attrKeys : Dict String Int
        , typeKeys : Dict String Int
        , attrEntries : List ( String, Entry )
        , typeEntries : List ( String, Entry )
        , numAttrs : Int
        , numTypes : Int
        }


{-| Returns the index of `attr` in the attribute list, or -1 if the table does
not hold it.
-}
attrIndex : MlirAttr -> AttrTypeTable -> Int
attrIndex attr (AttrTypeTable tbl) =
    Dict.get (attrToKey attr) tbl.attrKeys |> Maybe.withDefault -1


{-| Returns the index of `ty` in the type list, or -1 if the table does not hold
it.
-}
typeIndex : MlirType -> AttrTypeTable -> Int
typeIndex ty (AttrTypeTable tbl) =
    Dict.get (typeToKey ty) tbl.typeKeys |> Maybe.withDefault -1


{-| Returns the index of `loc` in the attribute list, or -1 if the table does not
hold it.

A location named `"unknown"` that starts at 0:0 is found as MLIR's unknown
location whatever its end, and any other location is found by its name and its
start alone.

-}
locIndex : Loc -> AttrTypeTable -> Int
locIndex loc (AttrTypeTable tbl) =
    Dict.get (locKey loc) tbl.attrKeys |> Maybe.withDefault -1


{-| Returns the index of the attribute dictionary `attrs` in the attribute list,
or -1 if the table does not hold it.

Collection records an operation's dictionary as `bytecodeAttrs` returns it. A
dictionary that still holds `_operand_types` is not found, so look up the
dictionary `bytecodeAttrs` returns. An empty dictionary is never collected.

-}
dictAttrIndex : Dict String MlirAttr -> AttrTypeTable -> Int
dictAttrIndex attrs (AttrTypeTable tbl) =
    Dict.get (dictToKey attrs) tbl.attrKeys |> Maybe.withDefault -1



-- ==== Keys ====


{-| Returns the entry key of `attr`, the string by which collection tells
attributes apart: attributes with the same key share one entry.

The key is made from what the attribute is encoded as, so `BoolAttr` and the
`i1` `IntAttr` of the same value share a key, an untyped `IntAttr` keys as an
`i64` one, and `VisibilityAttr Private` keys as the string attribute
`"private"`. A typed `ArrayAttr` keys by the values of its `IntAttr` elements,
with `?` in place of any other element, so two typed arrays encoded alike can
still have different keys.

Text goes into the key as it is, with no quoting, and `String.fromFloat` gives
0 and -0 the same text, so two attributes encoded differently can still have
the same key.

-}
attrToKey : MlirAttr -> String
attrToKey attr =
    case attr of
        StringAttr s ->
            "s:" ++ s

        BoolAttr b ->
            "i:"
                ++ typeToKey I1
                ++ ":"
                ++ (if b then
                        "1"

                    else
                        "0"
                   )

        IntAttr mt i ->
            "i:" ++ typeToKey (Maybe.withDefault I64 mt) ++ ":" ++ String.fromInt i

        TypedFloatAttr f t ->
            "f:" ++ typeToKey t ++ ":" ++ String.fromFloat f

        TypeAttr t ->
            "ta:" ++ typeToKey t

        ArrayAttr (Just t) items ->
            "da:"
                ++ typeToKey t
                ++ ":"
                ++ String.join ","
                    (List.map
                        (\item ->
                            case item of
                                IntAttr _ v ->
                                    String.fromInt v

                                _ ->
                                    "?"
                        )
                        items
                    )

        ArrayAttr Nothing items ->
            "aa:" ++ String.join "," (List.map attrToKey items)

        SymbolRefAttr s ->
            "r:" ++ s

        VisibilityAttr Private ->
            "s:private"

        UnitAttr ->
            "u:"


{-| Returns the entry key of the attribute dictionary `d`, made from each name
and its value's `attrToKey`, in name order.
-}
dictToKey : Dict String MlirAttr -> String
dictToKey d =
    "d:{" ++ (Dict.toList d |> List.map (\( k, v ) -> k ++ "=" ++ attrToKey v) |> String.join ",") ++ "}"


{-| Returns the entry key of `ty`: its MLIR spelling, such as `i64` or
`!eco.value`, or for a function type the keys of its inputs and of its results.
-}
typeToKey : MlirType -> String
typeToKey ty =
    case ty of
        I1 ->
            "i1"

        I8 ->
            "i8"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct s ->
            "!" ++ s

        FunctionType sig ->
            "fn(" ++ String.join "," (List.map typeToKey sig.inputs) ++ ")->(" ++ String.join "," (List.map typeToKey sig.results) ++ ")"


{-| Returns the entry key of `loc`.

Every location named `"unknown"` that starts at 0:0 has the one key of MLIR's
unknown location, whatever its end. Any other location is keyed by its name and
its start, so two locations that differ only in their end share an entry.

-}
locKey : Loc -> String
locKey (Loc loc) =
    if loc.name == "unknown" && loc.start.row == 0 && loc.start.col == 0 then
        "LOC:unknown"

    else
        "LOC:" ++ loc.name ++ ":" ++ String.fromInt loc.start.row ++ ":" ++ String.fromInt loc.start.col


{-| Returns the entry `loc` is encoded as, choosing between MLIR's unknown
location and a file, line and column location by the same test as `locKey`.
The end of the location is dropped.
-}
locEntry : Loc -> Entry
locEntry (Loc loc) =
    if loc.name == "unknown" && loc.start.row == 0 && loc.start.col == 0 then
        EUnknownLoc

    else
        EFileLineColLoc loc.name loc.start.row loc.start.col



-- ==== Collection ====


{-| A table while it is being collected.

`attrEntries` and `typeEntries` pair each entry with its dialect, newest first.
`nextAttr` and `nextType` are the next free indices, and so also the number of
entries in each list.

-}
type alias Accum =
    { attrKeys : Dict String Int
    , typeKeys : Dict String Int
    , attrEntries : List ( String, Entry )
    , typeEntries : List ( String, Entry )
    , nextAttr : Int
    , nextType : Int
    }


{-| The accumulator holding no entries.
-}
emptyAccum : Accum
emptyAccum =
    { attrKeys = Dict.empty
    , typeKeys = Dict.empty
    , attrEntries = []
    , typeEntries = []
    , nextAttr = 0
    , nextType = 0
    }


{-| A table being collected one operation at a time, whose indices never change
once given.

It starts as `initStreamAccum` and grows through `streamCollectOp`. A new entry
takes the next index in its list, in the order entries are first met, and an
entry met again keeps the index it has. So an operation can be encoded against
`streamAccumEncodingView` as soon as it has been collected, and the indices
written then are still right in the table `finalizeStreamAccum` makes at the
end.

-}
type StreamAccum
    = StreamAccum Accum


{-| The streaming table before any operation is collected. It already holds
`Mlir.Loc.unknown`, at attribute index 0.
-}
initStreamAccum : StreamAccum
initStreamAccum =
    StreamAccum (emptyAccum |> addLocEntry Mlir.Loc.unknown)


{-| Adds to the table, for `op` and everything inside its regions: its location,
its attribute dictionary as `bytecodeAttrs` returns it if that is not empty,
each name and value in that dictionary and what the values refer to, its result
types, and for each block its argument types, `Mlir.Loc.unknown` if it has
arguments, and its operations.
-}
streamCollectOp : MlirOp -> StreamAccum -> StreamAccum
streamCollectOp op (StreamAccum acc) =
    StreamAccum (collectOp op acc)


{-| Returns the finished table, for `encodeDataAndOffsets` to write.

Entries keep the indices they were given during collection. Unlike in
`collect`, the builtin types are not moved ahead of the others, so the types
stay in the order they were found and a dialect's entries may be split across
several dialect groups.

-}
finalizeStreamAccum : StreamAccum -> AttrTypeTable
finalizeStreamAccum (StreamAccum result) =
    AttrTypeTable
        { attrKeys = result.attrKeys
        , typeKeys = result.typeKeys
        , attrEntries = List.reverse result.attrEntries
        , typeEntries = List.reverse result.typeEntries
        , numAttrs = result.nextAttr
        , numTypes = result.nextType
        }


{-| Returns a table for encoding operations while collection goes on: it answers
`typeIndex`, `locIndex` and `dictAttrIndex` for everything collected so far, as
the finished table will, but it holds no entries for `encodeDataAndOffsets` to
write.
-}
streamAccumEncodingView : StreamAccum -> AttrTypeTable
streamAccumEncodingView (StreamAccum acc) =
    AttrTypeTable
        { attrKeys = acc.attrKeys
        , typeKeys = acc.typeKeys
        , attrEntries = []
        , typeEntries = []
        , numAttrs = 0
        , numTypes = 0
        }


{-| Returns the table of the attributes, types and locations collected from the
operations of `mod`, numbered and ready for `encodeDataAndOffsets`.

What is collected from each operation is what `streamCollectOp` collects. The
location of `mod` itself is not collected, but `Mlir.Loc.unknown` is always in
the table, at attribute index 0.

Once everything is collected, the builtin types are moved ahead of the others,
each part keeping the order it was found in, and type indices are renumbered to
match. Attribute indices stay in the order found.

-}
collect : MlirModule -> AttrTypeTable
collect mod =
    let
        result =
            emptyAccum
                |> addLocEntry Mlir.Loc.unknown
                |> (\acc -> List.foldl collectOp acc mod.body)

        -- Every attribute entry is in the builtin dialect, so these need no reordering.
        attrEntries =
            List.reverse result.attrEntries

        allTypeEntries =
            List.reverse result.typeEntries

        ( builtinTypes, otherTypes ) =
            List.partition (\( d, _ ) -> d == "builtin") allTypeEntries

        orderedTypeEntries =
            builtinTypes ++ otherTypes

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


{-| Adds `loc` to the attribute list, in the builtin dialect, with the next free
index, unless an entry with its key is already there.
-}
addLocEntry : Loc -> Accum -> Accum
addLocEntry loc acc =
    let
        key =
            locKey loc
    in
    case Dict.get key acc.attrKeys of
        Just _ ->
            acc

        Nothing ->
            let
                entry =
                    locEntry loc
            in
            { acc
                | attrKeys = Dict.insert key acc.nextAttr acc.attrKeys
                , attrEntries = ( "builtin", entry ) :: acc.attrEntries
                , nextAttr = acc.nextAttr + 1
            }


{-| Adds `attr` to the attribute list with the next free index, unless an entry
with its key is already there. What `attr` refers to is not added;
`collectAttrDeep` adds that.
-}
addAttrEntry : MlirAttr -> Accum -> Accum
addAttrEntry attr acc =
    let
        key =
            attrToKey attr
    in
    case Dict.get key acc.attrKeys of
        Just _ ->
            acc

        Nothing ->
            let
                entry =
                    attrToEntry attr

                dialect =
                    entryDialect entry
            in
            { acc
                | attrKeys = Dict.insert key acc.nextAttr acc.attrKeys
                , attrEntries = ( dialect, entry ) :: acc.attrEntries
                , nextAttr = acc.nextAttr + 1
            }


{-| Adds the attribute dictionary `attrs` to the attribute list as one entry,
in the builtin dialect, unless an entry with its key is already there. Its
names and values are not added; `collectDictContents` adds those.
-}
addDictAttrEntry : Dict String MlirAttr -> Accum -> Accum
addDictAttrEntry attrs acc =
    let
        key =
            dictToKey attrs
    in
    case Dict.get key acc.attrKeys of
        Just _ ->
            acc

        Nothing ->
            { acc
                | attrKeys = Dict.insert key acc.nextAttr acc.attrKeys
                , attrEntries = ( "builtin", EDictAttr attrs ) :: acc.attrEntries
                , nextAttr = acc.nextAttr + 1
            }


{-| Adds `ty` to the type list with the next free index, unless an entry with its
key is already there. The input and result types of a function type are added
before the function type itself.
-}
addTypeEntry : MlirType -> Accum -> Accum
addTypeEntry ty acc =
    let
        key =
            typeToKey ty
    in
    case Dict.get key acc.typeKeys of
        Just _ ->
            acc

        Nothing ->
            let
                accWithSubTypes =
                    case ty of
                        FunctionType sig ->
                            List.foldl addTypeEntry acc sig.inputs
                                |> (\a -> List.foldl addTypeEntry a sig.results)

                        _ ->
                            acc

                entry =
                    typeToEntry ty

                dialect =
                    typeEntryDialect entry
            in
            { accWithSubTypes
                | typeKeys = Dict.insert key accWithSubTypes.nextType accWithSubTypes.typeKeys
                , typeEntries = ( dialect, entry ) :: accWithSubTypes.typeEntries
                , nextType = accWithSubTypes.nextType + 1
            }


{-| Returns the entry `attr` is encoded as.

`BoolAttr` becomes an `i1` integer, an untyped `IntAttr` an `i64` one, and
`VisibilityAttr Private` the string attribute `"private"`. A typed `ArrayAttr`
becomes a dense array of the integers of its `IntAttr` elements; any other
element is dropped.

-}
attrToEntry : MlirAttr -> Entry
attrToEntry attr =
    case attr of
        StringAttr s ->
            EStringAttr s

        BoolAttr b ->
            EIntegerAttr I1
                (if b then
                    1

                 else
                    0
                )

        IntAttr mt i ->
            EIntegerAttr (Maybe.withDefault I64 mt) i

        TypedFloatAttr f t ->
            EFloatAttr f t

        TypeAttr t ->
            ETypeAttr t

        ArrayAttr (Just t) items ->
            EDenseArrayAttr t
                (List.filterMap
                    (\item ->
                        case item of
                            IntAttr _ v ->
                                Just v

                            _ ->
                                Nothing
                    )
                    items
                )

        ArrayAttr Nothing items ->
            EArrayAttr items

        SymbolRefAttr s ->
            ESymbolRefAttr s

        VisibilityAttr Private ->
            EStringAttr "private"

        UnitAttr ->
            EUnitAttr


{-| Returns the entry `ty` is encoded as.

A `NamedStruct` becomes an assembly-text entry. Its dialect is the part of its
name before the first `.`, or the whole name if there is no `.`, and its text
is the name with `!` in front of it.

-}
typeToEntry : MlirType -> Entry
typeToEntry ty =
    case ty of
        I1 ->
            EIntegerType 1

        I8 ->
            EIntegerType 8

        I16 ->
            EIntegerType 16

        I32 ->
            EIntegerType 32

        I64 ->
            EIntegerType 64

        F64 ->
            EFloat64Type

        NamedStruct s ->
            let
                dialect =
                    case String.split "." s of
                        d :: _ ->
                            d

                        _ ->
                            "builtin"
            in
            EAsmType dialect ("!" ++ s)

        FunctionType sig ->
            EFunctionType sig.inputs sig.results


{-| Returns the dialect an attribute entry belongs to: the dialect an `EAsmType`
carries, and `builtin` for any other entry. No attribute becomes an `EAsmType`,
so for an attribute this is always `builtin`.
-}
entryDialect : Entry -> String
entryDialect entry =
    case entry of
        EAsmType d _ ->
            d

        _ ->
            "builtin"


{-| Returns the dialect a type entry belongs to: the dialect an `EAsmType`
carries, and `builtin` for any other entry. It gives the same answer as
`entryDialect`.
-}
typeEntryDialect : Entry -> String
typeEntryDialect entry =
    case entry of
        EAsmType d _ ->
            d

        _ ->
            "builtin"


{-| Returns the entry key of the type a type entry came from, the same string
`typeToKey` gives that type, so that `collect` can renumber types from their
entries. It returns `""` for an attribute entry, which `collect` never gives
it.
-}
typeEntryToKey : Entry -> String
typeEntryToKey entry =
    case entry of
        EIntegerType w ->
            "i" ++ String.fromInt w

        EFloat64Type ->
            "f64"

        EAsmType _ asm ->
            asm

        EFunctionType inputs results ->
            "fn(" ++ String.join "," (List.map typeToKey inputs) ++ ")->(" ++ String.join "," (List.map typeToKey results) ++ ")"

        _ ->
            ""


{-| Returns an operation's attribute dictionary `attrs` as it is written to
bytecode, which is without `_operand_types`.

`Mlir.Pretty` takes the operand types it prints from `_operand_types`, and
nothing in the bytecode encoder reads it.
Only that exact name is removed. Other names that start with an underscore,
such as `_fast_evaluator`, are kept and written.

Collection records the dictionary this returns, and the encoder finds the
dictionary's index by looking it up again with `dictAttrIndex`. So a
dictionary looked up while it still holds `_operand_types` gives -1; look up
what this function returns.

-}
bytecodeAttrs : Dict String MlirAttr -> Dict String MlirAttr
bytecodeAttrs attrs =
    Dict.remove "_operand_types" attrs


{-| Adds to the table, for `op`: its location; its attribute dictionary as
`bytecodeAttrs` returns it, if that is not empty, with its names and values;
its result types; and what its regions hold.
-}
collectOp : MlirOp -> Accum -> Accum
collectOp op acc =
    let
        acc1 =
            addLocEntry op.loc acc

        attrs =
            bytecodeAttrs op.attrs

        acc2 =
            if Dict.isEmpty attrs then
                acc1

            else
                acc1
                    |> addDictAttrEntry attrs
                    |> collectDictContents attrs

        acc3 =
            List.foldl (\( _, t ) a -> addTypeEntry t a) acc2 op.results
    in
    List.foldl collectRegion acc3 op.regions


{-| Adds each name in `attrs` as a string attribute, and each value together
with what it refers to.
-}
collectDictContents : Dict String MlirAttr -> Accum -> Accum
collectDictContents attrs acc =
    Dict.foldl
        (\k v a ->
            addAttrEntry (StringAttr k) a
                |> addAttrEntry v
                |> collectAttrDeep v
        )
        acc
        attrs


{-| Adds what `attr` will refer to by index once encoded, but not `attr`
itself.

That is the type of a typed array, of a typed float, of a type attribute or of
an integer (`i64` for an untyped `IntAttr`, `i1` for a `BoolAttr`); the string
attribute holding a symbol reference's name; and each element of an untyped
array, together with what it refers to in turn.

-}
collectAttrDeep : MlirAttr -> Accum -> Accum
collectAttrDeep attr acc =
    case attr of
        ArrayAttr (Just t) _ ->
            addTypeEntry t acc

        ArrayAttr Nothing items ->
            List.foldl (\item a -> addAttrEntry item a |> collectAttrDeep item) acc items

        TypeAttr t ->
            addTypeEntry t acc

        TypedFloatAttr _ t ->
            addTypeEntry t acc

        IntAttr (Just t) _ ->
            addTypeEntry t acc

        IntAttr Nothing _ ->
            addTypeEntry I64 acc

        BoolAttr _ ->
            addTypeEntry I1 acc

        SymbolRefAttr s ->
            addAttrEntry (StringAttr s) acc

        _ ->
            acc


{-| Adds what `collectBlock` adds for each block of a region, the entry block
first and then the others in order.
-}
collectRegion : MlirRegion -> Accum -> Accum
collectRegion (MlirRegion r) acc =
    let
        acc1 =
            collectBlock r.entry acc
    in
    OrderedDict.foldl (\_ blk a -> collectBlock blk a) acc1 r.blocks


{-| Adds the types of the block's arguments, `Mlir.Loc.unknown` if it has any
arguments, and what `collectOp` adds for each of its operations and its
terminator.
`Mlir.Bytecode.IrSection` gives every block argument that location.
-}
collectBlock : MlirBlock -> Accum -> Accum
collectBlock blk acc =
    let
        acc1 =
            List.foldl (\( _, t ) a -> addTypeEntry t a) acc blk.args

        acc2 =
            List.foldl (\_ a -> addLocEntry Mlir.Loc.unknown a) acc1 blk.args

        acc3 =
            List.foldl collectOp acc2 blk.body
    in
    collectOp blk.terminator acc3



-- ==== Encoding ====


{-| One entry already encoded, with what the offset section needs to know about
it.

`size` is the length of `encoded` in bytes. `hasCustom` is `True` when the
bytes are the dialect's binary form and `False` when they are assembly text.

-}
type alias EncodedEntry =
    { dialect : String
    , encoded : Bytes.Bytes
    , size : Int
    , hasCustom : Bool
    }


{-| Returns every entry of the table encoded, in index order and split into
dialect groups: the attributes' groups, then the types'.

A group is a run of consecutive entries of one dialect, so a dialect whose
entries are not next to each other has more than one group. Gathering each
dialect's entries together instead would move entries away from their indices.
In a table from `collect` the builtin types are next to each other and form one
group.

Each entry is encoded once, and the same bytes serve the data section and the
sizes in the offset section.

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

        encodedAttrs =
            List.map encodeOne tbl.attrEntries

        encodedTypes =
            List.map encodeOne tbl.typeEntries

        groupByDialect items =
            groupSequential items

        groupSequential entries =
            case entries of
                [] ->
                    []

                first :: rest ->
                    let
                        ( group, remaining ) =
                            spanDialect first.dialect [ first ] rest
                    in
                    group :: groupSequential remaining

        spanDialect dialect acc entries =
            case entries of
                [] ->
                    ( List.reverse acc, [] )

                x :: rest ->
                    if x.dialect == dialect then
                        spanDialect dialect (x :: acc) rest

                    else
                        ( List.reverse acc, entries )

        attrGroups =
            groupByDialect encodedAttrs

        typeGroups =
            groupByDialect encodedTypes
    in
    attrGroups ++ typeGroups


{-| Returns the contents of the attribute and type data section and of its
offset section, in that order, for the entries of `table`. Neither includes the
id and length that frame a section.

The data section is every entry's encoding, attributes then types, end to end.
The offset section is the number of attributes, the number of types, and then
the dialect groups: runs of consecutive entries of one dialect, attributes
first. Each group is written as the dialect's index in `dialectRegistry`, the
number of entries, and for each entry its size in bytes times two, plus one
when the entry is in its dialect's binary form rather than assembly text.

String attributes are written as their indices in `st`. Neither `st` nor
`dialectRegistry` is checked, so a string or a dialect missing from them is
written as -1, as is any reference to an entry `table` does not hold.

-}
encodeDataAndOffsets : StringTable -> DialectRegistry -> AttrTypeTable -> ( BE.Encoder, BE.Encoder )
encodeDataAndOffsets st dialectRegistry ((AttrTypeTable tbl) as table) =
    let
        groups =
            computeEncodedGroups st table

        dataEncoder =
            BE.sequence
                (groups |> List.concatMap (List.map (\e -> BE.bytes e.encoded)))

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
                                                    encodeVarInt
                                                        (e.size
                                                            * 2
                                                            + (if e.hasCustom then
                                                                1

                                                               else
                                                                0
                                                              )
                                                        )
                                                )
                                in
                                Just (BE.sequence (encodeVarInt dialectIdx :: encodeVarInt numElements :: offsetEncoders))
                    )

        offsetEncoder =
            BE.sequence (encodeVarInt tbl.numAttrs :: encodeVarInt tbl.numTypes :: groupEncoders)
    in
    ( dataEncoder, offsetEncoder )


{-| Creates an encoder for one entry, in the form the builtin dialect's bytecode
gives it: a number naming the kind of attribute or type, then its fields, with
other entries written as their indices in `tbl` and a string attribute's text
as its index in `st`. An `EAsmType` is instead its assembly text followed by
a zero byte.

An integer attribute's value is a single byte when its type is 8 bits wide or
less, and otherwise a zigzag-encoded varint. A dense array's elements are 8
bytes each, the low 32 bits of the value then four zero bytes, whatever the
element type. A float is written by `encodeAPFloat`.

A file location's name is looked up as a string attribute, and collection does
not add one for it, so it is written as -1 unless the same text is a string
attribute somewhere else.

-}
encodeEntry : StringTable -> AttrTypeTable -> Entry -> BE.Encoder
encodeEntry st tbl entry =
    case entry of
        EUnknownLoc ->
            encodeVarInt 15

        EFileLineColLoc name line col ->
            let
                filenameIdx =
                    attrIndex (StringAttr name) tbl
            in
            BE.sequence [ encodeVarInt 11, encodeVarInt filenameIdx, encodeVarInt line, encodeVarInt col ]

        EStringAttr s ->
            BE.sequence [ encodeVarInt 2, encodeOwnedString st s ]

        EIntegerAttr ty val ->
            let
                tyIdx =
                    typeIndex ty tbl

                width =
                    typeWidth ty

                apintEnc =
                    if width <= 8 then
                        BE.unsignedInt8 val

                    else
                        encodeSignedVarInt val
            in
            BE.sequence [ encodeVarInt 8, encodeVarInt tyIdx, apintEnc ]

        EFloatAttr f ty ->
            let
                tyIdx =
                    typeIndex ty tbl
            in
            BE.sequence [ encodeVarInt 9, encodeVarInt tyIdx, encodeAPFloat f ]

        ETypeAttr ty ->
            let
                tyIdx =
                    typeIndex ty tbl
            in
            BE.sequence [ encodeVarInt 6, encodeVarInt tyIdx ]

        EArrayAttr items ->
            let
                encodedItems =
                    items |> List.map (\item -> encodeVarInt (attrIndex item tbl))
            in
            BE.sequence (encodeVarInt 0 :: encodeVarInt (List.length items) :: encodedItems)

        EDenseArrayAttr ty vals ->
            let
                tyIdx =
                    typeIndex ty tbl

                numElements =
                    List.length vals

                blob =
                    BE.encode
                        (BE.sequence
                            (List.map
                                (\v ->
                                    BE.sequence
                                        [ BE.unsignedInt8 (Bitwise.and v 0xFF)
                                        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 8 v) 0xFF)
                                        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 16 v) 0xFF)
                                        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 24 v) 0xFF)
                                        , BE.unsignedInt8 0
                                        , BE.unsignedInt8 0
                                        , BE.unsignedInt8 0
                                        , BE.unsignedInt8 0
                                        ]
                                )
                                vals
                            )
                        )
            in
            BE.sequence
                [ encodeVarInt 17
                , encodeVarInt tyIdx
                , encodeVarInt numElements
                , encodeVarInt (Bytes.width blob)
                , BE.bytes blob
                ]

        ESymbolRefAttr s ->
            let
                strAttrIdx =
                    attrIndex (StringAttr s) tbl
            in
            BE.sequence [ encodeVarInt 4, encodeVarInt strAttrIdx ]

        EUnitAttr ->
            BE.sequence [ encodeVarInt 7 ]

        EDictAttr attrs ->
            let
                entries =
                    Dict.toList attrs

                encodedEntries =
                    entries
                        |> List.map
                            (\( key, val ) ->
                                BE.sequence
                                    [ encodeVarInt (attrIndex (StringAttr key) tbl)
                                    , encodeVarInt (attrIndex val tbl)
                                    ]
                            )
            in
            BE.sequence (encodeVarInt 1 :: encodeVarInt (List.length entries) :: encodedEntries)

        EIntegerType width ->
            BE.sequence [ encodeVarInt 0, encodeVarInt (Bitwise.shiftLeftBy 2 width) ]

        EFloat64Type ->
            encodeVarInt 6

        EFunctionType inputs results ->
            let
                inputEncoders =
                    inputs |> List.map (\t -> encodeVarInt (typeIndex t tbl))

                resultEncoders =
                    results |> List.map (\t -> encodeVarInt (typeIndex t tbl))
            in
            BE.sequence
                (encodeVarInt 2
                    :: encodeVarInt (List.length inputs)
                    :: inputEncoders
                    ++ encodeVarInt (List.length results)
                    :: resultEncoders
                )

        EAsmType _ asm ->
            BE.sequence [ BE.string asm, BE.unsignedInt8 0x00 ]


{-| Creates an encoder that writes the index of `s` in the string table, or -1
if the table does not hold it.
-}
encodeOwnedString : StringTable -> String -> BE.Encoder
encodeOwnedString st s =
    encodeVarInt (StringTable.indexOf s st)


{-| Creates an encoder that writes `f` the way the builtin dialect's bytecode
holds a 64-bit float: the 64 bits of its IEEE 754 form, taken as a signed
integer, zigzag-encoded and written as a PrefixVarInt (as
`Mlir.Bytecode.VarInt` describes both).

An `Int` cannot hold every 64-bit integer exactly, so the zigzag step is done
on the two 32-bit halves of the bits, and the result is always written in the
9-byte form, which holds any 64-bit value.

-}
encodeAPFloat : Float -> BE.Encoder
encodeAPFloat f =
    let
        rawBytes =
            BE.encode (BE.float64 Bytes.LE f)

        decoder =
            BD.map2 Tuple.pair
                (BD.unsignedInt32 Bytes.LE)
                (BD.unsignedInt32 Bytes.LE)

        ( lo, hi ) =
            BD.decode decoder rawBytes
                |> Maybe.withDefault ( 0, 0 )

        -- Zigzag is (value << 1) ^ (value >> 63), and value >> 63 is all ones when the sign bit is set.
        signExtend =
            if Bitwise.and hi 0x80000000 /= 0 then
                0xFFFFFFFF

            else
                0

        shiftedLo =
            Bitwise.shiftLeftBy 1 lo

        -- The top bit of lo moves into hi.
        shiftedHi =
            Bitwise.or (Bitwise.shiftLeftBy 1 hi) (Bitwise.shiftRightZfBy 31 lo)

        zigLo =
            Bitwise.xor shiftedLo signExtend

        zigHi =
            Bitwise.xor shiftedHi signExtend
    in
    -- The 9-byte PrefixVarInt form: a zero byte, then the 8 bytes little-endian.
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


{-| Returns the width in bits of an integer or float type, and 64 for any other
type.
-}
typeWidth : MlirType -> Int
typeWidth ty =
    case ty of
        I1 ->
            1

        I8 ->
            8

        I16 ->
            16

        I32 ->
            32

        I64 ->
            64

        F64 ->
            64

        _ ->
            64
