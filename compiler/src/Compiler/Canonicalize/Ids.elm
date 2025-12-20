module Compiler.Canonicalize.Ids exposing
    ( IdState
    , initialIdState
    , allocId
    )

{-| Shared ID allocation for canonical AST nodes.

This module provides a unified ID space for both expressions and patterns
in the canonical AST. All canonical nodes (expressions and patterns) share
a single incrementing counter to ensure unique IDs across the entire module.


# State

@docs IdState, initialIdState


# Allocation

@docs allocId

-}


{-| State for tracking the next available ID.
-}
type alias IdState =
    { nextId : Int
    }


{-| Initial ID state starting at 0.
-}
initialIdState : IdState
initialIdState =
    { nextId = 0 }


{-| Allocate a new ID and return the updated state.
-}
allocId : IdState -> ( Int, IdState )
allocId state =
    ( state.nextId, { nextId = state.nextId + 1 } )
