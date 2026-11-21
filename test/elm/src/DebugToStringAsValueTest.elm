module DebugToStringAsValueTest exposing (main)

{-| `Debug.toString` and `Debug.log` used as function values print as they do
when called directly.

  - `Debug.toString` passed to `List.map` on lists of `Float`s, number literals
    (which default to `Int`, printed `"1"` and `"2"`), `String`s (with their
    quotes, escaped when the list is logged), a wrapper, a record and a `Maybe`
    of a custom type;
  - `Debug.log` passed to `List.map2`, and `Debug.log "x"` partially applied
    and passed to `List.map`;
  - `(Debug.log "y") v` and `v |> Debug.log "p"`, which are calls;
  - a `Debug.toString` value inside a function that has its own `a` and
    `number` type variables, used at other types.

## eco

A `Debug` value is rewritten before monomorphization into a lambda around a
saturated call (plans/constructor-representation-followups.md F3), so it prints
through the type table.

-}

-- CHECK: floats: ["1.5","2.5"]
-- CHECK: ints: ["1","2"]
-- CHECK: strings: ["\"a\"","\"b\""]
-- CHECK: boxes: ["Box \"x\""]
-- CHECK: records: ["{ n = 1 }"]
-- CHECK: maybes: ["Just (A 3)"]
-- CHECK: l: A 2
-- CHECK: x: A 1
-- CHECK: y: A 2
-- CHECK: p: B "q"
-- CHECK: scoped: ["Box 1.5","Box 2.5"]

import Html exposing (text)


type Box a
    = Box a


type Two
    = A Int
    | B String


scoped : a -> number -> List (Box Float) -> List String
scoped _ _ boxes =
    List.map Debug.toString boxes


main =
    let
        _ =
            Debug.log "floats" (List.map Debug.toString [ 1.5, 2.5 ])

        _ =
            Debug.log "ints" (List.map Debug.toString [ 1, 2 ])

        _ =
            Debug.log "strings" (List.map Debug.toString [ "a", "b" ])

        _ =
            Debug.log "boxes" (List.map Debug.toString [ Box "x" ])

        _ =
            Debug.log "records" (List.map Debug.toString [ { n = 1 } ])

        _ =
            Debug.log "maybes" (List.map Debug.toString [ Just (A 3) ])

        _ =
            List.map2 Debug.log [ "l" ] [ A 2 ]

        _ =
            List.map (Debug.log "x") [ A 1 ]

        _ =
            (Debug.log "y") (A 2)

        _ =
            B "q" |> Debug.log "p"

        _ =
            Debug.log "scoped" (scoped "unused" 7 [ Box 1.5, Box 2.5 ])
    in
    text "done"
