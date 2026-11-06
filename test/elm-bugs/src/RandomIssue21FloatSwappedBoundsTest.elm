module RandomIssue21FloatSwappedBoundsTest exposing (main)

{-| `Random.float` with its bounds swapped generates values outside them.

<https://github.com/elm/random/issues/21>

`Random.int 100 -100` sorts its bounds and stays within [-100, 100]. Elm 0.19.1 (elm/random 1.0.0)
does not do that for `Random.float`: `Random.float 100 -100` produces values in [100, 300].
Values must lie between the two bounds.

-}

-- CHECK: int within bounds: True
-- CHECK: float within bounds: True

import Html exposing (text)
import Random


sample : Random.Generator a -> List a
sample gen =
    Tuple.first (Random.step (Random.list 200 gen) (Random.initialSeed 42))


main =
    let
        _ =
            Debug.log "int within bounds" (List.all (\x -> x >= -100 && x <= 100) (sample (Random.int 100 -100)))

        _ =
            Debug.log "float within bounds" (List.all (\x -> x >= -100 && x <= 100) (sample (Random.float 100 -100)))
    in
    text "done"
