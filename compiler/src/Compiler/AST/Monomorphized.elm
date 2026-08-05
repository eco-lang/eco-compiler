module Compiler.AST.Monomorphized exposing
    ( MonoType(..), Literal(..), Constraint(..)
    , mList, mTuple, mRecord, mCustom, mFunction
    , layoutHashOf, specHashOf, eqKeySpec, eqKeyLayout
    , LayoutMap, layoutMapEmpty, layoutMapGet, layoutMapMember, layoutMapInsert
    , layoutMapSize, layoutMapIsEmpty, layoutMapFoldl, layoutMapMap, layoutMapToList, layoutMapValues, layoutMapFromList
    , SpecMap, specMapEmpty, specMapGet, specMapMember, specMapInsert
    , specMapSize, specMapIsEmpty, specMapFoldl, specMapToList, specMapValues, specMapRemove, specMapSingleton
    , SpecKeyMap, specKeyMapEmpty, specKeyMapGet, specKeyMapInsert, specKeyMapSize, globalHash
    , LambdaSetAnno(..), widenSets, eqLayout, shallowLayoutKey, headAnno, unionAnno, singletonHeadMember, joinAnnotations, overlayAnnotations
    , LambdaId(..)
    , Global(..), SpecKey(..), SpecId, SpecializationRegistry
    , MonoGraph(..), MainInfo(..), MonoNode(..), CtorShape, nodeType, MemberOrigin(..)
    , PortRegistration
    , MonoExpr(..), ClosureInfo, MonoDef(..), MonoDestructor(..), MonoPath(..)
    , MonoDtPath(..), dtPathType
    , Decider(..), MonoChoice(..)
    , ContainerKind(..)
    , typeOf
    , toComparableSpecKey, toComparableMonoType, toComparableLayoutKey, toComparableGlobal
    , getMonoPathType
    , monoTypeToDebugString
    , resolveNumberType, typeHasResidualNumber
    , Segmentation, segmentLengths, stageParamTypes, stageReturnType
    , chooseCanonicalSegmentation, buildSegmentedFunctionType
    , decomposeFunctionType, isFunctionType, countTotalArity
    , CallModel(..), CallKind(..), CallInfo, defaultCallInfo
    , ClosureKindId(..), ClosureKind(..), MaybeClosureKind
    , CaptureABI
    , containsAnyMVar, resultTypeOf
    -- Typed closure calling (ABI cloning)
    -- Call staging metadata
    -- Staging/Segmentation helpers
    )

{-| Monomorphized AST for backends that can optimize using concrete types.

This IR makes all specialized definitions, layouts, and closure structures
explicit so that later stages can generate low-level code without needing
type inference or layout computation.

High‑level properties:

  - Each polymorphic Elm definition that is actually used at one or more
    type instantiations appears as one or more specialized nodes in
    `MonoGraph`, identified by a concrete `SpecId`.

  - Record, tuple, and custom types carry their computed runtime layouts
    (`RecordLayout`, `TupleLayout`, `CustomLayout`), so consumers of this
    IR can rely on fixed shapes and unboxing decisions.

  - Higher‑order functions are either represented as explicit closures
    (`MonoClosure` with captured variables and parameter types) or as
    specialized top‑level function nodes (`MonoDefine`, `MonoTailFunc`).

  - Remaining type variables in `MonoType` are limited to a small,
    backend‑aware set of constrained variables (`MVar` with `Constraint`)
    that do not require further inference. In particular, any unresolved
    numeric variables are intended to be rejected before final code
    generation. See `MonoType` and `Constraint` for the precise invariants.

This module defines the data structures for the monomorphized program
(`MonoGraph`, `MonoNode`, `MonoExpr`, etc.) along with utilities such as
`typeOf` and the layout computation functions.


# Types

@docs MonoType, Literal, Constraint


# Structural Hashes and Smart Constructors

@docs MList, MTuple, MRecord, MCustom, MFunction
@docs layoutHashOf, specHashOf, eqKeySpec, eqKeyLayout


# MonoType-keyed Maps

@docs LayoutMap, layoutMapEmpty, layoutMapGet, layoutMapMember, layoutMapInsert
@docs layoutMapSize, layoutMapIsEmpty, layoutMapFoldl, layoutMapMap, layoutMapToList, layoutMapValues, layoutMapFromList
@docs SpecMap, specMapEmpty, specMapGet, specMapMember, specMapInsert
@docs specMapSize, specMapIsEmpty, specMapFoldl, specMapToList, specMapValues, specMapRemove, specMapSingleton
@docs SpecKeyMap, specKeyMapEmpty, specKeyMapGet, specKeyMapInsert, specKeyMapSize, globalHash


# Lambda Sets

@docs LambdaId


# Globals and Specialization

@docs Global, SpecKey, SpecId, SpecializationRegistry


# Program Graph

@docs MonoGraph, MainInfo, MonoNode, CtorShape, nodeType
@docs PortRegistration


# Expressions

@docs MonoExpr, ClosureInfo, MonoDef, MonoDestructor, MonoPath


# Decision Tree Paths

@docs MonoDtPath, dtPathType


# Pattern Matching

@docs Decider, MonoChoice


# Container Classification

@docs ContainerKind


# Type Utilities

@docs typeOf


# Comparison and Ordering

@docs toComparableSpecKey, toComparableMonoType, toComparableLayoutKey, toComparableGlobal


# Path Utilities

@docs getMonoPathType


# Debug

@docs monoTypeToDebugString


# Comparable Conversions


# Constraint Utilities

@docs resolveNumberType, typeHasResidualNumber


# Staging and Segmentation

@docs Segmentation, segmentLengths, stageParamTypes, stageReturnType
@docs chooseCanonicalSegmentation, buildSegmentedFunctionType
@docs decomposeFunctionType, isFunctionType, countTotalArity


# Call Staging Metadata

@docs CallModel, CallKind, CallInfo, defaultCallInfo


# Typed Closure Calling (ABI Cloning)

@docs ClosureKindId, ClosureKind, MaybeClosureKind
@docs CaptureABI


# Misc Helpers

@docs containsAnyMVar, resultTypeOf

-}

import Array exposing (Array)
import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.TypeIds as TypeIds exposing (MVarId)
import Compiler.Data.BitSet exposing (BitSet)
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Char
import Compiler.Reporting.Annotation exposing (Region)
import Data.HashMap as HashMap
import Dict exposing (Dict)
import System.TypeCheck.IO as IO



-- ============================================================================
-- ====== MONOMORPHIC TYPES ======
-- ============================================================================


