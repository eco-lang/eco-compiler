module ArrayGetIntInlineTest exposing (main)

{-| `Array.get` on an `Array Int` of 0 to 39 at indices 3 and 35, summed.

## eco

`Array.get` on an `Array Int` compiles to the inline `eco.array.get`, a plain load
of the raw slot that HEAP_046 makes sound, and never to a call of the boxing
kernel `Elm_Kernel_JsArray_unsafeGet_Int`. A regression lock: the post-mono
inliner already turns the `JsArray.unsafeGet` alias call into a direct kernel
call that reaches the intrinsic, and `Expr.coreIntrinsicHome`
(plans/constructor-representation-followups.md F5b) also covers an alias call
the inliner leaves in place (`Compiler.GenerateMlir.ArrayGetIntrinsicTest`).

-}

-- CHECK: sum: 38
-- CHECK-MLIR: eco.array.get
-- CHECK-MLIR-NOT: Elm_Kernel_JsArray_unsafeGet_Int

import Array
import Html exposing (text)


main =
    let
        arr =
            Array.initialize 40 identity

        total =
            Maybe.withDefault 0 (Array.get 3 arr) + Maybe.withDefault 0 (Array.get 35 arr)

        _ =
            Debug.log "sum" total
    in
    text "done"
