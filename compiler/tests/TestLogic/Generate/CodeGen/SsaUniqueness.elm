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
`TestLogic.TestPipeline.runToMlir` and checks every region of each `func.func`,
top-level or nested, starting from no names. All blocks of a region share one
scope. Within a block the names are collected in order: the block's arguments,
then the results of each op in its body, then the results of its terminator.
A block argument or op result whose name has already been collected is a
violation. An op's own regions are checked against the names collected up to
and including that op's results, and the names defined inside them are not
visible to the ops that follow.

Two sibling regions, such as two `eco.case` alternatives, may each define the
same name, as MLIR allows, since neither sees the other's names.

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
function in it redefines a visible SSA name, under the rules in the
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
`mlirModule` and the functions nested in them, function by function.
-}
checkSsaUniqueness : MlirModule -> List Violation
checkSsaUniqueness mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


{-| Returns the redefinitions in every region of `funcOp`, each starting from
no visible names, because a `func.func` region is isolated.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        funcName =
            getFuncName funcOp
    in
    List.concatMap (checkRegionSsa funcName Set.empty) funcOp.regions


{-| Returns the redefinitions in each block of a region, entry block first,
given the names `parentDefs` visible from the enclosing scopes.

All blocks of a region share one scope, so the names each block defines stay
visible while the later blocks are checked.

-}
checkRegionSsa : String -> Set String -> MlirRegion -> List Violation
checkRegionSsa funcName parentDefs (MlirRegion { entry, blocks }) =
    List.foldl
        (\block ( accViolations, accDefs ) ->
            let
                ( blockViolations, defsAfterBlock ) =
                    checkBlockSsa funcName accDefs block
            in
            ( accViolations ++ blockViolations, defsAfterBlock )
        )
        ( [], parentDefs )
        (entry :: OrderedDict.values blocks)
        |> Tuple.first


{-| Returns the redefinitions in `block`, given the names `defs` visible
where it starts, paired with the names visible at its end.

The block's arguments are checked and added first; then each op of the body,
and the terminator, is checked against the names defined before it.

-}
checkBlockSsa : String -> Set String -> MlirBlock -> ( List Violation, Set String )
checkBlockSsa funcName defs block =
    let
        ( argViolations, argDefs ) =
            defineNames funcName "block argument" ("block argument of " ++ funcName) (List.map Tuple.first block.args) defs

        ( bodyViolations, defsAfterBody ) =
            List.foldl
                (\op ( accViolations, accDefs ) ->
                    let
                        ( opViolations, newDefs ) =
                            checkOpSsa funcName accDefs op
                    in
                    ( accViolations ++ opViolations, newDefs )
                )
                ( argViolations, argDefs )
                block.body

        ( termViolations, defsAfterTerm ) =
            checkOpSsa funcName defsAfterBody block.terminator
    in
    ( bodyViolations ++ termViolations, defsAfterTerm )


{-| Adds `names` to the visible names `defs` one by one, giving a violation,
with `opId` and `opName` as given, for each name already visible (including
one repeated earlier in `names`).
-}
defineNames : String -> String -> String -> List String -> Set String -> ( List Violation, Set String )
defineNames funcName opId opName names defs =
    List.foldl
        (\varName ( accViolations, accDefs ) ->
            if Set.member varName accDefs then
                ( accViolations
                    ++ [ { opId = opId
                         , opName = opName
                         , message =
                            "SSA redefinition of '"
                                ++ varName
                                ++ "' in function "
                                ++ funcName
                         }
                       ]
                , accDefs
                )

            else
                ( accViolations, Set.insert varName accDefs )
        )
        ( [], defs )
        names


{-| Checks `op` against the visible names `defs`, returning the redefinitions
found and `defs` extended with the op's results.

A result whose name is already visible, including one repeated earlier in the
same op's results, is a violation on `op` with the message
`SSA redefinition of '<name>' in function <funcName>`. The op's regions are
then checked against the extended names; a nested `func.func` is isolated, so
its regions are checked from no names, as a function of its own. Names defined
inside the regions are not in the returned set.

-}
checkOpSsa : String -> Set String -> MlirOp -> ( List Violation, Set String )
checkOpSsa funcName defs op =
    let
        ( resultViolations, defsWithResults ) =
            defineNames funcName op.id op.name (List.map Tuple.first op.results) defs

        regionViolations =
            if op.name == "func.func" then
                checkFunction op

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
