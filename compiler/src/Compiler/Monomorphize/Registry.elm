module Compiler.Monomorphize.Registry exposing
    ( KeyedHit(..)
    , emptyRegistry
    , getOrCreateSpecId
    , getOrCreateSpecIdKeyed
    , lookupSpecKey
    , updateRegistryType
    , breadthLimitMessage, createdCount, prettyGlobal, typeNodesLimitMessage
    )

{-| Every specialization the monomorphizer creates gets its number here, so that
both engines, the substitution engine (`Compiler.Monomorphize.*`) and the
solver engine (`Compiler.MonoSolver.*`), number and deduplicate
specializations in the same way.

A specialization is one definition, a `Global`, instantiated at one concrete
`MonoType`. Its number is a `SpecId`. The record that holds the numbers is the
`SpecializationRegistry`, whose fields `Compiler.AST.Monomorphized` describes.
A demand for a global at a type is looked up by its `SpecKey`, the pair of
global and type; a key not seen before gets the next unused `SpecId`, and a
key seen before gets the `SpecId` it got the first time. Keys are compared as
`SpecKeyMap` compares them, which tells apart arrows whose lambda sets
differ. `SpecId`s are handed out in order from zero, and nothing here reuses or
renumbers one.

Two ways of getting a `SpecId` exist. `getOrCreateSpecId` files a
specialization under the type it records. `getOrCreateSpecIdKeyed` files it
under one type and records another, so that demands whose types differ only
in their lambda-set annotations can share one specialization; it then has to
keep the recorded type wide enough for all of them, and `KeyedHit` reports
what it did.

The rest of the module serves the specialization budget: the limits, named
by `ECO_SPEC_BREADTH_LIMIT` and `ECO_SPEC_TYPE_NODE_LIMIT`, on how many
specializations one global may get and on how large a demanded type may be.
The registry counts the specializations created for each global
(`createdCount`), and both engines report an exceeded limit with the messages
built here. The limits are checked elsewhere.


# Registry Operations

@docs KeyedHit
@docs emptyRegistry
@docs getOrCreateSpecId
@docs getOrCreateSpecIdKeyed
@docs lookupSpecKey
@docs updateRegistryType


# Specialization Budget

@docs breadthLimitMessage, createdCount, prettyGlobal, typeNodesLimitMessage

-}

import Array
import Compiler.AST.Monomorphized as Mono exposing (Global, MonoType, SpecId, SpecializationRegistry)
import Compiler.Elm.ModuleName as ModuleName
import Dict



-- ====== REGISTRY OPERATIONS ======


{-| What `getOrCreateSpecIdKeyed` found and did for one demand.

`CreatedNew` means the key was new, so a `SpecId` was allocated and the
demand's type recorded for it.

`HitIdentical` means the key was known and the recorded type is `==` to the
demand's, so the registry is unchanged. It is also the answer when the key is
known but its `SpecId` has no recorded entry.

`HitNoopJoin` means the key was known and the recorded type already covers
the demand's lambda-set annotations, so the registry is unchanged.

`HitChangedJoin` means the key was known and the recorded type has been
widened to cover the demand. A specialization already translated from the old
type is out of date and needs translating again.

-}
type KeyedHit
    = CreatedNew
    | HitIdentical
    | HitNoopJoin
    | HitChangedJoin


{-| A registry with no specializations, whose first `SpecId` will be zero.
-}
emptyRegistry : SpecializationRegistry
emptyRegistry =
    { nextId = 0
    , mapping = Mono.specKeyMapEmpty
    , reverseMapping = Array.empty
    , countByGlobal = Dict.empty
    }


{-| Returns the registry's per-global creation counts with one more counted for
`global`. Only the branches that allocate a new `SpecId` call it.
-}
bumpCountByGlobal : Global -> SpecializationRegistry -> Dict.Dict String Int
bumpCountByGlobal global registry =
    Dict.update (Mono.toComparableGlobal global)
        (\v -> Just (Maybe.withDefault 0 v + 1))
        registry.countByGlobal


