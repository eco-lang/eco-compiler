module NotEqualBoolMaybeTest exposing (main)

{-| `/=` on `Maybe Bool` values gives the right answer for `Just True`,
`Just False` and `Nothing`, compared in seven pairings: each value with
itself, the two `Just`s both ways round, and `Nothing` with `Just True` on
either side.
-}

-- CHECK: jt_jt: False
-- CHECK: jt_jf: True
-- CHECK: jf_jt: True
-- CHECK: jf_jf: False
-- CHECK: n_jt: True
-- CHECK: n_n: False
-- CHECK: jt_n: True

import Html exposing (text)


main =
    let
        jt : Maybe Bool
        jt = Just True

        jf : Maybe Bool
        jf = Just False

        n : Maybe Bool
        n = Nothing

        _ = Debug.log "jt_jt" (jt /= jt)
        _ = Debug.log "jt_jf" (jt /= jf)
        _ = Debug.log "jf_jt" (jf /= jt)
        _ = Debug.log "jf_jf" (jf /= jf)
        _ = Debug.log "n_jt" (n /= jt)
        _ = Debug.log "n_n" (n /= n)
        _ = Debug.log "jt_n" (jt /= n)
    in
    text "done"
