module Compiler.GenerateJs.KernelOverride exposing (marker, section)

{-| Kernel overrides (plans/js-kernel-overrides.md): JavaScript that changes a stock kernel function by
rebinding its name, or adds a definition a stock kernel lacks. Each comes from a file in
`compiler/kernel-overrides`, as `Compiler.GenerateJs.KernelOverride.Files` holds them.

The generator emits the chosen overrides after all kernel code and before all Elm code. There every
kernel function is defined and no Elm value has been built yet, so nothing can have used or captured a
function an override rebinds. The output is in strict mode, so an override that assigns a name no
kernel defines throws at load instead of doing nothing.

@docs marker, section

-}

import Compiler.GenerateJs.KernelOverride.Files as Files


{-| The comment line that opens the override section. Stage 1's `apply-overrides.js` writes the same
line (`MARKER` in `compiler/scripts/kernel-overrides-lib.js`), and refuses an output that already has it.
-}
marker : String
marker =
    "// KERNEL OVERRIDES (compiler/kernel-overrides)\n"


{-| The text emitted between the kernel code and the Elm code: a line break, `marker` and the text of
every override in `overrides` whose required kernel modules all satisfy `isPresent`, in the order of
`overrides`; the empty string when none is chosen. `isPresent` takes a ( prefix, home ) pair such as
( "Elm", "Bytes" ).
-}
section : (( String, String ) -> Bool) -> List Files.KernelOverride -> String
section isPresent overrides =
    case List.filter (\o -> List.all isPresent o.requires) overrides of
        [] ->
            ""

        chosen ->
            "\n" ++ marker ++ String.concat (List.map .text chosen)
