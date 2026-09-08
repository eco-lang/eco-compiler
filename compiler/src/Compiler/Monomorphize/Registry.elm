module Compiler.Monomorphize.Registry exposing
    ( KeyedHit(..)
    , emptyRegistry
    , getOrCreateSpecId
    , getOrCreateSpecIdKeyed
    , lookupSpecKey
    , updateRegistryType
    , breadthLimitMessage, createdCount, prettyGlobal, typeNodesLimitMessage
    )

{-| Specialization registry operations for monomorphization.

This module provides functions for managing the specialization registry, which
tracks all type specializations of polymorphic functions during monomorphization.

The registry maintains a bidirectional mapping between specialization keys
(function + concrete type + optional lambda ID) and unique specialization IDs.


# Registry Operations

@docs KeyedHit
@docs emptyRegistry
@docs getOrCreateSpecId
@docs getOrCreateSpecIdKeyed
@docs lookupSpecKey
@docs updateRegistryType

-}

import Array
import Compiler.AST.Monomorphized as Mono exposing (Global, MonoType, SpecId, SpecializationRegistry)
import Compiler.Elm.ModuleName as ModuleName
import Dict



-- ====== REGISTRY OPERATIONS ======


{-| Outcome of a keyed registry probe.

Phase 1 of `plans/lss-set-write-substrate.md` splits what used to be a bare
`Bool` (`storedChanged`) into the three hit shapes the census needs: the
branches already existed inside `getOrCreateSpecIdKeyed`, they simply were
not distinguishable by the caller. `HitChangedJoin` is the old `True`;
everything else is the old `False`.

  - `CreatedNew` — key miss, a new SpecId was allocated.
  - `HitIdentical` — the stored type is bit-identical to the demand; no join
    ran (the cheapest exit).
  - `HitNoopJoin` — the join ran, rebuilt a tree, and changed nothing; the
    result was discarded. Pure waste, and the population Phase 4 targets.
  - `HitChangedJoin` — the join widened the stored type; the caller must mark
    the spec dirty (LSS\_010).

-}
type KeyedHit
    = CreatedNew
    | HitIdentical
    | HitNoopJoin
    | HitChangedJoin


{-| Create an empty specialization registry.
-}
emptyRegistry : SpecializationRegistry
emptyRegistry =
    { nextId = 0
    , mapping = Mono.specKeyMapEmpty
    , reverseMapping = Array.empty
    , countByGlobal = Dict.empty
    }


{-| MONO\_030: bump the created-spec count for a global. Called only on the
create/miss branches — probe hits never touch it.
-}
bumpCountByGlobal : Global -> SpecializationRegistry -> Dict.Dict String Int
bumpCountByGlobal global registry =
    Dict.update (Mono.toComparableGlobal global)
        (\v -> Just (Maybe.withDefault 0 v + 1))
        registry.countByGlobal


{-| The created-spec count for a global (MONO\_030 breadth watchdog probe).
-}
createdCount : Global -> SpecializationRegistry -> Int
createdCount global registry =
    Maybe.withDefault 0 (Dict.get (Mono.toComparableGlobal global) registry.countByGlobal)


{-| Get an existing SpecId for a specialization key, or create a new one.

Returns the SpecId and the (possibly updated) registry.

-}
getOrCreateSpecId : Global -> MonoType -> SpecializationRegistry -> ( SpecId, SpecializationRegistry )
getOrCreateSpecId global monoType registry =
    let
        key =
            Mono.SpecKey global monoType
    in
    case Mono.specKeyMapGet key registry.mapping of
        Just specId ->
            ( specId, registry )

        Nothing ->
            let
                specId =
                    registry.nextId
            in
            ( specId
            , { nextId = specId + 1
              , mapping = Mono.specKeyMapInsert key specId registry.mapping
              , reverseMapping = Array.push (Just ( global, monoType )) registry.reverseMapping
              , countByGlobal = bumpCountByGlobal global registry
              }
            )


