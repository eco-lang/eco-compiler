module StringToIntFloatTest exposing (main)

-- CHECK: toInt_ok: Just 42
-- CHECK: toInt_fail: Nothing
-- CHECK: toFloat_ok: Just 3.14
-- CHECK: toFloat_fail: Nothing

import Html exposing (text)

main =
    let
        _ = Debug.log "toInt_ok" (String.toInt "42")
        _ = Debug.log "toInt_fail" (String.toInt "abc")
        _ = Debug.log "toFloat_ok" (String.toFloat "3.14")
        _ = Debug.log "toFloat_fail" (String.toFloat "xyz")
    in
    text "done"
