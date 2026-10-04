module TestLogic.Generate.CodeGen.SsaUniqueness exposing (expectSsaUniqueness)

{-| Generated MLIR must not define a name that is already visible where the
definition is made, and this module is the check for that rule.

In MLIR each value is an _SSA value_: it is defined once, as a block argument or
an op result, and is referred to by its name. The regions of a `func.func` are
_isolated_: names from outside are not visible in them. The regions of many
other ops, such as the alternatives of an `eco.case`, are not isolated: the
names defined before the op that holds them are visible inside, so defining one
of those names again inside the region is a redefinition. This check treats the
regions of every op other than `func.func` as not isolated.

`expectSsaUniqueness` compiles a source module with
`TestLogic.TestPipeline.runToMlir` and checks the first region of each
top-level `func.func`, starting from no names. Within a block the names are
collected in order: the block's arguments, then the results of each op in its
body, then the results of its terminator. An op result whose name has already
been collected is a violation. An op's own regions are checked against the
names collected up to and including that op's results, and the names defined
inside them are not visible to the ops that follow.

Among what is not checked: a block argument that repeats a visible name; a name
defined in two blocks of the same region, because each block starts from the
names of the enclosing scope only; a name defined in two sibling regions; the
regions of a `func.func` nested inside another op, which are skipped rather than
checked as a scope of their own; and any region of a `func.func` after the
first.

@docs expectSsaUniqueness

-}

import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict
import Set exposing (Set)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Compiles `srcModule` to MLIR and returns an expectation that passes when no
top-level function in it redefines a visible SSA name, under the rules in the
module docstring.

If `runToMlir` returns `Err`, the expectation fails with a message that starts
`Compilation failed:` and ends with the pipeline's message. Otherwise a failure
shows only the first violation, as
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes. A
violation's own message reads `SSA redefinition of '<name>' in function <f>`,
where `<f>` is the function's `sym_name`, or its op id if it has none.

-}
expectSsaUniqueness : Src.Module -> Expectation
expectSsaUniqueness srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkSsaUniqueness mlirModule)


{-| Returns the redefinitions found in the top-level `func.func` ops of
`mlirModule`, function by function.
-}
checkSsaUniqueness : MlirModule -> List Violation
checkSsaUniqueness mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


{-| Returns the redefinitions in the first region of `funcOp`, starting from no
visible names, because a `func.func` region is isolated. A function with no
region gives none, and any region after the first is not checked.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        funcName =
            getFuncName funcOp
    in
    case funcOp.regions of
        [] ->
            []

        region :: _ ->
            checkRegionSsa funcName Set.empty region


{-| Returns the redefinitions in each block of a region, entry block first,
given the names `parentDefs` visible from the enclosing scopes.

Every block is checked against `parentDefs` alone, so a name defined in one
block is not visible when another block of the region is checked.

-}
checkRegionSsa : String -> Set String -> MlirRegion -> List Violation
checkRegionSsa funcName parentDefs (MlirRegion { entry, blocks }) =
    let
        allBlocks =
            entry :: OrderedDict.values blocks
    in
    List.concatMap (checkBlockSsa funcName parentDefs) allBlocks


{-| Returns the redefinitions in `block`, given the names `parentDefs` visible
from the enclosing scopes.

The block's arguments are added to the visible names without being checked.
Each op of the body, and then the terminator, is checked against the names
defined before it.

-}
checkBlockSsa : String -> Set String -> MlirBlock -> List Violation
checkBlockSsa funcName parentDefs block =
    let
        argDefs =
            List.foldl (\( name, _ ) acc -> Set.insert name acc) parentDefs block.args

        ( bodyViolations, defsAfterBody ) =
            List.foldl
                (\op ( accViolations, accDefs ) ->
                    let
                        ( opViolations, newDefs ) =
                            checkOpSsa funcName accDefs op
                    in
                    ( accViolations ++ opViolations, newDefs )
                )
                ( [], argDefs )
                block.body

        ( termViolations, _ ) =
            checkOpSsa funcName defsAfterBody block.terminator
    in
    bodyViolations ++ termViolations


{-| Checks `op` against the visible names `defs`, returning the redefinitions
found and `defs` extended with the op's results.

A result whose name is already visible, including one repeated earlier in the
same op's results, is a violation on `op` with the message
`SSA redefinition of '<name>' in function <funcName>`. The op's regions are
then checked against the extended names, except that the regions of a
`func.func` are skipped. Names defined inside the regions are not in the
returned set.

-}
checkOpSsa : String -> Set String -> MlirOp -> ( List Violation, Set String )
checkOpSsa funcName defs op =
    let
        ( resultViolations, defsWithResults ) =
            List.foldl
                (\( varName, _ ) ( accViolations, accDefs ) ->
                    if Set.member varName accDefs then
                        ( { opId = op.id
                          , opName = op.name
                          , message =
                                "SSA redefinition of '"
                                    ++ varName
                                    ++ "' in function "
                                    ++ funcName
                          }
                            :: accViolations
                        , accDefs
                        )

                    else
                        ( accViolations, Set.insert varName accDefs )
                )
                ( [], defs )
                op.results

        -- A nested func.func's regions are not checked: only top-level functions are walked.
        regionViolations =
            if op.name == "func.func" then
                []

            else
                List.concatMap (checkRegionSsa funcName defsWithResults) op.regions
    in
    ( resultViolations ++ regionViolations, defsWithResults )


{-| Returns the `sym_name` string attribute of `op`, or its `id` if it has
none.
-}
getFuncName : MlirOp -> String
getFuncName op =
    case Dict.get "sym_name" op.attrs of
        Just (Mlir.Mlir.StringAttr name) ->
            name

        _ ->
            op.id
