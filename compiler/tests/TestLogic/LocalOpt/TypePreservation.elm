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
tail-recursive definitions and their parameters, `let` definitions,
destructured names, and the names a recursive group defines. Types are
compared with `TestLogic.LocalOpt.Typed.TypeEq.alphaEqStrict`, under which a
type variable matches only another type variable.

The check reports:

  - a local variable use whose type differs from the type recorded for the
    name in the environment;
  - a kernel reference whose type differs from that kernel's entry in the
    kernel type environment PostSolve built;
  - a case branch, held inline in the decision tree or reached by a jump,
    whose type differs from the type of the case;
  - a unit literal whose type is not `()`. This one comparison uses the looser
    `alphaEq` of this module, under which a type variable matches any type, so
    a unit literal typed by a variable passes.

Among what is not checked: literals other than unit, global references against
their annotations, a function's type against its parameters and body, the
result type of a call, and the types of `let`, `if`, destructuring and the
remaining expressions, which are only walked into. A local variable with no
entry in the environment, or a kernel with no entry in the kernel type
environment, passes. A case branch whose type fails the comparison is reported
but not walked into, so nothing inside it is reported.
Constructor, enum, box, link, kernel and effect manager nodes are not
visited.

The file also holds `oneWayUnify` and its helpers, which match a type against a
type scheme. Nothing outside that group calls them.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Type.KernelTypes as KernelTypes
import Data.Map
import Data.Set as EverySet
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
`"Jump target n"` for the jump target numbered `n`, or `"Unit"`. `storedType`
is the type on the expression and `expectedType` the type it was compared
with; this module always fills it. `context` is the module and name of the
global the expression is in, without the package, followed by `Def <name>` or
`TailDef <name>` for each definition the walk entered on the way, whether in a
`let` or in a recursive group, all separated by spaces.

-}
type alias Violation =
    { exprKind : String
    , storedType : Can.Type Name
    , expectedType : Maybe (Can.Type Name)
    , details : String
    , context : String
    }


{-| What the walk knows at an expression.

`locals` maps each local name in scope to the type recorded where it is bound.
`annotations` holds the module's top-level annotations but is never read.

-}
type alias TypeEnv =
    { locals : Dict Name.Name (Can.Type Name)
    , annotations : Dict Name.Name (Can.Annotation Name)
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
                    , annotations = artifacts.annotations
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
    Data.Map.foldl TOpt.compareGlobal
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
its declared type. Any other node has nothing to check.

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

Four kinds of expression are compared with something: a local variable with
its type in `env`, a kernel reference with the kernel type environment, a
case's branches with the case's type (through `checkDecider` and
`checkJumps`), and the unit literal with `()`. A local variable or kernel with
no entry passes. Functions and destructuring add the names they bind to `env`
for their bodies, and a `let` adds its name for the body that follows it.
Every other expression is only walked into. References to globals, enums,
boxes, cycle values and `Debug`, accessors, shaders, and literals other than
unit, are not checked at all.

-}
checkExpr : TypeEnv -> String -> TOpt.Expr Name -> List Violation
checkExpr env context expr =
    case expr of
        TOpt.Bool _ _ _ ->
            []

        TOpt.Int _ _ _ ->
            []

        TOpt.Float _ _ _ ->
            []

        TOpt.Chr _ _ _ ->
            []

        TOpt.Str _ _ _ ->
            []

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
                        [ violation context "VarLocal" tipe (Just envType) ("Variable '" ++ name ++ "' type doesn't match binding (strict)") ]

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
                        [ violation context "TrackedVarLocal" tipe (Just envType) ("Variable '" ++ name ++ "' type doesn't match binding (strict)") ]

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
                        [ violation context "VarKernel" tipe (Just kernelType) ("Kernel '" ++ home ++ "." ++ name ++ "' type doesn't match KernelTypeEnv (strict)") ]

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
            checkDef env context def
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
                ++ Data.Map.foldl A.compareLocated (\_ updateExpr acc -> checkExpr env context updateExpr ++ acc) [] updates

        TOpt.Record fields _ ->
            Dict.foldl (\_ fieldExpr acc -> checkExpr env context fieldExpr ++ acc) [] fields

        TOpt.TrackedRecord _ fields _ ->
            Data.Map.foldl A.compareLocated (\_ fieldExpr acc -> checkExpr env context fieldExpr ++ acc) [] fields

        TOpt.Tuple _ e1 e2 rest _ ->
            checkExpr env context e1
                ++ checkExpr env context e2
                ++ List.concatMap (checkExpr env context) rest

        TOpt.VarEnum _ _ _ _ ->
            []

        TOpt.VarBox _ _ _ ->
            []

        TOpt.VarCycle _ _ _ _ ->
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
given, which holds its own name only when the definition is in a recursive
group, whose names `checkNode` has already added.

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
`alphaEqStrict` gives a single violation and is not looked into further. One
that matches is checked like any other expression. A jump leaf gives nothing
here, because the target it names is checked by `checkJumps`.

