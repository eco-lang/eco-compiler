module Compiler.Generate.KernelHomeCollisionTest exposing (suite)

{-| SD-16: kernel modules were keyed in the optimized (JavaScript-backend)
global graph by their home only, without the `Elm`/`Eco` kernel prefix.
`Builder.Elm.Details.addLocalOptGraph` registered a kernel module with
`GA.addOptKernel (Tuple.second (Name.getKernel name))`, and
`GraphAssembly.toKernelGlobal` keyed it as `elm/kernel:<home>.$`. So
`Elm.Kernel.File` (package elm/file) and `Eco.Kernel.File` (package eco/kernel)
landed on the same key, and when the two packages' graphs were merged with
`GA.addOptGlobalGraph` one kernel's chunks silently replaced the other's.

Observed on a real program (deps elm/file + eco/kernel, `main` reaching both
`File.decoder` and `Eco.File.readString`, built with `eco make --output=x.js`):
the JS contains only Eco's `_File_*` definitions and fails at load with
`ReferenceError: _File_decoder is not defined`. (Separately, both kernels'
JavaScript defines `_File_size`, so even with distinct graph keys the emitted
names would still clash.) The native MLIR path is unaffected: its C symbols
keep the prefix (`Elm_Kernel_File_size` vs `Eco_Kernel_File_size`).

This test builds the two package graphs exactly as `Details` does and merges
them. It failed before the fix (one kernel's chunks were lost) and passes now
that both kernels survive the merge. The fix changed how `Details` registers a
kernel: `GA.addOptKernel` now takes the whole kernel module name and keys an
`Eco` kernel by it (`Opt.toKernelGlobal`), so `packageKernelGraph` below passes
the module name where it used to pass `Tuple.second (Name.getKernel name)`.
The JavaScript names are kept apart by `JsName.fromEcoKernel`
(`_Eco_File_size`).

-}

import Builder.GraphAssembly as GA
import Compiler.AST.Optimized as Opt
import Compiler.Elm.Kernel as K
import Data.Map
import Expect
import Test exposing (Test, describe, test)


{-| The kernel graph of one package holding the kernel module `moduleName`,
registered the way `Builder.Elm.Details.addLocalOptGraph` registers it.
-}
packageKernelGraph : String -> String -> Opt.GlobalGraph
packageKernelGraph moduleName marker =
    GA.addOptKernel moduleName [ K.JS marker ] Opt.empty


jsChunksOf : Opt.GlobalGraph -> List String
jsChunksOf (Opt.GlobalGraph nodes _) =
    Data.Map.values nodes
        |> List.concatMap
            (\node ->
                case node of
                    Opt.Kernel chunks _ ->
                        List.filterMap
                            (\c ->
                                case c of
                                    K.JS s ->
                                        Just s

                                    _ ->
                                        Nothing
                            )
                            chunks

                    _ ->
                        []
            )
        |> List.sort


suite : Test
suite =
    describe "SD-16: Elm.Kernel.File and Eco.Kernel.File share a kernel graph key"
        [ test "merging the elm/file and eco/kernel package graphs keeps both File kernels" <|
            \_ ->
                let
                    elmFile =
                        packageKernelGraph "Elm.Kernel.File" "/* elm/file Elm.Kernel.File */"

                    ecoFile =
                        packageKernelGraph "Eco.Kernel.File" "/* eco/kernel Eco.Kernel.File */"

                    merged =
                        GA.addOptGlobalGraph elmFile ecoFile
                in
                jsChunksOf merged
                    |> Expect.equal
                        [ "/* eco/kernel Eco.Kernel.File */"
                        , "/* elm/file Elm.Kernel.File */"
                        ]
        ]
