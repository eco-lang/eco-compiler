module NotEqualBoolTest exposing (main)

{-| `/=` over the canonical Bool 2x2. Mirrors `EqualityBoolTest` but
isolates the `Elm_Kernel_Utils_notEqual` symbol. Same root cause:
`Export::toPtr` collapses True/False to nullptr before
`Utils::notEqual = !equal(...)` runs, so any constant-vs-constant
inequality short-circuits via reference equality.
-}

-- CHECK: ntt: False
-- CHECK: ntf: True
-- CHECK: nft: True
-- CHECK: nff: False
-- CHECK: bntt: True
-- CHECK: bntf: False
-- CHECK: bnft: False
-- CHECK: bnff: True

import Html exposing (text)


main =
    let
        _ = Debug.log "ntt" (True /= True)
        _ = Debug.log "ntf" (True /= False)
        _ = Debug.log "nft" (False /= True)
        _ = Debug.log "nff" (False /= False)
        _ = Debug.log "bntt" (not (True /= True))
        _ = Debug.log "bntf" (not (True /= False))
        _ = Debug.log "bnft" (not (False /= True))
        _ = Debug.log "bnff" (not (False /= False))
    in
    text "done"
