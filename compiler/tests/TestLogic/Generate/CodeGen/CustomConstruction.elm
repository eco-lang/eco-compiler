module TestLogic.Generate.CodeGen.CustomConstruction exposing (expectCustomConstruction)

{-| An `eco.construct.custom` op builds a value of a custom type. Its `tag`
attribute identifies the constructor and its `size` attribute is the number of
fields. This module checks those attributes on the MLIR generated for a test
program, and checks that list values (a cell or the empty list) are not built
this way, since lists have their own ops (`eco.construct.list` for a cell,
`eco.constant` for the empty list).

Each `eco.construct.custom` op is reported as a violation, in the sense of
`TestLogic.Generate.CodeGen.Invariants`, for each of these that holds:

  - it has no integer `tag` attribute;
  - it has no integer `size` attribute;
  - its `size` is greater than its number of operands, or an operand after the
    first `size` is not recorded as `!eco.value` in `_operand_types`
    (`Compiler.Generate.MLIR.Ops.ecoConstructCustom` appends GC-root hint
    operands, always boxed values, after the `size` fields);
  - its `constructor` attribute is `Cons` or `Nil` and no custom type of the
    program has a constructor of that name (the monomorphized graph's
    constructor shapes, which never include `List`, are consulted), so the op
    builds a list.

Only the presence of `tag` is checked, not its value. An op with no
`constructor` attribute is never reported by the list check. Other built-in
types, such as `Maybe`, are not checked for.

@docs expectCustomConstruction

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Data.Name as Name
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import Set exposing (Set)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , findOpsNamed
        , getIntAttr
        , getStringAttr
        , isEcoValueType
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR with
`TestLogic.TestPipeline.runToMlir` and passes when no `eco.construct.custom` op
in the result breaks one of the four rules listed in the module docstring.

It fails with the pipeline's error if compilation fails, and otherwise with the
violations found.

-}
expectCustomConstruction : Src.Module -> Expectation
expectCustomConstruction srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule, monoGraph } ->
            violationsToExpectation (checkCustomConstruction (userCtorNames monoGraph) mlirModule)


{-| The names of the constructors of the program's custom types, from the
constructor shapes of `monoGraph`.
-}
userCtorNames : Mono.MonoGraph -> Set String
userCtorNames (Mono.MonoGraph { ctorShapes }) =
    Mono.layoutMapValues ctorShapes
        |> List.concat
        |> List.map (\shape -> Name.toElmString shape.name)
        |> Set.fromList


{-| Returns every violation found on the `eco.construct.custom` ops of the
module, at any depth, given the constructor names of the program's custom
types.
-}
checkCustomConstruction : Set String -> MlirModule -> List Violation
checkCustomConstruction ctorNames mlirModule =
    let
        customOps =
            findOpsNamed "eco.construct.custom" mlirModule
    in
    List.concatMap (checkCustomOp ctorNames) customOps


{-| Returns the violations of one `eco.construct.custom` op: at most three, in
the order missing `tag`, missing or mismatched `size`, list constructor.
-}
checkCustomOp : Set String -> MlirOp -> List Violation
checkCustomOp ctorNames op =
    let
        maybeTag =
            getIntAttr "tag" op

        maybeSize =
            getIntAttr "size" op

        operandCount =
            List.length op.operands

        maybeConstructorName =
            getStringAttr "constructor" op
    in
    List.filterMap identity
        [ -- One entry per attribute checked; Nothing means it passed.
          case maybeTag of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom missing tag attribute"
                    }

            _ ->
                Nothing
        , case maybeSize of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom missing size attribute"
                    }

            Just size ->
                if size > operandCount then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            "eco.construct.custom size="
                                ++ String.fromInt size
                                ++ " but operand count="
                                ++ String.fromInt operandCount
                        }

                else if not (List.all isEcoValueType (List.drop size (Maybe.withDefault [] (extractOperandTypes op)))) then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            "eco.construct.custom size="
                                ++ String.fromInt size
                                ++ " but an operand after the fields (a GC-root hint) is not !eco.value"
                        }

                else
                    Nothing
        , case maybeConstructorName of
            Just name ->
                if List.member name [ "Cons", "Nil" ] && not (Set.member name ctorNames) then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message = "List constructor '" ++ name ++ "' should use eco.construct.list or eco.constant, not eco.construct.custom"
                        }

                else
                    Nothing

            Nothing ->
                Nothing
        ]