-}
checkChoice : TypeEnv -> String -> Can.Type Name -> TOpt.Choice Name -> List Violation
checkChoice env context expectedType choice =
    case choice of
        TOpt.Inline expr ->
            let
                exprType =
                    TOpt.typeOf expr
            in
            if TypeEq.alphaEqStrict exprType expectedType then
                checkExpr env context expr

            else
                [ violation context "Inline" exprType (Just expectedType) "Inline expression type doesn't match Case result type (strict)" ]

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
            if TypeEq.alphaEqStrict exprType expectedType then
                checkExpr env context expr

            else
                [ violation context ("Jump target " ++ String.fromInt idx) exprType (Just expectedType) "Jump target type doesn't match Case result type (strict)" ]
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


{-| Returns a violation of kind `kind` when `actual` does not match `expected`
under the loose `alphaEq`, where a type variable on either side matches.
-}
checkLiteralType : String -> String -> Can.Type Name -> Can.Type Name -> List Violation
checkLiteralType context kind actual expected =
    if alphaEq actual expected then
        []

    else
        [ violation context kind actual (Just expected) "Literal type mismatch" ]


{-| Builds a `Violation` for an expression of kind `kind` found in `context`.
-}
violation : String -> String -> Can.Type Name -> Maybe (Can.Type Name) -> String -> Violation
violation context kind stored expected details =
    { exprKind = kind
    , storedType = stored
    , expectedType = expected
    , details = details
    , context = context
    }



-- ============================================================================
-- ALPHA EQUIVALENCE
-- ============================================================================


{-| Returns whether two types agree under a loose comparison in which a type
variable matches any type at all, so `a -> a` matches `a -> b` and `a` matches
`Int`.

Named types match when they have the same package and name, ignoring the
module, as `canonicalTypesEqual` does, and their arguments match. Records
match when either both or neither have an extension variable, whatever its
name, and their fields have the same names and matching types. Two aliases
match only when they have the same home and name, matching arguments, and
matching bodies of the same kind. An alias set against a type that is neither
an alias nor a variable is compared through its body. Arrow slots are ignored.

-}
alphaEq : Can.Type Name -> Can.Type Name -> Bool
alphaEq a b =
    case ( a, b ) of
        ( Can.TVar _, Can.TVar _ ) ->
            True

        ( Can.TVar _, _ ) ->
            True

        ( _, Can.TVar _ ) ->
            True

        ( Can.TType h1 n1 as1, Can.TType h2 n2 as2 ) ->
            canonicalTypesEqual h1 n1 h2 n2 && alphaEqList as1 as2

        ( Can.TLambda _ a1 r1, Can.TLambda _ a2 r2 ) ->
            alphaEq a1 a2 && alphaEq r1 r2

        ( Can.TRecord fields1 ext1, Can.TRecord fields2 ext2 ) ->
            alphaEqExt ext1 ext2 && alphaEqFields fields1 fields2

        ( Can.TUnit, Can.TUnit ) ->
            True

        ( Can.TTuple a1 b1 cs1, Can.TTuple a2 b2 cs2 ) ->
            alphaEq a1 a2 && alphaEq b1 b2 && alphaEqList cs1 cs2

        ( Can.TAlias h1 n1 args1 at1, Can.TAlias h2 n2 args2 at2 ) ->
            h1 == h2 && n1 == n2 && alphaEqArgs args1 args2 && alphaEqAlias at1 at2

        ( Can.TAlias _ _ _ at1, other ) ->
            case at1 of
                Can.Filled t ->
                    alphaEq t other

                Can.Holey t ->
                    alphaEq t other

        ( other, Can.TAlias _ _ _ at2 ) ->
            case at2 of
                Can.Filled t ->
                    alphaEq other t

                Can.Holey t ->
                    alphaEq other t

        _ ->
            False


{-| Returns whether two named types have the same package and the same name.

The module is ignored, so two types of the same name defined in different
modules of one package count as the same type.

-}
canonicalTypesEqual : ModuleName.Canonical -> String -> ModuleName.Canonical -> String -> Bool
canonicalTypesEqual (ModuleName.Canonical pkg1 _) name1 (ModuleName.Canonical pkg2 _) name2 =
    pkg1 == pkg2 && name1 == name2


{-| Returns whether two lists of types have the same length and match pairwise
under `alphaEq`.
-}
alphaEqList : List (Can.Type Name) -> List (Can.Type Name) -> Bool
alphaEqList xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: xrest, y :: yrest ) ->
            alphaEq x y && alphaEqList xrest yrest

        _ ->
            False