{-| Returns how many specializations of `global` this registry has created,
or zero for none. A demand that found an existing `SpecId` is not counted.
-}
createdCount : Global -> SpecializationRegistry -> Int
createdCount global registry =
    Maybe.withDefault 0 (Dict.get (Mono.toComparableGlobal global) registry.countByGlobal)


{-| Returns the `SpecId` of `global` at `monoType`, allocating the next one if
the pair has none yet.

On a new key the returned registry records `( global, monoType )` under the
new `SpecId` and counts one more creation for `global`; otherwise the registry
is returned unchanged.

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


{-| Returns the `SpecId` that `global` is filed under at `keyType`, allocating
the next one if there is none yet, and records `storeType` as its type.

Callers pass a `keyType` with lambda-set annotations widened, so that demands
differing only in their lambda sets share one specialization, and the
demand's own type as `storeType`. On a new key, `storeType` is recorded and
one more creation counted for `global`.

On a known key the recorded type becomes the annotation join
(`Mono.joinAnnotationsChanged`) of itself and `storeType`. One translated
specialization serves every demand filed under the key, so the lambda sets on
its recorded type must cover what each of those demands can pass; keeping
only the first demand's would claim a narrower set than a later caller uses.
The `KeyedHit` says whether the recorded type changed.

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
                        ( specId, registry, HitIdentical )

                    else
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


{-| Returns `global` as a reader would name it: `Module.name (author/project)`
for a top-level value, `.field` for an accessor.
-}
prettyGlobal : Global -> String
prettyGlobal global =
    case global of
        Mono.Global (ModuleName.Canonical ( author, project ) moduleName) name ->
            moduleName ++ "." ++ name ++ " (" ++ author ++ "/" ++ project ++ ")"

        Mono.Accessor field ->
            "." ++ field


{-| Builds the error message for `global` having had `count` specializations
created, more than the breadth `limit` allows. It names the global, the count,
the limit and the environment variable `ECO_SPEC_BREADTH_LIMIT`, and ends with
advice on the usual cause and the remedies.
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


{-| Builds the error message for a type demanded of `global` having more than
`limit` nodes. It names the global, the limit and the environment variable
`ECO_SPEC_TYPE_NODE_LIMIT`, and ends with advice on the usual cause and
the remedies.
-}
typeNodesLimitMessage : Global -> Int -> String
typeNodesLimitMessage global limit =
    "specialization type too large for "
        ++ prettyGlobal global
        ++ "\n  a demanded type exceeds "
        ++ String.fromInt limit
        ++ " logical nodes (ECO_SPEC_TYPE_NODE_LIMIT)"
        ++ watchdogAdvice


{-| The advice that ends both budget messages: the usual cause, polymorphic
recursion or unbounded type growth, two remedies, and how to get a report of
the specializations per global.
-}
watchdogAdvice : String
watchdogAdvice =
    "\n  This usually means polymorphic recursion reached the monomorphizer — commonly an"
        ++ "\n  ANNOTATED, MUTUALLY RECURSIVE cycle whose members call each other at growing"
        ++ "\n  type instantiations — or unbounded type growth. Break the chain with a concrete"
        ++ "\n  type annotation at the recursive call site, or raise the limit if the program"
        ++ "\n  is legitimately this large."
        ++ "\n  Inspect with ECO_MONO_LSS_REPORT=1 (see \"top specs/global\")."


{-| Returns the registry with `actualType` recorded as the type of `specId`,
keeping its global. A `specId` with no recorded entry leaves the registry
unchanged.

Only the recorded type changes: the specialization stays filed under the key
it was created with.

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


{-| Returns the global and type recorded for `specId`, or `Nothing` when there
is no recorded entry for it.
-}
lookupSpecKey : SpecId -> SpecializationRegistry -> Maybe ( Global, MonoType )
lookupSpecKey specId registry =
    Array.get specId registry.reverseMapping |> Maybe.andThen identity
