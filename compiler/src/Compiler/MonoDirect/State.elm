module Compiler.MonoDirect.State exposing
    ( MonoDirectState
    , WorkItem(..)
    , VarEnv(..)
    , initState
    , emptyVarEnv
    , insertVar
    , lookupVar
    , pushFrame
    , popFrame
    , LocalMultiState
    , LocalInstanceInfo
    )

{-| State for solver-directed monomorphization.

Uses a flat record instead of the accum/ctx split of `Monomorphize.State.MonoState`.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Data.Map as DataMap
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.Registry as Registry
import Compiler.Type.SolverSnapshot as SolverSnapshot exposing (SolverSnapshot)
import Dict exposing (Dict)
import System.TypeCheck.IO as IO


type WorkItem
    = SpecializeGlobal Mono.SpecId


type alias MonoDirectState =
    { worklist : List WorkItem
    , nodes : Dict Int Mono.MonoNode
    , inProgress : BitSet
    , scheduled : BitSet
    , registry : Mono.SpecializationRegistry
    , lambdaCounter : Int
    , currentModule : IO.Canonical
    , toptNodes : DataMap.Dict (List String) TOpt.Global TOpt.Node
    , currentGlobal : Maybe Mono.Global
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , varEnv : VarEnv
    , localMulti : List LocalMultiState
    , callEdges : Dict Int (List Int)
    , specHasEffects : BitSet
    , specValueUsed : BitSet
    , renameEpoch : Int
    , snapshot : SolverSnapshot
    }


initState :
    IO.Canonical
    -> DataMap.Dict (List String) TOpt.Global TOpt.Node
    -> TypeEnv.GlobalTypeEnv
    -> SolverSnapshot
    -> MonoDirectState
initState currentModule toptNodes globalTypeEnv snapshot =
    { worklist = []
    , nodes = Dict.empty
    , inProgress = BitSet.empty
    , scheduled = BitSet.empty
    , registry = Registry.emptyRegistry
    , lambdaCounter = 0
    , currentModule = currentModule
    , toptNodes = toptNodes
    , currentGlobal = Nothing
    , globalTypeEnv = globalTypeEnv
    , varEnv = emptyVarEnv
    , localMulti = []
    , callEdges = Dict.empty
    , specHasEffects = BitSet.empty
    , specValueUsed = BitSet.empty
    , renameEpoch = 0
    , snapshot = snapshot
    }



-- ========== VARIABLE ENVIRONMENT ==========


type VarEnv
    = VarEnv (List (Dict Name Mono.MonoType))


emptyVarEnv : VarEnv
emptyVarEnv =
    VarEnv [ Dict.empty ]


pushFrame : VarEnv -> VarEnv
pushFrame (VarEnv frames) =
    VarEnv (Dict.empty :: frames)


popFrame : VarEnv -> VarEnv
popFrame (VarEnv frames) =
    case frames of
        _ :: rest ->
            VarEnv rest

        [] ->
            VarEnv []


insertVar : Name -> Mono.MonoType -> VarEnv -> VarEnv
insertVar name monoType (VarEnv frames) =
    case frames of
        top :: rest ->
            VarEnv (Dict.insert name monoType top :: rest)

        [] ->
            VarEnv [ Dict.singleton name monoType ]


lookupVar : Name -> VarEnv -> Maybe Mono.MonoType
lookupVar name (VarEnv frames) =
    lookupVarHelp name frames


lookupVarHelp : Name -> List (Dict Name Mono.MonoType) -> Maybe Mono.MonoType
lookupVarHelp name frames =
    case frames of
        [] ->
            Nothing

        top :: rest ->
            case Dict.get name top of
                Just t ->
                    Just t

                Nothing ->
                    lookupVarHelp name rest



-- ========== LOCAL MULTI-SPECIALIZATION ==========


type alias LocalMultiState =
    { defName : Name
    , instances : Dict (List String) LocalInstanceInfo
    }


type alias LocalInstanceInfo =
    { freshName : Name
    , monoType : Mono.MonoType
    }
