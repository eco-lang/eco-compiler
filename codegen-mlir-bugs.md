# MLIR Codegen Bugs — Stage 6 Bootstrap Failure

Date: 2026-03-22
Stage 6 ran for 1122s (18m 42s), consumed ~1.1 GB RSS, then failed with 26 MLIR verification errors.

## Bug Category 1: `branch has 0 operands for successor #0, but target block has 1`

**Count:** 22 occurrences

**Root cause:** All 22 errors point to `eco.case` operations. During EcoToLLVM lowering,
`eco.case` regions are lowered to `cf.br` branches targeting blocks with arguments.
The generated branch passes 0 operands but the target block expects 1. This likely means
the lowering of `eco.case` is not correctly forwarding the result value as a block argument
in some code paths.

| MLIR Line | Enclosing Function | Source Module |
|-----------|-------------------|---------------|
| 44857 | `Compiler_Generate_JavaScript_Expression_generateBasicsCall_$_3533` | Compiler.Generate.JavaScript.Expression |
| 45454 | `Compiler_Generate_JavaScript_Expression_generateBitwiseCall_$_3565` | Compiler.Generate.JavaScript.Expression |
| 45539 | `Compiler_Generate_JavaScript_Expression_generateTupleCall_$_3567` | Compiler.Generate.JavaScript.Expression |
| 291207 | `Compiler_Reporting_Error_Syntax_toParseErrorReport_$_21600` | Compiler.Reporting.Error.Syntax |
| 292074 | `Compiler_Reporting_Error_Syntax_toDeclStartReport_$_21601` | Compiler.Reporting.Error.Syntax |
| 297324 | `Compiler_Reporting_Error_Syntax_toCaseReport_$_21618` | Compiler.Reporting.Error.Syntax |
| 422064 | `Compiler_Generate_MLIR_Expr_generateSaturatedCall_$_29271` | Compiler.Generate.MLIR.Expr |
| 430687 | `Compiler_Generate_MLIR_BytesFusion_Reify_matchLengthPrefixedPattern_$_29460` | Compiler.Generate.MLIR.BytesFusion.Reify |
| 430811 | `Compiler_Generate_MLIR_BytesFusion_Reify_reifyBytesDecodeCall_$_29463` | Compiler.Generate.MLIR.BytesFusion.Reify |
| 432343 | `Compiler_Generate_MLIR_Intrinsics_basicsIntrinsic_$_29537` | Compiler.Generate.MLIR.Intrinsics |
| 433004 | `Compiler_Generate_MLIR_Intrinsics_bitwiseIntrinsic_$_29538` | Compiler.Generate.MLIR.Intrinsics |
| 433142 | `Compiler_Generate_MLIR_Intrinsics_utilsIntrinsic_$_29539` | Compiler.Generate.MLIR.Intrinsics |
| 442142 | `Compiler_Generate_MLIR_BytesFusion_Reify_reifyBytesEncodeCall_$_29689` | Compiler.Generate.MLIR.BytesFusion.Reify |
| 442493 | `Compiler_Generate_MLIR_BytesFusion_Reify_reifyBytesKernelCall_$_29702` | Compiler.Generate.MLIR.BytesFusion.Reify |
| 454168 | `Compiler_Generate_MLIR_Functions_generateCtor_$_30172` | Compiler.Generate.MLIR.Functions |
| 454270 | `Compiler_Generate_MLIR_Functions_generateEnum_$_30173` | Compiler.Generate.MLIR.Functions |
| 488069 | `Compiler_Monomorphize_KernelAbi_convertTType_$_31602` | Compiler.Monomorphize.KernelAbi |
| 564825 | `Terminal_Main_lambda_16086$cap` | Terminal.Main (lambda capture) |
| 567350 | `Terminal_Main_lambda_15906$cap` | Terminal.Main (lambda capture) |
| 574320 | `Terminal_Main_lambda_14478$cap` | Terminal.Main (lambda capture) |
| 582085 | `Terminal_Main_lambda_13038$cap` | Terminal.Main (lambda capture) |
| 609806 | `Terminal_Main_lambda_7704$cap` | Terminal.Main (lambda capture) |
| 657749 | `Terminal_Main_lambda_18$cap` | Terminal.Main (lambda capture) |

## Bug Category 2: `'scf.while' op expects region #1 to have 0 or 1 blocks`

**Count:** 4 occurrences

**Root cause:** The "after" region (region #1) of `scf.while` is required by SCF semantics
to have exactly 0 or 1 basic blocks. These functions contain `scf.while` loops whose
after-region has an `eco.case` with multiple alternative blocks, which lowers to multiple
basic blocks. The while body needs to be restructured so the case dispatch happens within
a single block (e.g., by nesting the case inside the before-region, or by transforming the
loop structure).

| MLIR Line | Enclosing Function | Source Module |
|-----------|-------------------|---------------|
| 126094 | `Compiler_LocalOpt_Erased_Port_toDecoder_$_9492` | Compiler.LocalOpt.Erased.Port |
| 211235 | `Compiler_LocalOpt_Typed_Port_toDecoder_$_15055` | Compiler.LocalOpt.Typed.Port |
| 431132 | `Compiler_Generate_MLIR_BytesFusion_Reify_reifyEndianness_$_29467` | Compiler.Generate.MLIR.BytesFusion.Reify |
| 474625 | `Compiler_Monomorphize_TypeSubst_applySubst_$_31142` | Compiler.Monomorphize.TypeSubst |

## Performance Note

Even if these bugs are fixed, Stage 6 has an O(n²) bottleneck: `PapCreateOpLowering::matchAndRewrite`
calls `getOrCreateWrapper` which does a linear `mlir::SymbolTable::lookupSymbolIn` on the module
for each PAP operation. With ~28K functions in the module, this dominates runtime from ~90s onward
(single-threaded, all 12 worker threads idle). A `DenseMap<StringRef, LLVMFuncOp>` cache in
`getOrCreateWrapper` would eliminate this.
