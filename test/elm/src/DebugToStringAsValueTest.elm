module DebugToStringAsValueTest exposing (main)

{-| `Debug.toString` passed as a function value (`List.map Debug.toString`)
over lists of Floats, of number literals and of Strings in one program.

The list `[ 1, 2 ]` has a `number` element type. MONO_009 says a Debug kernel
reference keeps its type variables as `CEcoValue`; both monomorphization
engines give them fresh ids (`KernelAbi.remapEcoVarsFresh`). Kept at the
number variable's id, `Compiler.Monomorphize.Prune` closed it to `MInt`, the
reference was typed `Int -> a` and its kernel closure registered
`Elm_Kernel_Debug_toString : (i64) -> !eco.value`, clashing with the
`(!eco.value) -> !eco.value` of the other two uses: the compiler crashed with
"Kernel signature mismatch for Elm_Kernel_Debug_toString" (CGEN_038), and the
`[ 1, 2 ]` use on its own crashed at run time (SIGSEGV). See also
`DebugNumberAtFloatTest`.
-}

-- CHECK: floats: ["1.5", "2.5"]
-- CHECK: ints: ["1", "2"]
-- CHECK: strings: ["\"a\"", "\"b\""]

import Html exposing (text)


main =
    let
        _ =
            Debug.log "floats" (List.map Debug.toString [ 1.5, 2.5 ])

        _ =
            Debug.log "ints" (List.map Debug.toString [ 1, 2 ])

        _ =
            Debug.log "strings" (List.map Debug.toString [ "a", "b" ])
    in
    text "done"
