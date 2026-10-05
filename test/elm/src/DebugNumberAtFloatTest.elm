module DebugNumberAtFloatTest exposing (main)

{-| A `Debug` kernel used inside an unannotated `number` function that is
specialized at `Float`.

MONO_009 says a Debug kernel reference keeps its type variables as
`CEcoValue`. Both monomorphization engines give those variables fresh ids
(`Specialize.freshenDebugAbi`, `Translate.deriveKernelAbiTypeWith`, through
`KernelAbi.remapEcoVarsFresh`). Kept at the `number` variable's id,
`Compiler.Monomorphize.Prune` closed the variable to `MInt`, so in the Float
specialization the `Debug.toString` passed to `List.map` got a kernel closure
declared `Elm_Kernel_Debug_toString : (i64) -> !eco.value` over f64 list
heads, and the program crashed (SIGSEGV) before printing anything.
-}

-- CHECK: showAll: ["1.25", "2.5"]
-- CHECK: bump: 3.5
-- CHECK: bumpResult: 3.5
-- CHECK: showAllInt: ["2", "4"]

import Html exposing (text)


showAll n =
    List.map Debug.toString [ n, n + n ]


bump n =
    Debug.log "bump" (n + 1)


main =
    let
        _ =
            Debug.log "showAll" (showAll 1.25)

        _ =
            Debug.log "bumpResult" (bump 2.5)

        _ =
            Debug.log "showAllInt" (showAll 2)
    in
    text "done"
