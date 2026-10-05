module TestLogic.LocalOpt.TypePreservation exposing
    ( Violation
    , expectTypePreservation
    )

{-| Every expression typed optimization produces carries a stored type, and
the monomorphizer reads those stored types when it specializes the program.
This module checks that the stored types of one program agree in the places
where they can be compared without running type inference again.

`expectTypePreservation` takes the program as a source module, runs it through
typed optimization with `TestLogic.TestPipeline.runToTypedOpt`, and walks the
expressions of every definition, port and recursive group in the resulting
local graph. As it goes it keeps an environment of the local names in scope,
each with the type recorded where it is bound: function parameters,
tail-recursive definitions and their parameters, `let` definitions (in their
own bodies too, for a recursive one), destructured names, and the names a
recursive group defines, which its members refer to as `VarCycle`. Types are
compared with `TestLogic.LocalOpt.Typed.TypeEq.alphaEqStrict`, under which a
type variable matches only another type variable.

The check reports:

  - a local variable use whose type differs from the type recorded for the
    name in the environment;
  - a reference to a value or function of a recursive group (`VarCycle`)
    whose type differs from the type recorded for that name;
  - a kernel reference whose type differs from that kernel's entry in the
    kernel type environment PostSolve built;
  - a case branch, held inline in the decision tree or reached by a jump,
    whose type differs from the type of the case; the branch is still walked
    into, so a violation inside it is reported too;
  - a literal whose type is not its fixed type: `()` for unit, and
    `Basics.Bool`, `Basics.Float`, `Char.Char` and `String.String` for the
    others. An `Int` literal is not checked, since it may be typed `number`.

Among what is not checked: global references against their annotations, a
function's type against its parameters and body, the result type of a call,
and the types of `let`, `if`, destructuring and the remaining expressions,
which are only walked into. A local variable with no entry in the environment,
or a kernel with no entry in the kernel type environment, passes. Constructor,
enum, box, link, kernel and effect manager nodes are not visited.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Type.KernelTypes as KernelTypes
import Data.Map
import Dict exposing (Dict)
import Expect
import TestLogic.LocalOpt.Typed.TypeEq as TypeEq
import TestLogic.TestPipeline as Pipeline



-- ============================================================================
-- TYPES
-- ============================================================================


{-| One disagreement the check found between a stored type and the type it
should agree with.

`exprKind` names what disagreed: `"VarLocal"`, `"TrackedVarLocal"`,
`"VarKernel"`, `"Inline"` for a case branch held in the decision tree,
`"Jump target n"` for the jump target numbered `n`, `"VarCycle"`, or the
kind of literal. `storedType` is the type on the expression and
`expectedType` the type it was compared with. `context` is the module and name of the
global the expression is in, without the package, followed by `Def <name>` or
`TailDef <name>` for each definition the walk entered on the way, whether in a
`let` or in a recursive group, all separated by spaces.

-}
type alias Violation =
    { exprKind : String
    , storedType : Can.Type Name
    , expectedType : Can.Type Name
    , details : String
    , context : String
    }


{-| What the walk knows at an expression.

`locals` maps each local name in scope, and each name of the recursive group
being checked, to the type recorded where it is bound.

-}
type alias TypeEnv =
    { locals : Dict Name.Name (Can.Type Name)
    , kernelEnv : KernelTypes.KernelTypeEnv
    }



-- ============================================================================
-- MAIN TEST FUNCTION
-- ============================================================================


{-| Runs `srcModule` through typed optimization and passes when the check
finds no violation in the local graph. It fails with the pipeline's message
when typed optimization does not complete, and otherwise with a report listing
every violation found.
-}
expectTypePreservation : Src.Module -> Expect.Expectation
expectTypePreservation srcModule =
    case Pipeline.runToTypedOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                env =
                    { locals = Dict.empty
                    , kernelEnv = artifacts.kernelEnv
                    }

                violations =
                    checkLocalGraph env artifacts.localGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)



-- ============================================================================
-- LOCAL GRAPH CHECKING
-- ============================================================================