{-| Like `getOrCreateSpecId`, but the dedup KEY is computed from `keyType`
while the reverse mapping stores `storeType`. LSS `keyed = False` semantics
(design §8.5): keys are annotation-widened so lambda sets never fan out
specializations, while the stored demand keeps its annotations (types never
widen — MONO\_020/021/024).

On a key hit the stored type becomes the annotation JOIN of itself and the
new demand (LSS\_010): the single translated node serves every caller that
hits this key, so its demand-seeded annotations must cover all of them —
keeping only the first demand lets a singleton set lie about later
callers' values, which a fast-dispatch stamp turns into a silent
miscompile. `HitChangedJoin` means the join CHANGED the stored type — the
caller must re-translate an already-translated spec.

-}
getOrCreateSpecIdKeyed : Global -> MonoType -> MonoType -> SpecializationRegistry -> ( SpecId, SpecializationRegistry, KeyedHit )
getOrCreateSpecIdKeyed global keyType storeType registry =
    let
        key =
            Mono.SpecKey global keyType
    in
    case Mono.specKeyMapGet key registry.mapping of
        Just specId ->
            case Array.get specId registry.reverseMapping |> Maybe.andThen identity of
                Just ( storedGlobal, storedType ) ->
                    if storedType == storeType then
                        -- Common case: identical demand — one == walk, no join.
                        ( specId, registry, HitIdentical )

                    else
                        -- Phase 4a: the changed flag replaces the old
                        -- rebuild-then-compare pair. `False` means the join
                        -- added nothing to the stored type, and no tree was
                        -- rebuilt to discover it (was: full-tree rebuild + a
                        -- second full `==` walk + discard).
                        case Mono.joinAnnotationsChanged storedType storeType of
                            ( False, _ ) ->
                                ( specId, registry, HitNoopJoin )

                            ( True, joined ) ->
                                ( specId
                                , { registry
                                    | reverseMapping =
                                        Array.set specId (Just ( storedGlobal, joined )) registry.reverseMapping
                                  }
                                , HitChangedJoin
                                )

                Nothing ->
                    ( specId, registry, HitIdentical )

        Nothing ->
            let
                specId =
                    registry.nextId
            in
            ( specId
            , { nextId = specId + 1
              , mapping = Mono.specKeyMapInsert key specId registry.mapping
              , reverseMapping = Array.push (Just ( global, storeType )) registry.reverseMapping
              , countByGlobal = bumpCountByGlobal global registry
              }
            , CreatedNew
            )


{-| Human-facing rendering of a Global for the watchdog messages —
`Module.name (author/project)`, not the raw comparable key.
-}
prettyGlobal : Global -> String
prettyGlobal global =
    case global of
        Mono.Global (ModuleName.Canonical ( author, project ) moduleName) name ->
            moduleName ++ "." ++ name ++ " (" ++ author ++ "/" ++ project ++ ")"

        Mono.Accessor field ->
            "." ++ field


{-| MONO\_030 watchdog messages (plan §1.6): shared verbatim by the solver's
`LimitExceeded` failure and the subst engine's drain-level `Err`, so both
engines present the condition identically. The message must let a user act
without reading compiler source: it names the global, the limit, and the
env var that raises it. True source-region attribution would need demand
provenance the registry does not track (explicit non-goal).
-}
breadthLimitMessage : Global -> Int -> Int -> String
breadthLimitMessage global count limit =
    "specialization budget exceeded for "
        ++ prettyGlobal global
        ++ "\n  "
        ++ String.fromInt count
        ++ " specializations created (limit "
        ++ String.fromInt limit
        ++ ", ECO_SPEC_BREADTH_LIMIT)"
        ++ watchdogAdvice


typeNodesLimitMessage : Global -> Int -> String
typeNodesLimitMessage global limit =
    "specialization type too large for "
        ++ prettyGlobal global
        ++ "\n  a demanded type exceeds "
        ++ String.fromInt limit
        ++ " logical nodes (ECO_SPEC_TYPE_NODE_LIMIT)"
        ++ watchdogAdvice


watchdogAdvice : String
watchdogAdvice =
    "\n  This usually means polymorphic recursion reached the monomorphizer — commonly an"
        ++ "\n  ANNOTATED, MUTUALLY RECURSIVE cycle whose members call each other at growing"
        ++ "\n  type instantiations — or unbounded type growth. Break the chain with a concrete"
        ++ "\n  type annotation at the recursive call site, or raise the limit if the program"
        ++ "\n  is legitimately this large."
        ++ "\n  Inspect with ECO_MONO_LSS_REPORT=1 (see \"top specs/global\")."


{-| Update the type stored for an existing SpecId in the registry.

This is used when the actual type of a specialization becomes known
(e.g., after type checking the body of a function).

-}
updateRegistryType : SpecId -> MonoType -> SpecializationRegistry -> SpecializationRegistry
updateRegistryType specId actualType registry =
    case Array.get specId registry.reverseMapping |> Maybe.andThen identity of
        Nothing ->
            registry

        Just ( global, _ ) ->
            { registry
                | reverseMapping =
                    Array.set specId (Just ( global, actualType )) registry.reverseMapping
            }


{-| Look up a specialization key by its SpecId.

Returns the Global, MonoType, and optional LambdaId if found.

-}
lookupSpecKey : SpecId -> SpecializationRegistry -> Maybe ( Global, MonoType )
lookupSpecKey specId registry =
    Array.get specId registry.reverseMapping |> Maybe.andThen identity
