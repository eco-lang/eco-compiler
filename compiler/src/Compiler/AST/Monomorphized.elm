module Compiler.AST.Monomorphized exposing
    ( AnnoCoverage
    , CallInfo
    , CallKind(..)
    , CallModel(..)
    , CaptureABI
    , ClosureInfo
    , ClosureKind(..)
    , ClosureKindId(..)
    , Constraint(..)
    , ContainerKind(..)
    , CtorShape
    , Decider(..)
    , Global(..)
    , LambdaId(..)
    , LambdaSetAnno(..)
    , LayoutMap
    , Literal(..)
    , MainInfo(..)
    , MaybeClosureKind
    , MemberOrigin(..)
    , MonoChoice(..)
    , MonoDef(..)
    , MonoDestructor(..)
    , MonoDtPath(..)
    , MonoExpr(..)
    , MonoGraph(..)
    , MonoNode(..)
    , MonoPath(..)
    , MonoType(..)
    , PortRegistration
    , Segmentation
    , SpecId
    , SpecKey(..)
    , SpecKeyMap
    , SpecMap
    , SpecializationRegistry
    , annoCoverage
    , annoCovers
    , buildSegmentedFunctionType
    , chooseCanonicalSegmentation
    , clearLssTables
    , collectAnnoMembers
    , containsAnyMVar
    , countTotalArity
    , decomposeFunctionType
    , defaultCallInfo
    , dtPathType
    , emptyAnnoCoverage
    , enrichAnnotations
    , enrichAnnotationsTopOnly
    , eqKeyLayout
    , eqKeySpec
    , eqLayout
    , eqModuloTopLabel
    , getMonoPathType
    , globalHash
    , hasTopAnno
    , hasVarAnno
    , headAnno
    , isFunctionType
    , isTopAnno
    , joinAnnotations
    , joinAnnotationsChanged
    , joinCollisionCells
    , layoutHashOf
    , layoutMapEmpty
    , layoutMapFoldl
    , layoutMapFromList
    , layoutMapGet
    , layoutMapInsert
    , layoutMapIsEmpty
    , layoutMapMap
    , layoutMapMember
    , layoutMapSize
    , layoutMapToList
    , layoutMapValues
    , mCustom
    , mFunction
    , mList
    , mRecord
    , mTuple
    , monoTypeToDebugString
    , nodeType
    , overlayAnnotations
    , recoverStoredSets
    , resolveNumberType
    , resultTypeOf
    , segmentLengths
    , shallowLayoutKey
    , singletonHeadMember
    , specHashOf
    , specKeyMapEmpty
    , specKeyMapGet
    , specKeyMapInsert
    , specKeyMapSize
    , specMapEmpty
    , specMapFoldl
    , specMapGet
    , specMapInsert
    , specMapIsEmpty
    , specMapMember
    , specMapRemove
    , specMapSingleton
    , specMapSize
    , specMapToList
    , specMapValues
    , stageParamTypes
    , stageReturnType
    , tkAbi
    , tkClassCall
    , tkClassCase
    , tkClassDestr
    , tkClassIf
    , tkClassLambda
    , tkClassLet
    , tkClassLit
    , tkClassLocal
    , tkClassMisc
    , tkClassParam
    , tkConflict
    , tkDeclOther
    , tkDeclStoreC
    , tkDeclStoreS
    , tkDeclZonk
    , tkEdge
    , tkLegacy
    , tkPoison
    , tkRow
    , tkSynth
    , tkWiden
    , toComparableGlobal
    , toComparableMonoType
    , topAbi
    , topClassCall
    , topClassCase
    , topClassDestr
    , topClassIf
    , topClassLambda
    , topClassLet
    , topClassLit
    , topClassLocal
    , topClassMisc
    , topClassParam
    , topConflict
    , topDeclOther
    , topDeclStoreC
    , topDeclStoreS
    , topDeclZonk
    , topEdge
    , topKindLabel
    , topLegacy
    , topOfKind
    , topPoison
    , topRow
    , topSynth
    , topWiden
    , typeHasResidualNumber
    , typeNodesWithin
    , typeOf
    , unionAnno
    , unionSortedInts
    , widenSets
    )

{-| The native back end compiles a program in which every definition the
program uses appears once for each type it is used at, and every value has a
type that fixes its runtime representation. This module defines that program,
the monomorphized IR, and the types it is written in.

A _specialization_ is one definition at one type. A monomorphizer, either
`Compiler.Monomorphize.Monomorphize` (the substitution engine) or
`Compiler.MonoSolver.Monomorphize` (the solver engine), numbers each one with a
`SpecId`, records it in the `SpecializationRegistry` under its `SpecKey`, and
stores its code as a `MonoNode` in the `MonoGraph`, at the SpecId's index of
the node array. Expressions (`MonoExpr`) refer to other specializations by
SpecId.

A `MonoType` is the type of a value at run time. It is specialized to the
types the program uses, but it is not always free of type variables. An
`MVar _ CEcoValue` is a variable whose value is always boxed, and it may reach
code generation. An `MVar _ CNumber` is a `number` variable that is not yet
decided. It must not reach code generation: `Compiler.Monomorphize.Prune`
closes each one to `MInt` with `resolveNumberType`.

Most of the file serves three ideas.

The first is keying. Many tables are keyed by `MonoType`, and building a
comparable string from a large type at every lookup is costly. Every composite
`MonoType` (a list, tuple, record, custom type or function) therefore carries a
_packed hash_ in its first field: two hashes, each in `[0, 2^26)`, packed as
layout hash times 2^26 plus spec hash. They are computed from the children's
hashes when the type is built, so a composite must be built with `mList`,
`mTuple`, `mRecord`, `mCustom` or `mFunction`. The constructors are exposed,
so nothing prevents a hand-built `MList 0 t`, which carries a wrong hash and is
silently missed by every hash-keyed map. There are two keys on `MonoType`. The
_spec key_ (`eqKeySpec`, `specHashOf`, `toComparableMonoType`, and the
`SpecMap` and `SpecKeyMap` maps) tells arrows apart by their lambda sets. The
_layout key_ (`eqKeyLayout`, `layoutHashOf`, and the `LayoutMap` maps)
ignores lambda sets. Both keys treat `MVar _ CNumber` as `MInt`, treat every
`MVar _ CEcoValue` alike whatever its id, and ignore a ⊤'s provenance code.
Types with equal keys have equal hashes, but not the other way round, so every
hash hit is confirmed with the key equality. `==` is finer than either key.

The second is lambda sets. Every arrow of a function type carries a
`LambdaSetAnno` saying which function values can flow through it, so that a
call through an arrow known to carry one function can be made directly. The
annotations form a lattice, described on `LambdaSetAnno`; this module has its
join (`unionAnno`, `joinAnnotations`, `joinAnnotationsChanged`), its widening
to ⊤ (`widenSets`), merges that copy annotations from one type onto another of
the same shape (`overlayAnnotations`, `enrichAnnotations`,
`recoverStoredSets`), and helpers that count annotations for reports.

The third is function staging. A curried function type is a chain of
`MFunction`s, each taking one or more arguments. A _segmentation_ lists how
many arguments each stage takes, so `\a b -> \c -> e` has segmentation
`[2, 1]`. The helpers near the end of the file read and rebuild
segmentations, and `CallInfo` records on each `MonoCall` how the call is to be
made.

-}

import Array exposing (Array)
import Char
import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.TypeIds as TypeIds exposing (MVarId)
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation exposing (Region)
import Data.HashMap as HashMap
import Dict exposing (Dict)
import Eco.Hash



-- ============================================================================
-- ====== MONOMORPHIC TYPES ======
-- ============================================================================


{-| The type of a value at run time, after monomorphization.

`MInt`, `MFloat`, `MBool`, `MChar`, `MString` and `MUnit` are the built-in
types of those names.

`MList`, `MTuple`, `MRecord`, `MCustom` and `MFunction` are the composite
types. The `Int` each carries first is its packed hash, described in the
module docstring, and is correct only in a type built with the matching smart
constructor (`mList`, `mTuple`, `mRecord`, `mCustom`, `mFunction`).

`MTuple` carries its element types in order. `MRecord` carries its field types
by name; it says nothing about the order or layout of the fields at run time,
which code generation decides. `MCustom` carries the type's home module, its
name and its type arguments.

`MFunction` is one stage of a function: it takes all of its argument types at
once and returns its result type, which may be another `MFunction`. Its
`LambdaSetAnno` says which function values can flow through this arrow.
Monomorphization gives each source arrow one argument, so `a -> b -> c` is
`MFunction _ _ [ a ] (MFunction _ _ [ b ] c)`; later passes may regroup the
arguments into fewer, wider stages.

`MVar` is a type variable that monomorphization left open, with a
`Constraint` that says what it may stand for. Its `MVarId` is a program-wide
type-variable id (`Compiler.AST.TypeIds`).

-}
type MonoType
    = MInt
    | MFloat
    | MBool
    | MChar
    | MString
    | MUnit
    | MList Int MonoType
    | MTuple Int (List MonoType)
    | MRecord Int (Dict Name MonoType)
    | MCustom Int ModuleName.Canonical Name (List MonoType)
    | MFunction Int LambdaSetAnno (List MonoType) MonoType
    | MVar MVarId Constraint


{-| What an open type variable in a `MonoType` may stand for, which decides
whether it may reach code generation.

`CEcoValue` marks a variable not known to be a number. Its value is always
boxed, so its type does not change the layout of anything that holds it, and
it may reach code generation, which treats it as a boxed value. A variable
constrained to `comparable`, `appendable` or `compappend` is also
`CEcoValue`.

`CNumber` marks a `number` variable that has not yet been decided between
`Int` and `Float`. It must not reach code generation.
`Compiler.Monomorphize.Prune` closes every one it finds to `MInt` with
`resolveNumberType`, along with any `CEcoValue` variable that was found to be
a number after it was stamped, and crashes if one survives. Nothing during
specialization defaults it.

-}
type Constraint
    = CEcoValue
    | CNumber



-- ============================================================================
-- ====== STRUCTURAL HASHES AND SMART CONSTRUCTORS ======
-- ============================================================================


{-| The bound of each of the two hashes a composite `MonoType` carries, 2^26.
Both hashes are in `[0, hashBase)`, so two of them pack into one number below
2^52, which a JavaScript number and a 64-bit integer both hold exactly.
-}
hashBase : Int
hashBase =
    67108864


{-| Packs a layout hash and a spec hash into the one number a composite
`MonoType` carries: `layoutH * hashBase + specH`. Both must be in
`[0, hashBase)` for `layoutHashOf` and `specHashOf` to recover them.
-}
packHashes : Int -> Int -> Int
packHashes layoutH specH =
    layoutH * hashBase + specH


{-| Returns hash `h` with `x` mixed into it, in `[0, hashBase)`. `x` may be any
`Int`, including a negative one.
-}
mixHash : Int -> Int -> Int
mixHash h x =
    modBy hashBase (h * 33 + modBy hashBase x + 7)


{-| Returns the layout hash of a type: the hash of its layout key, which
ignores lambda sets. Types equal under `eqKeyLayout` have equal layout hashes.

For a composite type it is the upper half of the packed hash; for any other
type it is a small number standing for the leaf, as `leafKeyTag` gives.

-}
layoutHashOf : MonoType -> Int
layoutHashOf mt =
    case mt of
        MList h _ ->
            h // hashBase

        MTuple h _ ->
            h // hashBase

        MRecord h _ ->
            h // hashBase

        MCustom h _ _ _ ->
            h // hashBase

        MFunction h _ _ _ ->
            h // hashBase

        _ ->
            leafKeyTag mt


{-| Returns the spec hash of a type: the hash of its spec key, which tells
arrows apart by their lambda sets. Types equal under `eqKeySpec` have equal
spec hashes.

For a composite type it is the lower half of the packed hash; for any other
type it is the same leaf number `layoutHashOf` gives.

-}
specHashOf : MonoType -> Int
specHashOf mt =
    case mt of
        MList h _ ->
            modBy hashBase h

        MTuple h _ ->
            modBy hashBase h

        MRecord h _ ->
            modBy hashBase h

        MCustom h _ _ _ ->
            modBy hashBase h

        MFunction h _ _ _ ->
            modBy hashBase h

        _ ->
            leafKeyTag mt


{-| Returns a number from 1 to 7 standing for a leaf type in both keys, or 0
for a composite type.

It makes the same two merges as the keys: `MVar _ CNumber` gets the number of
`MInt`, and every `MVar _ CEcoValue` gets the same number whatever its id.

-}
leafKeyTag : MonoType -> Int
leafKeyTag mt =
    case mt of
        MInt ->
            1

        MFloat ->
            2

        MBool ->
            3

        MChar ->
            4

        MString ->
            5

        MUnit ->
            6

        MVar _ constraint ->
            case constraint of
                CEcoValue ->
                    7

                CNumber ->
                    1

        _ ->
            0


{-| Returns the hash of an arrow's annotation, which `mFunction` mixes into
the spec hash.

It must never separate two annotations that the spec key treats as one
(`toComparableFragments`, `annoKeyEq`). If it did, two types with one key would
land in different buckets of a spec-keyed map, the key equality would never
compare them, and the map would hold two entries for one key. Nothing in the
types catches this. Merging two annotations that the key separates costs only a
bucket collision.

So every ⊤ hashes alike, whatever its provenance code; `LVar n` hashes by `n`,
not as ⊤; and `LPartial xs` hashes as `LSet xs`.

-}
annoHash : LambdaSetAnno -> Int
annoHash anno =
    case anno of
        LTop _ ->
            3

        LVar n ->
            mixHash 17 n

        LSet members ->
            List.foldl (\m h -> mixHash h m) 5 members

        LPartial members ->
            List.foldl (\m h -> mixHash h m) 5 members


{-| Builds the list type of `inner`, with its packed hash.
-}
mList : MonoType -> MonoType
mList inner =
    MList
        (packHashes (mixHash 11 (layoutHashOf inner)) (mixHash 11 (specHashOf inner)))
        inner


{-| Builds the tuple type of `elementTypes`, with its packed hash.
-}
mTuple : List MonoType -> MonoType
mTuple elementTypes =
    let
        seed =
            mixHash 12 (List.length elementTypes)
    in
    MTuple
        (packHashes
            (List.foldl (\t h -> mixHash h (layoutHashOf t)) seed elementTypes)
            (List.foldl (\t h -> mixHash h (specHashOf t)) seed elementTypes)
        )
        elementTypes


