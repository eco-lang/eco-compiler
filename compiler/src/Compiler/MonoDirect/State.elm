module Compiler.MonoDirect.State exposing
    ( MonoDirectState
    , WorkItem(..)
    , initState
    )

{-| State for solver-directed monomorphization.

Mirrors `Compiler.Monomorphize.State.MonoState` but adds a `SolverSnapshot`
for solver-driven type resolution.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Compiler.Data.Map as DataMap
import Compiler.Monomorphize.Registry as Registry
import Compiler.Monomorphize.State as BaseState exposing (SchemeInfoCache, VarEnv)
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
    , localMulti : List BaseState.LocalMultiState
    , callEdges : Dict Int (List Int)
    , specHasEffects : BitSet
    , specValueUsed : BitSet
    , renameEpoch : Int
    , schemeCache : SchemeInfoCache
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
    , varEnv = BaseState.emptyVarEnv
    , localMulti = []
    , callEdges = Dict.empty
    , specHasEffects = BitSet.empty
    , specValueUsed = BitSet.empty
    , renameEpoch = 0
    , schemeCache = DataMap.empty TOpt.toComparableGlobal
    , snapshot = snapshot
    }
