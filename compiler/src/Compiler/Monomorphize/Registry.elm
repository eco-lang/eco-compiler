module Compiler.Monomorphize.Registry exposing
    ( emptyRegistry
    , getOrCreateSpecId
    , getOrCreateSpecIdKeyed
    , lookupSpecKey
    , updateRegistryType
    )

{-| Specialization registry operations for monomorphization.

This module provides functions for managing the specialization registry, which
tracks all type specializations of polymorphic functions during monomorphization.

The registry maintains a bidirectional mapping between specialization keys
(function + concrete type + optional lambda ID) and unique specialization IDs.


# Registry Operations

@docs emptyRegistry
@docs getOrCreateSpecId
@docs lookupSpecKey
@docs updateRegistryType

-}

import Array
import Compiler.AST.Monomorphized as Mono exposing (Global, MonoType, SpecId, SpecializationRegistry)



-- ====== REGISTRY OPERATIONS ======


{-| Create an empty specialization registry.
-}
emptyRegistry : SpecializationRegistry
emptyRegistry =
    { nextId = 0
    , mapping = Mono.specKeyMapEmpty
    , reverseMapping = Array.empty
    }


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
              }
            )


{-| Like `getOrCreateSpecId`, but the dedup KEY is computed from `keyType`
while the reverse mapping stores `storeType`. LSS `keyed = False` semantics
(design §8.5): keys are annotation-widened so lambda sets never fan out
specializations, while the stored demand keeps its annotations (types never
widen — MONO_020/021/024).

On a key hit the stored type becomes the annotation JOIN of itself and the
new demand (LSS_010): the single translated node serves every caller that
hits this key, so its demand-seeded annotations must cover all of them —
keeping only the first demand lets a singleton set lie about later
callers' values, which a fast-dispatch stamp turns into a silent
miscompile. The returned Bool is True when the join CHANGED the stored
type — the caller must re-translate an already-translated spec.

-}
getOrCreateSpecIdKeyed : Global -> MonoType -> MonoType -> SpecializationRegistry -> ( SpecId, SpecializationRegistry, Bool )
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
                        ( specId, registry, False )

                    else
                        let
                            joined =
                                Mono.joinAnnotations storedType storeType
                        in
                        if joined == storedType then
                            ( specId, registry, False )

                        else
                            ( specId
                            , { registry
                                | reverseMapping =
                                    Array.set specId (Just ( storedGlobal, joined )) registry.reverseMapping
                              }
                            , True
                            )

                Nothing ->
                    ( specId, registry, False )

        Nothing ->
            let
                specId =
                    registry.nextId
            in
            ( specId
            , { nextId = specId + 1
              , mapping = Mono.specKeyMapInsert key specId registry.mapping
              , reverseMapping = Array.push (Just ( global, storeType )) registry.reverseMapping
              }
            , False
            )


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
