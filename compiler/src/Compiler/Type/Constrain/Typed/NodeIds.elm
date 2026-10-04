module Compiler.Type.Constrain.Typed.NodeIds exposing
    ( NodeVarMap, NodeIdState
    , emptyNodeIdState, erasedNodeIdState
    , recordNodeVar, recordSyntheticExprVar
    , SchemeBinderVars, recordSchemeBinders
    )

{-| After a module's types are solved, the type of each of its expressions and
patterns is wanted, not only the types of its top-level definitions. The solver
only knows variables, so while constraints are generated something has to note
which variable stands for which node. This module is that record and the
operations that add to it.

A _node id_ is the integer that canonicalization puts on every canonical
expression and pattern; expressions and patterns share one numbering within a
module. The record maps each node id to the solver variable whose solved type is
that node's type. It also keeps, under each annotated definition's name, the
solver variables that stand for type variables of that definition's annotation.

The record lives in the type checker's state, as the `NodeIdState` that
`System.TypeCheck.IO` defines and describes, so each recording operation is an
`IO ()` action and nothing else has to be threaded through constraint
generation. That state carries a `recording` flag. With it off, every recording
operation here leaves the state unchanged, so constraints can be generated
without building a record; `emptyNodeIdState` and `erasedNodeIdState` are the
starting states with it on and off.

Recording never fails and never checks for an earlier entry: a second record
for the same node id, or for the same definition name, replaces the first. A
negative node id is never recorded.


# Types

@docs NodeVarMap, NodeIdState


# State

@docs emptyNodeIdState, erasedNodeIdState


# Recording

@docs recordNodeVar, recordSyntheticExprVar


# Scheme Binder Recording

@docs SchemeBinderVars, recordSchemeBinders

-}

import Array exposing (Array)
import Compiler.AST.TypeVars as Vars
import Compiler.Data.Name as Name
import Data.Set as EverySet
import Dict
import System.TypeCheck.IO as IO exposing (IO)


{-| Solver variables for the type variables of annotated definitions, keyed by
the definition's name and then by the type variable's name.

Which of an annotation's type variables have an entry is up to the caller of
`recordSchemeBinders`.

Definitions are told apart by name alone, so two annotated definitions of the
same name in one module share one entry, and the one recorded later replaces
the other.

-}
type alias SchemeBinderVars =
    Dict.Dict Name.Name (Dict.Dict Name.Name Vars.Variable)


{-| The solver variable recorded for each node, indexed by node id.

`Nothing` at an index means no variable was recorded for that id. The array
grows only as far as the recorded ids require, so an id beyond its end has no
variable either. This is a name for an `Array`, not a new type, and the
compiler does not check that it is indexed by node id.

-}
type alias NodeVarMap =
    Array (Maybe Vars.Variable)


{-| The node-id record kept in the type checker's state while constraints are
generated.

This is another name for `System.TypeCheck.IO.NodeIdState`, whose docstring
describes its fields.

-}
type alias NodeIdState =
    IO.NodeIdState


{-| The node-id state to start constraint generation from when a record is
wanted: nothing recorded yet, and `recording` on.
-}
emptyNodeIdState : NodeIdState
emptyNodeIdState =
    { mapping = Array.empty
    , syntheticExprIds = EverySet.empty
    , schemeBinderVars = Dict.empty
    , recording = True
    }


{-| The node-id state to start constraint generation from when no record is
wanted: nothing recorded, and `recording` off, so `recordNodeVar`,
`recordSyntheticExprVar` and `recordSchemeBinders` all leave it unchanged.
-}
erasedNodeIdState : NodeIdState
erasedNodeIdState =
    { emptyNodeIdState | recording = False }


{-| Records `var` as the solver variable for node `id`, replacing any variable
already recorded for it.

Nothing is recorded when `recording` is off or `id` is negative.

-}
recordNodeVar : Int -> Vars.Variable -> IO ()
recordNodeVar id var =
    IO.modifyNodeIds
        (\state ->
            if state.recording && id >= 0 then
                { state | mapping = arraySetGrowing id (Just var) state.mapping }

            else
                state
        )


{-| Records `var` as the solver variable for expression `id`, as
`recordNodeVar` does, and also marks `id` as one whose variable is a
placeholder, by adding it to `syntheticExprIds`.

A placeholder is a variable made only so that an expression with no variable of
its own has one to record. Nothing is recorded when `recording` is off or `id`
is negative.

-}
recordSyntheticExprVar : Int -> Vars.Variable -> IO ()
recordSyntheticExprVar id var =
    IO.modifyNodeIds
        (\state ->
            if state.recording && id >= 0 then
                { state
                    | mapping = arraySetGrowing id (Just var) state.mapping
                    , syntheticExprIds = EverySet.insert identity id state.syntheticExprIds
                }

            else
                state
        )


{-| Records `binders`, solver variables keyed by type variable name, as the
entry for the annotated definition named `defName`, replacing any entry already
recorded under that name. Nothing is recorded when `recording` is off.
-}
recordSchemeBinders : Name.Name -> Dict.Dict Name.Name Vars.Variable -> IO ()
recordSchemeBinders defName binders =
    IO.modifyNodeIds
        (\state ->
            if state.recording then
                { state | schemeBinderVars = Dict.insert defName binders state.schemeBinderVars }

            else
                state
        )


{-| Returns `arr` with `val` at index `idx`, first lengthening it with `Nothing`
up to `idx` when it is too short.

`idx` must not be negative; the callers here check that.

-}
arraySetGrowing : Int -> Maybe a -> Array (Maybe a) -> Array (Maybe a)
arraySetGrowing idx val arr =
    if idx < Array.length arr then
        Array.set idx val arr

    else
        Array.append arr (Array.repeat (idx - Array.length arr) Nothing)
            |> Array.push val