{-| Returns whether two records agree on having an extension variable: both
have one, whatever its name, or neither does.
-}
alphaEqExt : Maybe Name.Name -> Maybe Name.Name -> Bool
alphaEqExt e1 e2 =
    case ( e1, e2 ) of
        ( Nothing, Nothing ) ->
            True

        ( Just _, Just _ ) ->
            True

        _ ->
            False


{-| Returns whether two records' fields have the same names and each field's
types match under `alphaEq`. Field indices are ignored.
-}
alphaEqFields : Dict Name.Name (Can.FieldType Name) -> Dict Name.Name (Can.FieldType Name) -> Bool
alphaEqFields f1 f2 =
    let
        keys1 =
            Dict.keys f1

        keys2 =
            Dict.keys f2
    in
    keys1
        == keys2
        && List.all
            (\k ->
                case ( Dict.get k f1, Dict.get k f2 ) of
                    ( Just (Can.FieldType _ t1), Just (Can.FieldType _ t2) ) ->
                        alphaEq t1 t2

                    _ ->
                        False
            )
            keys1


{-| Returns whether two aliases' argument lists have the same length and match
pairwise under `alphaEq`. Parameter names are ignored.
-}
alphaEqArgs : List ( Name.Name, Can.Type Name ) -> List ( Name.Name, Can.Type Name ) -> Bool
alphaEqArgs args1 args2 =
    case ( args1, args2 ) of
        ( [], [] ) ->
            True

        ( ( _, t1 ) :: rest1, ( _, t2 ) :: rest2 ) ->
            alphaEq t1 t2 && alphaEqArgs rest1 rest2

        _ ->
            False


{-| Returns whether two alias bodies match under `alphaEq`, which needs both to
be `Holey` or both `Filled`.
-}
alphaEqAlias : Can.AliasType Name -> Can.AliasType Name -> Bool
alphaEqAlias at1 at2 =
    case ( at1, at2 ) of
        ( Can.Holey t1, Can.Holey t2 ) ->
            alphaEq t1 t2

        ( Can.Filled t1, Can.Filled t2 ) ->
            alphaEq t1 t2

        _ ->
            False



-- ============================================================================
-- SCHEME INSTANTIATION (UNUSED)
-- ============================================================================


{-| Matches `instanceT` against `schemeT`, a type whose variables named in
`schemeVars` may stand for any type. Returns `subst`, the types bound to those
variables so far, extended with the bindings this match needs, or `Nothing`
when `instanceT` does not fit. Nothing outside its own helpers calls it.

A variable in `schemeVars` binds to whatever type stands in its place, and once
bound it must meet a type that matches its binding under the loose `alphaEq`.
Any other variable matches only a variable of the same name. Named types and
aliases need the same home, including the module, the same name and the same
number of arguments. Two such aliases then have their arguments and their
bodies matched in turn; an alias is never unwrapped to match another kind of
type. A record extension variable in `schemeVars` accepts any extension or
none and is not recorded in `subst`. Arrow slots and field indices are
ignored.

-}
oneWayUnify : EverySet.EverySet String Name.Name -> Can.Type Name -> Can.Type Name -> Dict Name.Name (Can.Type Name) -> Maybe (Dict Name.Name (Can.Type Name))
oneWayUnify schemeVars schemeT instanceT subst =
    case schemeT of
        Can.TVar name ->
            if EverySet.member identity name schemeVars then
                case Dict.get name subst of
                    Just boundType ->
                        if alphaEq boundType instanceT then
                            Just subst

                        else
                            Nothing

                    Nothing ->
                        Just (Dict.insert name instanceT subst)

            else
                case instanceT of
                    Can.TVar name2 ->
                        if name == name2 then
                            Just subst

                        else
                            Nothing

                    _ ->
                        Nothing

        Can.TType mod name args ->
            case instanceT of
                Can.TType mod2 name2 args2 ->
                    if mod == mod2 && name == name2 && List.length args == List.length args2 then
                        unifyLists schemeVars args args2 subst

                    else
                        Nothing

                _ ->
                    Nothing

        Can.TLambda _ a b ->
            case instanceT of
                Can.TLambda _ a2 b2 ->
                    oneWayUnify schemeVars a a2 subst
                        |> Maybe.andThen (oneWayUnify schemeVars b b2)

                _ ->
                    Nothing

        Can.TRecord fields ext ->
            case instanceT of
                Can.TRecord fields2 ext2 ->
                    let
                        extResult =
                            case ( ext, ext2 ) of
                                ( Nothing, Nothing ) ->
                                    Just subst

                                ( Just extName, _ ) ->
                                    if EverySet.member identity extName schemeVars then
                                        Just subst

                                    else
                                        case ext2 of
                                            Just extName2 ->
                                                if extName == extName2 then
                                                    Just subst

                                                else
                                                    Nothing

                                            Nothing ->
                                                Nothing

                                ( Nothing, Just _ ) ->
                                    Nothing
                    in
                    case extResult of
                        Nothing ->
                            Nothing

                        Just s ->
                            unifyFields schemeVars fields fields2 s

                _ ->
                    Nothing

        Can.TUnit ->
            case instanceT of
                Can.TUnit ->
                    Just subst

                _ ->
                    Nothing

        Can.TTuple a b cs ->
            case instanceT of
                Can.TTuple a2 b2 cs2 ->
                    if List.length cs == List.length cs2 then
                        oneWayUnify schemeVars a a2 subst
                            |> Maybe.andThen (oneWayUnify schemeVars b b2)
                            |> Maybe.andThen (\s -> unifyLists schemeVars cs cs2 s)

                    else
                        Nothing

                _ ->
                    Nothing

        Can.TAlias mod name args aliasType ->
            case instanceT of
                Can.TAlias mod2 name2 args2 aliasType2 ->
                    if mod == mod2 && name == name2 && List.length args == List.length args2 then
                        unifyArgPairs schemeVars args args2 subst
                            |> Maybe.andThen (unifyAliasTypes schemeVars aliasType aliasType2)

                    else
                        Nothing

                _ ->
                    Nothing