{-| Builds the record type with `fields`, with its packed hash. Only the
length of each field name enters the hash; the key equalities compare the
names themselves.
-}
mRecord : Dict Name MonoType -> MonoType
mRecord fields =
    let
        seed =
            mixHash 13 (Dict.size fields)

        fold hashOf =
            Dict.foldl
                (\name t h -> mixHash (mixHash h (String.length name)) (hashOf t))
                seed
                fields
    in
    MRecord (packHashes (fold layoutHashOf) (fold specHashOf)) fields


{-| Builds the custom type `name` from module `canonical`, applied to `args`,
with its packed hash.

Only the lengths of the author, project, module and type names enter the hash,
so that building a type never walks a string. Two types whose names have the
same lengths share a bucket, and the key equalities, which compare the names,
tell them apart.

-}
mCustom : ModuleName.Canonical -> Name -> List MonoType -> MonoType
mCustom canonical name args =
    let
        (ModuleName.Canonical ( author, project ) modName) =
            canonical

        seed =
            mixHash
                (mixHash
                    (mixHash (mixHash (mixHash 14 (String.length name)) (String.length modName))
                        (String.length project)
                    )
                    (String.length author)
                )
                (List.length args)
    in
    MCustom
        (packHashes
            (List.foldl (\t h -> mixHash h (layoutHashOf t)) seed args)
            (List.foldl (\t h -> mixHash h (specHashOf t)) seed args)
        )
        canonical
        name
        args


{-| Builds the function stage that takes `args` and returns `ret`, with lambda
set `anno` on its arrow, and with its packed hash. `anno` enters the spec hash
only, so two arrows that differ only in their lambda sets have the same layout
hash.
-}
mFunction : LambdaSetAnno -> List MonoType -> MonoType -> MonoType
mFunction anno args ret =
    let
        arity =
            mixHash 15 (List.length args)

        layoutSeed =
            mixHash arity (layoutHashOf ret)

        specSeed =
            mixHash (mixHash arity (specHashOf ret)) (annoHash anno)
    in
    MFunction
        (packHashes
            (List.foldl (\t h -> mixHash h (layoutHashOf t)) layoutSeed args)
            (List.foldl (\t h -> mixHash h (specHashOf t)) specSeed args)
        )
        anno
        args
        ret


{-| Returns whether two types have the same spec key, the key that tells arrows
apart by their lambda sets. It builds nothing and stops at the first
difference, and it is what confirms a hit in a spec-keyed map.

It is meant to agree with comparing `toComparableMonoType` strings, and it
does except in two cases. An `LPartial` arrow in a pair of types that are not
`==` matches neither an equal `LPartial` nor the `LSet` with the same members,
because `annoKeyEq` has no `LPartial` case, although the string and the hash
treat all three alike. And two different record types can share a string,
because the string runs field names and field types together (`{ bIaUb : Int }`
and `{ b : Int, bIa : () }` both give `R(bIaUbI)`); `eqKeySpec` tells them
apart.

-}
eqKeySpec : MonoType -> MonoType -> Bool
eqKeySpec a b =
    identicalOr True a b


{-| Returns whether two types have the same layout key, the key that ignores
lambda sets. It is what confirms a hit in a layout-keyed map.

`eqLayout` also ignores lambda sets but is finer than this: it compares leaves
with `==`, so it tells apart `MVar` ids, and `MVar _ CNumber` from `MInt`,
which the key treats as one.

-}
eqKeyLayout : MonoType -> MonoType -> Bool
eqKeyLayout a b =
    identicalOr False a b


{-| Returns whether two types have the same key, trying `a == b` before the
walk in `eqKeyWith`. `annoSensitive` chooses the spec key (`True`) or the
layout key (`False`).

Two `==` types have the same key, because `==` is finer than either key. The
test is made once, here, and not at every level of the walk, so a pair that
differs pays for one `==` and one walk.

-}
identicalOr : Bool -> MonoType -> MonoType -> Bool
identicalOr annoSensitive a b =
    (a == b) || eqKeyWith annoSensitive a b


{-| Returns whether two types have the same key, by walking both. Composite
types match when their constructors, names and children match; arrows also
need equal annotations under `annoKeyEq` when `annoSensitive` is `True`; leaves
match when `leafKeyTag` gives them the same non-zero number.
-}
eqKeyWith : Bool -> MonoType -> MonoType -> Bool
eqKeyWith annoSensitive a b =
    case ( a, b ) of
        ( MList _ xa, MList _ xb ) ->
            eqKeyWith annoSensitive xa xb

        ( MTuple _ xsa, MTuple _ xsb ) ->
            eqKeyList annoSensitive xsa xsb

        ( MRecord _ fieldsA, MRecord _ fieldsB ) ->
            eqFieldsBy (eqKeyWith annoSensitive) fieldsA fieldsB

        ( MCustom _ homeA nameA argsA, MCustom _ homeB nameB argsB ) ->
            nameA == nameB && homeA == homeB && eqKeyList annoSensitive argsA argsB

        ( MFunction _ annoA argsA retA, MFunction _ annoB argsB retB ) ->
            (not annoSensitive || annoKeyEq annoA annoB)
                && eqKeyList annoSensitive argsA argsB
                && eqKeyWith annoSensitive retA retB

        _ ->
            let
                tagA =
                    leafKeyTag a
            in
            tagA /= 0 && tagA == leafKeyTag b


{-| Returns whether two arrow annotations are the same in the spec key. Any ⊤
matches any ⊤, whatever the provenance codes; `LVar i` matches only `LVar i`;
`LSet xs` matches only `LSet xs`.

It is meant to decide exactly what `toComparableFragments` and `annoHash`
decide, but it has no `LPartial` case: it returns `False` for any pair that
includes an `LPartial`, even `LPartial xs` against itself or against `LSet xs`,
which the string key and the hash treat as equal.

-}
annoKeyEq : LambdaSetAnno -> LambdaSetAnno -> Bool
annoKeyEq a b =
    case ( a, b ) of
        ( LSet xs, LSet ys ) ->
            xs == ys

        ( LVar i, LVar j ) ->
            i == j

        ( LTop _, LTop _ ) ->
            True

        _ ->
            False


{-| Returns whether two type lists have the same length and the same key at
each position, as `eqKeyWith` decides it.
-}
eqKeyList : Bool -> List MonoType -> List MonoType -> Bool
eqKeyList annoSensitive xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: restX, y :: restY ) ->
            eqKeyWith annoSensitive x y && eqKeyList annoSensitive restX restY

        _ ->
            False


{-| Returns whether two record field maps have the same field names, with the
field types under each name equal under `eq`. It looks each field of
`fieldsA` up in `fieldsB` and builds no list.

The size test is needed: the lookups only show that the names of `fieldsA` are
among those of `fieldsB`, and equal sizes make the two sets of names the same.

-}
eqFieldsBy : (MonoType -> MonoType -> Bool) -> Dict Name MonoType -> Dict Name MonoType -> Bool
eqFieldsBy eq fieldsA fieldsB =
    (Dict.size fieldsA == Dict.size fieldsB)
        && Dict.foldl
            (\name ta ok ->
                ok
                    && (case Dict.get name fieldsB of
                            Just tb ->
                                eq ta tb

                            Nothing ->
                                False
                       )
            )
            True
            fieldsA



-- ============================================================================
-- ====== HASH-KEYED MONOTYPE MAPS ======
-- ============================================================================


{-| A table keyed by `MonoType` under the layout key, which ignores lambda sets:
two types that differ only in the annotations on their arrows are one key.

`LayoutMap` and `SpecMap` are both names for the same `HashMap`, so the
compiler accepts either where the other is expected. A map is only correct if
it is built and read with one family of functions, `layoutMap*` here or
`specMap*`: reading a layout-keyed map with `specMapGet` hashes by the wrong
key and can miss an entry that is there. Nothing catches the mix-up. The two
hashes agree only for types with no arrow, so the mix-up shows as soon as a key
contains a function type.

-}
type alias LayoutMap v =
    HashMap.HashMap MonoType v


{-| A table keyed by `MonoType` under the spec key, which tells arrows apart by
their lambda sets, as `toComparableMonoType` does. Build and read it with the
`specMap*` functions only; see `LayoutMap` for why the two families must not
be mixed.
-}
type alias SpecMap v =
    HashMap.HashMap MonoType v


{-| An empty layout-keyed map.
-}
layoutMapEmpty : LayoutMap v
layoutMapEmpty =
    HashMap.empty


{-| Returns the value stored under the layout key of `key`, if any.
-}
layoutMapGet : MonoType -> LayoutMap v -> Maybe v
layoutMapGet key m =
    HashMap.get layoutHashOf eqKeyLayout key m


{-| Returns whether a value is stored under the layout key of `key`.
-}
layoutMapMember : MonoType -> LayoutMap v -> Bool
layoutMapMember key m =
    HashMap.member layoutHashOf eqKeyLayout key m


{-| Returns the map with `value` stored under the layout key of `key`, replacing
any value already there.
-}
layoutMapInsert : MonoType -> v -> LayoutMap v -> LayoutMap v
layoutMapInsert key value m =
    HashMap.insert layoutHashOf eqKeyLayout key value m


{-| Returns the number of entries in a layout-keyed map.
-}
layoutMapSize : LayoutMap v -> Int
layoutMapSize m =
    HashMap.size m


{-| Returns whether a layout-keyed map has no entries.
-}
layoutMapIsEmpty : LayoutMap v -> Bool
layoutMapIsEmpty m =
    HashMap.isEmpty m


{-| Folds `step` over the entries of a layout-keyed map, in insertion order, a
key removed and inserted again counting as new.
-}
layoutMapFoldl : (MonoType -> v -> b -> b) -> b -> LayoutMap v -> b
layoutMapFoldl step init m =
    HashMap.foldl step init m


{-| Returns the map with each value replaced by `f` of its key and value.
-}
layoutMapMap : (MonoType -> a -> b) -> LayoutMap a -> LayoutMap b
layoutMapMap f m =
    HashMap.map f m


{-| Returns the entries of a layout-keyed map, in insertion order, a key
removed and inserted again counting as new.
-}
layoutMapToList : LayoutMap v -> List ( MonoType, v )
layoutMapToList m =
    HashMap.toList m


{-| Returns the values of a layout-keyed map, in insertion order, a key
removed and inserted again counting as new.
-}
layoutMapValues : LayoutMap v -> List v
layoutMapValues m =
    HashMap.values m


{-| Builds a layout-keyed map from `entries`. Where two entries have the same
layout key, the later value is kept.
-}
layoutMapFromList : List ( MonoType, v ) -> LayoutMap v
layoutMapFromList entries =
    HashMap.fromList layoutHashOf eqKeyLayout entries


{-| Returns a hash of a global, for tables keyed by globals. Equal globals have
equal hashes.

The definition or field name is hashed character by character; the module's
author, project and module name enter only by their lengths, so building the
hash walks one short string.

-}
globalHash : Global -> Int
globalHash g =
    case g of
        Global (ModuleName.Canonical ( author, project ) modName) name ->
            mixHash
                (mixHash
                    (mixHash (mixHash 21 (String.length author)) (String.length project))
                    (String.length modName)
                )
                (stringHash name)

        Accessor name ->
            mixHash 22 (stringHash name)


{-| Returns the narrow hash of `s` from `Eco.Hash.stringWithSeed`, with seed 23.
-}
stringHash : String -> Int
stringHash s =
    Eco.Hash.stringWithSeed 23 s


{-| A table keyed by `SpecKey`. Two keys are the same entry when their globals are
`==` and their types have the same spec key, so two arrows that differ only in
their lambda sets give different entries. It is a name for `HashMap`, and only
the `specKeyMap*` functions hash and compare keys this way.
-}
type alias SpecKeyMap v =
    HashMap.HashMap SpecKey v


{-| Returns the hash of a `SpecKey`, from the hash of its global and the spec hash
of its type.
-}
specKeyHash : SpecKey -> Int
specKeyHash (SpecKey global monoType) =
    mixHash (globalHash global) (specHashOf monoType)


{-| Returns whether two `SpecKey`s are the same entry of a `SpecKeyMap`.
-}
specKeyEq : SpecKey -> SpecKey -> Bool
specKeyEq (SpecKey g1 t1) (SpecKey g2 t2) =
    g1 == g2 && eqKeySpec t1 t2


{-| An empty map keyed by `SpecKey`.
-}
specKeyMapEmpty : SpecKeyMap v
specKeyMapEmpty =
    HashMap.empty


{-| Returns the value stored under `key`, if any.
-}
specKeyMapGet : SpecKey -> SpecKeyMap v -> Maybe v
specKeyMapGet key m =
    HashMap.get specKeyHash specKeyEq key m


{-| Returns the map with `value` stored under `key`, replacing any value already
there.
-}
specKeyMapInsert : SpecKey -> v -> SpecKeyMap v -> SpecKeyMap v
specKeyMapInsert key value m =
    HashMap.insert specKeyHash specKeyEq key value m


{-| Returns the number of entries in a map keyed by `SpecKey`.
-}
specKeyMapSize : SpecKeyMap v -> Int
specKeyMapSize m =
    HashMap.size m


{-| An empty spec-keyed map.
-}
specMapEmpty : SpecMap v
specMapEmpty =
    HashMap.empty


{-| Returns the value stored under the spec key of `key`, if any.
-}
specMapGet : MonoType -> SpecMap v -> Maybe v
specMapGet key m =
    HashMap.get specHashOf eqKeySpec key m


{-| Returns whether a value is stored under the spec key of `key`.
-}
specMapMember : MonoType -> SpecMap v -> Bool
specMapMember key m =
    HashMap.member specHashOf eqKeySpec key m


{-| Returns the map with `value` stored under the spec key of `key`, replacing any
value already there.
-}
specMapInsert : MonoType -> v -> SpecMap v -> SpecMap v
specMapInsert key value m =
    HashMap.insert specHashOf eqKeySpec key value m


{-| Returns the number of entries in a spec-keyed map.
-}
specMapSize : SpecMap v -> Int
specMapSize m =
    HashMap.size m


{-| Returns whether a spec-keyed map has no entries.
-}
specMapIsEmpty : SpecMap v -> Bool
specMapIsEmpty m =
    HashMap.isEmpty m


{-| Folds `step` over the entries of a spec-keyed map, in insertion order, a key
removed and inserted again counting as new.
-}
specMapFoldl : (MonoType -> v -> b -> b) -> b -> SpecMap v -> b
specMapFoldl step init m =
    HashMap.foldl step init m


