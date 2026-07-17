module CrossStageCallKindTest exposing (main)

{-| Cross-stage papExtend batches must carry `_call_kind = "segmentation_unknown"`
(H6.2 Layer 1 contract; CGEN_052/CGEN_060).

`caseFunc 0 5 3` is a multi-stage call over a case join of differently staged
lambdas (two flat [2], one curried [1,1] -> canonical staging [1,2]). The
stage-2 batch extends a RUNTIME-COMPUTED value (the case-selected lambda), so
Layer 1 makes it fully generic: no `remaining_arity` — and the downgrade must
tag it `_call_kind = "segmentation_unknown"` so the lowering takes
`lowerSegmentationUnknown` (typed args buffer, NO primitive boxing) instead of
the boxing `lowerGenericApply`, and so the CGEN_052 checkers can tell it apart
from an op that unsoundly LOST its typed arity claim.

Regression pin for the `applyByStages` dead-arm bug (Expr.elm ~:2016-2051,
found 2026-07-16 via TestLogic fixtures majority2Flat / "Case returns
differently staged lambdas"): later batches recursed with
`callKindAttr = Nothing` and the segmentation_unknown re-tag lived only in
the `Just` arm — so cross-stage batches emitted NEITHER attribute.

-}

-- CHECK-MLIR: segmentation_unknown
-- CHECK: result: 8

import Html exposing (text)


caseFunc : Int -> Int -> Int -> Int
caseFunc x =
    case x of
        0 ->
            \a b -> a + b

        1 ->
            \a b -> a - b

        _ ->
            \a -> \b -> a * b


main =
    let
        _ =
            Debug.log "result" (caseFunc 0 5 3)
    in
    text "done"