{-| Returns the violations found in every node of a local graph, each labelled
with the name of its global.
-}
checkLocalGraph : TypeEnv -> TOpt.LocalGraph Name -> List Violation
checkLocalGraph env (TOpt.LocalGraph data) =
    Data.Map.foldl
        (\global node acc ->
            let
                context =
                    globalToString global
            in
            checkNode env context node ++ acc
        )
        []
        data.nodes


{-| Returns a global's module and name joined by a dot, without the package.
-}
globalToString : TOpt.Global -> String
globalToString (TOpt.Global home name) =
    case home of
        ModuleName.Canonical _ moduleName ->
            moduleName ++ "." ++ name


{-| Returns the violations in one node.

A definition or port has its expression checked. A recursive group has each of
its values and definitions checked with every name the group defines added to
the environment, a value with the type of its expression and a definition with
its declared type, for the `VarCycle` references among them. Any other node
has nothing to check.

-}
checkNode : TypeEnv -> String -> TOpt.Node Name -> List Violation
checkNode env context node =
    case node of
        TOpt.Define expr _ _ ->
            checkExpr env context expr

        TOpt.TrackedDefine _ expr _ _ ->
            checkExpr env context expr

        TOpt.Cycle _ values defs _ ->
            let
                cycleEnv =
                    List.foldl
                        (\( name, valExpr ) e ->
                            { e | locals = Dict.insert name (TOpt.typeOf valExpr) e.locals }
                        )
                        env
                        values

                defEnv =
                    List.foldl
                        (\def e ->
                            let
                                ( name, defType ) =
                                    getDefNameAndType def
                            in
                            { e | locals = Dict.insert name defType e.locals }
                        )
                        cycleEnv
                        defs
            in
            List.concatMap (\( _, valExpr ) -> checkExpr defEnv context valExpr) values
                ++ List.concatMap (checkDef defEnv context) defs

        TOpt.PortIncoming expr _ _ ->
            checkExpr env context expr

        TOpt.PortOutgoing expr _ _ ->
            checkExpr env context expr

        _ ->
            []



-- ============================================================================
-- EXPRESSION CHECKING
-- ============================================================================


