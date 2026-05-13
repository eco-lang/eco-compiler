module EqualityBoolTest exposing (main)

{-| Canonical 2x2 truth table for `(==)` and `(/=)` on `Bool` literals.

This is the smallest reproducer for the embedded-constant equality bug:
`True`/`False` are HPointer constants. The unsuffixed
`Elm_Kernel_Utils_equal` collapses both sides through `Export::toPtr`
into `nullptr`, then `eqHelp` short-circuits with reference equality,
so any pair of embedded constants compares equal.

There is no `MBool` arm in `utilsIntrinsic`, so no intrinsic lowering
masks the kernel call.
-}

-- CHECK: tt: True
-- CHECK: tf: False
-- CHECK: ft: False
-- CHECK: ff: True
-- CHECK: ntt: False
-- CHECK: ntf: True
-- CHECK: nft: True
-- CHECK: nff: False

import Html exposing (text)


main =
    let
        _ = Debug.log "tt" (True == True)
        _ = Debug.log "tf" (True == False)
        _ = Debug.log "ft" (False == True)
        _ = Debug.log "ff" (False == False)
        _ = Debug.log "ntt" (True /= True)
        _ = Debug.log "ntf" (True /= False)
        _ = Debug.log "nft" (False /= True)
        _ = Debug.log "nff" (False /= False)
    in
    text "done"