{-| Returns the map without the entry stored under the spec key of `key`.
-}
specMapRemove : MonoType -> SpecMap v -> SpecMap v
specMapRemove key m =
    HashMap.remove specHashOf eqKeySpec key m


{-| Builds a spec-keyed map holding one entry.
-}
specMapSingleton : MonoType -> v -> SpecMap v
specMapSingleton key value =
    specMapInsert key value specMapEmpty


{-| Returns the entries of a spec-keyed map, in insertion order, a key
removed and inserted again counting as new.
-}
specMapToList : SpecMap v -> List ( MonoType, v )
specMapToList m =
    HashMap.toList m


{-| Returns the values of a spec-keyed map, in insertion order, a key
removed and inserted again counting as new.
-}
specMapValues : SpecMap v -> List v
specMapValues m =
    HashMap.values m



-- ============================================================================
-- ====== LAMBDA SETS ======
-- ============================================================================


{-| The lambda set on one arrow of a function type: what is known about which
functions can be the value that flows through it.

A _member_ is a number standing for one function: a lambda, or something
`MemberOrigin` describes, such as a global or a constructor used as a value.
The four forms say how much is known about the members of an arrow.

`LTop` is ⊤: the set is not known, and any function may flow through the arrow.
Its `Int` is a _provenance code_ (`tkPoison` and the constants after it) saying
why. The code is for counting only: the spec key, `annoHash`, `annoKeyEq`,
`annoCovers` and `eqModuloTopLabel` all ignore it, though `==` does not.

`LVar` is a set variable: a set that has not been decided yet. Its number
identifies the variable within the enclosing `MonoType`, so two arrows of one
type with the same number share one set, and the spec key keeps the number, so
`(α → α)` and `(α → β)` are different keys. It is never the same key as ⊤.

`LSet` is a complete set: no function outside it can flow through the arrow.
It may still name a function that never reaches this particular arrow, since
sets are joined where several uses share one specialization. Its members are
kept in ascending order without duplicates.

`LPartial` is a lower bound: these members can flow through the arrow, and so
may others. `unionAnno` makes one where a complete set meets a set variable.
No join (`unionAnno`, `joinAnnotations`) and no `enrichAnnotations` merge turns
an `LPartial` back into an `LSet`; `overlayAnnotations` replaces it with
whatever the source holds. `singletonHeadMember` never treats one as a single
known function. The spec key and `annoHash` treat `LPartial xs` as `LSet xs`;
`annoKeyEq` does not (see `eqKeySpec`).

-}
type LambdaSetAnno
    = LTop Int
    | LVar Int
    | LSet (List Int)
    | LPartial (List Int)


{-| The ⊤ provenance code 0, labelled `poison`.

Each `tk*` constant is one provenance code, and `topKindLabel` gives the label
reports print for it. Where two ⊤s are joined, `unionAnno` keeps the lower
code, and `topOfKind` reads any code at or below 0 as this one.

-}
tkPoison : Int
tkPoison =
    0


{-| The ⊤ provenance code 1, labelled `conflict`. `unionAnno` gives it where two
different set variables meet.
-}
tkConflict : Int
tkConflict =
    1


{-| The ⊤ provenance code 2, labelled `widen`. `widenSets` puts it on every arrow.
-}
tkWiden : Int
tkWiden =
    2


{-| The ⊤ provenance code 3, labelled `edge`.
-}
tkEdge : Int
tkEdge =
    3


{-| The ⊤ provenance code 4, labelled `abi`.
-}
tkAbi : Int
tkAbi =
    4


{-| The ⊤ provenance code 5, labelled `declZonk`.

Codes 5 to 8 mark a ⊤ placed on the arrows of a declaration's type, and tell
apart the code paths that placed it.

-}
tkDeclZonk : Int
tkDeclZonk =
    5


{-| The ⊤ provenance code 6, labelled `declStoreC`.
-}
tkDeclStoreC : Int
tkDeclStoreC =
    6


{-| The ⊤ provenance code 7, labelled `declStoreS`.
-}
tkDeclStoreS : Int
tkDeclStoreS =
    7


{-| The ⊤ provenance code 8, labelled `declOther`.
-}
tkDeclOther : Int
tkDeclOther =
    8


{-| The ⊤ provenance code 9, labelled `synth`.
-}
tkSynth : Int
tkSynth =
    9


{-| The ⊤ provenance code 10, labelled `legacy`. `normalizeTopLabels` gives every
⊤ and every set variable this code, `headAnno` returns it for a type that is
not a function, and `topOfKind` reads any code it does not know as this one.
-}
tkLegacy : Int
tkLegacy =
    10


{-| The ⊤ provenance code 11, labelled `clsCase`.

Codes 11 to 20 mark a ⊤ placed by a type classifier, and tell apart the kind
of expression it was classifying: a case, an if, a local, a literal, a
parameter, a destructuring, a lambda, a call, a let, or anything else.

-}
tkClassCase : Int
tkClassCase =
    11


{-| The ⊤ provenance code 12, labelled `clsIf`.
-}
tkClassIf : Int
tkClassIf =
    12


{-| The ⊤ provenance code 13, labelled `clsLocal`.
-}
tkClassLocal : Int
tkClassLocal =
    13


{-| The ⊤ provenance code 14, labelled `clsLit`.
-}
tkClassLit : Int
tkClassLit =
    14


{-| The ⊤ provenance code 15, labelled `clsParam`.
-}
tkClassParam : Int
tkClassParam =
    15


{-| The ⊤ provenance code 16, labelled `clsDestr`.
-}
tkClassDestr : Int
tkClassDestr =
    16


{-| The ⊤ provenance code 17, labelled `clsLambda`.
-}
tkClassLambda : Int
tkClassLambda =
    17


{-| The ⊤ provenance code 18, labelled `clsCall`.
-}
tkClassCall : Int
tkClassCall =
    18


{-| The ⊤ provenance code 19, labelled `clsLet`.
-}
tkClassLet : Int
tkClassLet =
    19


{-| The ⊤ provenance code 20, labelled `clsMisc`.
-}
tkClassMisc : Int
tkClassMisc =
    20


{-| The ⊤ provenance code 21, labelled `row`.
-}
tkRow : Int
tkRow =
    21


{-| The ⊤ with provenance code `tkPoison`. Each `top*` constant is the ⊤ with the
matching `tk*` code, built once so that writing a ⊤ need not build a new one.
-}
topPoison : LambdaSetAnno
topPoison =
    LTop 0


{-| The ⊤ with provenance code `tkConflict`.
-}
topConflict : LambdaSetAnno
topConflict =
    LTop 1


{-| The ⊤ with provenance code `tkWiden`.
-}
topWiden : LambdaSetAnno
topWiden =
    LTop 2


{-| The ⊤ with provenance code `tkEdge`.
-}
topEdge : LambdaSetAnno
topEdge =
    LTop 3


{-| The ⊤ with provenance code `tkAbi`.
-}
topAbi : LambdaSetAnno
topAbi =
    LTop 4


{-| The ⊤ with provenance code `tkDeclZonk`.
-}
topDeclZonk : LambdaSetAnno
topDeclZonk =
    LTop 5


{-| The ⊤ with provenance code `tkDeclStoreC`.
-}
topDeclStoreC : LambdaSetAnno
topDeclStoreC =
    LTop 6


{-| The ⊤ with provenance code `tkDeclStoreS`.
-}
topDeclStoreS : LambdaSetAnno
topDeclStoreS =
    LTop 7


{-| The ⊤ with provenance code `tkDeclOther`.
-}
topDeclOther : LambdaSetAnno
topDeclOther =
    LTop 8


{-| The ⊤ with provenance code `tkSynth`.
-}
topSynth : LambdaSetAnno
topSynth =
    LTop 9


{-| The ⊤ with provenance code `tkLegacy`.
-}
topLegacy : LambdaSetAnno
topLegacy =
    LTop 10


{-| The ⊤ with provenance code `tkClassCase`.
-}
topClassCase : LambdaSetAnno
topClassCase =
    LTop 11


{-| The ⊤ with provenance code `tkClassIf`.
-}
topClassIf : LambdaSetAnno
topClassIf =
    LTop 12


{-| The ⊤ with provenance code `tkClassLocal`.
-}
topClassLocal : LambdaSetAnno
topClassLocal =
    LTop 13


{-| The ⊤ with provenance code `tkClassLit`.
-}
topClassLit : LambdaSetAnno
topClassLit =
    LTop 14


{-| The ⊤ with provenance code `tkClassParam`.
-}
topClassParam : LambdaSetAnno
topClassParam =
    LTop 15


{-| The ⊤ with provenance code `tkClassDestr`.
-}
topClassDestr : LambdaSetAnno
topClassDestr =
    LTop 16


{-| The ⊤ with provenance code `tkClassLambda`.
-}
topClassLambda : LambdaSetAnno
topClassLambda =
    LTop 17


{-| The ⊤ with provenance code `tkClassCall`.
-}
topClassCall : LambdaSetAnno
topClassCall =
    LTop 18


{-| The ⊤ with provenance code `tkClassLet`.
-}
topClassLet : LambdaSetAnno
topClassLet =
    LTop 19


{-| The ⊤ with provenance code `tkClassMisc`.
-}
topClassMisc : LambdaSetAnno
topClassMisc =
    LTop 20


{-| The ⊤ with provenance code `tkRow`.
-}
topRow : LambdaSetAnno
topRow =
    LTop 21


{-| Returns whether an annotation is ⊤, whatever its provenance code.
-}
isTopAnno : LambdaSetAnno -> Bool
isTopAnno anno =
    case anno of
        LTop _ ->
            True

        _ ->
            False


{-| Returns the shared ⊤ with provenance code `k`. A code at or below 0 gives
`topPoison`, and a code above 21 gives `topLegacy`.
-}
topOfKind : Int -> LambdaSetAnno
topOfKind k =
    if k <= 0 then
        topPoison

    else if k == 1 then
        topConflict

    else if k == 2 then
        topWiden

    else if k == 3 then
        topEdge

    else if k == 4 then
        topAbi

    else if k == 5 then
        topDeclZonk

    else if k == 6 then
        topDeclStoreC

    else if k == 7 then
        topDeclStoreS

    else if k == 8 then
        topDeclOther

    else if k == 9 then
        topSynth

    else if k == 11 then
        topClassCase

    else if k == 12 then
        topClassIf

    else if k == 13 then
        topClassLocal

    else if k == 14 then
        topClassLit

    else if k == 15 then
        topClassParam

    else if k == 16 then
        topClassDestr

    else if k == 17 then
        topClassLambda

    else if k == 18 then
        topClassCall

    else if k == 19 then
        topClassLet

    else if k == 20 then
        topClassMisc

    else if k == 21 then
        topRow

    else
        topLegacy


{-| Returns the label reports print for provenance code `k`. A code at or below 0
is `"poison"`, and a code above 21 is `"legacy"`.
-}
topKindLabel : Int -> String
topKindLabel k =
    if k <= 0 then
        "poison"

    else if k == 1 then
        "conflict"

    else if k == 2 then
        "widen"

    else if k == 3 then
        "edge"

    else if k == 4 then
        "abi"

    else if k == 5 then
        "declZonk"

    else if k == 6 then
        "declStoreC"

    else if k == 7 then
        "declStoreS"

    else if k == 8 then
        "declOther"

    else if k == 9 then
        "synth"

    else if k == 11 then
        "clsCase"

    else if k == 12 then
        "clsIf"

    else if k == 13 then
        "clsLocal"

    else if k == 14 then
        "clsLit"

    else if k == 15 then
        "clsParam"

    else if k == 16 then
        "clsDestr"

    else if k == 17 then
        "clsLambda"

    else if k == 18 then
        "clsCall"

    else if k == 19 then
        "clsLet"

    else if k == 20 then
        "clsMisc"

    else if k == 21 then
        "row"

    else
        "legacy"


{-| Returns whether `monoType` has at most `limit` nodes, counting each type
constructor once for every place it occurs, so a subtree that appears twice is
counted twice. The count stops as soon as it passes `limit`, so a large type
costs no more than `limit` steps.

A `limit` of 0 or less gives `False` for every type, even `MInt`. It is not a
way of switching the check off.

-}
typeNodesWithin : Int -> MonoType -> Bool
typeNodesWithin limit monoType =
    typeNodesGo monoType limit >= 0


{-| Returns what is left of `budget` after counting the nodes of `monoType`, or a
negative number once the budget runs out.
-}
typeNodesGo : MonoType -> Int -> Int
typeNodesGo monoType budget =
    if budget <= 0 then
        -1

    else
        case monoType of
            MFunction _ _ args result ->
                typeNodesGoList args (typeNodesGo result (budget - 1))

            MList _ inner ->
                typeNodesGo inner (budget - 1)

            MTuple _ elems ->
                typeNodesGoList elems (budget - 1)

            MRecord _ fields ->
                Dict.foldl (\_ t b -> typeNodesGoStep t b) (budget - 1) fields

            MCustom _ _ _ args ->
                typeNodesGoList args (budget - 1)

            _ ->
                budget - 1


{-| Returns `typeNodesGo t b`, or `b` unchanged when the budget is already
negative, so that the rest of a list or record is not walked.
-}
typeNodesGoStep : MonoType -> Int -> Int
typeNodesGoStep t b =
    if b < 0 then
        b

    else
        typeNodesGo t b


{-| Returns what is left of budget `b` after counting the nodes of every type in
`ts`.
-}
typeNodesGoList : List MonoType -> Int -> Int
typeNodesGoList ts b =
    List.foldl typeNodesGoStep b ts


{-| Returns the members named by every `LSet` and `LPartial` annotation in the
type, in no particular order and possibly with duplicates.
-}
collectAnnoMembers : MonoType -> List Int
collectAnnoMembers monoType =
    collectAnnoGo monoType []


{-| Returns `acc` with the members named in the type's `LSet` and `LPartial`
annotations added to it.
-}
collectAnnoGo : MonoType -> List Int -> List Int
collectAnnoGo monoType acc =
    case monoType of
        MFunction _ anno args result ->
            let
                acc1 =
                    case anno of
                        LSet ms ->
                            ms ++ acc

                        LTop _ ->
                            acc

                        LVar _ ->
                            acc

                        LPartial ms ->
                            ms ++ acc
            in
            List.foldl collectAnnoGo (collectAnnoGo result acc1) args

        MList _ inner ->
            collectAnnoGo inner acc

        MTuple _ elems ->
            List.foldl collectAnnoGo acc elems

        MRecord _ fields ->
            Dict.foldl (\_ t a -> collectAnnoGo t a) acc fields

        MCustom _ _ _ args ->
            List.foldl collectAnnoGo acc args

        _ ->
            acc


