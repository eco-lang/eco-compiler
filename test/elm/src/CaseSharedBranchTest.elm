module CaseSharedBranchTest exposing (main)

{-| Checks a `case` on a custom type whose first branch holds a nested `case` on
the constructor's `String` argument.

The calls cover both string literals (`"hello"`, `"bye"`), the string wildcard,
and the other constructor, `Fixed`.

-}

-- CHECK: r1: "greeting"
-- CHECK: r2: "farewell"
-- CHECK: r3: "unknown cmd"
-- CHECK: r4: "fixed"

import Html exposing (text)


type Wrapper
    = Named String
    | Fixed


describe : Wrapper -> String
describe w =
    case w of
        Named name ->
            case name of
                "hello" ->
                    "greeting"

                "bye" ->
                    "farewell"

                _ ->
                    "unknown cmd"

        Fixed ->
            "fixed"


main =
    let
        _ = Debug.log "r1" (describe (Named "hello"))
        _ = Debug.log "r2" (describe (Named "bye"))
        _ = Debug.log "r3" (describe (Named "other"))
        _ = Debug.log "r4" (describe Fixed)
    in
    text "done"