{-| Monomorphized type used by the MLIR backend.

This type represents the fully elaborated runtime shape of values after
monomorphization. All concrete instantiations of source types (including
primitives, functions, lists, tuples, records, and custom types) must appear
here as `MInt`, `MFloat`, `MList`, `MTuple`, etc.

Type variables only remain in the form of `MVar` with an attached `Constraint`
when their exact runtime type is either:

  - Guaranteed to be represented as a boxed `eco.value` (`CEcoValue`), or
  - A numeric type (`CNumber`) that is waiting to be resolved to `MInt` or
    `MFloat` during specialization.

INVARIANTS BY PHASE:

  - Before codegen:
      - `MVar _ CNumber` is allowed as an intermediate result of
        monomorphization and must be resolved to either `MInt` or `MFloat`
        for any reachable code path that performs numeric operations.
      - `MVar _ CEcoValue` is allowed for positions whose concrete type does
        not affect layout (always boxed) and may remain until codegen.

  - At codegen time:
      - No `MVar _ CNumber` may remain in any reachable `MonoType`. Such
        a case indicates a failed specialization and is a compiler bug.
      - Any remaining `MVar _ CEcoValue` is treated as a boxed `eco.value`
        in the target representation.

The actual specialization to `MInt` or `MFloat` is expected tp be done at call
sites during code generation.

-}
type MonoType
    = MInt
    | MFloat
    | MBool
    | MChar
    | MString
    | MUnit
    | MList Int MonoType
    | MTuple Int (List MonoType) -- Element types (layout computed at codegen)
    | MRecord Int (Dict Name MonoType) -- Field name -> type (layout computed at codegen)
    | MCustom Int IO.Canonical Name (List MonoType)
    | MFunction Int LambdaSetAnno (List MonoType) MonoType
    | MVar MVarId Constraint


{-| Constraint on an unspecialized type variable in `MonoType`.

These constraints record how much is known about a type variable after
monomorphization and determine what obligations remain before codegen.

  - `CEcoValue`:
    The variable's concrete Elm type is erased in the backend and is
    always represented as a boxed `eco.value`. Its precise source type
    does not influence layout or calling convention; it is only tracked
    for comparison/debugging purposes. It is safe (and expected) for
    `MVar _ CEcoValue` to survive to MLIR codegen, where it is lowered
    uniformly to `eco.value`.

  - `CNumber`:
    The variable is known to be a numeric type (`Int` or `Float` in Elm).
    This variable MUST be resolved to either `MInt` or `MFloat` by the
    monomorphization/specialization phase for all reachable code paths
    that perform numeric operations. Any occurrence of `MVar _ CNumber`
    in a `MonoType` that reaches MLIR codegen is a compiler bug.

In other words, `CEcoValue` marks "erased / always boxed" variables that can
remain polymorphic at the backend, while `CNumber` marks numeric variables
that must be fully specialized before code generation.

-}
type Constraint
    = CEcoValue
    | CNumber



-- ============================================================================
-- ====== STRUCTURAL HASHES AND SMART CONSTRUCTORS (K4) ======
-- ============================================================================


{-| Every composite `MonoType` carries a PACKED pair of structural hashes in
its leading `Int` field: `layoutHash * hashBase + specHash`, each of them in
`[0, hashBase)`.

They exist so a `MonoType`-keyed dictionary can key on an `Int` that is
already in the value instead of on a comparable string it must first build by
walking the type (K4 of `plans/mono-comparable-key-optimization.md`). The two
hashes mirror the two comparable-key FLAVOURS exactly:

  - `specHashOf` corresponds to `toComparableMonoType` (annotation-SENSITIVE);
  - `layoutHashOf` corresponds to `toComparableLayoutKey` (arrows erased).

The contract is one-directional: **equal keys imply equal hashes**, never the
converse. These are hashes, not identities, so every hash-keyed lookup MUST
confirm a candidate with `eqKeySpec` / `eqKeyLayout`, which are exactly key
equality. `ComparableKeyEncodingTest` pins both halves of that contract.

Hashes are computed ONCE, here, from the children's already-stored hashes:
O(arity) per construction, never a tree walk, and never a string walk — only
`String.length`, so that construction stays cheap. Names themselves are
compared by the eq functions, on the rare bucket collision.

**Build composite types ONLY through the smart constructors below.** A
hand-written `MList 0 t` carries a wrong hash and would silently miss in every
hash-keyed dictionary; the leading field is deliberately un-guessable so that
the type checker forces you here.

-}
hashBase : Int
hashBase =
    -- 2^26. Two of these pack into 2^52, inside the exact-integer range of
    -- both the native i64 and the JS-hosted double.
    67108864


packHashes : Int -> Int -> Int
packHashes layoutH specH =
    layoutH * hashBase + specH


mixHash : Int -> Int -> Int
mixHash h x =
    modBy hashBase (h * 33 + modBy hashBase x + 7)


