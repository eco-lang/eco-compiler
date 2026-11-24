module Compiler.GenerateMlir.HashIntrinsicTest exposing (suite)

{-| Tests that a call of eco/system's value hash (`Eco.Kernel.FNV.hash`) at a
known type is emitted as the `eco.hash` op while `hashIntrinsic` is on, and as a
call of the kernel while it is off (plans/seq-data-structures-performance.md D1,
`ECO_HASH_INTRINSIC`).

Each fixture is a graph whose static main is `Main.main`, defined as the hash of
one literal, printed with `Compiler.GenerateMlir.BackendModule.generateProgram`;
the tests read the printed MLIR text.

  - An Int argument gives `eco.hash` with kind `int`, and no kernel call.
  - A String argument gives `eco.hash` with kind `string`, and no kernel call.
  - With `hashIntrinsic` off, the Int argument gives a call of
    `Eco_Kernel_FNV_hash` and no `eco.hash`.

Among what is not tested: the typed chains of tuples and records (the E2E test
`test/eco-system/src/HashTypedTest.elm` covers them) and the values the ops
compute (`test/codegen/hash_inline_matches_runtime.mlir`).

-}

import Array
import Compiler.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.GenerateMlir.BackendModule as Backend
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Registry as Registry
import Compiler.Core.Annotation as A
import Data.BitSet as BitSet
import Dict
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Compiler.GenerateMlir: FNV.hash at a known type is eco.hash"
        [ Test.test "an Int argument is eco.hash of kind int, not a kernel call" <|
            \_ ->
                generate Config.default (Mono.LInt 7) Mono.MInt
                    |> Expect.all
                        [ \t -> String.contains "\"eco.hash\"" t |> Expect.equal True
                        , \t -> String.contains "kind = \"int\"" t |> Expect.equal True
                        , \t -> String.contains "Eco_Kernel_FNV_hash" t |> Expect.equal False
                        ]
        , Test.test "a String argument is eco.hash of kind string, not a kernel call" <|
            \_ ->
                generate Config.default (Mono.LStr "abc") Mono.MString
                    |> Expect.all
                        [ \t -> String.contains "\"eco.hash\"" t |> Expect.equal True
                        , \t -> String.contains "kind = \"string\"" t |> Expect.equal True
                        , \t -> String.contains "Eco_Kernel_FNV_hash" t |> Expect.equal False
                        ]
        , Test.test "with hashIntrinsic off, an Int argument calls the kernel" <|
            \_ ->
                generate { default | hashIntrinsic = False } (Mono.LInt 7) Mono.MInt
                    |> Expect.all
                        [ \t -> String.contains "\"eco.hash\"" t |> Expect.equal False
                        , \t -> String.contains "Eco_Kernel_FNV_hash" t |> Expect.equal True
                        ]
        ]


default : Config.EcoConfig
default =
    Config.default



-- ====== FIXTURES ======


{-| Returns the printed MLIR module for a graph whose static main is
`Main.main = FNV.hash <literal>`, generated under `cfg`.
-}
generate : Config.EcoConfig -> Mono.Literal -> Mono.MonoType -> String
generate cfg literal argType =
    let
        ( mainId, registry ) =
            Registry.getOrCreateSpecId
                (Mono.Global (ModuleName.Canonical Pkg.dummyName "Main") "main")
                Mono.MInt
                Registry.emptyRegistry

        hashCall =
            Mono.MonoCall A.zero
                (Mono.MonoVarKernel A.zero "Eco" "FNV" "hash" (Mono.mFunction Mono.topPoison [ argType ] Mono.MInt))
                [ Mono.MonoLiteral literal argType ]
                Mono.MInt
                kernelCallInfo

        -- a saturated call of a kernel, as GlobalOptimize.computeCallInfo marks it
        kernelCallInfo =
            let
                info =
                    Mono.defaultCallInfo
            in
            { info | callModel = Mono.FlattenedExternal, callKind = Mono.CallDirectFlat, evaluatorReturnType = Mono.MInt }

        nodes =
            Array.fromList [ Just (Mono.MonoDefine hashCall Mono.MInt) ]

        graph =
            Mono.MonoGraph
                { nodes = nodes
                , main = Mono.StaticMain mainId
                , registry = registry
                , ctorShapes = Mono.layoutMapEmpty
                , nextLambdaIndex = 0
                , callEdges = Array.repeat (Array.length nodes) Nothing
                , specHasEffects = BitSet.empty
                , specValueUsed = BitSet.empty
                , ports = []
                , flagsDecoder = Nothing
                , flagsSchema = ""
                , lssMemberOrigins = Dict.empty
                , lssMemberKinds = Dict.empty
                , lssBlockedMembers = Dict.empty
                , repr = Mono.emptyReprInfo
                }
    in
    Backend.generateProgram cfg graph
