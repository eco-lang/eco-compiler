module CaseMixedPatternTest exposing (main)

{-| Checks that a single `case` can match a custom type constructor whose argument
is itself matched as a list, with `x :: _` and `[]` patterns nested inside the
constructor pattern.

- `headOfContainer` matches `Container (x :: _)` and `Container []`; both are
  exercised.
- `pairHead` matches a two-argument constructor, `Pair n (x :: _)` and
  `Pair n []`; both are exercised.
- `nestedHead` nests a list pattern inside `Just` inside a constructor. Only the
  `Nested (Just (x :: _))` branch is exercised.

Among what is not tested: the `Nested (Just [])` and `Nested Nothing` branches.

-}

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
