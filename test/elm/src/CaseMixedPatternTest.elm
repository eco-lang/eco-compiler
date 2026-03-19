module CaseMixedPatternTest exposing (main)

{-| Test case with mixed constructor and list patterns in a single expression. -}

-- CHECK: head: 42
-- CHECK: empty: 0
-- CHECK: pair_head: 10
-- CHECK: pair_empty: -1
-- CHECK: nested: 99

import Html exposing (text)


type Container
    = Container (List Int)


headOfContainer c =
    case c of
        Container (x :: _) ->
            x

        Container [] ->
            0


type Pair
    = Pair Int (List Int)


pairHead p =
    case p of
        Pair n (x :: _) ->
            x

        Pair n [] ->
            -1


type Nested
    = Nested (Maybe (List Int))


nestedHead n =
    case n of
        Nested (Just (x :: _)) ->
            x

        Nested (Just []) ->
            0

        Nested Nothing ->
            -1


main =
    let
        _ = Debug.log "head" (headOfContainer (Container [ 42, 99 ]))
        _ = Debug.log "empty" (headOfContainer (Container []))
        _ = Debug.log "pair_head" (pairHead (Pair 5 [ 10, 20 ]))
        _ = Debug.log "pair_empty" (pairHead (Pair 5 []))
        _ = Debug.log "nested" (nestedHead (Nested (Just [ 99, 88 ])))
    in
    text "done"
