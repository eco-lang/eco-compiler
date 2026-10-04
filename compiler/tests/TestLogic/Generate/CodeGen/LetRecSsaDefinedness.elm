module TestLogic.Generate.CodeGen.LetRecSsaDefinedness exposing (expectLetRecSsaDefinedness)

{-| Generated MLIR in which a function uses a value it never defines is
invalid, and this module checks a compiled program for that.

In MLIR an SSA value is a name beginning with `%` that one place defines and
any number of operands use. Inside a function a value is defined either as the
result of an op or as an argument of a block; the function's parameters are the
arguments of its first region's entry block.

The check is aimed at recursive `let` groups. When the code generator
(`Compiler.Generate.MLIR.Expr`) compiles one, it gives each bound name a
placeholder SSA name before compiling the definitions, so that a closure built
for one binding can capture a sibling by that name. Ordinarily, when the op
that produces a binding's value is among the ops compiled for that binding,
Expr's private `forceResultVar` renames it so that it defines the placeholder.
A binding whose value is an existing SSA value, such as a plain variable reference, is
mapped to that value instead of defining the placeholder. Where a sibling
closure uses a placeholder that nothing defines, this check fails.

The check itself knows nothing of `let`. For each top-level `func.func` it
collects every SSA name defined anywhere in the function's regions, nested
regions included, and every operand beginning with `%`, and reports each
operand name that is not among the definitions.

Among what is not checked: that a definition comes before its uses or is in a
scope they can see, since both sets are gathered from the whole function; that
a name is defined only once; and any op outside a top-level `func.func`.

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict
import Set exposing (Set)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR with
`TestLogic.TestPipeline.runToMlir` and passes when every top-level function
defines each SSA name its operands use.

When compilation fails it fails with `Compilation failed:` followed by the
pipeline's message. Otherwise a failure reports one undefined name only: in the
first function, in module order, that has any, the name that sorts first as a
string.

-}
expectLetRecSsaDefinedness : Src.Module -> Expectation
expectLetRecSsaDefinedness srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkLetRecSsaDefinedness mlirModule)


{-| Returns one violation for each SSA name that a top-level `func.func` of
`mlirModule` uses as an operand without defining, function by function in
module order.
-}
checkLetRecSsaDefinedness : MlirModule -> List Violation
checkLetRecSsaDefinedness mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


{-| Returns one violation for each SSA name that `funcOp` uses as an operand
anywhere in its regions but defines nowhere in them, sorted as strings.

Each violation's `opId` is the undefined name itself rather than an op id, and
its `opName` is `func.func @` followed by the function's `sym_name`, or
`<unknown>` when its `sym_name` attribute is missing or is neither a string nor
a symbol reference.

-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        funcName =
            getStringAttr "sym_name" funcOp
                |> Maybe.withDefault "<unknown>"

        defs =
            collectAllDefs funcOp

        uses =
            collectAllUses funcOp

        undefinedUses =
            Set.diff uses defs
    in
    undefinedUses
        |> Set.toList
        |> List.map
            (\name ->
                { opId = name
                , opName = "func.func @" ++ funcName
                , message =
                    "SSA value '"
                        ++ name
                        ++ "' is used as an operand but never defined in function '"
                        ++ funcName
                        ++ "'"
                }
            )


{-| Returns every SSA name defined in `funcOp`'s regions, at any depth, as an
op result or a block argument.
-}
collectAllDefs : MlirOp -> Set String
collectAllDefs funcOp =
    List.foldl collectDefsFromRegion Set.empty funcOp.regions


{-| Adds to `acc` every SSA name defined in the region's entry block and its
further blocks, including those of regions nested inside them.
-}
collectDefsFromRegion : MlirRegion -> Set String -> Set String
collectDefsFromRegion (MlirRegion { entry, blocks }) acc =
    let
        withEntry =
            collectDefsFromBlock entry acc
    in
    List.foldl collectDefsFromBlock withEntry (OrderedDict.values blocks)


{-| Adds to `acc` the block's arguments and every SSA name defined by its body
ops and its terminator, including inside their regions.
-}
collectDefsFromBlock : MlirBlock -> Set String -> Set String
collectDefsFromBlock block acc =
    let
        withArgs =
            List.foldl (\( name, _ ) s -> Set.insert name s) acc block.args

        withBody =
            List.foldl collectDefsFromOp withArgs block.body
    in
    collectDefsFromOp block.terminator withBody


{-| Adds to `acc` the op's result names and every SSA name defined inside its
regions.
-}
collectDefsFromOp : MlirOp -> Set String -> Set String
collectDefsFromOp op acc =
    let
        withResults =
            List.foldl (\( name, _ ) s -> Set.insert name s) acc op.results
    in
    List.foldl collectDefsFromRegion withResults op.regions


{-| Returns every operand beginning with `%` of the ops in `funcOp`'s regions,
at any depth. Operands not beginning with `%` are left out.
-}
collectAllUses : MlirOp -> Set String
collectAllUses funcOp =
    List.foldl collectUsesFromRegion Set.empty funcOp.regions


{-| Adds to `acc` the SSA operands used in the region's entry block and its
further blocks, including in regions nested inside them.
-}
collectUsesFromRegion : MlirRegion -> Set String -> Set String
collectUsesFromRegion (MlirRegion { entry, blocks }) acc =
    let
        withEntry =
            collectUsesFromBlock entry acc
    in
    List.foldl collectUsesFromBlock withEntry (OrderedDict.values blocks)


{-| Adds to `acc` the SSA operands of the block's body ops and its terminator,
including inside their regions.
-}
collectUsesFromBlock : MlirBlock -> Set String -> Set String
collectUsesFromBlock block acc =
    let
        withBody =
            List.foldl collectUsesFromOp acc block.body
    in
    collectUsesFromOp block.terminator withBody


{-| Adds to `acc` the op's operands that begin with `%` and the SSA operands
used inside its regions.
-}
collectUsesFromOp : MlirOp -> Set String -> Set String
collectUsesFromOp op acc =
    let
        ssaOperands =
            List.filter (\name -> String.startsWith "%" name) op.operands

        withOperands =
            List.foldl Set.insert acc ssaOperands
    in
    List.foldl collectUsesFromRegion withOperands op.regions
