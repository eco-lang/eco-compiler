module Compiler.Generate.KernelHomeCollisionTest exposing (suite)

{-| An `Elm` kernel module and an `Eco` kernel module can share a home:
`Elm.Kernel.File` (package elm/file) and `Eco.Kernel.File` (package
eco/kernel) both have home `File`. If the two were registered under the same
graph key, merging the two packages' global graphs, a left-biased union, would
keep one kernel's node and silently drop the other's, and the dropped
kernel's JavaScript would be missing from the merged graph. This test catches
that.

The fixture is two global graphs, each built from `Opt.empty` by
`GA.addOptKernel` with one kernel module holding a single JavaScript chunk, a
comment naming its package and module, so that the chunks of the merged graph
show which kernels survived. `packageKernelGraph` passes the whole module name,
as `Builder.Elm.Details.addLocalOptGraph` does; the key it gets is the one
`Opt.toKernelGlobal` describes.

The test establishes:

  - Merging the `Elm.Kernel.File` graph and the `Eco.Kernel.File` graph with
    `GA.addOptGlobalGraph` yields a graph whose kernel nodes hold both chunks.

Among what is not tested: the key each kernel is given, the dependencies and
field counts `addOptKernel` records, and the JavaScript names generated for
the two kernels' definitions.

-}

import Builder.GraphAssembly as GA
import Compiler.AST.Optimized as Opt
import Compiler.Elm.Kernel as K
import Data.Map
import Expect
import Test exposing (Test, describe, test)


{-| The kernel graph of one package holding the kernel module `moduleName`,
with `marker` as its one JavaScript chunk, registered the way
`Builder.Elm.Details.addLocalOptGraph` registers it.
-}
packageKernelGraph : String -> String -> Opt.GlobalGraph
packageKernelGraph moduleName marker =
    GA.addOptKernel moduleName [ K.JS marker ] Opt.empty


{-| Returns the JavaScript chunks of every kernel node in the graph, sorted, so
that the result does not depend on node order.
-}
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


{-| The test of merging the elm/file and eco/kernel kernel graphs.
-}
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