{-| Counts of a program's arrow annotations, by what they say about the lambda
set: `k1` one-member `LSet`s, `kN` larger `LSet`s, `var` set variables, `top`
⊤s and `part` `LPartial`s. It counts positions in types, one per arrow, not
how often an annotation is read.

`annoCoverage` never changes `row`.

-}
type alias AnnoCoverage =
    { k1 : Int, kN : Int, var : Int, top : Int, part : Int, row : Int }


{-| An `AnnoCoverage` with every count at zero.
-}
emptyAnnoCoverage : AnnoCoverage
emptyAnnoCoverage =
    { k1 = 0, kN = 0, var = 0, top = 0, part = 0, row = 0 }


{-| Returns `structural` with each arrow's annotation merged with the annotation
at the same position in `annoSource`, so that a set known on either side is
kept. The structure comes from `structural`, and where the two types differ in
shape (a different constructor, number of arguments, field names or custom
type), that part of `structural` is kept as it is.

With `s` the annotation in `structural` and `a` the one in `annoSource`:

    LSet xs,     LSet ys     -> LSet (xs ∪ ys)
    any LPartial with an LSet or LPartial
                             -> LPartial of the union
    LPartial xs, LVar or ⊤   -> LPartial xs
    LVar,        LPartial ys -> LPartial ys
    ⊤,           LPartial ys -> s, the ⊤
    LSet xs,     LVar or ⊤   -> LSet xs
    LVar or ⊤,   LSet ys     -> LSet ys
    otherwise                -> s

Unlike `unionAnno`, a ⊤ does not absorb a set here, and a set does not become
an `LPartial` by meeting a set variable.

-}
enrichAnnotations : MonoType -> MonoType -> MonoType
enrichAnnotations =
    enrichAnnotationsWith enrichAnno


{-| Returns what `enrichAnnotations` returns, except that an `LVar` in `structural`
is kept whatever `annoSource` holds there. Members are therefore written only
onto an arrow that already had a set, an `LPartial` or ⊤, never onto an `LVar`.
-}
enrichAnnotationsTopOnly : MonoType -> MonoType -> MonoType
enrichAnnotationsTopOnly =
    enrichAnnotationsWith
        (\a b ->
            case a of
                LVar _ ->
                    a

                _ ->
                    enrichAnno a b
        )


{-| Returns `structural` with each arrow's annotation replaced by `merge` of it and
the annotation at the same position in `annoSource`, walking the two types
together. Where their shapes differ, that part of `structural` is kept as it
is.
-}
enrichAnnotationsWith : (LambdaSetAnno -> LambdaSetAnno -> LambdaSetAnno) -> MonoType -> MonoType -> MonoType
enrichAnnotationsWith merge structural annoSource =
    case ( structural, annoSource ) of
        ( MFunction _ annoA argsA retA, MFunction _ annoB argsB retB ) ->
            if List.length argsA == List.length argsB then
                mFunction (merge annoA annoB)
                    (List.map2 (enrichAnnotationsWith merge) argsA argsB)
                    (enrichAnnotationsWith merge retA retB)

            else
                structural

        ( MList _ xa, MList _ xb ) ->
            mList (enrichAnnotationsWith merge xa xb)

        ( MTuple _ xsa, MTuple _ xsb ) ->
            if List.length xsa == List.length xsb then
                mTuple (List.map2 (enrichAnnotationsWith merge) xsa xsb)

            else
                structural

        ( MRecord _ fieldsA, MRecord _ fieldsB ) ->
            if sameFieldKeys fieldsA fieldsB then
                mRecord (Dict.map (\k ta -> enrichAnnotationsWith merge ta (Maybe.withDefault ta (Dict.get k fieldsB))) fieldsA)

            else
                structural

        ( MCustom _ homeA nameA argsA, MCustom _ homeB nameB argsB ) ->
            if homeA == homeB && nameA == nameB && List.length argsA == List.length argsB then
                mCustom homeA nameA (List.map2 (enrichAnnotationsWith merge) argsA argsB)

            else
                structural

        _ ->
            structural


{-| Returns the annotation `enrichAnnotations` puts on an arrow whose annotation is
`a` in the structural type and `b` in the source, by the table on
`enrichAnnotations`.
-}
enrichAnno : LambdaSetAnno -> LambdaSetAnno -> LambdaSetAnno
enrichAnno a b =
    case ( a, b ) of
        ( LSet xs, LSet ys ) ->
            LSet (unionSortedInts xs ys)

        -- Any LPartial keeps the result partial: a complete side does not
        -- make it complete. A ⊤ base is kept, not turned into a partial.
        ( LPartial xs, LPartial ys ) ->
            LPartial (unionSortedInts xs ys)

        ( LPartial xs, LSet ys ) ->
            LPartial (unionSortedInts xs ys)

        ( LSet xs, LPartial ys ) ->
            LPartial (unionSortedInts xs ys)

        ( LPartial _, _ ) ->
            a

        ( LVar _, LPartial _ ) ->
            b

        ( LTop _, LPartial _ ) ->
            a

        ( LSet _, _ ) ->
            a

        ( _, LSet _ ) ->
            b

        _ ->
            a


{-| Returns whether any arrow in the type carries an `LVar` or an `LPartial`: an
annotation that leaves room for functions not yet recorded.
-}
hasVarAnno : MonoType -> Bool
hasVarAnno monoType =
    case monoType of
        MFunction _ anno args result ->
            (case anno of
                LVar _ ->
                    True

                LPartial _ ->
                    True

                _ ->
                    False
            )
                || hasVarAnno result
                || List.any hasVarAnno args

        MList _ inner ->
            hasVarAnno inner

        MTuple _ elems ->
            List.any hasVarAnno elems

        MRecord _ fields ->
            Dict.foldl (\_ t a -> a || hasVarAnno t) False fields

        MCustom _ _ _ args ->
            List.any hasVarAnno args

        _ ->
            False


{-| Returns whether any arrow in the type carries ⊤.
-}
hasTopAnno : MonoType -> Bool
hasTopAnno monoType =
    case monoType of
        MFunction _ anno args result ->
            isTopAnno anno || hasTopAnno result || List.any hasTopAnno args

        MList _ inner ->
            hasTopAnno inner

        MTuple _ elems ->
            List.any hasTopAnno elems

        MRecord _ fields ->
            Dict.foldl (\_ t a -> a || hasTopAnno t) False fields

        MCustom _ _ _ args ->
            List.any hasTopAnno args

        _ ->
            False


{-| Returns `joined` with each ⊤ annotation replaced by the `LSet` at the same
position in `stored`, together with the number of annotations replaced. Every
other annotation and all structure come from `joined`.

The two types are walked together. Where they differ in constructor, the part
of `joined` is kept, but custom types are not compared by name, so two
different custom types have their arguments paired. Record fields missing from
`stored` are kept. Lists of
arguments, tuple elements and custom-type arguments are paired by position
without comparing lengths, so where `stored` has fewer, the extra ones of
`joined` are dropped from the result. Nothing here checks that a set in
`stored` is right for `joined`; that is for the caller to know.

-}
recoverStoredSets : MonoType -> MonoType -> ( MonoType, Int )
recoverStoredSets joined stored =
    case ( joined, stored ) of
        ( MFunction _ annoJ argsJ resJ, MFunction _ annoS argsS resS ) ->
            let
                ( anno1, n0 ) =
                    case ( annoJ, annoS ) of
                        ( LTop _, LSet ms ) ->
                            ( LSet ms, 1 )

                        _ ->
                            ( annoJ, 0 )

                ( args1, nA ) =
                    List.foldr
                        (\( aj, asx ) ( accL, accN ) ->
                            let
                                ( a1, n1 ) =
                                    recoverStoredSets aj asx
                            in
                            ( a1 :: accL, accN + n1 )
                        )
                        ( [], 0 )
                        (List.map2 Tuple.pair argsJ argsS)

                ( res1, nR ) =
                    recoverStoredSets resJ resS
            in
            ( mFunction anno1 args1 res1, n0 + nA + nR )

        ( MList _ xj, MList _ xs ) ->
            let
                ( x1, n ) =
                    recoverStoredSets xj xs
            in
            ( mList x1, n )

        ( MTuple _ xsJ, MTuple _ xsS ) ->
            let
                ( xs1, n ) =
                    List.foldr
                        (\( a, b ) ( accL, accN ) ->
                            let
                                ( x1, n1 ) =
                                    recoverStoredSets a b
                            in
                            ( x1 :: accL, accN + n1 )
                        )
                        ( [], 0 )
                        (List.map2 Tuple.pair xsJ xsS)
            in
            ( mTuple xs1, n )

        ( MRecord _ fj, MRecord _ fs ) ->
            let
                ( f1, n ) =
                    Dict.foldl
                        (\k vj ( accD, accN ) ->
                            case Dict.get k fs of
                                Just vs ->
                                    let
                                        ( v1, n1 ) =
                                            recoverStoredSets vj vs
                                    in
                                    ( Dict.insert k v1 accD, accN + n1 )

                                Nothing ->
                                    ( Dict.insert k vj accD, accN )
                        )
                        ( Dict.empty, 0 )
                        fj
            in
            ( mRecord f1, n )

        ( MCustom _ home name xsJ, MCustom _ _ _ xsS ) ->
            let
                ( xs1, n ) =
                    List.foldr
                        (\( a, b ) ( accL, accN ) ->
                            let
                                ( x1, n1 ) =
                                    recoverStoredSets a b
                            in
                            ( x1 :: accL, accN + n1 )
                        )
                        ( [], 0 )
                        (List.map2 Tuple.pair xsJ xsS)
            in
            ( mCustom home name xs1, n )

        _ ->
            ( joined, 0 )


{-| Returns one report key for each arrow position where one of two types has an
`LSet` and the other has an `LVar` or a ⊤, walking the two types together.

A key is `"jc|" ++ side ++ kind ++ "|" ++ position`. `kind` is `Var` or `Top`,
and `side` is `a` when `ta` holds it and `s` when `tb` does. `position` says
where the arrow is: `head` for the outermost arrow of the type, `spine` for an
arrow returned by one of the first `arity - 1` stages, `tail` for one further
along that chain of returned functions, and `nested` for one inside an argument
type or inside a list, tuple, record or custom type.

Where the constructors differ, that part is skipped; argument lists, tuples and
type arguments are paired up to the shorter, custom types are not compared by
name, and record fields missing from `tb` are skipped.

-}
joinCollisionCells : Int -> MonoType -> MonoType -> List String
joinCollisionCells arity ta tb =
    let
        posName depth nested =
            if nested then
                "nested"

            else if depth == 0 then
                "head"

            else if depth < arity then
                "spine"

            else
                "tail"

        cellOf pos annoA annoB =
            case ( annoA, annoB ) of
                ( LSet _, LVar _ ) ->
                    [ "jc|sVar|" ++ pos ]

                ( LVar _, LSet _ ) ->
                    [ "jc|aVar|" ++ pos ]

                ( LSet _, LTop _ ) ->
                    [ "jc|sTop|" ++ pos ]

                ( LTop _, LSet _ ) ->
                    [ "jc|aTop|" ++ pos ]

                _ ->
                    []

        go depth nested a b acc =
            case ( a, b ) of
                ( MFunction _ annoA argsA resA, MFunction _ annoB argsB resB ) ->
                    let
                        acc1 =
                            cellOf (posName depth nested) annoA annoB ++ acc

                        accArgs =
                            List.foldl (\( x, y ) accX -> go 0 True x y accX)
                                acc1
                                (List.map2 Tuple.pair argsA argsB)
                    in
                    go (depth + 1) nested resA resB accArgs

                ( MList _ xa, MList _ xb ) ->
                    go 0 True xa xb acc

                ( MTuple _ xsA, MTuple _ xsB ) ->
                    List.foldl (\( x, y ) accX -> go 0 True x y accX) acc (List.map2 Tuple.pair xsA xsB)

                ( MRecord _ fa, MRecord _ fb ) ->
                    Dict.foldl
                        (\k va accX ->
                            case Dict.get k fb of
                                Just vb ->
                                    go 0 True va vb accX

                                Nothing ->
                                    accX
                        )
                        acc
                        fa

                ( MCustom _ _ _ xsA, MCustom _ _ _ xsB ) ->
                    List.foldl (\( x, y ) accX -> go 0 True x y accX) acc (List.map2 Tuple.pair xsA xsB)

                _ ->
                    acc
    in
    go 0 False ta tb []


{-| Returns `acc` with each arrow annotation in the type counted into it, by its
form as `AnnoCoverage` describes.
-}
annoCoverage : MonoType -> AnnoCoverage -> AnnoCoverage
annoCoverage monoType acc =
    case monoType of
        MFunction _ anno args result ->
            let
                acc1 =
                    case anno of
                        LSet ms ->
                            case ms of
                                [ _ ] ->
                                    { acc | k1 = acc.k1 + 1 }

                                _ ->
                                    -- An empty LSet is not expected, so this
                                    -- is the case of two or more members.
                                    { acc | kN = acc.kN + 1 }

                        LVar _ ->
                            { acc | var = acc.var + 1 }

                        LTop _ ->
                            { acc | top = acc.top + 1 }

                        LPartial _ ->
                            { acc | part = acc.part + 1 }
            in
            List.foldl annoCoverage (annoCoverage result acc1) args

        MList _ inner ->
            annoCoverage inner acc

        MTuple _ elems ->
            List.foldl annoCoverage acc elems

        MRecord _ fields ->
            Dict.foldl (\_ t a -> annoCoverage t a) acc fields

        MCustom _ _ _ args ->
            List.foldl annoCoverage acc args

        _ ->
            acc


{-| Returns whether two types are `==` once every `LVar` and every ⊤ is taken to
be the same annotation, whatever its number or provenance code.

This is looser than the spec key, which tells `LVar` apart from ⊤ and one
`LVar` from another, and it is meant for asking whether anything changed.
`LSet` and `LPartial` annotations, and every leaf, still compare with `==`, so
`MVar` ids count.

`a == b` is tried first. The types are only rebuilt with `normalizeTopLabels`
when one of them has an annotation it would change, as `hasUnknownAnno`
reports.

-}
eqModuloTopLabel : MonoType -> MonoType -> Bool
eqModuloTopLabel a b =
    (a == b)
        || ((hasUnknownAnno a || hasUnknownAnno b)
                && (normalizeTopLabels a == normalizeTopLabels b)
           )