{-| Annotation-INSENSITIVE structural hash — the `toComparableLayoutKey` side.
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


{-| Annotation-SENSITIVE structural hash — the `toComparableMonoType` side.
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


{-| The key identity of a leaf, or 0 for a composite. Note the two merges the
comparable key performs and this must therefore perform too: `MVar _ CNumber`
keys as `"I"`, exactly like `MInt` (D4 quiescence-before-defaulting), and a
`MVar _ CEcoValue` drops its id (MONO\_003 layout erasure).
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


annoHash : LambdaSetAnno -> Int
annoHash anno =
    case anno of
        LTop ->
            3

        LSet members ->
            List.foldl (\m h -> mixHash h m) 5 members


{-| Smart constructor for `MList`. See the `hashBase` docs.
-}
mList : MonoType -> MonoType
mList inner =
    MList
        (packHashes (mixHash 11 (layoutHashOf inner)) (mixHash 11 (specHashOf inner)))
        inner


{-| Smart constructor for `MTuple`. See the `hashBase` docs.
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


{-| Smart constructor for `MRecord`. See the `hashBase` docs.
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


{-| Smart constructor for `MCustom`. See the `hashBase` docs. Only the LENGTHS
of the canonical and the type name enter the hash — hashing the characters
would put a string walk on every construction, and the eq functions compare
the names themselves when a bucket collides.
-}
mCustom : IO.Canonical -> Name -> List MonoType -> MonoType
mCustom canonical name args =
    let
        (IO.Canonical ( author, project ) modName) =
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


{-| Smart constructor for `MFunction`. See the `hashBase` docs. The lambda-set
annotation enters the SPEC hash only — the layout hash must agree across
arrows that differ solely in their sets, exactly as `toComparableLayoutKey`
does.
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


{-| Comparable-key equality for the SPECIALIZATION flavour:
`eqKeySpec a b == (toComparableMonoType a == toComparableMonoType b)`, but
allocation-free and with early exit. Use it to confirm a hash-keyed hit.
-}
eqKeySpec : MonoType -> MonoType -> Bool
eqKeySpec a b =
    identicalOr True a b


{-| Comparable-key equality for the LAYOUT flavour:
`eqKeyLayout a b == (toComparableLayoutKey a == toComparableLayoutKey b)`.

Do NOT confuse this with `eqLayout`, which is STRICTER: its `a == b` fallback
distinguishes `MVar` ids that the key erases and separates `MVar _ CNumber`
from `MInt`, which the key deliberately merges.

-}
eqKeyLayout : MonoType -> MonoType -> Bool
eqKeyLayout a b =
    identicalOr False a b


{-| Identity fast path for both key flavours (K6 of
`plans/mono-comparable-key-optimization.md`).

Sound in exactly the direction needed: `==` is STRICTER than key equality — it
separates `MVar` ids and `MVar _ CNumber` from `MInt`, both of which the keys
deliberately merge — so `a == b` implies key equality, while the converse does
not hold and is never assumed.

Cheap because the runtime's structural equality returns at the first pointer
comparison (`eqHelp` in `elm-kernel-cpp/src/core/Utils.cpp`), and
construction-time hash-consing (`Compiler.AST.Intern`) makes equal types the
SAME object on the substitution paths. Applied only at the entry points, not
inside `eqKeyWith`'s recursion: a per-node retry would make every MISS pay a
structural walk twice.

-}
identicalOr : Bool -> MonoType -> MonoType -> Bool
identicalOr annoSensitive a b =
    (a == b) || eqKeyWith annoSensitive a b


eqKeyWith : Bool -> MonoType -> MonoType -> Bool
eqKeyWith annoSensitive a b =
    case ( a, b ) of
        ( MList _ xa, MList _ xb ) ->
            eqKeyWith annoSensitive xa xb

        ( MTuple _ xsa, MTuple _ xsb ) ->
            eqKeyList annoSensitive xsa xsb

        ( MRecord _ fieldsA, MRecord _ fieldsB ) ->
            (Dict.size fieldsA == Dict.size fieldsB)
                && eqKeyFields annoSensitive (Dict.toList fieldsA) (Dict.toList fieldsB)

        ( MCustom _ homeA nameA argsA, MCustom _ homeB nameB argsB ) ->
            nameA == nameB && homeA == homeB && eqKeyList annoSensitive argsA argsB

        ( MFunction _ annoA argsA retA, MFunction _ annoB argsB retB ) ->
            (not annoSensitive || annoA == annoB)
                && eqKeyList annoSensitive argsA argsB
                && eqKeyWith annoSensitive retA retB

        _ ->
            -- Leaves, including the two key merges recorded on `leafKeyTag`.
            let
                tagA =
                    leafKeyTag a
            in
            tagA /= 0 && tagA == leafKeyTag b


eqKeyList : Bool -> List MonoType -> List MonoType -> Bool
eqKeyList annoSensitive xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: restX, y :: restY ) ->
            eqKeyWith annoSensitive x y && eqKeyList annoSensitive restX restY

        _ ->
            False


eqKeyFields : Bool -> List ( Name, MonoType ) -> List ( Name, MonoType ) -> Bool
eqKeyFields annoSensitive xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( ( na, ta ) :: restX, ( nb, tb ) :: restY ) ->
            na == nb && eqKeyWith annoSensitive ta tb && eqKeyFields annoSensitive restX restY

        _ ->
            False


-- ============================================================================
-- ====== HASH-KEYED MONOTYPE MAPS (K4) ======
-- ============================================================================


{-| A dictionary keyed by `MonoType` under LAYOUT-key semantics — the
`toComparableLayoutKey` flavour, where arrows compare equal whatever their
lambda sets. Use it for layout-intent dictionaries: the MLIR type registry,
`ctorShapes`, pattern container keys.
-}
type alias LayoutMap v =
    HashMap.HashMap MonoType v


{-| A dictionary keyed by `MonoType` under SPECIALIZATION-key semantics — the
`toComparableMonoType` flavour, where lambda sets deliberately split entries.
-}
type alias SpecMap v =
    HashMap.HashMap MonoType v


{-| **The two flavours are the same TYPE but not interchangeable.** A map
built and read with the layout pair behaves like `toComparableLayoutKey`; one
built and read with the spec pair behaves like `toComparableMonoType`. Mixing
them merges specialization keys with layout keys — the exact bug the M4 `==`
audit exists to prevent, and one that is INVISIBLE with the flag off, because
all-`LTop` graphs key identically under both. Always reach for the `layoutMap*`
family or the `specMap*` family as a set, never a mixture.
-}
layoutMapEmpty : LayoutMap v
layoutMapEmpty =
    HashMap.empty


layoutMapGet : MonoType -> LayoutMap v -> Maybe v
layoutMapGet key m =
    HashMap.get layoutHashOf eqKeyLayout key m


layoutMapMember : MonoType -> LayoutMap v -> Bool
layoutMapMember key m =
    HashMap.member layoutHashOf eqKeyLayout key m


layoutMapInsert : MonoType -> v -> LayoutMap v -> LayoutMap v
layoutMapInsert key value m =
    HashMap.insert layoutHashOf eqKeyLayout key value m


layoutMapSize : LayoutMap v -> Int
layoutMapSize m =
    HashMap.size m


layoutMapIsEmpty : LayoutMap v -> Bool
layoutMapIsEmpty m =
    HashMap.isEmpty m


layoutMapFoldl : (MonoType -> v -> b -> b) -> b -> LayoutMap v -> b
layoutMapFoldl step init m =
    HashMap.foldl step init m


layoutMapMap : (MonoType -> a -> b) -> LayoutMap a -> LayoutMap b
layoutMapMap f m =
    HashMap.map f m


layoutMapToList : LayoutMap v -> List ( MonoType, v )
layoutMapToList m =
    HashMap.toList m


layoutMapValues : LayoutMap v -> List v
layoutMapValues m =
    HashMap.values m


layoutMapFromList : List ( MonoType, v ) -> LayoutMap v
layoutMapFromList entries =
    HashMap.fromList layoutHashOf eqKeyLayout entries


{-| Hash of a `Global`. The NAME is hashed character by character (names are
short and this decides bucket quality for same-shaped globals); the canonical
contributes its lengths only. Cheaper either way than the string
`toComparableGlobal` built per lookup.
-}
globalHash : Global -> Int
globalHash g =
    case g of
        Global (IO.Canonical ( author, project ) modName) name ->
            mixHash
                (mixHash
                    (mixHash (mixHash 21 (String.length author)) (String.length project))
                    (String.length modName)
                )
                (stringHash name)

        Accessor name ->
            mixHash 22 (stringHash name)


stringHash : String -> Int
stringHash s =
    String.foldl (\c h -> mixHash h (Char.toCode c)) 23 s


{-| A map keyed by `SpecKey` — the specialization registry's key. Spec flavour
throughout: two arrows that differ only in their lambda sets are DIFFERENT
specializations.
-}
type alias SpecKeyMap v =
    HashMap.HashMap SpecKey v


specKeyHash : SpecKey -> Int
specKeyHash (SpecKey global monoType) =
    mixHash (globalHash global) (specHashOf monoType)


specKeyEq : SpecKey -> SpecKey -> Bool
specKeyEq (SpecKey g1 t1) (SpecKey g2 t2) =
    g1 == g2 && eqKeySpec t1 t2


specKeyMapEmpty : SpecKeyMap v
specKeyMapEmpty =
    HashMap.empty


specKeyMapGet : SpecKey -> SpecKeyMap v -> Maybe v
specKeyMapGet key m =
    HashMap.get specKeyHash specKeyEq key m


specKeyMapInsert : SpecKey -> v -> SpecKeyMap v -> SpecKeyMap v
specKeyMapInsert key value m =
    HashMap.insert specKeyHash specKeyEq key value m


specKeyMapSize : SpecKeyMap v -> Int
specKeyMapSize m =
    HashMap.size m


{-| Specialization-flavour map operations. See the flavour warning on
`layoutMapEmpty`.
-}
specMapEmpty : SpecMap v
specMapEmpty =
    HashMap.empty


specMapGet : MonoType -> SpecMap v -> Maybe v
specMapGet key m =
    HashMap.get specHashOf eqKeySpec key m


specMapMember : MonoType -> SpecMap v -> Bool
specMapMember key m =
    HashMap.member specHashOf eqKeySpec key m


specMapInsert : MonoType -> v -> SpecMap v -> SpecMap v
specMapInsert key value m =
    HashMap.insert specHashOf eqKeySpec key value m


specMapSize : SpecMap v -> Int
specMapSize m =
    HashMap.size m


specMapIsEmpty : SpecMap v -> Bool
specMapIsEmpty m =
    HashMap.isEmpty m


specMapFoldl : (MonoType -> v -> b -> b) -> b -> SpecMap v -> b
specMapFoldl step init m =
    HashMap.foldl step init m


specMapRemove : MonoType -> SpecMap v -> SpecMap v
specMapRemove key m =
    HashMap.remove specHashOf eqKeySpec key m


specMapSingleton : MonoType -> v -> SpecMap v
specMapSingleton key value =
    specMapInsert key value specMapEmpty


specMapToList : SpecMap v -> List ( MonoType, v )
specMapToList m =
    HashMap.toList m


specMapValues : SpecMap v -> List v
specMapValues m =
    HashMap.values m


-- ============================================================================
-- ====== LAMBDA SETS ======
-- ============================================================================


{-| The lambda-set fact on an arrow. `LTop` = statically unknown or
deliberately widened — exactly today's world; the whole existing pipeline
(boxed closures, papCreate/papExtend, CallGenericApply) is the correct
lowering of `LTop`. `LSet` is a non-empty, ascending-sorted list of member
ids (Phase-0 lambda ids + engine-interned globals/ctors/kernels/accessors);
an unconstrained residual zonks to `LTop`, never to an empty set, so
`LSet []` is unrepresentable by construction (LSS_001).
-}
type LambdaSetAnno
    = LTop
    | LSet (List Int)


{-| Widen every arrow annotation to `LTop`, recursively. Used for
annotation-insensitive keying/comparison (`eqLayout`, budget-widened
specialization keys).
-}
widenSets : MonoType -> MonoType
widenSets monoType =
    case monoType of
        MFunction _ _ args result ->
            mFunction LTop (List.map widenSets args) (widenSets result)

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


{-| Annotation-insensitive structural equality. Layout comparisons must not
become set-sensitive: two types with the same shape but different lambda
sets have identical representation (an arrow is a boxed closure value
regardless of its set — REP_* untouched by LSS).

Allocation-free with early exit (M3.5/M4 scale discipline): the widenSets
formulation copies both types per call, which is ruinous on
self-compile-sized types (the solver's `S` record reaches tens of KB of
structure).

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
            (Dict.size fieldsA == Dict.size fieldsB)
                && eqLayoutFields (Dict.toList fieldsA) (Dict.toList fieldsB)

        ( MCustom _ homeA nameA argsA, MCustom _ homeB nameB argsB ) ->
            nameA == nameB && homeA == homeB && eqLayoutList argsA argsB

        _ ->
            a == b


eqLayoutList : List MonoType -> List MonoType -> Bool
eqLayoutList xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: restX, y :: restY ) ->
            eqLayout x y && eqLayoutList restX restY

        _ ->
            False


eqLayoutFields : List ( Name, MonoType ) -> List ( Name, MonoType ) -> Bool
eqLayoutFields xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( ( na, ta ) :: restX, ( nb, tb ) :: restY ) ->
            na == nb && eqLayout ta tb && eqLayoutFields restX restY

        _ ->
            False


{-| A small, DEPTH-CAPPED layout fingerprint for bucketing (never a full
key): constructors and arities only, annotations ignored, subtrees beyond
the cap collapse to "~". Bounded size regardless of type size, so it is
safe to build once per closure instance and once per candidate call site.
Bucket collisions are resolved by a full `eqLayout` confirm — the
fingerprint only has to be RIGHT, not injective.

The marker is a single opaque ASCII token (`~`, which cannot occur elsewhere
in the key grammar `I F B C S U V L( T<n>( R<n>( X<name><n>( A<n>( -> , )`).
It was formerly U+2026 (`…`), a non-ASCII code point that forced the whole
key to UTF-16 and made every subsequent ASCII fragment append widen — see
`utf8-widen-cliff-solver-2026-07-31.md`. ASCII keeps the append path UTF-8.
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


{-| The head arrow's annotation; `LTop` for non-function types.
-}
headAnno : MonoType -> LambdaSetAnno
headAnno monoType =
    case monoType of
        MFunction _ anno _ _ ->
            anno

        _ ->
            LTop


{-| Pointwise annotation join of two layout-identical types (LSS_010).

Used on spec-registry key hits under widened keys: the stored type must be
the JOIN of every admitted demand's annotations, because the (single)
translated node serves all of those callers — seeding it from just the
first demand lets a singleton annotation lie about later callers' values
(a fast-dispatch stamp on such a site is a silent miscompile). Layout
mismatch (impossible for same-widened-key inputs, but total anyway) falls
back to widening the whole type — always sound.

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
            if Dict.keys fieldsA == Dict.keys fieldsB then
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


{-| Structure from the FIRST type, lambda-set annotations from the SECOND
where the layouts agree pointwise (keep the first's annotation on any
mismatch). NOT a join: `unionAnno` treats `LTop` as absorbing, but here
the first type is a storeless classification whose annotations are all
`LTop` placeholders — the store zonk's sets must REPLACE them, not be
absorbed by them.

This is the M3-transport ABI guard: binder/param/node types must keep the
byte-path `classify` STRUCTURE (the storeless classification is the ABI
truth the rest of codegen — tail-rec loop params, case results — is built
around), while the demand-seeded store zonk contributes ONLY annotations.
Letting the zonk decide structure diverged on demand-concretized erased
leaves and number residuals, yielding loop-param ABI mismatches at
self-compile scale (eco.case result i64 vs !eco.value yields).

-}
overlayAnnotations : MonoType -> MonoType -> MonoType
overlayAnnotations structural annoSource =
    case ( structural, annoSource ) of
        ( MFunction _ annoA argsA retA, MFunction _ annoB argsB retB ) ->
            if List.length argsA == List.length argsB then
                mFunction annoB (List.map2 overlayAnnotations argsA argsB) (overlayAnnotations retA retB)

            else
                mFunction annoA argsA retA

        ( MList _ xa, MList _ xb ) ->
            mList (overlayAnnotations xa xb)

        ( MTuple _ xsa, MTuple _ xsb ) ->
            if List.length xsa == List.length xsb then
                mTuple (List.map2 overlayAnnotations xsa xsb)

            else
                structural

        ( MRecord _ fieldsA, MRecord _ fieldsB ) ->
            if Dict.keys fieldsA == Dict.keys fieldsB then
                mRecord (Dict.map (\k ta -> overlayAnnotations ta (Maybe.withDefault ta (Dict.get k fieldsB))) fieldsA)

            else
                structural

        ( MCustom _ homeA nameA argsA, MCustom _ homeB nameB argsB ) ->
            if homeA == homeB && nameA == nameB && List.length argsA == List.length argsB then
                mCustom homeA nameA (List.map2 overlayAnnotations argsA argsB)

            else
                structural

        _ ->
            structural


{-| The sole member of a singleton head annotation, if any.

Every GlobalOpt-synthesized closure whose provenance is unknown (alias /
general wrappers from wrapTopLevelCallables) must adopt this identity as
its `srcLambda` (LSS_008): its type claims exactly one member, so the
wrapper must register as an instance of that member — instance
MULTIPLICITY is what keeps AbiCloning's singleton upgrade sound. A
synthesized closure hiding under `srcLambda = Nothing` while its type
names one member would let the upgrade stamp that member's evaluator and
capture ABI at sites whose runtime value is the wrapper.

-}
singletonHeadMember : MonoType -> Maybe Int
singletonHeadMember monoType =
    case headAnno monoType of
        LSet [ m ] ->
            Just m

        _ ->
            Nothing


{-| Join two annotations: the least annotation covering both. `LTop`
absorbs; sets union (kept ascending-sorted for key canonicality).
-}
unionAnno : LambdaSetAnno -> LambdaSetAnno -> LambdaSetAnno
unionAnno a b =
    case ( a, b ) of
        ( LTop, _ ) ->
            LTop

        ( _, LTop ) ->
            LTop

        ( LSet xs, LSet ys ) ->
            LSet (unionSortedInts xs ys)


{-| Union of two ascending-sorted int lists, ascending and deduplicated.
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


{-| Closing operator for quiescence-before-defaulting: structurally resolve every
residual number var in a MonoType to `MInt`.

Table-consulting: a var closes to `MInt` if EITHER its stamped constraint is
`CNumber` (an original number var) OR the `isNumber` predicate reports its id as
number-tainted in the final `superVars` (a boxed var that Join-R merged into a
number class after this copy was stamped — the stale `CEcoValue` stamp is
healed). A genuine, never-tainted `CEcoValue` var is left untouched (boxed).
`applySubst` no longer defaults number vars during the fixpoint; this discharges
them once, at the end, from `resolveResidualNumbers`.

-}
resolveNumberType : (MVarId -> Bool) -> MonoType -> MonoType
resolveNumberType isNumber monoType =
    -- Identity-preserving (perf): a residual number var is rare, so short-circuit
    -- and return the input by reference when the type has none — no copy. Only
    -- rebuild the subtrees that actually contain a residual.
    if typeHasResidualNumber isNumber monoType then
        resolveNumberTypeRebuild isNumber monoType

    else
        monoType


{-| Does the type contain a residual number var — `MVar _ CNumber`, or an
`MVar id CEcoValue` that `isNumber` reports as Join-R-tainted? Allocation-free.
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
            List.any (typeHasResidualNumber isNumber) elems

        MRecord _ fields ->
            Dict.foldl (\_ t acc -> acc || typeHasResidualNumber isNumber t) False fields

        MCustom _ _ _ args ->
            List.any (typeHasResidualNumber isNumber) args

        MFunction _ _ args result ->
            List.any (typeHasResidualNumber isNumber) args || typeHasResidualNumber isNumber result

        _ ->
            False


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
            -- Rebuilder: thread the annotation through (never stamp LTop here).
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


{-| Extract the final result type from a (possibly curried) function type.
E.g., MFunction [MInt] (MFunction [MInt] MInt) -> MInt
For non-function types, returns the type itself.
-}
resultTypeOf : MonoType -> MonoType
resultTypeOf monoType =
    case monoType of
        MFunction _ _ _ result ->
            resultTypeOf result

        _ ->
            monoType


{-| Check whether a MonoType contains any `MVar` (any constraint).
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


containsAnyMVarList : List MonoType -> Bool
containsAnyMVarList types =
    case types of
        [] ->
            False

        t :: rest ->
            containsAnyMVar t || containsAnyMVarList rest


{-| Identifier for lambda functions in lambda sets, distinguishing named functions from closures.
-}
type LambdaId
    = AnonymousLambda IO.Canonical Int



-- ============================================================================
-- ====== SPECIALIZATION KEYS AND IDS ======
-- ============================================================================


{-| A reference to a top-level definition in a module, or a virtual
global for record field accessors (.field).
-}
type Global
    = Global IO.Canonical Name
    | Accessor Name


{-| Key identifying a unique specialization of a polymorphic function.
-}
type SpecKey
    = SpecKey Global MonoType


{-| Unique integer identifier for a function specialization.
-}
type alias SpecId =
    Int


{-| Registry tracking all function specializations in the program.
-}
type alias SpecializationRegistry =
    { nextId : Int
    , mapping : SpecKeyMap SpecId
    , reverseMapping : Array (Maybe ( Global, MonoType ))
    }



-- ============================================================================
-- ====== CONSTRUCTOR SHAPES ======
-- ============================================================================


{-| Backend-agnostic constructor shape: name, tag, field types.

This captures the semantic structure without layout-specific details like
field indices and unboxing bitmaps. The CtorLayout is computed from this
shape during code generation.

-}
type alias CtorShape =
    { name : Name
    , tag : Int
    , fieldTypes : List MonoType
    }



-- ============================================================================
-- ====== MONO GRAPH ======
-- ============================================================================


{-| The complete monomorphized program graph containing all specialized definitions.
-}
type MonoGraph
    = MonoGraph
        { nodes : Array (Maybe MonoNode)
        , main : Maybe MainInfo
        , registry : SpecializationRegistry
        , ctorShapes : LayoutMap (List CtorShape)
        , nextLambdaIndex : Int
        , callEdges : Array (Maybe (List Int)) -- Collected during monomorphization. Reuse in downstream passes instead of re-traversing MonoExpr trees.
        , specHasEffects : BitSet -- SpecIds whose node body references Debug.* kernels
        , specValueUsed : BitSet -- SpecIds whose value is referenced via MonoVarGlobal
        , ports : List PortRegistration -- Ports reached during monomorphization; drives @__eco_register_ports emission (PORT_003)
        , flagsDecoder : Maybe SpecId -- The root program's flags decoder (Phase 5); registered at startup like port decoders
        , lssMemberOrigins : Dict Int MemberOrigin -- B3.5: LSS standalone-member origins (mid → global/ctor/kernel/accessor); Dict.empty under subst
        }


{-| What an LSS member id resolves to when it is NOT a lambda (borrow B3.5,
design §10). Built by inverting `LssMemberTable.byKey` at the solver assemble
site; empty under the subst engine.
-}
type MemberOrigin
    = OriginGlobal Global -- g| members (Monomorphized's own Global)
    | OriginKernel Name Name -- k| members (home, name; prefix dropped)
    | OriginCtor Global -- c| members
    | OriginAccessor Name -- a| members (field name)


{-| One port registration collected during monomorphization.

`name` is the bare port name — the effect-manager registry key, globally
unique per program (PORT\_001, JS `_Platform_checkPortName` parity). For
incoming ports `decoderSpecId` points at the synthetic `MonoDefine`
specialization holding the payload `Decoder` value; Prune keeps it
reachable and the MLIR backend's `@__eco_register_ports` preamble calls
its thunk to register the decoder with the runtime.

-}
type alias PortRegistration =
    { name : String
    , key : String -- comparable Global; dedup key (same port, many instantiations)
    , incoming : Bool
    , decoderSpecId : Maybe SpecId
    }


{-| Information about the main entry point.

  - Static: A simple main value (Html, Svg, etc.)
  - Dynamic: An application with flags decoder (Browser.element, etc.)

-}
type MainInfo
    = StaticMain SpecId -- main specId, flags decoder expression



-- ============================================================================
-- ====== MONO NODES ======
-- ============================================================================


{-| A node in the monomorphized dependency graph representing a specialized definition.
-}
type MonoNode
    = MonoDefine MonoExpr MonoType
    | MonoTailFunc (List ( Name, MonoType )) MonoExpr MonoType
    | MonoCtor CtorShape MonoType -- Layout computed from shape at codegen
    | MonoEnum Int MonoType
    | MonoExtern MonoType
    | MonoManagerLeaf String MonoType -- Effect manager leaf: home module name, type
    | MonoPortIncoming MonoExpr MonoType
    | MonoPortOutgoing MonoExpr MonoType



-- ============================================================================
-- ====== MONO EXPRESSIONS ======
-- ============================================================================


{-| Extract the MonoType from any MonoNode variant.
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


{-| A monomorphized expression with concrete types and explicit closures.
-}
type MonoExpr
    = MonoLiteral Literal MonoType
    | MonoVarLocal Name MonoType
    | MonoVarGlobal Region SpecId MonoType
    | MonoVarKernel Region Name Name Name MonoType -- kernel prefix, home, name, type
    | MonoList Region (List MonoExpr) MonoType
    | MonoClosure ClosureInfo MonoExpr MonoType
    | MonoCall Region MonoExpr (List MonoExpr) MonoType CallInfo
    | MonoTailCall Name (List ( Name, MonoExpr )) MonoType
    | MonoIf (List ( MonoExpr, MonoExpr )) MonoExpr MonoType
    | MonoLet MonoDef MonoExpr MonoType
    | MonoDestruct MonoDestructor MonoExpr MonoType
    | MonoCase Name Name (Decider MonoChoice) (List ( Int, MonoExpr )) MonoType
    | MonoRecordCreate (List ( Name, MonoExpr )) MonoType -- Fields with names, codegen reorders by layout
    | MonoRecordAccess MonoExpr Name MonoType -- Field name only, codegen computes index/isUnboxed
    | MonoRecordUpdate MonoExpr (List ( Name, MonoExpr )) MonoType -- Field names, codegen computes indices
    | MonoTupleCreate Region (List MonoExpr) MonoType -- Layout computed at codegen
    | MonoUnit
    | MonoAccessorValue Region Name MonoType -- Deferred accessor .field value; eliminated by ResolveAccessorValues


{-| Literal values in monomorphized expressions.
-}
type Literal
    = LBool Bool
    | LInt Int
    | LFloat Float
    | LChar String
    | LStr String


{-| Information about a closure including its lambda ID, captured variables, and parameters.

Extended for typed closure calling:

  - closureKind: Three-way lattice state for ABI cloning
  - captureAbi: Explicit capture ABI (for closures with captures)

-}
type alias ClosureInfo =
    { lambdaId : LambdaId
    , srcLambda : Maybe TypeIds.SrcLambdaId -- source identity (LSS member); several instances MAY share one (inliner copies verbatim — unlike lambdaId, MONO_019)
    , lssMember : Maybe Int -- Fix B (LSS_017): the member id this instance was minted under — spec-qualified for keyed-routed globals, srcLambdaKey otherwise. AbiCloning's index key; keeps annotations and instances in ONE member space. Nothing when lss is off or the lambda is untagged.
    , captures : List ( Name, MonoExpr, Bool )
    , params : List ( Name, MonoType )
    , closureKind : MaybeClosureKind
    , captureAbi : Maybe CaptureABI
    }


{-| A local definition in monomorphized code.
-}
type MonoDef
    = MonoDef Name MonoExpr
    | MonoTailDef Name (List ( Name, MonoType )) MonoExpr


{-| Destructuring pattern for extracting values from data structures.
Contains the variable name, path to navigate to the value, and the type of the destructured value.
-}
type MonoDestructor
    = MonoDestructor Name MonoPath MonoType


{-| The kind of container being navigated during destructuring.

This is used to select the correct runtime projection operation:

  - ListContainer: eco.project.list.head / eco.project.list.tail
  - Tuple2Container: eco.project.tuple2
  - Tuple3Container: eco.project.tuple3
  - CustomContainer: eco.project (generic custom type)
  - RecordContainer: eco.project (record field access)

-}
type ContainerKind
    = ListContainer
    | Tuple2Container
    | Tuple3Container
    | CustomContainer Name -- Constructor name for layout lookup


{-| Path for navigating into a data structure during destructuring.

MonoIndex now carries ContainerKind and MonoType to enable type-specific projection ops.
The MonoType is the RESULT type of evaluating that path segment.
In generateMonoPath, the container type for a MonoIndex is obtained via getMonoPathType subPath.

-}
type MonoPath
    = MonoIndex Int ContainerKind MonoType MonoPath -- MonoType = result type after projection
    | MonoField Name MonoType MonoPath -- MonoType = result type after field access (record field by name)
    | MonoUnbox MonoType MonoPath -- MonoType = result type after unwrapping (the field type)
    | MonoRoot Name MonoType -- MonoType = variable's type


{-| Get the result type of evaluating a MonoPath.
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


{-| Convert a MonoType to a simple debug string for error messages.
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


{-| A typed path for decision-tree navigation.

Mirrors `MonoPath` but only carries the constructors relevant to decision trees
(Index, Unbox, Root — no Field or ArrayIndex). The root embeds the scrutinee
variable name and its MonoType, so codegen does not need a separate `root` param.

-}
type MonoDtPath
    = DtRoot Name MonoType
    | DtIndex Int ContainerKind MonoType MonoDtPath
    | DtUnbox MonoType MonoDtPath


{-| Get the result type of evaluating a MonoDtPath.
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


{-| Decision tree for pattern matching.

This matches the structure of Opt.Decider from Compiler.AST.Optimized:

  - Chain carries a list of (MonoDtPath, Test) pairs for the condition
  - FanOut carries the MonoDtPath being tested

-}
type Decider a
    = Leaf a
    | Chain (List ( MonoDtPath, DT.Test )) (Decider a) (Decider a)
    | FanOut MonoDtPath (List ( DT.Test, Decider a )) (Decider a)


{-| Action to take when a pattern match succeeds.
-}
type MonoChoice
    = Inline MonoExpr
    | Jump Int



-- ============================================================================
-- ====== TYPE UTILITIES ======
-- ============================================================================


{-| Extract the monomorphic type from any expression.
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


{-| Convert a global reference to a comparable key for use in dictionaries.
-}
toComparableGlobal : Global -> String
toComparableGlobal global =
    case global of
        Global home name ->
            let
                (IO.Canonical ( author, project ) modName) =
                    home
            in
            String.concat [ "G", author, "\u{0000}", project, "\u{0000}", modName, "\u{0000}", name ]

        Accessor fieldName ->
            String.concat [ "A", fieldName ]


{-| Convert a monomorphic type to a comparable String key for use in dictionaries.

This is used for:

  - Specialization keys in the monomorphization registry
  - Let-bound multi-specialization (localMulti / valueMulti)
  - Type table keys in MLIR codegen

IMPORTANT: `MVar _ CEcoValue` is layout-erased (MONO\_003). All such variables
are normalized to a canonical placeholder ID when building this comparable key,
so fresh MVarIds do not produce distinct keys. `MVar _ CNumber` retains its
numeric ID to preserve distinct numeric specializations.

Fragments are emitted straight into a `List String` and concatenated once,
for O(n) instead of the O(n²) of repeated `++`. See `toComparableFragments`
for the emission order and what it deliberately does NOT allocate.

-}
toComparableMonoType : MonoType -> String
toComparableMonoType monoType =
    String.concat (toComparableFragments True monoType [])


{-| Annotation-INSENSITIVE comparable key: identical to
`toComparableMonoType` except every arrow keys as the plain `"A("`
fragment regardless of its lambda set (M4 `==` audit, design §5.2).

Use this for LAYOUT-intent dictionaries — the MLIR type registry,
`ctorShapes` build/lookup, pattern container keys: two types with the same
shape have identical representation whatever their sets (REP\_\* untouched
by LSS), so a set-bearing key on one side of such a Dict and not the other
is a silent miss. Keep `toComparableMonoType` for SPECIALIZATION-intent
keys (the registry under `keyed = True`, per-instance local-multi keys),
where sets deliberately split entries. Flag-off graphs are all-`LTop`, so
both functions produce byte-identical strings there.

-}
toComparableLayoutKey : MonoType -> String
toComparableLayoutKey monoType =
    String.concat (toComparableFragments False monoType [])


{-| Emit the comparable-key fragments for a MonoType in FORWARD order,
prepended onto `tail`.

The encoding is byte-identical to the explicit-work-stack helper this
replaced: children are emitted LAST-TO-FIRST, because that stack was built
with `List.foldl (::)` and therefore popped its children in reverse.
Building forward onto a tail deletes three allocation pools that shape
needed — the `WorkItem` wrappers, the work-stack cons cells and the
`List.reverse` copy — leaving only the fragment cons cells themselves
(K2 of `plans/mono-comparable-key-optimization.md`).

Stack depth is type NESTING depth, bounded by source syntax; breadth costs
no stack, because the child walkers below recurse in tail position.

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
                    -- Layout-erased: ignore numeric ID (MONO_003). All CEcoValue MVars
                    -- produce the same key fragment so fresh IDs don't split specializations.
                    "V" :: "0" :: "\u{0000}" :: "ecovalue" :: tail

                CNumber ->
                    -- Quiescence-before-defaulting (D4): an OPEN number var is
                    -- a residual that closes to Int (Float always manifests as
                    -- bound MFloat, never open CNumber, at a locally-quiescent
                    -- key point). Key it IDENTICALLY to MInt ("I") so open-number
                    -- and explicit-Int instantiations of a global merge to one
                    -- specialization (they are the same after
                    -- the residual-number close in Prune), while Float ("F") stays distinct
                    -- and the boxed CEcoValue sentinel ("V") stays distinct from
                    -- i64. The MVarId is dropped so fresh ids never split specs.
                    -- Callers apply `refreshConstraints` before keying so a
                    -- number-tainted (Join-R) var reaches this arm.
                    "I" :: tail

        MList _ inner ->
            "L(" :: toComparableFragments annoSensitive inner (")" :: tail)

        MTuple _ elementTypes ->
            "T"
                :: String.fromInt (List.length elementTypes)
                :: "("
                :: toComparableFragmentsRev annoSensitive elementTypes (")" :: tail)

        MRecord _ fields ->
            -- Dict.foldl walks ascending field order and PREPENDS, which lands the
            -- fields in the same reverse order the work stack popped them — and
            -- skips the `Dict.toList` pair list that version had to build.
            "R("
                :: Dict.foldl
                    (\name ty acc -> name :: toComparableFragments annoSensitive ty acc)
                    (")" :: tail)
                    fields

        MCustom _ canonical name args ->
            let
                (IO.Canonical ( author, project ) modName) =
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
                -- LTop must keep today's exact "A(" fragment so that
                -- all-LTop graphs key byte-identically (M1 gate).
                annoKey =
                    if annoSensitive then
                        case anno of
                            LTop ->
                                "A("

                            LSet members ->
                                "A[" ++ String.join "," (List.map String.fromInt members) ++ "]("

                    else
                        -- toComparableLayoutKey: arrows key uniformly —
                        -- layout-intent Dicts must not split on sets.
                        "A("
            in
            annoKey
                :: toComparableFragmentsRev annoSensitive
                    args
                    ("->" :: toComparableFragments annoSensitive ret (")" :: tail))


{-| Emit fragments for a list of types LAST-TO-FIRST, matching the pop order of
the work stack this replaced. Tail-recursive, so breadth costs no stack.
-}
toComparableFragmentsRev : Bool -> List MonoType -> List String -> List String
toComparableFragmentsRev annoSensitive types tail =
    case types of
        [] ->
            tail

        ty :: rest ->
            toComparableFragmentsRev annoSensitive rest (toComparableFragments annoSensitive ty tail)


{-| Convert a specialization key to a single comparable String for use in dictionaries.

Uses compact encoding to avoid intermediate List allocation.
Parts are separated by \\u{0001}.

-}
toComparableSpecKey : SpecKey -> String
toComparableSpecKey (SpecKey global monoType) =
    String.concat
        [ toComparableGlobal global
        , "\u{0001}"
        , toComparableMonoType monoType
        ]



-- ============================================================================
-- ====== FUNCTION SHAPE HELPERS ======
-- ============================================================================


{-| Check if a MonoType is a function type.
-}
isFunctionType : MonoType -> Bool
isFunctionType monoType =
    case monoType of
        MFunction _ _ _ _ ->
            True

        _ ->
            False


{-| Count the total number of arguments in a curried function type.
-}
countTotalArity : MonoType -> Int
countTotalArity monoType =
    case monoType of
        MFunction _ _ argTypes result ->
            List.length argTypes + countTotalArity result

        _ ->
            0


{-| Stage parameter types: outermost mFunction argument list.
-}
stageParamTypes : MonoType -> List MonoType
stageParamTypes monoType =
    case monoType of
        MFunction _ _ argTypes _ ->
            argTypes

        _ ->
            []


{-| Stage return type: the result type after applying the current stage's arguments.

For `MFunction [a, b] (MFunction [c] d)`, this returns `MFunction [c] d`.
For non-function types, returns the type itself.

-}
stageReturnType : MonoType -> MonoType
stageReturnType monoType =
    case monoType of
        MFunction _ _ _ result ->
            result

        other ->
            other


{-| Decompose a function type into its flattened arguments and final result.
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


{-| A Segmentation is a list of stage arities: [m1, m2, ...] means
stage 1 takes m1 args, stage 2 takes m2 args, etc.
-}
type alias Segmentation =
    List Int


{-| Call model of a function, independent of backend.
This is the AST-side version; MLIR Context.CallModel can be removed.
-}
type CallModel
    = FlattenedExternal
    | StageCurried


{-| Call lowering strategy, determined by GlobalOpt based on closure kind
analysis and staging solver results. Controls how MLIR codegen lowers the call.

  - CallDirectKnownSegmentation: staging is known, use typed papExtend with
    remaining\_arity and typed closure calling dispatch.
  - CallDirectFlat: flattened external/kernel call, no staged currying.
  - CallGenericApply: closure kind is heterogeneous or unknown, or staging
    slot is dynamic. Use generic-mode eco.papExtend (no remaining\_arity),
    which determines saturation at runtime from the closure header.

-}
type CallKind
    = CallDirectKnownSegmentation
    | CallDirectFlat
    | CallGenericApply
    | CallSegmentationUnknown


{-| Staging / call-site metadata for MonoCall.

  - callModel: FlattenedExternal vs StageCurried
  - stageArities: Full list of stage arities [a1, a2, ...] for the callee.
  - isSingleStageSaturated: True if this call consumes all arguments and
    fits entirely in the first stage.
  - initialRemaining: Stage arity of the current closure value at this call site
    (used as sourceRemaining in applyByStages).
  - remainingStageArities: Stage arities for subsequent stages after saturating
    the current closure (used in applyByStages).
  - evaluatorReturnType: Mono return type of the evaluator func.func invoked
    at this call site (one MFunction peel from the callee's type). Used by
    MLIR codegen to satisfy CGEN\_056: typed saturating papExtends must use
    the evaluator's func.func result type, NOT the caller's
    MonoCall.resultType, which differs from it on over-saturated calls.

Extended for typed closure calling:

  - closureKind: Three-way lattice for callee value's closure kind
  - captureAbi: For typed closure calls with known ABI
  - fastEvaluator: LambdaId of the UNIQUE reachable closure instance the
    callee value must be (stamped by AbiCloning's LSS singleton upgrade,
    design §9.2/§9.3). MLIR codegen derives the fast-clone symbol from it
    (`lambdaIdToString id ++ "$cap"` when captures are non-empty, the base
    name otherwise) and emits `_fast_evaluator`/`_capture_abi` on the
    saturating typed papExtend. Only consulted on the
    CallGenericApply/CallSegmentationUnknown emission paths — sites the
    staging solver could not type; advisory metadata everywhere else.
  - fastPapPrefix: E2 PAP-shape stamp (LSS_011). `Just k` when the stamped
    callee value is a PAP of the fastEvaluator instance holding k applied
    args: `captureAbi.captureTypes` then equals the instance's REAL
    captures ++ its first k param types (the PAP's filled value slots, in
    slot order), and `captureAbi.paramTypes` is the remaining param
    suffix. Codegen must derive the bare-vs-$cap symbol from the REAL
    capture count (`length captureTypes - k`), not from captureTypes
    alone — a captureless member has no $cap clone.

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
    , fastPapPrefix : Maybe Int
    , callKind : CallKind
    , evaluatorReturnType : MonoType
    }


{-| Default/placeholder CallInfo for newly constructed calls.
Will be overwritten by annotateCallStaging pass in GlobalOpt.
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
    , fastPapPrefix = Nothing
    , callKind = CallGenericApply
    , evaluatorReturnType = MUnit
    }


{-| Extract the staging pattern (segment lengths) from a function type.
For `MFunction [A,B] (MFunction [C,D] R)` returns `[2, 2]`.
For `MFunction [A,B,C,D] R` returns `[4]`.
For non-function types returns `[]`.
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


{-| Choose the canonical ABI segmentation for a join point.
Given leaf function types from case branches:

1.  Pick the segmentation that appears most often (minimize wrappers)
2.  Among ties, pick the one with fewest stages (prefer flatter)

Returns (canonicalSegmentation, flatArgs, flatRet).

-}
chooseCanonicalSegmentation : List MonoType -> ( Segmentation, List MonoType, MonoType )
chooseCanonicalSegmentation leafTypes =
    case leafTypes of
        [] ->
            -- Should not happen for well-formed MonoCase
            ( [], [], MUnit )

        firstType :: _ ->
            let
                -- Shared flattened signature (all branches must agree)
                ( flatArgs, flatRet ) =
                    decomposeFunctionType firstType

                -- Count how often each segmentation occurs
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

                -- Find maximum count
                maxCount =
                    Dict.foldl (\_ count acc -> max count acc) 0 freqDict

                -- All segmentations that hit maxCount
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

                -- Among them, prefer fewest stages (most flat)
                canonicalSeg =
                    case List.sortBy List.length bestSegs of
                        shortest :: _ ->
                            shortest

                        [] ->
                            -- Fallback: use first type's segmentation
                            segmentLengths firstType
            in
            ( canonicalSeg, flatArgs, flatRet )


{-| Rebuild a nested mFunction from flat args and a segmentation.
buildSegmentedFunctionType anno [A,B,C,D] R [2,2] = MFunction anno [A,B] (MFunction anno [C,D] R)
buildSegmentedFunctionType anno [A,B,C,D] R [4] = MFunction anno [A,B,C,D] R

The annotation is stamped on EVERY stage arrow it builds: the stages of one
callable share provenance (PAP results keep the underlying callee's member),
so re-segmenting a type must not lose or invent set facts. Callers derive
`anno` from the original type's head arrow (`headAnno`), joining branch
annotations (`unionAnno`) where several types merge.
-}
buildSegmentedFunctionType : LambdaSetAnno -> List MonoType -> MonoType -> Segmentation -> MonoType
buildSegmentedFunctionType anno flatArgs finalRet seg =
    let
        -- Split flatArgs according to seg = [m1, m2, ...]
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
    -- Build nested MFunction from inside out
    List.foldr
        (\stageArgs acc -> mFunction anno stageArgs acc)
        finalRet
        stageArgsLists



-- ============================================================================
-- ====== TYPED CLOSURE CALLING (ABI CLONING) ======
-- ============================================================================


{-| Unique identifier for a closure kind (lambda + capture ABI combination).
Each distinct closure creation site with a unique capture ABI gets its own ID.
-}
type ClosureKindId
    = ClosureKindId Int


{-| Three-way lattice for closure kind tracking.

  - Known id: definitely this specific closure kind (homogeneous)
  - Heterogeneous: definitely one of several closure kinds (analysis proved it)

This is wrapped in Maybe to provide the third state (Nothing = unknown/untracked).

-}
type ClosureKind
    = Known ClosureKindId


{-| Maybe ClosureKind provides the third state:

  - Just (Known id): homogeneous - SSA value is definitely closure kind `id`
  - Just Heterogeneous: known heterogeneous - SSA value is one of multiple closure kinds
  - Nothing: unknown - no closure-kind info (non-closure, legacy path, or analysis bug)

-}
type alias MaybeClosureKind =
    Maybe ClosureKind


{-| The ABI signature for a closure's captures + params + return.
Used to determine if two closures have compatible calling conventions.
-}
type alias CaptureABI =
    { captureTypes : List MonoType
    , paramTypes : List MonoType
    , returnType : MonoType
    }