{-| Returns the violations in `expr` and the expressions under it, with `env`
giving the local names in scope.

Five kinds of expression are compared with something: a local variable or a
recursive-group reference with its type in `env`, a kernel reference with the
kernel type environment, a case's branches with the case's type (through
`checkDecider` and `checkJumps`), and a literal other than `Int` with its
fixed type. A local variable, group reference or kernel with no entry passes.
Functions and destructuring add the names they bind to `env` for their
bodies, and a `let` adds its name for its own body and the body that follows
it. Every other expression is only walked into. References to globals, enums,
boxes and `Debug`, accessors, shaders and `Int` literals are not checked at
all.

-}
checkExpr : TypeEnv -> String -> TOpt.Expr Name -> List Violation
checkExpr env context expr =
    case expr of
        TOpt.Bool _ _ meta ->
            checkLiteralType context "Bool" meta.tipe (Can.TType ModuleName.basics "Bool" [])

        TOpt.Int _ _ _ ->
            []

        TOpt.Float _ _ meta ->
            checkLiteralType context "Float" meta.tipe (Can.TType ModuleName.basics "Float" [])

        TOpt.Chr _ _ meta ->
            checkLiteralType context "Chr" meta.tipe (Can.TType ModuleName.char "Char" [])

        TOpt.Str _ _ meta ->
            checkLiteralType context "Str" meta.tipe (Can.TType ModuleName.string "String" [])

        TOpt.Unit meta ->
            checkLiteralType context "Unit" meta.tipe Can.TUnit

        TOpt.VarLocal name meta ->
            let
                tipe =
                    meta.tipe
            in
            case Dict.get name env.locals of
                Just envType ->
                    if TypeEq.alphaEqStrict tipe envType then
                        []

                    else
                        [ violation context "VarLocal" tipe envType ("Variable '" ++ name ++ "' type doesn't match binding (strict)") ]

                Nothing ->
                    []

        TOpt.TrackedVarLocal _ name meta ->
            let
                tipe =
                    meta.tipe
            in
            case Dict.get name env.locals of
                Just envType ->
                    if TypeEq.alphaEqStrict tipe envType then
                        []

                    else
                        [ violation context "TrackedVarLocal" tipe envType ("Variable '" ++ name ++ "' type doesn't match binding (strict)") ]

                Nothing ->
                    []

        TOpt.VarKernel _ _ home name meta ->
            let
                tipe =
                    meta.tipe
            in
            case KernelTypes.lookup home name env.kernelEnv of
                Just kernelType ->
                    if TypeEq.alphaEqStrict tipe kernelType then
                        []

                    else
                        [ violation context "VarKernel" tipe kernelType ("Kernel '" ++ home ++ "." ++ name ++ "' type doesn't match KernelTypeEnv (strict)") ]

                Nothing ->
                    []

        TOpt.VarGlobal _ _ _ ->
            []

        TOpt.Function _ params body _ ->
            let
                extendedEnv =
                    { env
                        | locals =
                            List.foldl
                                (\( name, paramType ) acc -> Dict.insert name paramType acc)
                                env.locals
                                params
                    }
            in
            checkExpr extendedEnv context body

        TOpt.TrackedFunction _ params body _ ->
            let
                extendedEnv =
                    { env
                        | locals =
                            List.foldl
                                (\( A.At _ name, paramType ) acc -> Dict.insert name paramType acc)
                                env.locals
                                params
                    }
            in
            checkExpr extendedEnv context body

        TOpt.Call _ func args _ ->
            checkExpr env context func
                ++ List.concatMap (checkExpr env context) args

        TOpt.TailCall _ args _ ->
            List.concatMap (\( _, argExpr ) -> checkExpr env context argExpr) args

        TOpt.Let def body _ ->
            let
                ( defName, defType ) =
                    getDefNameAndType def

                extendedEnv =
                    { env | locals = Dict.insert defName defType env.locals }
            in
            checkDef extendedEnv context def
                ++ checkExpr extendedEnv context body

        TOpt.Destruct destructor body _ ->
            let
                (TOpt.Destructor destructName _ destructMeta) =
                    destructor

                extendedEnv =
                    { env | locals = Dict.insert destructName destructMeta.tipe env.locals }
            in
            checkExpr extendedEnv context body

        TOpt.If branches else_ _ ->
            let
                checkBranch ( cond, body ) =
                    checkExpr env context cond
                        ++ checkExpr env context body
            in
            List.concatMap checkBranch branches
                ++ checkExpr env context else_

        TOpt.Case _ _ decider jumps meta ->
            let
                tipe =
                    meta.tipe
            in
            checkDecider env context tipe decider
                ++ checkJumps env context tipe jumps

        TOpt.List _ items _ ->
            List.concatMap (checkExpr env context) items

        TOpt.Access recordExpr _ _ _ ->
            checkExpr env context recordExpr

        TOpt.Update _ recordExpr updates _ ->
            checkExpr env context recordExpr
                ++ Data.Map.foldl (\_ updateExpr acc -> checkExpr env context updateExpr ++ acc) [] updates

        TOpt.Record fields _ ->
            Dict.foldl (\_ fieldExpr acc -> checkExpr env context fieldExpr ++ acc) [] fields

        TOpt.TrackedRecord _ fields _ ->
            Data.Map.foldl (\_ fieldExpr acc -> checkExpr env context fieldExpr ++ acc) [] fields

        TOpt.Tuple _ e1 e2 rest _ ->
            checkExpr env context e1
                ++ checkExpr env context e2
                ++ List.concatMap (checkExpr env context) rest

        TOpt.VarEnum _ _ _ _ ->
            []

        TOpt.VarBox _ _ _ ->
            []

        TOpt.VarCycle _ _ name meta ->
            case Dict.get name env.locals of
                Just envType ->
                    if TypeEq.alphaEqStrict meta.tipe envType then
                        []

                    else
                        [ violation context "VarCycle" meta.tipe envType ("Recursive-group reference '" ++ name ++ "' type doesn't match its definition (strict)") ]

                Nothing ->
                    []

        TOpt.VarDebug _ _ _ _ _ ->
            []

        TOpt.Accessor _ _ _ ->
            []

        TOpt.Shader _ _ _ _ ->
            []