{-| Returns whether any arrow carries an `LVar`, or a ⊤ whose code is not
`tkLegacy`: that is, whether `normalizeTopLabels` would change any annotation
of the type.
-}
hasUnknownAnno : MonoType -> Bool
hasUnknownAnno monoType =
    case monoType of
        MFunction _ anno args result ->
            isVarAnno anno
                || List.any hasUnknownAnno args
                || hasUnknownAnno result

        MList _ inner ->
            hasUnknownAnno inner

        MTuple _ elems ->
            List.any hasUnknownAnno elems

        MRecord _ fields ->
            Dict.foldl (\_ t acc -> acc || hasUnknownAnno t) False fields

        MCustom _ _ _ args ->
            List.any hasUnknownAnno args

        _ ->
            False


{-| Returns whether `normalizeTopLabels` rewrites this annotation: `True` for an
`LVar`, and for a ⊤ whose code is not `tkLegacy`.
-}
isVarAnno : LambdaSetAnno -> Bool
isVarAnno anno =
    case anno of
        LVar _ ->
            True

        LTop k ->
            k /= tkLegacy

        _ ->
            False


{-| Returns the type with every `LVar` and every ⊤ replaced by `topLegacy`, keeping
`LSet` and `LPartial` annotations as they are.
-}
normalizeTopLabels : MonoType -> MonoType
normalizeTopLabels monoType =
    case monoType of
        MFunction _ anno args result ->
            mFunction
                (case anno of
                    LVar _ ->
                        topLegacy

                    LTop _ ->
                        topLegacy

                    other ->
                        other
                )
                (List.map normalizeTopLabels args)
                (normalizeTopLabels result)

        MList _ inner ->
            mList (normalizeTopLabels inner)

        MTuple _ elems ->
            mTuple (List.map normalizeTopLabels elems)

        MRecord _ fields ->
            mRecord (Dict.map (\_ t -> normalizeTopLabels t) fields)

        MCustom _ home name args ->
            mCustom home name (List.map normalizeTopLabels args)

        _ ->
            monoType


{-| Returns the type with every arrow's annotation replaced by `topWiden`, so that
it keeps only its layout. Since the spec key treats every ⊤ alike, two types
with the same layout key have the same spec key once widened.

`Compiler.AST.Intern.widenSets` computes the same type, and the two must change
together: a type widened by one and looked up by the other would get a
different key, with no error from the compiler.

-}
widenSets : MonoType -> MonoType
widenSets monoType =
    case monoType of
        MFunction _ _ args result ->
            mFunction topWiden (List.map widenSets args) (widenSets result)

        MList _ inner ->
            mList (widenSets inner)

        MTuple _ elems ->
            mTuple (List.map widenSets elems)

        MRecord _ fields ->
            mRecord (Dict.map (\_ t -> widenSets t) fields)

        MCustom _ home name args ->
            mCustom home name (List.map widenSets args)

        _ ->
            monoType


{-| Returns whether two types are the same apart from the annotations on their
arrows. It walks both and stops at the first difference, building nothing.

It is finer than `eqKeyLayout`: leaves are compared with `==`, so `MVar` ids
count, and `MVar _ CNumber` differs from `MInt`.

-}
eqLayout : MonoType -> MonoType -> Bool
eqLayout a b =
    case ( a, b ) of
        ( MFunction _ _ argsA retA, MFunction _ _ argsB retB ) ->
            eqLayoutList argsA argsB && eqLayout retA retB

        ( MList _ xa, MList _ xb ) ->
            eqLayout xa xb

        ( MTuple _ xsa, MTuple _ xsb ) ->
            eqLayoutList xsa xsb

        ( MRecord _ fieldsA, MRecord _ fieldsB ) ->
            eqFieldsBy eqLayout fieldsA fieldsB

        ( MCustom _ homeA nameA argsA, MCustom _ homeB nameB argsB ) ->
            nameA == nameB && homeA == homeB && eqLayoutList argsA argsB

        _ ->
            a == b


{-| Returns whether two lists of types have the same length and are `eqLayout` at
each position.
-}
eqLayoutList : List MonoType -> List MonoType -> Bool
eqLayoutList xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: restX, y :: restY ) ->
            eqLayout x y && eqLayoutList restX restY

        _ ->
            False


{-| Returns a short string describing the outer `depth` levels of a type, for
sorting types into buckets. It ignores annotations, writes each level below the
cut as `~`, and writes a record by its field names only.

Types that are `eqLayout` get the same string, and different types may share
one, so a bucket match still has to be confirmed with `eqLayout`. The string
has the same size whatever the size of the type below the cut.

-}
shallowLayoutKey : Int -> MonoType -> String
shallowLayoutKey depth monoType =
    if depth <= 0 then
        "~"

    else
        case monoType of
            MInt ->
                "I"

            MFloat ->
                "F"

            MBool ->
                "B"

            MChar ->
                "C"

            MString ->
                "S"

            MUnit ->
                "U"

            MVar _ CEcoValue ->
                "V"

            MVar _ CNumber ->
                "I"

            MList _ inner ->
                "L(" ++ shallowLayoutKey (depth - 1) inner ++ ")"

            MTuple _ elems ->
                "T" ++ String.fromInt (List.length elems) ++ "(" ++ String.join "," (List.map (shallowLayoutKey (depth - 1)) elems) ++ ")"

            MRecord _ fields ->
                "R" ++ String.fromInt (Dict.size fields) ++ "(" ++ String.join "," (Dict.keys fields) ++ ")"

            MCustom _ _ name args ->
                "X" ++ name ++ String.fromInt (List.length args) ++ "(" ++ String.join "," (List.map (shallowLayoutKey (depth - 1)) args) ++ ")"

            MFunction _ _ args ret ->
                "A" ++ String.fromInt (List.length args) ++ "(" ++ String.join "," (List.map (shallowLayoutKey (depth - 1)) args) ++ "->" ++ shallowLayoutKey (depth - 1) ret ++ ")"


{-| Returns the annotation on the type's outermost arrow, or `topLegacy` for a type
that is not a function.
-}
headAnno : MonoType -> LambdaSetAnno
headAnno monoType =
    case monoType of
        MFunction _ anno _ _ ->
            anno

        _ ->
            topLegacy


{-| Returns `a` with each arrow's annotation joined (`unionAnno`) with the
annotation at the same position in `b`.

The two types are meant to have the same layout. Where they do not (a
different constructor, number of arguments, field names or custom type, or a
different leaf), the part of `a` at that point is widened with `widenSets`
instead.

-}
joinAnnotations : MonoType -> MonoType -> MonoType
joinAnnotations a b =
    case ( a, b ) of
        ( MFunction _ annoA argsA retA, MFunction _ annoB argsB retB ) ->
            if List.length argsA == List.length argsB then
                mFunction (unionAnno annoA annoB) (List.map2 joinAnnotations argsA argsB) (joinAnnotations retA retB)

            else
                widenSets a

        ( MList _ xa, MList _ xb ) ->
            mList (joinAnnotations xa xb)

        ( MTuple _ xsa, MTuple _ xsb ) ->
            if List.length xsa == List.length xsb then
                mTuple (List.map2 joinAnnotations xsa xsb)

            else
                widenSets a

        ( MRecord _ fieldsA, MRecord _ fieldsB ) ->
            if sameFieldKeys fieldsA fieldsB then
                mRecord (Dict.map (\k ta -> joinAnnotations ta (Maybe.withDefault ta (Dict.get k fieldsB))) fieldsA)

            else
                widenSets a

        ( MCustom _ homeA nameA argsA, MCustom _ homeB nameB argsB ) ->
            if homeA == homeB && nameA == nameB && List.length argsA == List.length argsB then
                mCustom homeA nameA (List.map2 joinAnnotations argsA argsB)

            else
                widenSets a

        _ ->
            if a == b then
                a

            else
                widenSets a


{-| Returns `joinAnnotations a b`, paired with whether it differs from `a`. When
the flag is `False` the type returned is `==` to `a`, and when it is `True` only
the parts that changed are rebuilt.

The flag has to be exact. One that is falsely `False` keeps an annotation
narrower than the join, so code can rely on a set that is missing members; one
that is falsely `True` reports a change that did not happen, so a loop that
repeats until nothing changes may never stop. It depends on
`annoCovers annoA annoB` deciding `unionAnno annoA annoB == annoA`, and on the
widening fallback comparing its result with `a`.

There is one difference from `joinAnnotations`. Where a ⊤ in `a` meets a ⊤
with a lower provenance code in `b`, `a`'s ⊤ is kept and no change reported,
where `joinAnnotations` takes the lower code.

-}
joinAnnotationsChanged : MonoType -> MonoType -> ( Bool, MonoType )
joinAnnotationsChanged a b =
    if a == b then
        -- A type joined with itself is itself, so equal inputs need no walk.
        ( False, a )

    else
        case ( a, b ) of
            ( MFunction _ annoA argsA retA, MFunction _ annoB argsB retB ) ->
                if List.length argsA == List.length argsB then
                    let
                        ( argsChanged, args ) =
                            joinListChanged argsA argsB

                        ( retChanged, ret ) =
                            joinAnnotationsChanged retA retB
                    in
                    if annoCovers annoA annoB then
                        if argsChanged || retChanged then
                            ( True, mFunction annoA args ret )

                        else
                            ( False, a )

                    else
                        ( True, mFunction (unionAnno annoA annoB) args ret )

                else
                    joinWidened a

            ( MList _ xa, MList _ xb ) ->
                case joinAnnotationsChanged xa xb of
                    ( True, x ) ->
                        ( True, mList x )

                    ( False, _ ) ->
                        ( False, a )

            ( MTuple _ xsa, MTuple _ xsb ) ->
                if List.length xsa == List.length xsb then
                    case joinListChanged xsa xsb of
                        ( True, xs ) ->
                            ( True, mTuple xs )

                        ( False, _ ) ->
                            ( False, a )

                else
                    joinWidened a

            ( MRecord _ fieldsA, MRecord _ fieldsB ) ->
                if sameFieldKeys fieldsA fieldsB then
                    case joinFieldsChanged fieldsA fieldsB of
                        ( True, fields ) ->
                            ( True, mRecord fields )

                        ( False, _ ) ->
                            ( False, a )

                else
                    joinWidened a

            ( MCustom _ homeA nameA argsA, MCustom _ homeB nameB argsB ) ->
                if homeA == homeB && nameA == nameB && List.length argsA == List.length argsB then
                    case joinListChanged argsA argsB of
                        ( True, args ) ->
                            ( True, mCustom homeA nameA args )

                        ( False, _ ) ->
                            ( False, a )

                else
                    joinWidened a

            _ ->
                if a == b then
                    ( False, a )

                else
                    joinWidened a


{-| Returns `widenSets a`, paired with whether it differs from `a` under `==`.
Widening a leaf, or a type whose arrows already carry `topWiden`, changes
nothing and is not reported as a change.
-}
joinWidened : MonoType -> ( Bool, MonoType )
joinWidened a =
    let
        widened =
            widenSets a
    in
    ( widened /= a, widened )


{-| Returns the pointwise `joinAnnotationsChanged` of two lists, paired with
whether any element changed. When none did, the list returned is `xsA` itself.
The lists are meant to have the same length; the walk stops at the end of the
shorter.
-}
joinListChanged : List MonoType -> List MonoType -> ( Bool, List MonoType )
joinListChanged xsA xsB =
    joinListChangedHelp xsA xsB xsA False []


{-| Does the work of `joinListChanged`: `acc` holds the joined elements so far in
reverse, and `original` is returned when no element changed.
-}
joinListChangedHelp : List MonoType -> List MonoType -> List MonoType -> Bool -> List MonoType -> ( Bool, List MonoType )
joinListChangedHelp remA remB original anyChanged acc =
    case ( remA, remB ) of
        ( x :: restA, y :: restB ) ->
            let
                ( changed, joined ) =
                    joinAnnotationsChanged x y
            in
            joinListChangedHelp restA restB original (anyChanged || changed) (joined :: acc)

        _ ->
            if anyChanged then
                ( True, List.reverse acc )

            else
                ( False, original )


{-| Returns the field-by-field `joinAnnotationsChanged` of two records' fields,
paired with whether any field changed. Changed fields are inserted into
`fieldsA`, and when none changed the map returned is `fieldsA` itself. A field
missing from `fieldsB` is joined with itself.
-}
joinFieldsChanged : Dict Name MonoType -> Dict Name MonoType -> ( Bool, Dict Name MonoType )
joinFieldsChanged fieldsA fieldsB =
    let
        fold key ta accPair =
            let
                ( changed, joined ) =
                    joinAnnotationsChanged ta (Maybe.withDefault ta (Dict.get key fieldsB))
            in
            if changed then
                ( True, Dict.insert key joined (Tuple.second accPair) )

            else
                accPair
    in
    case Dict.foldl fold ( False, fieldsA ) fieldsA of
        ( True, newFields ) ->
            ( True, newFields )

        _ ->
            ( False, fieldsA )


{-| Returns whether joining `b` into `a` leaves `a` as it is, that is whether
`unionAnno a b == a`, without building the join. `LSet xs` and `LPartial xs`
cover a set of members only when they hold all of them.

It must agree with `unionAnno`, because `joinAnnotationsChanged` reports a
change exactly when this returns `False`. It does in every case but one: any ⊤
covers any other ⊤ here, but `unionAnno` keeps the lower provenance code, so
`unionAnno (LTop 5) (LTop 1)` is `LTop 1`, not `a`.

-}
annoCovers : LambdaSetAnno -> LambdaSetAnno -> Bool
annoCovers a b =
    case ( a, b ) of
        ( LTop _, _ ) ->
            True

        ( LPartial xs, LVar _ ) ->
            True

        ( LPartial xs, LPartial ys ) ->
            sortedSubsetOf ys xs

        ( LPartial xs, LSet ys ) ->
            sortedSubsetOf ys xs

        ( LPartial _, LTop _ ) ->
            False

        ( _, LPartial _ ) ->
            False

        ( LVar i, LVar j ) ->
            i == j

        ( LVar _, _ ) ->
            False

        ( LSet _, LTop _ ) ->
            False

        ( LSet _, LVar _ ) ->
            False

        ( LSet xs, LSet ys ) ->
            sortedSubsetOf ys xs


