module Compiler.Generate.MLIR.BytesFusion.EmitReadUtf8OkTest exposing (suite)

{-| SD-22/SD-23 review list, item SD-23: the fused decoder must not discard
the validity flag of `bf.read.utf8`.

`bf.read.utf8` has three results: the string, the advanced cursor and `ok`.
`ok` is false when the bytes are not valid UTF-8 (BFToLLVM lowers it to
`elm_utf8_decode(...) != null`, and `elm_utf8_decode` returns 0 on malformed
input). Stock elm/bytes makes the whole decode `Nothing` in that case
(BFOPS_016, BFOPS_018). `Emit.emitReadUtf8Nested` and
`Emit.emitReadUtf8VarNested` mint the `ok` result but never use it: only the
`bf.require` bounds flag guards the rest of the decoder, so an invalid
string decodes to `Just <null string>` instead of `Nothing`.

The defect is latent while `Bytes.Decode.string` does not fuse (the inliner
expands it to kernel calls first), so these tests drive `emitFusedDecoder`
directly with hand-built Loop IR and check that the `ok` result of every
emitted `bf.read.utf8` is an operand of some other op.

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


bytesExpr : Mono.MonoExpr
bytesExpr =
    Mono.MonoVarLocal "bytes" Mono.MInt


{-| Stub expression compiler: every expression becomes an i64 constant.
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


freshContext : Context
freshContext =
    Context.initContext (Mode.Dev Nothing) Registry.emptyRegistry Array.empty HashMap.empty


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


flatten : MlirOp -> List MlirOp
flatten op =
    op :: List.concatMap flattenRegion op.regions


flattenRegion : MlirRegion -> List MlirOp
flattenRegion (MlirRegion r) =
    let
        blockOps b =
            List.concatMap flatten (b.body ++ [ b.terminator ])
    in
    blockOps r.entry ++ List.concatMap (\( _, b ) -> blockOps b) (OrderedDict.toList r.blocks)