{-| Matches each type in `ts2` against the type at the same position in `ts1`
with `oneWayUnify`, threading `subst` through. Returns `Nothing` if the lists
differ in length or any pair fails.
-}
unifyLists : EverySet.EverySet String Name.Name -> List (Can.Type Name) -> List (Can.Type Name) -> Dict Name.Name (Can.Type Name) -> Maybe (Dict Name.Name (Can.Type Name))
unifyLists schemeVars ts1 ts2 subst =
    case ( ts1, ts2 ) of
        ( [], [] ) ->
            Just subst

        ( t1 :: rest1, t2 :: rest2 ) ->
            oneWayUnify schemeVars t1 t2 subst
                |> Maybe.andThen (unifyLists schemeVars rest1 rest2)

        _ ->
            Nothing


{-| Matches an instance record's fields, `fields2`, against a scheme record's,
`fields1`, with `oneWayUnify`, threading `subst` through. The two must have
the same field names.
-}
unifyFields : EverySet.EverySet String Name.Name -> Dict Name.Name (Can.FieldType Name) -> Dict Name.Name (Can.FieldType Name) -> Dict Name.Name (Can.Type Name) -> Maybe (Dict Name.Name (Can.Type Name))
unifyFields schemeVars fields1 fields2 subst =
    let
        keys1 =
            Dict.keys fields1

        keys2 =
            Dict.keys fields2
    in
    if keys1 /= keys2 then
        Nothing

    else
        List.foldl
            (\k acc ->
                case acc of
                    Nothing ->
                        Nothing

                    Just s ->
                        case ( Dict.get k fields1, Dict.get k fields2 ) of
                            ( Just (Can.FieldType _ t1), Just (Can.FieldType _ t2) ) ->
                                oneWayUnify schemeVars t1 t2 s

                            _ ->
                                Nothing
            )
            (Just subst)
            keys1


{-| Matches an instance alias's arguments, `args2`, against a scheme alias's,
`args1`, position by position with `oneWayUnify`, threading `subst` through.
-}
unifyArgPairs : EverySet.EverySet String Name.Name -> List ( Name.Name, Can.Type Name ) -> List ( Name.Name, Can.Type Name ) -> Dict Name.Name (Can.Type Name) -> Maybe (Dict Name.Name (Can.Type Name))
unifyArgPairs schemeVars args1 args2 subst =
    case ( args1, args2 ) of
        ( [], [] ) ->
            Just subst

        ( ( _, t1 ) :: rest1, ( _, t2 ) :: rest2 ) ->
            oneWayUnify schemeVars t1 t2 subst
                |> Maybe.andThen (unifyArgPairs schemeVars rest1 rest2)

        _ ->
            Nothing


{-| Matches an instance alias body against a scheme alias body with
`oneWayUnify`. The two must both be `Holey` or both `Filled`.
-}
unifyAliasTypes : EverySet.EverySet String Name.Name -> Can.AliasType Name -> Can.AliasType Name -> Dict Name.Name (Can.Type Name) -> Maybe (Dict Name.Name (Can.Type Name))
unifyAliasTypes schemeVars at1 at2 subst =
    case ( at1, at2 ) of
        ( Can.Holey t1, Can.Holey t2 ) ->
            oneWayUnify schemeVars t1 t2 subst

        ( Can.Filled t1, Can.Filled t2 ) ->
            oneWayUnify schemeVars t1 t2 subst

        _ ->
            Nothing



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
        ++ (case v.expectedType of
                Just e ->
                    typeToString e

                Nothing ->
                    "(could not derive)"
           )
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
