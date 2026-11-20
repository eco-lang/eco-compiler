module EraseWrapperDebugTest exposing (main)

{-| `Debug.toString` and `Debug.log` of wrapper values print the constructor
whether or not `EraseWrappers` (plans/constructor-representation-levels.md E1a,
E2) represents the value as its field: a wrapper on its own, nested, inside a
list, a tuple, a record, a `Maybe` and a `Dict`, and elm/core's `Set`, which is
itself a wrapper around a `Dict`.

-}

-- CHECK: one: Box "x"
-- CHECK: nested: Box (Box "y")
-- CHECK: list: [Box "a",Box "b"]
-- CHECK: tuple: (Box "a",3)
-- CHECK: record: { tag = Tag [1,2], w = Box "r" }
-- CHECK: maybe: Just (Box "m")
-- CHECK: dict: Dict.fromList [(1,Box "d")]
-- CHECK: set: Set.fromList [1,2,3]
-- CHECK: setOfWrapped: Set.fromList ["p","q"]
-- CHECK: str: "Box \"s\""
-- CHECK: fn: Fn <function>

import Dict
import Html exposing (text)
import Set


type Box a
    = Box a


type Tag
    = Tag (List Int)


type Fn
    = Fn (Int -> Int)


main =
    let
        _ =
            Debug.log "one" (Box "x")

        _ =
            Debug.log "nested" (Box (Box "y"))

        _ =
            Debug.log "list" (List.map Box [ "a", "b" ])

        _ =
            Debug.log "tuple" ( Box "a", 3 )

        _ =
            Debug.log "record" { w = Box "r", tag = Tag [ 1, 2 ] }

        _ =
            Debug.log "maybe" (Just (Box "m"))

        _ =
            Debug.log "dict" (Dict.fromList [ ( 1, Box "d" ) ])

        _ =
            Debug.log "set" (Set.fromList [ 3, 1, 2 ])

        _ =
            Debug.log "setOfWrapped" (Set.fromList [ "q", "p" ])

        _ =
            Debug.log "str" (Debug.toString (Box "s"))

        _ =
            Debug.log "fn" (Fn (\n -> n + 1))
    in
    text "done"
