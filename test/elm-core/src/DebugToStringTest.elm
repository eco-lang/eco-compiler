module DebugToStringTest exposing (main)

-- CHECK: int_str: "42"
-- CHECK: float_str: "3.14"
-- CHECK: bool_str: "True"
-- CHECK: string_str: "\"hello\""
-- CHECK: list_str: "[1, 2, 3]"
-- CHECK: tuple_str: "(1, 2)"
-- CHECK: maybe_just_str: "Just 5"
-- CHECK: maybe_nothing_str: "Nothing"

import Html exposing (text)

main =
    let
        _ = Debug.log "int_str" (Debug.toString 42)
        _ = Debug.log "float_str" (Debug.toString 3.14)
        _ = Debug.log "bool_str" (Debug.toString True)
        _ = Debug.log "string_str" (Debug.toString "hello")
        _ = Debug.log "list_str" (Debug.toString [1, 2, 3])
        _ = Debug.log "tuple_str" (Debug.toString (1, 2))
        _ = Debug.log "maybe_just_str" (Debug.toString (Just 5))
        _ = Debug.log "maybe_nothing_str" (Debug.toString Nothing)
    in
    text "done"