{-| Returns whether every element of `ys` is in `xs`. Both lists must be in
ascending order without duplicates; given lists that are not, the answer can
be wrong.
-}
sortedSubsetOf : List Int -> List Int -> Bool
sortedSubsetOf ys xs =
    case ( ys, xs ) of
        ( [], _ ) ->
            True

        ( _, [] ) ->
            False

        ( y :: yRest, x :: xRest ) ->
            if y == x then
                sortedSubsetOf yRest xRest

            else if x < y then
                sortedSubsetOf ys xRest

            else
                -- y < x: ys is ascending, so y appears nowhere in the rest of xs.
                False


{-| Returns whether two dictionaries have the same keys, without building a list.
Equal sizes, with every key of `a` present in `b`, make the two key sets the
same.
-}
sameFieldKeys : Dict Name a -> Dict Name b -> Bool
sameFieldKeys a b =
    Dict.size a == Dict.size b && Dict.foldl (\k _ ok -> ok && Dict.member k b) True a


{-| Returns `overlayAnnotations structural annoSource`, paired with whether it
differs from `structural`. When the flag is `False` the type returned is
`structural` itself, and when it is `True` only the parts that changed are
rebuilt.
-}
overlayAnnotationsChanged : MonoType -> MonoType -> ( Bool, MonoType )
overlayAnnotationsChanged structural annoSource =
    if structural == annoSource then
        ( False, structural )

    else
        case ( structural, annoSource ) of
            ( MFunction _ annoA argsA retA, MFunction _ annoB argsB retB ) ->
                if List.length argsA == List.length argsB then
                    let
                        ( argsChanged, args ) =
                            overlayListChanged argsA argsB

                        ( retChanged, ret ) =
                            overlayAnnotationsChanged retA retB
                    in
                    if argsChanged || retChanged || annoA /= annoB then
                        ( True, mFunction annoB args ret )

                    else
                        ( False, structural )

                else
                    ( False, structural )

            ( MList _ xa, MList _ xb ) ->
                case overlayAnnotationsChanged xa xb of
                    ( True, x ) ->
                        ( True, mList x )

                    ( False, _ ) ->
                        ( False, structural )

            ( MTuple _ xsa, MTuple _ xsb ) ->
                if List.length xsa == List.length xsb then
                    case overlayListChanged xsa xsb of
                        ( True, xs ) ->
                            ( True, mTuple xs )

                        ( False, _ ) ->
                            ( False, structural )

                else
                    ( False, structural )

            ( MRecord _ fieldsA, MRecord _ fieldsB ) ->
                if sameFieldKeys fieldsA fieldsB then
                    case overlayFieldsChanged fieldsA fieldsB of
                        ( True, fields ) ->
                            ( True, mRecord fields )

                        ( False, _ ) ->
                            ( False, structural )

                else
                    ( False, structural )

            ( MCustom _ homeA nameA argsA, MCustom _ homeB nameB argsB ) ->
                if homeA == homeB && nameA == nameB && List.length argsA == List.length argsB then
                    case overlayListChanged argsA argsB of
                        ( True, args ) ->
                            ( True, mCustom homeA nameA args )

                        ( False, _ ) ->
                            ( False, structural )

                else
                    ( False, structural )

            _ ->
                ( False, structural )


{-| Returns the pointwise `overlayAnnotationsChanged` of two lists, paired with
whether any element changed. When none did, the list returned is `xsA` itself.
Elements of `xsA` beyond the end of `xsB` are kept as they are.
-}
overlayListChanged : List MonoType -> List MonoType -> ( Bool, List MonoType )
overlayListChanged xsA xsB =
    case ( xsA, xsB ) of
        ( x :: ra, y :: rb ) ->
            let
                ( c1, x1 ) =
                    overlayAnnotationsChanged x y

                ( c2, rest ) =
                    overlayListChanged ra rb
            in
            if c1 || c2 then
                ( True, x1 :: rest )

            else
                ( False, xsA )

        _ ->
            ( False, xsA )


{-| Returns the field-by-field `overlayAnnotationsChanged` of two records' fields,
paired with whether any field changed. Changed fields are inserted into
`fieldsA`, and when none changed the map returned is `fieldsA` itself.
-}
overlayFieldsChanged : Dict Name MonoType -> Dict Name MonoType -> ( Bool, Dict Name MonoType )
overlayFieldsChanged fieldsA fieldsB =
    let
        fold key ta accPair =
            let
                ( changed, overlaid ) =
                    overlayAnnotationsChanged ta (Maybe.withDefault ta (Dict.get key fieldsB))
            in
            if changed then
                ( True, Dict.insert key overlaid (Tuple.second accPair) )

            else
                accPair
    in
    case Dict.foldl fold ( False, fieldsA ) fieldsA of
        ( True, newFields ) ->
            ( True, newFields )

        _ ->
            ( False, fieldsA )


{-| Returns `structural` with each arrow's annotation replaced by the annotation at
the same position in `annoSource`, wherever the two types have the same shape.
Where they differ (a different constructor, number of arguments, field names or
custom type), that part of `structural` is kept with its own annotations.

Only annotations are taken from `annoSource`; all structure, leaves included,
is `structural`'s. It is not a join: `annoSource` wins outright, so a ⊤ in
`structural` is replaced by a set, and a set by a ⊤.

-}
overlayAnnotations : MonoType -> MonoType -> MonoType
overlayAnnotations structural annoSource =
    Tuple.second (overlayAnnotationsChanged structural annoSource)


{-| Returns the member of the type's outermost arrow when its annotation is an
`LSet` of exactly one member. An `LPartial` of one member gives `Nothing`,
since other functions may flow through that arrow too.
-}
singletonHeadMember : MonoType -> Maybe Int
singletonHeadMember monoType =
    case headAnno monoType of
        LSet [ m ] ->
            Just m

        _ ->
            Nothing


{-| Returns the join of two annotations: one that admits every function `a` or `b`
admits. It is what one specialization commits to when it has to serve uses
whose annotations differ.

    ⊤ p,      ⊤ q       -> ⊤ with the lower of p and q
    ⊤,        anything  -> that ⊤
    LVar i,   LVar i    -> LVar i
    LVar i,   LVar j    -> topConflict
    LVar,     LSet ys   -> LPartial ys
    LPartial, anything but ⊤
                        -> LPartial of the members either names
    LSet xs,  LSet ys   -> LSet (xs ∪ ys)

Two different set variables cannot be joined into one variable, so they give
⊤. A set variable meeting a complete set keeps the set's members, but the
variable may stand for more, so the result is an `LPartial`. Once an
`LPartial` is involved the result stays one, unless the other side is ⊤.

-}
unionAnno : LambdaSetAnno -> LambdaSetAnno -> LambdaSetAnno
unionAnno a b =
    case ( a, b ) of
        ( LTop mergeP, LTop mergeQ ) ->
            topOfKind (min mergeP mergeQ)

        ( LTop _, _ ) ->
            a

        ( _, LTop _ ) ->
            b

        ( LVar i, LVar j ) ->
            if i == j then
                LVar i

            else
                topConflict

        ( LVar _, LSet ys ) ->
            LPartial ys

        ( LSet xs, LVar _ ) ->
            LPartial xs

        ( LPartial xs, LPartial ys ) ->
            LPartial (unionSortedInts xs ys)

        ( LPartial xs, LSet ys ) ->
            LPartial (unionSortedInts xs ys)

        ( LSet xs, LPartial ys ) ->
            LPartial (unionSortedInts xs ys)

        ( LPartial xs, LVar _ ) ->
            LPartial xs

        ( LVar _, LPartial ys ) ->
            LPartial ys

        ( LSet xs, LSet ys ) ->
            LSet (unionSortedInts xs ys)


{-| Returns the union of two lists in ascending order without duplicates, given two
lists that are each in ascending order without duplicates.
-}
unionSortedInts : List Int -> List Int -> List Int
unionSortedInts xs ys =
    case ( xs, ys ) of
        ( [], _ ) ->
            ys

        ( _, [] ) ->
            xs

        ( x :: xRest, y :: yRest ) ->
            if x < y then
                x :: unionSortedInts xRest ys

            else if y < x then
                y :: unionSortedInts xs yRest

            else
                x :: unionSortedInts xRest yRest


{-| Returns the type with every residual number variable replaced by `MInt`.

A _residual number variable_ is an `MVar _ CNumber`, or an `MVar id CEcoValue`
for which `isNumber id` holds: a variable found to be a number after its
constraint was stamped. Every other `MVar` is left as it is, as is every arrow
annotation. A type with nothing to replace is returned as it is, not copied.

-}
resolveNumberType : (MVarId -> Bool) -> MonoType -> MonoType
resolveNumberType isNumber monoType =
    if typeHasResidualNumber isNumber monoType then
        resolveNumberTypeRebuild isNumber monoType

    else
        monoType


{-| Returns whether the type contains a residual number variable, as
`resolveNumberType` defines it.
-}
typeHasResidualNumber : (MVarId -> Bool) -> MonoType -> Bool
typeHasResidualNumber isNumber monoType =
    case monoType of
        MVar mvarId constraint ->
            case constraint of
                CNumber ->
                    True

                CEcoValue ->
                    isNumber mvarId

        MList _ inner ->
            typeHasResidualNumber isNumber inner

        MTuple _ elems ->
            anyResidualNumber isNumber elems

        MRecord _ fields ->
            Dict.foldl (\_ t acc -> acc || typeHasResidualNumber isNumber t) False fields

        MCustom _ _ _ args ->
            anyResidualNumber isNumber args

        MFunction _ _ args result ->
            anyResidualNumber isNumber args || typeHasResidualNumber isNumber result

        _ ->
            False


{-| Returns whether any type in `xs` contains a residual number variable.
-}
anyResidualNumber : (MVarId -> Bool) -> List MonoType -> Bool
anyResidualNumber isNumber xs =
    case xs of
        [] ->
            False

        x :: rest ->
            typeHasResidualNumber isNumber x || anyResidualNumber isNumber rest


{-| Returns the type with its residual number variables replaced by `MInt`, as
`resolveNumberType` does, rebuilding this level. Each child goes back through
`resolveNumberType`, so a child with nothing to replace is kept as it is.
-}
resolveNumberTypeRebuild : (MVarId -> Bool) -> MonoType -> MonoType
resolveNumberTypeRebuild isNumber monoType =
    case monoType of
        MVar mvarId constraint ->
            case constraint of
                CNumber ->
                    MInt

                CEcoValue ->
                    if isNumber mvarId then
                        MInt

                    else
                        monoType

        MList _ inner ->
            mList (resolveNumberType isNumber inner)

        MTuple _ elems ->
            mTuple (List.map (resolveNumberType isNumber) elems)

        MRecord _ fields ->
            mRecord (Dict.map (\_ t -> resolveNumberType isNumber t) fields)

        MCustom _ home name args ->
            mCustom home name (List.map (resolveNumberType isNumber) args)

        MFunction _ anno args result ->
            mFunction anno (List.map (resolveNumberType isNumber) args) (resolveNumberType isNumber result)

        MInt ->
            monoType

        MFloat ->
            monoType

        MBool ->
            monoType

        MChar ->
            monoType

        MString ->
            monoType

        MUnit ->
            monoType


{-| Returns what a function type gives once every stage has been applied, or the
type itself when it is not a function. For
`MFunction _ _ [ MInt ] (MFunction _ _ [ MInt ] MInt)` it is `MInt`.
-}
resultTypeOf : MonoType -> MonoType
resultTypeOf monoType =
    case monoType of
        MFunction _ _ _ result ->
            resultTypeOf result

        _ ->
            monoType


{-| Returns whether the type contains an `MVar` of either constraint.
-}
containsAnyMVar : MonoType -> Bool
containsAnyMVar monoType =
    case monoType of
        MVar _ _ ->
            True

        MList _ t ->
            containsAnyMVar t

        MFunction _ _ args result ->
            containsAnyMVarList args || containsAnyMVar result

        MTuple _ elems ->
            containsAnyMVarList elems

        MRecord _ fields ->
            Dict.foldl (\_ t acc -> acc || containsAnyMVar t) False fields

        MCustom _ _ _ args ->
            containsAnyMVarList args

        _ ->
            False


{-| Returns whether any type in `types` contains an `MVar`.
-}
containsAnyMVarList : List MonoType -> Bool
containsAnyMVarList types =
    case types of
        [] ->
            False

        t :: rest ->
            containsAnyMVar t || containsAnyMVarList rest


{-| The identity of one closure: the module its code belongs to and a number that
tells it apart from the module's other closures.
-}
type LambdaId
    = AnonymousLambda ModuleName.Canonical Int



-- ============================================================================
-- ====== SPECIALIZATION KEYS AND IDS ======
-- ============================================================================


{-| A definition that can be specialized. `Global` is a top-level value of a
module. `Accessor` is the function `.field` for the record field it names,
which belongs to no module.
-}
type Global
    = Global ModuleName.Canonical Name
    | Accessor Name


{-| What a specialization is filed under: a global and the type it is used at.

In a `SpecKeyMap`, two keys are the same specialization when their globals are
`==` and their types have the same spec key, which is coarser than `==` on the
whole `SpecKey`.

-}
type SpecKey
    = SpecKey Global MonoType


{-| The number of a specialization. It is the specialization's index in the
`MonoGraph`'s node array and in the registry's `reverseMapping`.

This is a name for `Int`, not a new type, so the compiler accepts any `Int`
where a `SpecId` is expected.

-}
type alias SpecId =
    Int


{-| The record of which specializations exist.

`nextId` is the SpecId the next new specialization will get. `mapping` finds a
specialization's SpecId from its `SpecKey`. `reverseMapping` holds, at each
SpecId's index, the global and type recorded for that specialization, or
`Nothing`. `countByGlobal` counts the specializations created for each global,
keyed by `toComparableGlobal`.

`mapping` and `countByGlobal` may be empty in a finished graph, where only
`reverseMapping` is kept (`clearLssTables` empties them too).

-}
type alias SpecializationRegistry =
    { nextId : Int
    , mapping : SpecKeyMap SpecId
    , reverseMapping : Array (Maybe ( Global, MonoType ))
    , countByGlobal : Dict String Int
    }



-- ============================================================================
-- ====== CONSTRUCTOR SHAPES ======
-- ============================================================================


