module Compiler.Monomorphize.State exposing
    ( MonoState, WorkItem(..), Substitution, VarTypes
    , initState
    )

{-| State types and utilities for monomorphization.

This module contains the core state threading types used throughout
the monomorphization process.


# Types

@docs MonoState, WorkItem, Substitution, VarTypes


# Initialization

@docs initState


# Utilities

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO


{-| State maintained during monomorphization, tracking work to be done and completed specializations.
-}
type alias MonoState =
    { worklist : List WorkItem
    , nodes : Dict Int Int Mono.MonoNode
    , inProgress : EverySet Int Int
    , registry : Mono.SpecializationRegistry
    , lambdaCounter : Int
    , currentModule : IO.Canonical
    , toptNodes : Dict (List String) TOpt.Global TOpt.Node
    , currentGlobal : Maybe Mono.Global
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , varTypes : VarTypes -- Mapping of variable names to their MonoTypes
    }


{-| Work item representing a function specialization to be processed.
-}
type WorkItem
    = SpecializeGlobal Mono.Global Mono.MonoType (Maybe Mono.LambdaId)


{-| Substitution mapping type variable names to their concrete monomorphic types.
-}
type alias Substitution =
    Dict String Name Mono.MonoType


{-| Mapping of variable names to their MonoTypes, used during specialization.
-}
type alias VarTypes =
    Dict String Name Mono.MonoType


{-| Initialize the monomorphization state with empty worklist and registry.
-}
initState : IO.Canonical -> Dict (List String) TOpt.Global TOpt.Node -> TypeEnv.GlobalTypeEnv -> MonoState
initState currentModule toptNodes globalTypeEnv =
    { worklist = []
    , nodes = Dict.empty
    , inProgress = EverySet.empty
    , registry = Mono.emptyRegistry
    , lambdaCounter = 0
    , currentModule = currentModule
    , toptNodes = toptNodes
    , currentGlobal = Nothing
    , globalTypeEnv = globalTypeEnv
    , varTypes = Dict.empty
    }
