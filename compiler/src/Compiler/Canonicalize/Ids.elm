module Compiler.Canonicalize.Ids exposing
    ( IdState, initialIdState
    , allocId
    )

{-| Gives every expression and pattern node of a canonical module a number of
its own, so that later phases can attach information, such as an inferred type,
to one node by that number.

That number is the node's _node id_: the `id` in the `{ id, node }` record that
wraps each expression and pattern in `Compiler.AST.Canonical`. This module is
only the counter that hands the numbers out. `initialIdState` starts it at 0,
and `allocId` returns the current number and moves the counter on by one.
Expressions and patterns draw from the same counter, so they share one space of
ids.

The counter is a plain value, not a shared cell. Ids come out distinct only if
each state is used once and the state `allocId` returns is the one passed on;
allocating twice from the same state gives the same id twice.

Nothing here decides which node gets which id or how widely one counter is
shared. `Compiler.Canonicalize.Module` starts one counter per module and threads
it through the module's top-level values, so ids are distinct within a module,
not across modules. `Compiler.Canonicalize.Expression` and
`Compiler.Canonicalize.Pattern` decide the order in which nodes take their ids,
and some nodes take theirs after their children, so ids do not follow a
pre-order walk of the tree.


# State

@docs IdState, initialIdState


# Allocation

@docs allocId

-}


{-| The counter that hands out node ids, holding the id the next allocation
will return.

This is a record alias, not an opaque type, so nothing stops a caller building
one with any `nextId` or reusing an old one; either can hand out an id already
in use.

-}
type alias IdState =
    { nextId : Int
    }


{-| The counter before any id has been handed out, so that the first id is 0.
-}
initialIdState : IdState
initialIdState =
    { nextId = 0 }


{-| Returns the id `state` holds, paired with the state that will hand out the
next one.
-}
allocId : IdState -> ( Int, IdState )
allocId state =
    ( state.nextId, { nextId = state.nextId + 1 } )
