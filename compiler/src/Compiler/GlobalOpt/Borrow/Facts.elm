module Compiler.GlobalOpt.Borrow.Facts exposing
    ( CalleeParamFacts, OracleFacts
    , emptyFacts, borrowedParamsOf, borrowedParamsOfLambda
    )

{-| OC0.2 (plans/borrow-oracle-consumers.md): the distilled, consumer-facing
borrow-oracle facts.

Facts are SpecId / LSS-member-keyed ONLY — no ResVars, no walk-order keys —
so they survive graph rewrites by construction (the same property that makes
`BorrowSig` the one durable analysis artifact). The types live in this leaf
module (imports: Dict/Set only) so `Generate/MLIR/Context.elm` can hold them
without importing the analysis driver; `Borrow.deriveFacts` produces them
from the FINAL (post-CafHoist) graph at emission time.

Consumers (OC1+) must treat `emptyFacts` as "no facts available", never as
evidence of anything: absence of a param index in `borrowedParams` means
UNKNOWN (default owned), not owned-proven.

@docs CalleeParamFacts, OracleFacts
@docs emptyFacts, borrowedParamsOf, borrowedParamsOfLambda

-}

import Dict exposing (Dict)
import Set exposing (Set)


{-| Per-callee distillation of a `BorrowSig`. `borrowedParams` holds the
0-based param indices that are WHOLLY borrowed: the param's `SigTy` carries
at least one heap position, every position's mode is `Borrowed`, and the
index appears in no `resultLts` coupling — i.e. the callee neither retains
nor returns-any-alias-of the argument.
-}
type alias CalleeParamFacts =
    { borrowedParams : Set Int
    }


{-| `bySpec` is keyed by `Mono.SpecId` (def sigs from the SCC fixpoint);
`byLambda` by LSS member id (per-member lambda sigs, B3.5).
-}
type alias OracleFacts =
    { bySpec : Dict Int CalleeParamFacts
    , byLambda : Dict Int CalleeParamFacts
    }


emptyFacts : OracleFacts
emptyFacts =
    { bySpec = Dict.empty
    , byLambda = Dict.empty
    }


{-| Borrowed param indices for a def SpecId; empty when unknown (= owned).
-}
borrowedParamsOf : OracleFacts -> Int -> Set Int
borrowedParamsOf facts specId =
    Dict.get specId facts.bySpec
        |> Maybe.map .borrowedParams
        |> Maybe.withDefault Set.empty


{-| Borrowed param indices for an LSS member id; empty when unknown.
-}
borrowedParamsOfLambda : OracleFacts -> Int -> Set Int
borrowedParamsOfLambda facts memberId =
    Dict.get memberId facts.byLambda
        |> Maybe.map .borrowedParams
        |> Maybe.withDefault Set.empty
