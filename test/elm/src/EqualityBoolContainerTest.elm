module EqualityBoolContainerTest exposing (main)

{-| Structural equality over Bool-carrying tuples and lists. Even if the
top-level `==` were rewritten to a direct i1 compare, the recursive
`eqHelp` walk on tuples/lists still routes each Bool slot through the
embedded-constant nullptr collapse, so this bug propagates into
containers.
-}

-- CHECK: pairTT_TT: True
-- CHECK: pairTT_TF: False
-- CHECK: pairTF_TT: False
-- CHECK: pairTF_FT: False
-- CHECK: tripleTFT_TFT: True
-- CHECK: tripleTFT_TFF: False
-- CHECK: listTT_TT: True
-- CHECK: listTF_TF: True
-- CHECK: listTF_FT: False
-- CHECK: listTF_TT: False
-- CHECK: listEmpty: True

import Html exposing (text)


main =
    let
        emptyBools : List Bool
        emptyBools = []

        _ = Debug.log "pairTT_TT" ((True, True) == (True, True))
        _ = Debug.log "pairTT_TF" ((True, True) == (True, False))
        _ = Debug.log "pairTF_TT" ((True, False) == (True, True))
        _ = Debug.log "pairTF_FT" ((True, False) == (False, True))

        _ = Debug.log "tripleTFT_TFT" ((True, False, True) == (True, False, True))
        _ = Debug.log "tripleTFT_TFF" ((True, False, True) == (True, False, False))

        _ = Debug.log "listTT_TT" ([True, True] == [True, True])
        _ = Debug.log "listTF_TF" ([True, False] == [True, False])
        _ = Debug.log "listTF_FT" ([True, False] == [False, True])
        _ = Debug.log "listTF_TT" ([True, False] == [True, True])
        _ = Debug.log "listEmpty" (emptyBools == [])
    in
    text "done"
