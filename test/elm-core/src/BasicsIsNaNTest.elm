module BasicsIsNaNTest exposing (main)

-- CHECK: nan_check: True
-- CHECK: not_nan: False
-- CHECK: inf_check: True
-- CHECK: not_inf: False

import Html exposing (text)

main =
    let
        _ = Debug.log "nan_check" (isNaN (0 / 0))
        _ = Debug.log "not_nan" (isNaN 42.0)
        _ = Debug.log "inf_check" (isInfinite (1 / 0))
        _ = Debug.log "not_inf" (isInfinite 42.0)
    in
    text "done"