{-| One constructor of a custom type as code generation needs it: its name, its
tag, and the types of its fields in order. It says nothing about layout, which
code generation works out from it.
-}
type alias CtorShape =
    { name : Name
    , tag : Int
    , fieldTypes : List MonoType
    }



-- ============================================================================
-- ====== MONO GRAPH ======
-- ============================================================================


{-| The whole monomorphized program.

`nodes` holds each specialization's code at its SpecId's index, or `Nothing`
where there is none. `main` is the program's `main`, if it has one, and
`flagsDecoder` the specialization of its flags decoder, if it has one.
`ctorShapes` gives, for each custom type, the shapes of its constructors.
`nextLambdaIndex` is the number the next closure made will get.

`callEdges`, `specHasEffects` and `specValueUsed` are derived from the nodes
when the graph is built, and not every later pass keeps them up to date; a
pass may empty them. `callEdges` holds, at each SpecId's index, the SpecIds its
node refers to.

`lssMemberOrigins`, `lssMemberKinds` and `lssBlockedMembers` are tables about
lambda-set members. They are empty when the program was monomorphized by the
substitution engine.

-}
type MonoGraph
    = MonoGraph
        { nodes : Array (Maybe MonoNode)
        , main : Maybe MainInfo
        , registry : SpecializationRegistry
        , ctorShapes : LayoutMap (List CtorShape)
        , nextLambdaIndex : Int
        , callEdges : Array (Maybe (List Int))
        , specHasEffects : BitSet -- SpecIds whose node refers to a Debug kernel function
        , specValueUsed : BitSet -- SpecIds some node refers to, and main's
        , ports : List PortRegistration
        , flagsDecoder : Maybe SpecId
        , lssMemberOrigins : Dict Int MemberOrigin -- for members that are not lambdas
        , lssMemberKinds : Dict Int String -- member id to its interned key, for reports
        , lssBlockedMembers : Dict Int () -- members ABI cloning must not stamp
        }


{-| Returns the graph with these tables emptied, to free memory:
`lssMemberKinds`, `lssBlockedMembers`, the registry's `mapping` and
`countByGlobal`, and the `specHasEffects` and `specValueUsed` sets.
`lssMemberOrigins` is emptied too, unless `keepOrigins` is set.

Whether a table is still needed is for the caller to know; this only empties
them.

-}
clearLssTables : { keepOrigins : Bool } -> MonoGraph -> MonoGraph
clearLssTables { keepOrigins } (MonoGraph record) =
    let
        registry =
            record.registry
    in
    MonoGraph
        { record
            | lssMemberKinds = Dict.empty
            , lssBlockedMembers = Dict.empty
            , lssMemberOrigins =
                if keepOrigins then
                    record.lssMemberOrigins

                else
                    Dict.empty
            , registry = { registry | mapping = specKeyMapEmpty, countByGlobal = Dict.empty }
            , specHasEffects = BitSet.empty
            , specValueUsed = BitSet.empty
        }


{-| What a lambda-set member stands for when it is not a lambda.

`OriginGlobal` is a top-level definition used as a function value, and
`OriginCtor` a constructor used as one. `OriginKernel` is a kernel function, by
its home and name. `OriginAccessor` is the accessor function for the named
record field.

`OriginPap` is a partial application of a global, with the number of arguments
already supplied. It names the partial application so that it can be counted
and so that a call through it can read the supplied arguments back out of the
closure. It must not be turned into a direct call of the global's
specialization, which would lose those arguments.

-}
type MemberOrigin
    = OriginGlobal Global
    | OriginKernel Name Name
    | OriginCtor Global
    | OriginAccessor Name
    | OriginPap Global Int


{-| A port the program uses, found during monomorphization.

`name` is the port's name, which is unique within a program. `key` is the
`toComparableGlobal` of the port's global, so that a port used at several types
is registered once. For an incoming port, `decoderSpecId` is the
specialization that holds the decoder for the values it receives; it is
`Nothing` for an outgoing one.

-}
type alias PortRegistration =
    { name : String
    , key : String
    , incoming : Bool
    , decoderSpecId : Maybe SpecId
    }


{-| The program's `main`. `StaticMain` holds the SpecId of its specialization. A
flags decoder, when there is one, is not part of this: it is `MonoGraph`'s
`flagsDecoder`.
-}
type MainInfo
    = StaticMain SpecId



-- ============================================================================
-- ====== MONO NODES ======
-- ============================================================================


{-| The code of one specialization, which is what the `MonoGraph` stores at its
SpecId. Each kind carries a type last, which `nodeType` reads. For
`MonoCtor` it is the constructed custom type, not the constructor's function
type.

`MonoDefine` is a value or function given by an expression.

`MonoTailFunc` is a function with named, typed parameters and a body. Its type
is the type of the whole function, not of its result. A tail-recursive
definition becomes one, and so does a record accessor used as a function.

`MonoCtor` is a constructor, with its shape. `MonoEnum` is a constructor with no
fields, by its tag.

`MonoExtern` is a definition whose code is not in the graph, such as a kernel
function.

`MonoManagerLeaf` is a leaf of an effect manager, with the name of the
manager's home module.

`MonoPortIncoming` and `MonoPortOutgoing` are ports, each with the expression
that implements it.

-}
type MonoNode
    = MonoDefine MonoExpr MonoType
    | MonoTailFunc (List ( Name, MonoType )) MonoExpr MonoType
    | MonoCtor CtorShape MonoType
    | MonoEnum Int MonoType
    | MonoExtern MonoType
    | MonoManagerLeaf String MonoType
    | MonoPortIncoming MonoExpr MonoType
    | MonoPortOutgoing MonoExpr MonoType



-- ============================================================================
-- ====== MONO EXPRESSIONS ======
-- ============================================================================


{-| Returns the type stored in a node, whichever kind it is.
-}
nodeType : MonoNode -> MonoType
nodeType node =
    case node of
        MonoDefine _ t ->
            t

        MonoTailFunc _ _ t ->
            t

        MonoCtor _ t ->
            t

        MonoEnum _ t ->
            t

        MonoExtern t ->
            t

        MonoManagerLeaf _ t ->
            t

        MonoPortIncoming _ t ->
            t

        MonoPortOutgoing _ t ->
            t


{-| An expression of the monomorphized program. Every kind except `MonoUnit`
carries its own type, which `typeOf` reads.

`MonoLiteral` is a literal. `MonoList` is a list literal of its element
expressions.

`MonoVarLocal` is a local variable. `MonoVarGlobal` refers to a specialization
by its SpecId. `MonoVarKernel` is a kernel function, with its kernel prefix,
home and name.

`MonoClosure` is a lambda, with what `ClosureInfo` describes and its body.

`MonoCall` calls a function value with arguments, and its `CallInfo` says how
the call is to be made. `MonoTailCall` is a call of the enclosing tail-recursive
function, named, which pairs each argument with the parameter it is passed to;
it has no `CallInfo`.

`MonoIf` holds its conditions with their branches, then the final `else`
branch. `MonoLet` binds a local definition around its body, and `MonoDestruct`
binds one part of a value, as `MonoDestructor` describes, around its body.

`MonoCase` is a `case`. Its first `Name` is a label for the case and its second
is the variable being matched, which the decision-tree paths start from. The
decision tree's leaves either hold a branch's body `Inline` or `Jump` to a
numbered branch in the list that follows, so that list holds only the branches
reached by a jump and can be empty: a walk over every branch has to read the
decision tree as well.

`MonoRecordCreate`, `MonoRecordAccess` and `MonoRecordUpdate` name record fields
by name only; where each field sits is decided by code generation.
`MonoTupleCreate` builds a tuple, and `MonoUnit` is the unit value.

`MonoAccessorValue` is `.field` used as a value, until
`Compiler.Monomorphize.ResolveAccessorValues` replaces it.

-}
type MonoExpr
    = MonoLiteral Literal MonoType
    | MonoVarLocal Name MonoType
    | MonoVarGlobal Region SpecId MonoType
    | MonoVarKernel Region Name Name Name MonoType
    | MonoList Region (List MonoExpr) MonoType
    | MonoClosure ClosureInfo MonoExpr MonoType
    | MonoCall Region MonoExpr (List MonoExpr) MonoType CallInfo
    | MonoTailCall Name (List ( Name, MonoExpr )) MonoType
    | MonoIf (List ( MonoExpr, MonoExpr )) MonoExpr MonoType
    | MonoLet MonoDef MonoExpr MonoType
    | MonoDestruct MonoDestructor MonoExpr MonoType
    | MonoCase Name Name (Decider MonoChoice) (List ( Int, MonoExpr )) MonoType
    | MonoRecordCreate (List ( Name, MonoExpr )) MonoType
    | MonoRecordAccess MonoExpr Name MonoType
    | MonoRecordUpdate MonoExpr (List ( Name, MonoExpr )) MonoType
    | MonoTupleCreate Region (List MonoExpr) MonoType
    | MonoUnit
    | MonoAccessorValue Region Name MonoType


{-| A literal value in an expression. `LChar` holds its character as a `String`.
-}
type Literal
    = LBool Bool
    | LInt Int
    | LFloat Float
    | LChar String
    | LStr String


{-| What a closure carries besides its body.

`lambdaId` identifies this closure. `srcLambda` is the lambda in the source it
was made from, and several closures may share one when code has been copied.
`lssMember` is the member that stands for this closure in lambda sets, or
`Nothing` when it has none. `captures` are the values the closure captures, each
with the name it is known by inside the body and a flag that code generation
reads as whether the capture is stored unboxed.

`closureKind` and `captureAbi` describe how the closure is called, for ABI
cloning; each is `Nothing` when that is not known.

-}
type alias ClosureInfo =
    { lambdaId : LambdaId
    , srcLambda : Maybe TypeIds.SrcLambdaId
    , lssMember : Maybe Int
    , captures : List ( Name, MonoExpr, Bool )
    , params : List ( Name, MonoType )
    , closureKind : MaybeClosureKind
    , captureAbi : Maybe CaptureABI
    }


{-| A local definition. `MonoDef` binds a name to the value of an expression.
`MonoTailDef` is a local tail-recursive function, with its parameters and body.
-}
type MonoDef
    = MonoDef Name MonoExpr
    | MonoTailDef Name (List ( Name, MonoType )) MonoExpr


{-| One binding made by destructuring: a name, the path from a variable to the part
of its value bound to the name, and that part's type.
-}
type MonoDestructor
    = MonoDestructor Name MonoPath MonoType


{-| The kind of value a path step reads into, which decides how code generation
reads it: a list, a two-tuple, a three-tuple, or a custom type, where
`CustomContainer` names the constructor whose layout gives the field's
position. There is no record kind: a record field is reached by `MonoField`.
-}
type ContainerKind
    = ListContainer
    | Tuple2Container
    | Tuple3Container
    | CustomContainer Name


{-| A path from a variable to one part of its value, written from the outermost
step in.

`MonoRoot` is the variable, with its type. Every other step reads into the
value its inner path yields and carries the type of what it reads out, so
`getMonoPathType` reads the type of a whole path off its outermost step.
`MonoIndex` reads the field at a position of a container of the given kind,
`MonoField` reads a record field by name, and `MonoUnbox` reads the one value
a wrapper holds.

-}
type MonoPath
    = MonoIndex Int ContainerKind MonoType MonoPath
    | MonoField Name MonoType MonoPath
    | MonoUnbox MonoType MonoPath
    | MonoRoot Name MonoType


{-| Returns the type of the value a path yields.
-}
getMonoPathType : MonoPath -> MonoType
getMonoPathType path =
    case path of
        MonoRoot _ ty ->
            ty

        MonoIndex _ _ ty _ ->
            ty

        MonoField _ ty _ ->
            ty

        MonoUnbox ty _ ->
            ty


{-| Returns a short description of a type for an error message: the name of a
leaf type, the kind of a composite type without its contents, the name of a
custom type, or the id of a variable.
-}
monoTypeToDebugString : MonoType -> String
monoTypeToDebugString monoType =
    case monoType of
        MInt ->
            "MInt"

        MFloat ->
            "MFloat"

        MBool ->
            "MBool"

        MChar ->
            "MChar"

        MString ->
            "MString"

        MUnit ->
            "MUnit"

        MList _ _ ->
            "mList ..."

        MTuple _ _ ->
            "mTuple ..."

        MRecord _ _ ->
            "mRecord ..."

        MCustom _ _ name _ ->
            "mCustom " ++ name ++ " ..."

        MFunction _ _ _ _ ->
            "mFunction ..."

        MVar mvarId _ ->
            "MVar#" ++ String.fromInt (Id.toComparable mvarId)


{-| A path into the value a decision tree tests, like `MonoPath` but without a
record field step. `DtRoot` is the variable being matched, with its type, so
the path carries everything code generation needs to reach the value.
-}
type MonoDtPath
    = DtRoot Name MonoType
    | DtIndex Int ContainerKind MonoType MonoDtPath
    | DtUnbox MonoType MonoDtPath


{-| Returns the type of the value a decision-tree path yields.
-}
dtPathType : MonoDtPath -> MonoType
dtPathType path =
    case path of
        DtRoot _ ty ->
            ty

        DtIndex _ _ ty _ ->
            ty

        DtUnbox ty _ ->
            ty


{-| A decision tree for a `case`, whose leaves hold an `a`.

`Chain` holds tests that must all pass, each on the value at its path, then the
tree to follow when they do and the tree to follow when they do not. `FanOut`
tests the value at one path, and holds a tree for each test and a tree to
follow when none passes.

-}
type Decider a
    = Leaf a
    | Chain (List ( MonoDtPath, DT.Test )) (Decider a) (Decider a)
    | FanOut MonoDtPath (List ( DT.Test, Decider a )) (Decider a)


{-| What a `case` does at a leaf of its decision tree: evaluate the branch body
held `Inline` there, or `Jump` to the branch with that number in the
`MonoCase`'s list of shared branches.
-}
type MonoChoice
    = Inline MonoExpr
    | Jump Int



-- ============================================================================
-- ====== TYPE UTILITIES ======
-- ============================================================================


