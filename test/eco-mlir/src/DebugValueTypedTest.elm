module DebugValueTypedTest exposing (main)

{-| `Debug.toString` passed to `List.map` over a list of a custom type, and a
partial `Debug.log` mapped over it.

## eco

Each `Debug` value is rewritten before monomorphization into a lambda around a
saturated call (plans/constructor-representation-followups.md F3), which is
lowered to the typed printer `Elm_Kernel_Debug_toString_typed` (or `eco.dbg`
with a type id): never a closure over the untyped `Elm_Kernel_Debug_toString`,
which prints `Ctor0` for a constructor.

-}

-- CHECK: shown: ["Leaf 1","Node"]
-- CHECK: logged: Leaf 2
-- CHECK-MLIR: Elm_Kernel_Debug_toString_typed
-- CHECK-MLIR-NOT: sym_name = "Elm_Kernel_Debug_toString"
-- CHECK-MLIR-NOT: @Elm_Kernel_Debug_toString,

import Html exposing (text)


type Tree
    = Leaf Int
    | Node


main =
    let
        _ =
            Debug.log "shown" (List.map Debug.toString [ Leaf 1, Node ])

        _ =
            List.map (Debug.log "logged") [ Leaf 2 ]
    in
    text "done"
