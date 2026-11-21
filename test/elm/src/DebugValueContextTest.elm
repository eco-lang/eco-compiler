module DebugValueContextTest exposing (main)

{-| `Debug.toString` used as a value where the surrounding code does not fix its
argument type at the point of use: bound by `let` and applied later, stored in a
record field, in a list, and chosen by an `if`.

## eco

The pre-mono rewrite of `Debug` values (plans/constructor-representation-followups.md
F3) gives each a lambda whose parameter type monomorphization fixes from the
context. These are the positions where the context fixes it later than at the
use (a binding, a record, a list, a branch); monomorphization still resolves the
parameter to `Box`, so each prints with its constructor.

-}

-- CHECK: letBound: "Box 1"
-- CHECK: field: "Box 2"
-- CHECK: listed: ["Box 3"]
-- CHECK: chosen: "Box 4"

import Html exposing (text)


type Box
    = Box Int


main =
    let
        show =
            Debug.toString

        holder =
            { show = Debug.toString }

        shows =
            [ Debug.toString ]

        pick =
            if List.isEmpty shows then
                \_ -> ""

            else
                Debug.toString

        _ =
            Debug.log "letBound" (show (Box 1))

        _ =
            Debug.log "field" (holder.show (Box 2))

        _ =
            Debug.log "listed" (List.map (\f -> f (Box 3)) shows)

        _ =
            Debug.log "chosen" (pick (Box 4))
    in
    text "done"