{-| Returns the type of an expression. For `MonoUnit` it is `MUnit`.
-}
typeOf : MonoExpr -> MonoType
typeOf expr =
    case expr of
        MonoLiteral _ t ->
            t

        MonoVarLocal _ t ->
            t

        MonoVarGlobal _ _ t ->
            t

        MonoVarKernel _ _ _ _ t ->
            t

        MonoList _ _ t ->
            t

        MonoClosure _ _ t ->
            t

        MonoCall _ _ _ t _ ->
            t

        MonoTailCall _ _ t ->
            t

        MonoIf _ _ t ->
            t

        MonoLet _ _ t ->
            t

        MonoDestruct _ _ t ->
            t

        MonoCase _ _ _ _ t ->
            t

        MonoRecordCreate _ t ->
            t

        MonoRecordAccess _ _ t ->
            t

        MonoRecordUpdate _ _ t ->
            t

        MonoTupleCreate _ _ t ->
            t

        MonoUnit ->
            MUnit

        MonoAccessorValue _ _ t ->
            t



-- ============================================================================
-- ====== COMPARISON FUNCTIONS ======
-- ============================================================================


{-| Returns a string that stands for a global, different for different globals.
-}
toComparableGlobal : Global -> String
toComparableGlobal global =
    case global of
        Global home name ->
            let
                (ModuleName.Canonical ( author, project ) modName) =
                    home
            in
            String.concat [ "G", author, "\u{0000}", project, "\u{0000}", modName, "\u{0000}", name ]

        Accessor fieldName ->
            String.concat [ "A", fieldName ]


{-| Returns the spec key of a type as a string.

`MVar _ CNumber` is written as `MInt` is, without its id. Every
`MVar _ CEcoValue` is written alike, whatever its id. Every ⊤ is written alike,
whatever its provenance code; `LVar n` keeps `n`; `LPartial xs` is written as
`LSet xs` is. Two different record types can give the same string, because
field names and field types are written one after the other with nothing
between them; `eqKeySpec` tells them apart.

-}
toComparableMonoType : MonoType -> String
toComparableMonoType monoType =
    String.concat (toComparableFragments True monoType [])


{-| Returns the pieces of the string `toComparableMonoType` builds for `mt`, put in
front of `tail`. With `annoSensitive` set to `False`, every arrow is written
alike, giving the layout key instead, but `toComparableMonoType`, its only
caller, passes `True`.

Arguments, tuple elements and custom-type arguments are written last first,
and record fields in descending order of name. The recursion is as deep as the
type is nested, and walking along a list of children uses no stack.

-}
toComparableFragments : Bool -> MonoType -> List String -> List String
toComparableFragments annoSensitive mt tail =
    case mt of
        MInt ->
            "I" :: tail

        MFloat ->
            "F" :: tail

        MBool ->
            "B" :: tail

        MChar ->
            "C" :: tail

        MString ->
            "S" :: tail

        MUnit ->
            "U" :: tail

        MVar _ constraint ->
            case constraint of
                CEcoValue ->
                    "V" :: "0" :: "\u{0000}" :: "ecovalue" :: tail

                CNumber ->
                    -- Keyed as MInt: a residual number variable is closed to MInt
                    -- (`resolveNumberType`), so the two make one specialization.
                    "I" :: tail

        MList _ inner ->
            "L(" :: toComparableFragments annoSensitive inner (")" :: tail)

        MTuple _ elementTypes ->
            "T"
                :: String.fromInt (List.length elementTypes)
                :: "("
                :: toComparableFragmentsRev annoSensitive elementTypes (")" :: tail)

        MRecord _ fields ->
            "R("
                :: Dict.foldl
                    (\name ty acc -> name :: toComparableFragments annoSensitive ty acc)
                    (")" :: tail)
                    fields

        MCustom _ canonical name args ->
            let
                (ModuleName.Canonical ( author, project ) modName) =
                    canonical
            in
            "X"
                :: author
                :: "\u{0000}"
                :: project
                :: "\u{0000}"
                :: modName
                :: "\u{0000}"
                :: name
                :: "("
                :: toComparableFragmentsRev annoSensitive args (")" :: tail)

        MFunction _ anno args ret ->
            let
                annoKey =
                    if annoSensitive then
                        case anno of
                            LTop _ ->
                                "A("

                            LVar n ->
                                "Av" ++ String.fromInt n ++ "("

                            LSet members ->
                                "A[" ++ String.join "," (List.map String.fromInt members) ++ "]("

                            LPartial members ->
                                "A[" ++ String.join "," (List.map String.fromInt members) ++ "]("

                    else
                        "A("
            in
            annoKey
                :: toComparableFragmentsRev annoSensitive
                    args
                    ("->" :: toComparableFragments annoSensitive ret (")" :: tail))


{-| Returns the pieces for each type in `types`, the last type first, put in front
of `tail`.
-}
toComparableFragmentsRev : Bool -> List MonoType -> List String -> List String
toComparableFragmentsRev annoSensitive types tail =
    case types of
        [] ->
            tail

        ty :: rest ->
            toComparableFragmentsRev annoSensitive rest (toComparableFragments annoSensitive ty tail)



-- ============================================================================
-- ====== FUNCTION SHAPE HELPERS ======
-- ============================================================================


{-| Returns whether the type is a function type.
-}
isFunctionType : MonoType -> Bool
isFunctionType monoType =
    case monoType of
        MFunction _ _ _ _ ->
            True

        _ ->
            False


{-| Returns how many arguments a function type takes over all its stages, or 0 for
a type that is not a function.
-}
countTotalArity : MonoType -> Int
countTotalArity monoType =
    case monoType of
        MFunction _ _ argTypes result ->
            List.length argTypes + countTotalArity result

        _ ->
            0


{-| Returns the argument types of a function type's first stage, or `[]` for a type
that is not a function.
-}
stageParamTypes : MonoType -> List MonoType
stageParamTypes monoType =
    case monoType of
        MFunction _ _ argTypes _ ->
            argTypes

        _ ->
            []


{-| Returns what a function type's first stage returns, or the type itself when it
is not a function.

For `MFunction [a, b] (MFunction [c] d)` it is `MFunction [c] d`.

-}
stageReturnType : MonoType -> MonoType
stageReturnType monoType =
    case monoType of
        MFunction _ _ _ result ->
            result

        other ->
            other


{-| Returns every argument type of a function type, over all its stages in order,
and the result type left after the last stage.
-}
decomposeFunctionType : MonoType -> ( List MonoType, MonoType )
decomposeFunctionType monoType =
    case monoType of
        MFunction _ _ argTypes result ->
            let
                ( nestedArgs, finalResult ) =
                    decomposeFunctionType result
            in
            ( argTypes ++ nestedArgs, finalResult )

        other ->
            ( [], other )


{-| How a function's arguments are grouped into stages: the number each stage
takes, outermost first.

This is a name for `List Int`, so nothing checks that the numbers are positive
or that they match any function's type.

-}
type alias Segmentation =
    List Int


{-| How a callee takes its arguments. `FlattenedExternal` takes all of them in one
flat call, and `StageCurried` takes them stage by stage, as its type's
segmentation groups them.
-}
type CallModel
    = FlattenedExternal
    | StageCurried


{-| How code generation is to make a call, which the optimizer decides.

`CallDirectKnownSegmentation` is a call whose callee's stages are known, so the
arguments can be applied knowing how many each stage takes.
`CallDirectFlat` is a flat call of an external or kernel function, with no
stages.

`CallGenericApply` is a call through a value whose closure is not known well
enough to call directly, or whose return type is polymorphic, so the caller's
result type cannot be trusted. The call is made in the generic way, and the
runtime decides from the closure itself when it has all its arguments.

`CallSegmentationUnknown` is a call whose callee is known but whose stages are
not, for example when they are known only from its type. It too leaves the
runtime to decide when the closure has all its arguments.

-}
type CallKind
    = CallDirectKnownSegmentation
    | CallDirectFlat
    | CallGenericApply
    | CallSegmentationUnknown


{-| How one `MonoCall` is to be made.

`callModel` and `callKind` are described on `CallModel` and `CallKind`.
`stageArities` is the callee's segmentation, and `remainingStageArities` the
stages that follow the one this call starts in. `initialRemaining` is the
number of arguments code generation is told the callee value still takes at
this call, or 0 when it is not known. `isSingleStageSaturated` is `True` only
when the call supplies exactly the arguments the callee value still takes in
its current stage, as the optimizer knows that arity; it is `False` when that
arity is not known.
`evaluatorReturnType` is the return type of the function a saturating call
actually invokes, which differs from the `MonoCall`'s own type when the call
supplies more arguments than one stage takes.

The other fields are what ABI cloning has found out about the callee value, and
are `Nothing` until it has. `closureKind` and `captureAbi` describe its closure.
`fastEvaluator` is the one closure the callee value must be, when that is
known, which lets code generation call that closure's code directly.
`fastEvaluatorSpec` is set when that closure is the top-level body of a
specialization: it is then emitted as that specialization's function, not
under its own `LambdaId`, and this is that SpecId. It is `Nothing` for a closure
nested inside an expression, which is emitted under its `LambdaId`.

`fastPapPrefix` is `Just k` when the callee value is a partial application of
the `fastEvaluator` closure holding `k` arguments. Then `captureAbi`'s
`captureTypes` lists the closure's own captures followed by its first `k`
parameter types, and its `paramTypes` lists the parameters that remain, so the
closure's own capture count is the length of `captureTypes` minus `k`.

-}
type alias CallInfo =
    { callModel : CallModel
    , stageArities : List Int
    , isSingleStageSaturated : Bool
    , initialRemaining : Int
    , remainingStageArities : List Int
    , closureKind : MaybeClosureKind
    , captureAbi : Maybe CaptureABI
    , fastEvaluator : Maybe LambdaId

    -- Set only when `fastEvaluator` is a specialization's top-level closure.
    , fastEvaluatorSpec : Maybe SpecId
    , fastPapPrefix : Maybe Int
    , callKind : CallKind
    , evaluatorReturnType : MonoType
    }


{-| A placeholder `CallInfo` for a call made before anything is known about how to
make it: a generic call (`CallGenericApply`) with no stages and nothing from
ABI cloning.
-}
defaultCallInfo : CallInfo
defaultCallInfo =
    { callModel = StageCurried
    , stageArities = []
    , isSingleStageSaturated = False
    , initialRemaining = 0
    , remainingStageArities = []
    , closureKind = Nothing
    , captureAbi = Nothing
    , fastEvaluator = Nothing
    , fastEvaluatorSpec = Nothing
    , fastPapPrefix = Nothing
    , callKind = CallGenericApply
    , evaluatorReturnType = MUnit
    }


{-| Returns the segmentation of a function type, read off its chain of stages.

For `MFunction [A,B] (MFunction [C,D] R)` it is `[2, 2]`, for
`MFunction [A,B,C,D] R` it is `[4]`, and for a type that is not a function it
is `[]`.

-}
segmentLengths : MonoType -> Segmentation
segmentLengths monoType =
    let
        go t acc =
            case t of
                MFunction _ _ stageArgs stageRet ->
                    go stageRet (List.length stageArgs :: acc)

                _ ->
                    List.reverse acc
    in
    go monoType []


{-| Returns one segmentation for a value that can be any of `leafTypes`, together
with the argument types and result type of the first of them, flattened.

The segmentation chosen is the one most of the types have. Among equally common
ones the one with fewest stages wins, and between two of the same length, the
one that is greater as a `List Int`. An empty `leafTypes` gives `[]`, no
arguments and `MUnit`.

-}
chooseCanonicalSegmentation : List MonoType -> ( Segmentation, List MonoType, MonoType )
chooseCanonicalSegmentation leafTypes =
    case leafTypes of
        [] ->
            ( [], [], MUnit )

        firstType :: _ ->
            let
                ( flatArgs, flatRet ) =
                    decomposeFunctionType firstType

                countSegmentations : List MonoType -> Dict (List Int) Int
                countSegmentations types =
                    List.foldl
                        (\t accDict ->
                            let
                                seg =
                                    segmentLengths t

                                current =
                                    Dict.get seg accDict |> Maybe.withDefault 0
                            in
                            Dict.insert seg (current + 1) accDict
                        )
                        Dict.empty
                        types

                freqDict =
                    countSegmentations leafTypes

                maxCount =
                    Dict.foldl (\_ count acc -> max count acc) 0 freqDict

                bestSegs =
                    Dict.foldl
                        (\seg count acc ->
                            if count == maxCount then
                                seg :: acc

                            else
                                acc
                        )
                        []
                        freqDict

                canonicalSeg =
                    case List.sortBy List.length bestSegs of
                        shortest :: _ ->
                            shortest

                        [] ->
                            segmentLengths firstType
            in
            ( canonicalSeg, flatArgs, flatRet )


{-| Builds the function type that takes `flatArgs` in stages of the sizes `seg`
gives and returns `finalRet`, with `anno` on the arrow of every stage.

    buildSegmentedFunctionType anno [ A, B, C, D ] R [ 2, 2 ]
        == MFunction anno [ A, B ] (MFunction anno [ C, D ] R)

    buildSegmentedFunctionType anno [ A, B, C, D ] R [ 4 ]
        == MFunction anno [ A, B, C, D ] R

Arguments beyond the sum of `seg` are dropped, and a stage that asks for more
arguments than remain gets only those that remain.

-}
buildSegmentedFunctionType : LambdaSetAnno -> List MonoType -> MonoType -> Segmentation -> MonoType
buildSegmentedFunctionType anno flatArgs finalRet seg =
    let
        splitBySegments : List MonoType -> Segmentation -> List (List MonoType)
        splitBySegments remaining segLengths =
            case segLengths of
                [] ->
                    []

                m :: rest ->
                    let
                        ( now, later ) =
                            ( List.take m remaining, List.drop m remaining )
                    in
                    now :: splitBySegments later rest

        stageArgsLists =
            splitBySegments flatArgs seg
    in
    List.foldr
        (\stageArgs acc -> mFunction anno stageArgs acc)
        finalRet
        stageArgsLists



-- ============================================================================
-- ====== TYPED CLOSURE CALLING (ABI CLONING) ======
-- ============================================================================


{-| The number of a closure kind, which ABI cloning gives each kind it finds.
-}
type ClosureKindId
    = ClosureKindId Int


{-| What is known about which closure a value is: `Known` names its kind. It is
used as a `MaybeClosureKind`, where `Nothing` means nothing is known.
-}
type ClosureKind
    = Known ClosureKindId


{-| The closure kind of a value when it is known, and `Nothing` when it is not.
-}
type alias MaybeClosureKind =
    Maybe ClosureKind


{-| How a closure is called: the types of its captured values, the types of its
parameters, and its return type.
-}
type alias CaptureABI =
    { captureTypes : List MonoType
    , paramTypes : List MonoType
    , returnType : MonoType
    }
