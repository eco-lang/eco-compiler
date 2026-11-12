module EcoTensorRangeRefusedTest exposing (main)

{-| An integer value outside its dtype's range is a build error, not a silently wrapped constant:
300 for `uint8`, -129 for `int8`, 2^31 for `int32` (plans/tensor-eval-in-elm.md, V0).
-}

-- CHECK: u8: "errors: c: value 300 does not fit ui8"
-- CHECK: i8: "errors: c: value -129 does not fit si8"
-- CHECK: i32: "errors: c: value 2147483648 does not fit si32"

import EcoTensorSupport exposing (graphText, two64)
import Graph
import Html
import Signature as Sig
import Tensor as T


type N
    = N


main =
    let
        _ =
            Debug.log "u8" (graphText (Graph.function "c" Sig.unit (\() -> T.fromList T.uint8 (T.r1 (T.dim N 1)) [ 300 ])))

        _ =
            Debug.log "i8" (graphText (Graph.function "c" Sig.unit (\() -> T.constant T.int8 -129)))

        _ =
            Debug.log "i32" (graphText (Graph.function "c" Sig.unit (\() -> T.full T.int32 (two64 31) (T.r1 (T.dim N 2)))))
    in
    Html.text "done"
