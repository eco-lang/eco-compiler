module Compiler.GlobalOpt.Borrow.Facts exposing
    ( CalleeParamFacts, OracleFacts
    , emptyFacts, borrowedParamsOfLambda
    )

{-| The results of borrow inference reduced to what code generation can use:
for each callee, which of its parameters it only borrows.

A callee borrows an argument when it does not take ownership of it, so the
caller still owns the value after the call. Borrow inference
(`Compiler.GlobalOpt.Borrow`) decides this separately for each heap
position of a parameter, a heap position being a place in a value of the
parameter's type that refers to the heap (an `Int` has none, a `String` has
one), and it records which parts of the callee's result may alias which
parameters. Code generation needs only a yes or no per parameter. These yes
answers are the _oracle facts_. This module holds their types and the lookups
on them, and it imports nothing but `Dict` and `Set`, so a module can hold the
facts without depending on the analysis.

A parameter is _wholly borrowed_ when its type has at least one heap position,
every one of them is borrowed, and no part of the callee's result may alias
it. Only wholly borrowed parameters are recorded. A parameter that is not
recorded may be owned, borrowed in part, free of heap positions, or aliased by
the result, so its absence proves nothing, and the only safe reading is that
the callee may take ownership of the argument. The same holds for a callee
with no entry, and so for every lookup on `emptyFacts`.

A callee is named in one of two ways: a specialization by its `SpecId`, and a
function value reached through a lambda set by its lambda-set member id, the
integer interned for each member. The facts refer to nothing else in the
graph, such as a place inside a function body, but they still describe the
graph they were derived from, not whatever that graph is later rewritten
into.

@docs CalleeParamFacts, OracleFacts
@docs emptyFacts, borrowedParamsOfLambda

-}

import Dict exposing (Dict)
import Set exposing (Set)


{-| The oracle facts for one callee.

`borrowedParams` holds the 0-based positions, in the callee's parameter list,
of its wholly borrowed parameters. The record does not check that meaning;
it holds whatever its builder put in it.

-}
type alias CalleeParamFacts =
    { borrowedParams : Set Int
    }


{-| The oracle facts for a whole program.

`bySpec` is keyed by `SpecId` and `byLambda` by lambda-set member id. The two
key spaces are numbered independently, so the same number in both need not
name the same callee.

-}
type alias OracleFacts =
    { bySpec : Dict Int CalleeParamFacts
    , byLambda : Dict Int CalleeParamFacts
    }


{-| The oracle facts that record nothing. Every lookup on it returns the empty
set, which means that nothing is known, not that every parameter is owned.
-}
emptyFacts : OracleFacts
emptyFacts =
    { bySpec = Dict.empty
    , byLambda = Dict.empty
    }


{-| Returns the positions of the wholly borrowed parameters of the lambda-set
member numbered `memberId`, or the empty set when `facts` has no entry for it.
-}
borrowedParamsOfLambda : OracleFacts -> Int -> Set Int
borrowedParamsOfLambda facts memberId =
    Dict.get memberId facts.byLambda
        |> Maybe.map .borrowedParams
        |> Maybe.withDefault Set.empty
