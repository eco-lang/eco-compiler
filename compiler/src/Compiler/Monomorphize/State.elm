module Compiler.Monomorphize.State exposing
    ( MonoState, SpecAccum, SpecContext, WorkItem(..), Substitution, SchemeInfo, SchemeInfoCache
    , initState
    , LocalInstanceInfo, LocalMultiState
    , ValueInstanceInfo, ValueMultiState
    , VarEnv(..), emptyVarEnv, insertVar, lookupVar, popFrame, pushFrame, varEnvKeys
    , MVarEnv, initMVarEnv, freshMVar, isNumberVar, taintNumber
    )

{-| The state that monomorphization threads through every specialization step,
defined once so that every module taking part agrees on its shape.

Monomorphization turns each polymorphic global into one copy, a
_specialization_, per concrete type it is used at. Each specialization has a
`SpecId`, an index the registry hands out. Work proceeds from a worklist: a
specialization is enqueued when first needed and processed later, and
processing it can enqueue more.

The state therefore has two halves. `SpecAccum` is what the whole run builds
up: the worklist, the finished nodes, and the bookkeeping that keeps a
specialization from being scheduled or entered twice. `SpecContext` is where
the traversal currently is: which global it is inside, which local names are in
scope and at what types, and which let-bound definitions are being copied once
per use type.

Type variables are identified by `MVarId`s. `MVarEnv` hands out fresh ones and
records which variables are known to be numbers, which is what later lets an
unresolved number variable be closed to `Int`.


# Types

@docs MonoState, SpecAccum, SpecContext, WorkItem, Substitution, SchemeInfo, SchemeInfoCache


# Initialization

@docs initState


# Local Specialization

@docs LocalInstanceInfo, LocalMultiState


# Value Specialization

@docs ValueInstanceInfo, ValueMultiState


# Variable Environment

@docs VarEnv, emptyVarEnv, insertVar, lookupVar, popFrame, pushFrame, varEnvKeys


# Monomorphization Variable Environment

@docs MVarEnv, initMVarEnv, freshMVar, isNumberVar, taintNumber

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Intern as Intern exposing (Intern)
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds exposing (MVarId)
import Compiler.AST.TypeVars as Vars
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Monomorphize.Registry as Registry
import Data.Map as DataMap
import Dict exposing (Dict)
import Set


{-| A callee's type scheme, prepared once for instantiation at call sites: its
type with every variable given a fresh `MVarId`, and that type split into
argument types and a result type.

`varIds` lists the fresh variables, and `numberVarKeys` holds the comparable
keys of those that are numbers. `schemeType` is the whole renamed type.

-}
type alias SchemeInfo =
    { varIds : List MVarId
    , numberVarKeys : Set.Set Int
    , argTypes : List (Can.Type MVarId)
    , resultType : Can.Type MVarId
    , argCount : Int
    , schemeType : Can.Type MVarId
    }


{-| The `SchemeInfo` already built for each top-level global.
-}
type alias SchemeInfoCache =
    DataMap.Dict String TOpt.Global SchemeInfo


{-| The supply of fresh type variables, together with what is known about each
variable's super constraint (number, comparable, appendable or compappend).

`nextId` is the next id to hand out. The table of super constraints comes
from whoever builds the environment with `initMVarEnv`; afterwards this module
only ever adds `Number` entries to it, through `freshMVar` and `taintNumber`.

-}
type alias MVarEnv =
    { nextId : MVarId
    , superVars : Dict Int Vars.SuperType -- keyed by Id.toComparable
    }


{-| Builds an environment whose next fresh id is `nextId` and whose super
constraints are `superVars`.
-}
initMVarEnv : MVarId -> Dict Int Vars.SuperType -> MVarEnv
initMVarEnv nextId superVars =
    { nextId = nextId
    , superVars = superVars
    }


{-| Returns the next fresh id and the environment after it.

A `CNumber` constraint is recorded as a `Number` super constraint; a
`CEcoValue` constraint records nothing.

-}
freshMVar : Mono.Constraint -> MVarEnv -> ( MVarId, MVarEnv )
freshMVar constraint env =
    let
        currentId =
            env.nextId

        newSuperVars =
            case constraint of
                Mono.CNumber ->
                    Dict.insert (Id.toComparable currentId) Vars.Number env.superVars

                Mono.CEcoValue ->
                    env.superVars
    in
    ( currentId
    , { nextId = Id.succ currentId
      , superVars = newSuperVars
      }
    )


{-| Tells whether a variable is recorded as a number. A variable recorded as
comparable, appendable or compappend is not.
-}
isNumberVar : MVarId -> MVarEnv -> Bool
isNumberVar mvarId env =
    -- A case match, not `== Just Vars.Number`, so no `Just` is allocated per probe.
    case Dict.get (Id.toComparable mvarId) env.superVars of
        Just Vars.Number ->
            True

        _ ->
            False


{-| Records a variable as a number, replacing any super constraint it had.

This is for a variable found to be equal to a number variable after copies of
its type were already made. Recording it here means those copies are also
treated as numbers wherever this table is consulted. Nothing in this module
removes the mark.

-}
taintNumber : MVarId -> MVarEnv -> MVarEnv
taintNumber mvarId env =
    { env | superVars = Dict.insert (Id.toComparable mvarId) Vars.Number env.superVars }


{-| What a monomorphization run builds up across all its work items.

`nodes` is indexed by `SpecId`, with `Nothing` for a specialization not yet
built. `scheduled` holds every `SpecId` ever put on the worklist, and
`inProgress` those currently being processed.

-}
type alias SpecAccum =
    { worklist : List WorkItem
    , nodes : Array (Maybe Mono.MonoNode)
    , inProgress : BitSet
    , scheduled : BitSet
    , registry : Mono.SpecializationRegistry
    , schemeCache : SchemeInfoCache
    , ports : List Mono.PortRegistration -- ports reached so far
    , intern : Intern
    }


{-| Where the traversal currently is, together with the read-only inputs it
consults.

`currentGlobal` is the global being specialized, and `currentFreeVars` the
free type variables of its annotation. `localMulti` and `valueMulti` are
stacks, one entry per enclosing let whose definition is being copied once per
use type. `lambdaCounter` numbers anonymous lambdas.

-}
type alias SpecContext =
    { currentModule : ModuleName.Canonical
    , toptNodes : DataMap.Dict String TOpt.Global (TOpt.Node MVarId)
    , currentGlobal : Maybe Mono.Global
    , currentFreeVars : Can.FreeVars
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , annotations : TOpt.AnnotationsByGlobal MVarId
    , varEnv : VarEnv
    , localMulti : List LocalMultiState
    , valueMulti : List ValueMultiState
    , lambdaCounter : Int
    , mvarEnv : MVarEnv
    }


{-| The whole monomorphization state. It is split in two so that an update to
either half copies only that half's fields.
-}
type alias MonoState =
    { accum : SpecAccum
    , ctx : SpecContext
    }


{-| One entry on the worklist: the specialization to build.
-}
type WorkItem
    = SpecializeGlobal Mono.SpecId


{-| A mapping from type variables to the types they stand for, keyed by
`Id.toComparable` of the `MVarId`.

This is a name for a `Dict`, so nothing checks that a key came from an
`MVarId`, and the types it maps to may themselves contain variables.

-}
type alias Substitution =
    Dict Int Mono.MonoType


{-| The types of the local names in scope, as a stack of frames, one per
nested scope. An inner binding hides an outer one of the same name, and leaving
a scope drops its bindings at once.
-}
type VarEnv
    = VarEnv (List (Dict Name Mono.MonoType))


{-| An environment with no bindings and one frame.
-}
emptyVarEnv : VarEnv
emptyVarEnv =
    VarEnv [ Dict.empty ]


{-| Returns the type of `name` in the innermost frame that binds it.
-}
lookupVar : Name -> VarEnv -> Maybe Mono.MonoType
lookupVar name (VarEnv frames) =
    lookupVarHelp name frames


{-| Returns the type of `name` in the first of `frames` that binds it.
-}
lookupVarHelp : Name -> List (Dict Name Mono.MonoType) -> Maybe Mono.MonoType
lookupVarHelp name frames =
    case frames of
        [] ->
            Nothing

        frame :: rest ->
            case Dict.get name frame of
                Just t ->
                    Just t

                Nothing ->
                    lookupVarHelp name rest


{-| Binds `name` in the innermost frame, creating a frame if there is none.
-}
insertVar : Name -> Mono.MonoType -> VarEnv -> VarEnv
insertVar name t (VarEnv frames) =
    case frames of
        [] ->
            VarEnv [ Dict.singleton name t ]

        frame :: rest ->
            VarEnv (Dict.insert name t frame :: rest)


{-| Returns every bound name, innermost frame first, with a name repeated if
several frames bind it.
-}
varEnvKeys : VarEnv -> List Name
varEnvKeys (VarEnv frames) =
    List.concatMap Dict.keys frames


{-| Opens a new, empty innermost frame.
-}
pushFrame : VarEnv -> VarEnv
pushFrame (VarEnv frames) =
    VarEnv (Dict.empty :: frames)


{-| Drops the innermost frame and its bindings. An environment with no frames
is returned unchanged.
-}
popFrame : VarEnv -> VarEnv
popFrame (VarEnv frames) =
    case frames of
        [] ->
            VarEnv []

        _ :: rest ->
            VarEnv rest


{-| One copy of a let-bound function, made for one type it is used at.

`freshName` is the name the copy is bound under, and `subst` the substitution
that turns the function's type into `monoType`.

-}
type alias LocalInstanceInfo =
    { freshName : Name
    , monoType : Mono.MonoType
    , subst : Substitution
    }


{-| The copies made so far of one let-bound function, `defName`, which is
copied once per type it is used at.

`instances` is keyed by the use type, compared as `Mono.SpecMap` compares keys.

-}
type alias LocalMultiState =
    { defName : Name
    , instances : Mono.SpecMap LocalInstanceInfo
    }


{-| One copy of a let-bound value that is not a function, made for one type it
is used at.

`monoType` is the type the copy is keyed by. `subst` can be refined after the
copy is first made, as uses of the value pin down more of its type.
`derivedDestructorNames` are the local names bound by destructuring this copy.

-}
type alias ValueInstanceInfo =
    { freshName : Name
    , monoType : Mono.MonoType
    , subst : Substitution
    , derivedDestructorNames : Set.Set Name
    }


{-| The copies made so far of one let-bound value that is not a function, with
the original definition and its type, from which each copy is made.

`instances` is keyed by the use type, compared as `Mono.SpecMap` compares keys.

-}
type alias ValueMultiState =
    { defName : Name
    , defCanType : Can.Type MVarId
    , def : TOpt.Def MVarId
    , instances : Mono.SpecMap ValueInstanceInfo
    }


{-| Builds the state at the start of a run in `currentModule`: an empty
worklist, registry and scheme cache, no current global, and an empty variable
environment.
-}
initState : ModuleName.Canonical -> DataMap.Dict String TOpt.Global (TOpt.Node MVarId) -> TOpt.AnnotationsByGlobal MVarId -> TypeEnv.GlobalTypeEnv -> MVarEnv -> MonoState
initState currentModule toptNodes annotations globalTypeEnv mvarEnv =
    { accum =
        { worklist = []
        , nodes = Array.empty
        , inProgress = BitSet.empty
        , scheduled = BitSet.empty
        , registry = Registry.emptyRegistry
        , schemeCache = DataMap.empty
        , ports = []
        , intern = Intern.empty
        }
    , ctx =
        { currentModule = currentModule
        , toptNodes = toptNodes
        , currentGlobal = Nothing
        , currentFreeVars = Dict.empty
        , globalTypeEnv = globalTypeEnv
        , annotations = annotations
        , varEnv = emptyVarEnv
        , localMulti = []
        , valueMulti = []
        , lambdaCounter = 0
        , mvarEnv = mvarEnv
        }
    }