-- ============================================================================
-- DEF CHECKING
-- ============================================================================


{-| Returns the violations in a definition's body, with the definition's name
added to `context`.

A tail-recursive definition's body is checked with its own name and its
parameters added to `env`. A plain definition's body is checked with `env` as
given; its callers have already added its own name, so that a recursive
definition's references to itself are checked.

-}
checkDef : TypeEnv -> String -> TOpt.Def Name -> List Violation
checkDef env context def =
    case def of
        TOpt.Def _ name expr _ ->
            checkExpr env (context ++ " Def " ++ name) expr

        TOpt.TailDef _ name params expr defType _ ->
            let
                envWithSelf =
                    { env | locals = Dict.insert name defType env.locals }

                extendedEnv =
                    List.foldl
                        (\( A.At _ paramName, paramType ) e ->
                            { e | locals = Dict.insert paramName paramType e.locals }
                        )
                        envWithSelf
                        params
            in
            checkExpr extendedEnv (context ++ " TailDef " ++ name) expr



-- ============================================================================
-- DECIDER CHECKING
-- ============================================================================


{-| Returns the violations in the inline leaves of a case's decision tree,
each checked against `expectedType`, the type of the case. Jump leaves give
nothing here; `checkJumps` checks their targets.
-}
checkDecider : TypeEnv -> String -> Can.Type Name -> TOpt.Decider (TOpt.Choice Name) -> List Violation
checkDecider env context expectedType decider =
    case decider of
        TOpt.Leaf choice ->
            checkChoice env context expectedType choice

        TOpt.Chain _ success failure ->
            checkDecider env context expectedType success
                ++ checkDecider env context expectedType failure

        TOpt.FanOut _ options fallback ->
            List.concatMap (\( _, d ) -> checkDecider env context expectedType d) options
                ++ checkDecider env context expectedType fallback


{-| Returns the violations for one leaf of a decision tree.

An inline branch whose type does not match `expectedType` under
`alphaEqStrict` gives a violation, and is then checked like any other
expression either way. A jump leaf gives nothing here, because the target it
names is checked by `checkJumps`.

-}
checkChoice : TypeEnv -> String -> Can.Type Name -> TOpt.Choice Name -> List Violation
checkChoice env context expectedType choice =
    case choice of
        TOpt.Inline expr ->
            let
                exprType =
                    TOpt.typeOf expr
            in
            (if TypeEq.alphaEqStrict exprType expectedType then
                []

             else
                [ violation context "Inline" exprType expectedType "Inline expression type doesn't match Case result type (strict)" ]
            )
                ++ checkExpr env context expr

        TOpt.Jump _ ->
            []


{-| Returns the violations in a case's jump targets, the branches its decision
tree reaches by `Jump`, each checked against `expectedType` as `checkChoice`
checks an inline branch.
-}
checkJumps : TypeEnv -> String -> Can.Type Name -> List ( Int, TOpt.Expr Name ) -> List Violation
checkJumps env context expectedType jumps =
    List.concatMap
        (\( idx, expr ) ->
            let
                exprType =
                    TOpt.typeOf expr
            in
            (if TypeEq.alphaEqStrict exprType expectedType then
                []

             else
                [ violation context ("Jump target " ++ String.fromInt idx) exprType expectedType "Jump target type doesn't match Case result type (strict)" ]
            )
                ++ checkExpr env context expr
        )
        jumps



-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================


