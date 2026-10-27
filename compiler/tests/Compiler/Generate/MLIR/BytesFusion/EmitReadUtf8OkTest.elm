module Compiler.Generate.MLIR.BytesFusion.EmitReadUtf8OkTest exposing (suite)

{-| Checks that a fused decoder turns invalid UTF-8 into `Nothing` rather than
`Just` a string.

`bf.read.utf8` has three results: the string, the advanced cursor and `ok`, an
`i1` that is false when the bytes are not valid UTF-8. A separate `bf.require`
only checks that enough bytes remain, so if the emitter dropped `ok` an invalid
string would still decode to `Just` and nothing else would notice. Here
`Emit.emitFusedDecoder` is driven directly with hand-built Loop IR (the
decoder operations of `Compiler.Generate.MLIR.BytesFusion.LoopIR`) and a stub
expression compiler.

  - `ReadUtf8` with its length given by an expression: the emitted ops contain a
    `bf.read.utf8`, and the third result of each one is an operand of some op.
  - `ReadUtf8Var` with its length read earlier by `ReadU8`: the same assertion.

Among what is not tested: which op consumes `ok`, or that it makes the decoder
return `Nothing`; the emitted MLIR is not run.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.MLIR.BytesFusion.Emit as Emit
import Compiler.Generate.MLIR.BytesFusion.LoopIR as IR
import Compiler.Generate.MLIR.Context as Context exposing (Context)
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.Mode as Mode
import Compiler.Monomorphize.Registry as Registry
import Data.HashMap as HashMap
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Test exposing (Test)


{-| The two tests, one per UTF-8 read operation.
-}
suite : Test
suite =
    Test.describe "SD-23: fused bf.read.utf8 validity flag is used"
        [ Test.test "ReadUtf8 (length from an expression): ok result is consumed" <|
            \_ ->
                expectOkUsed
                    [ IR.InitReadCursor "c" bytesExpr
                    , IR.ReadUtf8 "c" (Mono.MonoLiteral (Mono.LInt 3) Mono.MInt) "s"
                    , IR.ReturnJust "s"
                    ]
        , Test.test "ReadUtf8Var (length from an earlier read): ok result is consumed" <|
            \_ ->
                expectOkUsed
                    [ IR.InitReadCursor "c" bytesExpr
                    , IR.ReadU8 "c" "n"
                    , IR.ReadUtf8Var "c" "n" "s"
                    , IR.ReturnJust "s"
                    ]
        ]


{-| The input expression given to `InitReadCursor`. The emitter does not compile
it; the cursor starts on the `%bytes` name passed to `emitFusedDecoder`.
-}
bytesExpr : Mono.MonoExpr
bytesExpr =
    Mono.MonoVarLocal "bytes" Mono.MInt


{-| A stand-in expression compiler that compiles every expression to the `i64`
constant 3.
-}
stubCompile : Emit.ExprCompiler
stubCompile _ ctx =
    let
        ( v, ctx1 ) =
            Context.freshVar ctx

        ( ctx2, op ) =
            Ops.arithConstantInt ctx1 v 3
    in
    { ops = [ op ], resultVar = v, resultType = I64, ctx = ctx2 }


{-| An empty development-mode code generation context.
-}
freshContext : Context
freshContext =
    Context.initContext (Mode.Dev Nothing) Registry.emptyRegistry Array.empty HashMap.empty


{-| Emits a fused decoder for `decoderOps` and passes if it contains at least one
`bf.read.utf8` and the third result of every one is an operand of some emitted
op, at any nesting depth. Fails naming each unused result, or
`<no ok result>` for a read with fewer than three results.
-}
expectOkUsed : List IR.DecoderOp -> Expectation
expectOkUsed decoderOps =
    let
        ( ops, _, _ ) =
            Emit.emitFusedDecoder stubCompile freshContext "%bytes" decoderOps

        all =
            List.concatMap flatten ops

        reads =
            List.filter (\o -> o.name == "bf.read.utf8") all

        used =
            List.concatMap .operands all
    in
    case reads of
        [] ->
            Expect.fail "no bf.read.utf8 emitted"

        _ ->
            let
                unused =
                    List.filterMap
                        (\o ->
                            case List.drop 2 o.results of
                                ( okVar, _ ) :: _ ->
                                    if List.member okVar used then
                                        Nothing

                                    else
                                        Just okVar

                                [] ->
                                    Just "<no ok result>"
                        )
                        reads
            in
            if List.isEmpty unused then
                Expect.pass

            else
                Expect.fail
                    ("SD-23: the ok (UTF-8 validity) result of bf.read.utf8 is never used, "
                        ++ "so invalid UTF-8 decodes to Just: "
                        ++ String.join ", " unused
                    )


{-| Returns `op` followed by every op nested in its regions, depth first.
-}
flatten : MlirOp -> List MlirOp
flatten op =
    op :: List.concatMap flattenRegion op.regions


{-| Returns every op in a region, nested ones included, entry block first and
each block's terminator after its body.
-}
flattenRegion : MlirRegion -> List MlirOp
flattenRegion (MlirRegion r) =
    let
        blockOps b =
            List.concatMap flatten (b.body ++ [ b.terminator ])
    in
    blockOps r.entry ++ List.concatMap (\( _, b ) -> blockOps b) (OrderedDict.toList r.blocks)
