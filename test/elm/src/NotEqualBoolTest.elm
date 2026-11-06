module NotEqualBoolTest exposing (main)

{-| `/=` gives the right answer on all four combinations of `Bool` literals,
and so does `not` applied to each of those results.
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