{-| Returns the name a definition binds and its declared type.
-}
getDefNameAndType : TOpt.Def Name -> ( Name.Name, Can.Type Name )
getDefNameAndType def =
    case def of
        TOpt.Def _ name _ tipe ->
            ( name, tipe )

        TOpt.TailDef _ name _ _ tipe _ ->
            ( name, tipe )


{-| Returns a violation of kind `kind` when the literal type `actual` does not
match `expected` under `alphaEqStrict`.
-}
checkLiteralType : String -> String -> Can.Type Name -> Can.Type Name -> List Violation
checkLiteralType context kind actual expected =
    if TypeEq.alphaEqStrict actual expected then
        []

    else
        [ violation context kind actual expected "Literal type mismatch" ]


{-| Builds a `Violation` for an expression of kind `kind` found in `context`.
-}
violation : String -> String -> Can.Type Name -> Can.Type Name -> String -> Violation
violation context kind stored expected details =
    { exprKind = kind
    , storedType = stored
    , expectedType = expected
    , details = details
    , context = context
    }



-- ============================================================================
-- FORMATTING
-- ============================================================================


{-| Renders `violations` as one failure message: a header giving how many
there are, then each as `formatViolation` lays it out, separated by blank
lines.
-}
formatViolations : List Violation -> String
formatViolations violations =
    let
        header =
            "TOPT_004 violations: "
                ++ String.fromInt (List.length violations)
                ++ " type preservation issue(s)\n\n"
    in
    header ++ (violations |> List.map formatViolation |> String.join "\n\n")


{-| Renders one violation: where it was found and what kind of expression it
is, then the stored type, the expected type and the details, one per line.
-}
formatViolation : Violation -> String
formatViolation v =
    "TOPT_004 violation in "
        ++ v.context
        ++ " ("
        ++ v.exprKind
        ++ "):\n  stored:   "
        ++ typeToString v.storedType
        ++ "\n  expected: "
        ++ typeToString v.expectedType
        ++ "\n  details:  "
        ++ v.details


{-| Renders a type for a failure message.

A named type is written in full as `author/package:Module.Name` followed by its
arguments. An alias is written the same way followed by `(alias)`, without its
arguments. A record's fields are written in name order.

-}
typeToString : Can.Type Name -> String
typeToString tipe =
    case tipe of
        Can.TVar name ->
            name

        Can.TType (ModuleName.Canonical pkg mod) name args ->
            let
                prefix =
                    Tuple.first pkg ++ "/" ++ Tuple.second pkg ++ ":" ++ mod ++ "."
            in
            if List.isEmpty args then
                prefix ++ name

            else
                prefix ++ name ++ " " ++ String.join " " (List.map typeToStringParens args)

        Can.TLambda _ a b ->
            typeToStringParens a ++ " -> " ++ typeToString b

        Can.TRecord fields ext ->
            let
                fieldStrs =
                    Dict.toList fields
                        |> List.map (\( k, Can.FieldType _ t ) -> k ++ " : " ++ typeToString t)
                        |> String.join ", "
            in
            case ext of
                Nothing ->
                    "{ " ++ fieldStrs ++ " }"

                Just extName ->
                    "{ " ++ extName ++ " | " ++ fieldStrs ++ " }"

        Can.TUnit ->
            "()"

        Can.TTuple a b cs ->
            "( " ++ String.join ", " (List.map typeToString (a :: b :: cs)) ++ " )"

        Can.TAlias (ModuleName.Canonical pkg mod) name _ _ ->
            Tuple.first pkg ++ "/" ++ Tuple.second pkg ++ ":" ++ mod ++ "." ++ name ++ " (alias)"


{-| Renders a type as `typeToString` does, in parentheses when it is a
function type or a named type with arguments, as an argument position needs.
-}
typeToStringParens : Can.Type Name -> String
typeToStringParens tipe =
    case tipe of
        Can.TLambda _ _ _ ->
            "(" ++ typeToString tipe ++ ")"

        Can.TType _ _ (_ :: _) ->
            "(" ++ typeToString tipe ++ ")"

        _ ->
            typeToString tipe
