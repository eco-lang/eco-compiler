module LetNumberFloatArithCrashTest exposing (main)

{-| An unannotated let-bound `number` literal passed to `sqrt`, or combined
with a `Float` by `(+)`, `(/)` or `(^)`, is a `Float`.

Each top-level value binds `n` in its own `let` and returns a `Float`:

  - `sqrtN` is `sqrt 144`, logged as 12.
  - `addN` is `30 + 1.4`, which rounds to 31.
  - `divN` is `30 / 5.0`, logged as 6.
  - `powN` is `2 ^ 3.0`, logged as 8.

-}

-- CHECK: sqrt: 12
-- CHECK: add: 31
-- CHECK: div: 6
-- CHECK: pow: 8

import Html exposing (text)


sqrtN : Float
sqrtN =
    let
        n =
            144
    in
    sqrt n


addN : Float
addN =
    let
        n =
            30
    in
    n + 1.4


divN : Float
divN =
    let
        n =
            30
    in
    n / 5.0


powN : Float
powN =
    let
        n =
            2
    in
    n ^ 3.0


main =
    let
        _ =
            Debug.log "sqrt" (round sqrtN)

        _ =
            Debug.log "add" (round addN)

        _ =
            Debug.log "div" (round divN)

        _ =
            Debug.log "pow" (round powN)
    in
    text "done"
