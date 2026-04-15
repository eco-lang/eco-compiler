module Compiler.Monomorphize.Registry exposing
    ( emptyRegistry
    , getOrCreateSpecId
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
import Compiler.AST.Monomorphized as Mono exposing (Global, LambdaId, MonoType, SpecId, SpecializationRegistry)
import Dict



-- ====== REGISTRY OPERATIONS ======


{-| Create an empty specialization registry.
-}
emptyRegistry : SpecializationRegistry
emptyRegistry =
    { nextId = 0
    , mapping = Dict.empty
    , reverseMapping = Array.empty
    }


{-| Get an existing SpecId for a specialization key, or create a new one.

Returns the SpecId and the (possibly updated) registry.

-}
getOrCreateSpecId : Global -> MonoType -> Maybe LambdaId -> SpecializationRegistry -> ( SpecId, SpecializationRegistry )
getOrCreateSpecId global monoType maybeLambda registry =
    let
        key =
            Mono.toComparableSpecKey (Mono.SpecKey global monoType maybeLambda)
    in
    case Dict.get key registry.mapping of
        Just specId ->
            ( specId, registry )

        Nothing ->
            let
                specId =
                    registry.nextId
            in
            ( specId
            , { nextId = specId + 1
              , mapping = Dict.insert key specId registry.mapping
              , reverseMapping = Array.push (Just ( global, monoType, maybeLambda )) registry.reverseMapping
              }
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

        Just ( global, _, maybeLambda ) ->
            { registry
                | reverseMapping =
                    Array.set specId (Just ( global, actualType, maybeLambda )) registry.reverseMapping
            }


{-| Look up a specialization key by its SpecId.

Returns the Global, MonoType, and optional LambdaId if found.

-}
lookupSpecKey : SpecId -> SpecializationRegistry -> Maybe ( Global, MonoType, Maybe LambdaId )
lookupSpecKey specId registry =
    Array.get specId registry.reverseMapping |> Maybe.andThen identity
