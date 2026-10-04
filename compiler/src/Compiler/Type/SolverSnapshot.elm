module Compiler.Type.SolverSnapshot exposing
    ( SolverState, TypeVar
    , resolveVariable
    )

{-| The solver's union-find store lives in the state that the
`System.TypeCheck.IO` monad threads, and is freed when the run ends. This module
lets code outside that monad find the root of a type variable's class, by
reading a copy of the store taken before then.

The store and its terms, _point_, _class_, _root_ and the `Root` and `Chain`
cells, are described in `Compiler.AST.TypeVars`. A _snapshot_ is an array of every
cell of one store. `Compiler.Type.Solve.runWithIds` returns one, taken after
solving, when solving succeeds. Finding a root is then a matter of following
`Chain` cells through the array.

A store numbers its points from 0, so a snapshot answers only for the variables
of the solve it was taken from. Resolving a variable against a snapshot of a
different store gives a meaningless answer, and no error.

@docs SolverState, TypeVar
@docs resolveVariable

-}

import Array exposing (Array)
import Compiler.AST.TypeVars as Vars


{-| A type variable of the solver, which is a point of its union-find store.

This is a name for `Compiler.AST.TypeVars.Variable`, not a new type, and the two
are interchangeable.

-}
type alias TypeVar =
    Vars.Variable


{-| A snapshot of one solver's union-find store.

`cells` holds the cell of each point at the index the point carries. This is a
record alias, so any array of cells is accepted, and nothing checks that it was
taken from the store a variable belongs to.

-}
type alias SolverState =
    { cells : Array Vars.PointCell
    }


{-| Returns the root of the class that `var` belongs to in `cells`, following
`Chain` cells until it reaches a point whose cell is a `Root`. A point whose
index has no cell in `cells` is returned as it is, as though it were a root.
-}
resolveVariableHelp : Array Vars.PointCell -> TypeVar -> TypeVar
resolveVariableHelp cells var =
    case var of
        Vars.Pt idx ->
            case Array.get idx cells of
                Just (Vars.Chain parent) ->
                    resolveVariableHelp cells parent

                _ ->
                    var


{-| Returns the root of the class that `var` belongs to, as recorded in
`state`. A root is returned unchanged. So is a variable whose index is outside
`state`, as though it were a root, rather than being reported.
-}
resolveVariable : SolverState -> TypeVar -> TypeVar
resolveVariable state var =
    resolveVariableHelp state.cells var
