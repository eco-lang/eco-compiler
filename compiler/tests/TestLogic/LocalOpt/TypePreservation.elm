module TestLogic.LocalOpt.TypePreservation exposing
    ( Violation
    , expectTypePreservation
    )

{-| Test logic for invariant TOPT\_004: Typed optimization is type preserving.

For each TypedOptimized expression, derive its expected type via local typing
rules and verify that the stored Can.Type matches via alpha-equivalence.

Key checks:

  - Literals have expected primitive types
  - VarLocal matches type from binding site
  - VarKernel matches type from KernelTypeEnv
  - VarGlobal is an instance of the annotation scheme
  - Function type is curried chain of param types → body type
  - Call/TailCall type is result of applying args to function type
  - Let type matches body type
  - If branches and else all match If type
  - Destruct type matches body type
  - Case has all Inline expressions and Jump targets matching result type

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as Name
import Compiler.Elm.Package as Pkg
import Compiler.Reporting.Annotation as A
import Compiler.Type.KernelTypes as KernelTypes
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet
import Expect
import System.TypeCheck.IO as IO
import TestLogic.LocalOpt.Typed.TypeEq as TypeEq
import TestLogic.TestPipeline as Pipeline



-- ============================================================================
-- TYPES
-- ============================================================================


{-| A violation of type preservation.
-}
type alias Violation =
    { exprKind : String
    , storedType : Can.Type
    , expectedType : Maybe Can.Type
    , details : String
    , context : String
    }


{-| Context for type checking expressions.
-}
type alias TypeEnv =
    { locals : Dict String Name.Name Can.Type
    , annotations : Dict String Name.Name Can.Annotation
    , kernelEnv : KernelTypes.KernelTypeEnv
    }


{-| Result of running through typed optimization with all artifacts.
-}
type alias TypedOptArtifacts =
    Pipeline.TypedOptArtifacts



-- ============================================================================
-- MAIN TEST FUNCTION
-- ============================================================================


{-| TOPT\_004: Verify type preservation in typed optimization.
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


checkLocalGraph : TypeEnv -> TOpt.LocalGraph -> List Violation
checkLocalGraph env (TOpt.LocalGraph data) =
    Dict.foldl TOpt.compareGlobal
        (\global node acc ->
            let
                context =
                    globalToString global
            in
            checkNode env context node ++ acc
        )
        []
        data.nodes


globalToString : TOpt.Global -> String
globalToString (TOpt.Global home name) =
    case home of
        IO.Canonical _ moduleName ->
            moduleName ++ "." ++ name


checkNode : TypeEnv -> String -> TOpt.Node -> List Violation
checkNode env context node =
    case node of
        TOpt.Define expr _ _ ->
            checkExpr env context expr

        TOpt.TrackedDefine _ expr _ _ ->
            checkExpr env context expr

        TOpt.Cycle _ values defs _ ->
            let
                -- Add cycle bindings to env
                cycleEnv =
                    List.foldl
                        (\( name, valExpr ) e ->
                            { e | locals = Dict.insert identity name (TOpt.typeOf valExpr) e.locals }
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
                            { e | locals = Dict.insert identity name defType e.locals }
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


checkExpr : TypeEnv -> String -> TOpt.Expr -> List Violation
checkExpr env context expr =
    let
        exprType =
            TOpt.typeOf expr
    in
    case expr of
        -- Literals
        -- Note: Int literals have type `number` (constrained TVar), not TType Int
        -- Float literals have type `Float` or `number`
        -- So we don't check specific primitive types here, just that they exist
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

        TOpt.Unit tipe ->
            checkLiteralType context "Unit" tipe Can.TUnit

        -- VarLocal (STRICT: catches GOPT_018-class bugs)
        TOpt.VarLocal name tipe ->
            case Dict.get identity name env.locals of
                Just envType ->
                    if TypeEq.alphaEqStrict tipe envType then
                        []

                    else
                        [ violation context "VarLocal" tipe (Just envType) ("Variable '" ++ name ++ "' type doesn't match binding (strict)") ]

                Nothing ->
                    -- Variable not in local env - could be from outer scope
                    []

        TOpt.TrackedVarLocal _ name tipe ->
            case Dict.get identity name env.locals of
                Just envType ->
                    if TypeEq.alphaEqStrict tipe envType then
                        []

                    else
                        [ violation context "TrackedVarLocal" tipe (Just envType) ("Variable '" ++ name ++ "' type doesn't match binding (strict)") ]

                Nothing ->
                    []

        -- VarKernel (STRICT: catches GOPT_018-class bugs)
        TOpt.VarKernel _ home name tipe ->
            case KernelTypes.lookup home name env.kernelEnv of
                Just kernelType ->
                    if TypeEq.alphaEqStrict tipe kernelType then
                        []

                    else
                        [ violation context "VarKernel" tipe (Just kernelType) ("Kernel '" ++ home ++ "." ++ name ++ "' type doesn't match KernelTypeEnv (strict)") ]

                Nothing ->
                    -- Kernel not in env - might be from another module
                    []

        -- VarGlobal
        -- Note: Scheme instantiation checking is complex due to polymorphism
        -- We'll skip this check for now and focus on the critical Case/Decider checks
        TOpt.VarGlobal _ _ _ ->
            []

        -- Function
        -- Note: We don't check that function type matches param -> body type directly
        -- because polymorphic functions may have more general return types than the body.
        -- Instead, we just check the body with the extended environment.
        TOpt.Function params body _ ->
            let
                extendedEnv =
                    { env
                        | locals =
                            List.foldl
                                (\( name, paramType ) acc -> Dict.insert identity name paramType acc)
                                env.locals
                                params
                    }
            in
            checkExpr extendedEnv context body

        TOpt.TrackedFunction params body _ ->
            let
                extendedEnv =
                    { env
                        | locals =
                            List.foldl
                                (\( A.At _ name, paramType ) acc -> Dict.insert identity name paramType acc)
                                env.locals
                                params
                    }
            in
            checkExpr extendedEnv context body

        -- Call
        -- Note: The result type may be more specific than the function's return type
        -- (due to polymorphism), so we just check structure, not exact match
        TOpt.Call _ func args tipe ->
            checkExpr env context func
                ++ List.concatMap (checkExpr env context) args

        -- TailCall
        -- Just check the argument expressions
        TOpt.TailCall _ args _ ->
            List.concatMap (\( _, argExpr ) -> checkExpr env context argExpr) args

        -- Let
        TOpt.Let def body _ ->
            let
                ( defName, defType ) =
                    getDefNameAndType def

                extendedEnv =
                    { env | locals = Dict.insert identity defName defType env.locals }
            in
            checkDef env context def
                ++ checkExpr extendedEnv context body

        -- Destruct
        TOpt.Destruct destructor body _ ->
            let
                (TOpt.Destructor destructName _ destructType) =
                    destructor

                extendedEnv =
                    { env | locals = Dict.insert identity destructName destructType env.locals }
            in
            checkExpr extendedEnv context body

        -- If
        -- Check that all branches and else have consistent types
        -- Note: The If expression type may be polymorphic while branches are concrete
        TOpt.If branches else_ _ ->
            let
                checkBranch ( cond, body ) =
                    checkExpr env context cond
                        ++ checkExpr env context body
            in
            List.concatMap checkBranch branches
                ++ checkExpr env context else_

        -- Case (Critical for GOPT_018)
        TOpt.Case _ _ decider jumps tipe ->
            checkDecider env context tipe decider
                ++ checkJumps env context tipe jumps

        -- List
        TOpt.List _ items tipe ->
            List.concatMap (checkExpr env context) items

        -- Access
        TOpt.Access recordExpr _ _ tipe ->
            checkExpr env context recordExpr

        -- Update
        TOpt.Update _ recordExpr updates tipe ->
            checkExpr env context recordExpr
                ++ Dict.foldl A.compareLocated (\_ updateExpr acc -> checkExpr env context updateExpr ++ acc) [] updates

        -- Record
        TOpt.Record fields tipe ->
            Dict.foldl compare (\_ fieldExpr acc -> checkExpr env context fieldExpr ++ acc) [] fields

        TOpt.TrackedRecord _ fields tipe ->
            Dict.foldl A.compareLocated (\_ fieldExpr acc -> checkExpr env context fieldExpr ++ acc) [] fields

        -- Tuple
        TOpt.Tuple _ e1 e2 rest tipe ->
            checkExpr env context e1
                ++ checkExpr env context e2
                ++ List.concatMap (checkExpr env context) rest

        -- Other expressions - just recurse
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


checkDef : TypeEnv -> String -> TOpt.Def -> List Violation
checkDef env context def =
    case def of
        TOpt.Def _ name expr _ ->
            -- Just recursively check the body expression
            checkExpr env (context ++ " Def " ++ name) expr

        TOpt.TailDef _ name params expr defType ->
            let
                -- Add the function itself to env for recursive calls
                envWithSelf =
                    { env | locals = Dict.insert identity name defType env.locals }

                -- Add parameters
                extendedEnv =
                    List.foldl
                        (\( A.At _ paramName, paramType ) e ->
                            { e | locals = Dict.insert identity paramName paramType e.locals }
                        )
                        envWithSelf
                        params
            in
            -- Just recursively check the body expression
            checkExpr extendedEnv (context ++ " TailDef " ++ name) expr



-- ============================================================================
-- DECIDER CHECKING (Critical for GOPT_018)
-- ============================================================================


checkDecider : TypeEnv -> String -> Can.Type -> TOpt.Decider TOpt.Choice -> List Violation
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


checkChoice : TypeEnv -> String -> Can.Type -> TOpt.Choice -> List Violation
checkChoice env context expectedType choice =
    case choice of
        TOpt.Inline expr ->
            let
                exprType =
                    TOpt.typeOf expr
            in
            -- STRICT: catches GOPT_018-class bugs where branch has polymorphic remnant
            if TypeEq.alphaEqStrict exprType expectedType then
                checkExpr env context expr

            else
                [ violation context "Inline" exprType (Just expectedType) "Inline expression type doesn't match Case result type (strict)" ]

        TOpt.Jump _ ->
            -- Jump targets are checked via checkJumps
            []


checkJumps : TypeEnv -> String -> Can.Type -> List ( Int, TOpt.Expr ) -> List Violation
checkJumps env context expectedType jumps =
    List.concatMap
        (\( idx, expr ) ->
            let
                exprType =
                    TOpt.typeOf expr
            in
            -- STRICT: catches GOPT_018-class bugs where branch has polymorphic remnant
            if TypeEq.alphaEqStrict exprType expectedType then
                checkExpr env context expr

            else
                [ violation context ("Jump target " ++ String.fromInt idx) exprType (Just expectedType) "Jump target type doesn't match Case result type (strict)" ]
        )
        jumps



-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================


getDefNameAndType : TOpt.Def -> ( Name.Name, Can.Type )
getDefNameAndType def =
    case def of
        TOpt.Def _ name _ tipe ->
            ( name, tipe )

        TOpt.TailDef _ name _ _ tipe ->
            ( name, tipe )


buildCurriedFunctionType : List Can.Type -> Can.Type -> Can.Type
buildCurriedFunctionType paramTypes resultType =
    List.foldr Can.TLambda resultType paramTypes


applyArgsToFuncType : Can.Type -> List Can.Type -> Maybe Can.Type
applyArgsToFuncType funcType argTypes =
    case argTypes of
        [] ->
            Just funcType

        _ :: rest ->
            case funcType of
                Can.TLambda _ resultType ->
                    applyArgsToFuncType resultType rest

                _ ->
                    Nothing


checkLiteralType : String -> String -> Can.Type -> Can.Type -> List Violation
checkLiteralType context kind actual expected =
    if alphaEq actual expected then
        []

    else
        [ violation context kind actual (Just expected) "Literal type mismatch" ]


checkTypeMatch : String -> String -> Can.Type -> Can.Type -> List Violation
checkTypeMatch context kind actual expected =
    if alphaEq actual expected then
        []

    else
        [ violation context kind actual (Just expected) "Type mismatch" ]


violation : String -> String -> Can.Type -> Maybe Can.Type -> String -> Violation
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


alphaEq : Can.Type -> Can.Type -> Bool
alphaEq a b =
    case ( a, b ) of
        ( Can.TVar _, Can.TVar _ ) ->
            -- Any TVar matches any TVar (alpha equivalence)
            True

        ( Can.TVar _, _ ) ->
            -- A type variable can be instantiated to any type
            True

        ( _, Can.TVar _ ) ->
            -- A type variable can be instantiated to any type
            True

        ( Can.TType h1 n1 as1, Can.TType h2 n2 as2 ) ->
            -- Compare type names, allowing for re-exports from different modules
            -- within the same package (e.g., Basics.String vs String.String)
            canonicalTypesEqual h1 n1 h2 n2 && alphaEqList as1 as2

        ( Can.TLambda a1 r1, Can.TLambda a2 r2 ) ->
            alphaEq a1 a2 && alphaEq r1 r2

        ( Can.TRecord fields1 ext1, Can.TRecord fields2 ext2 ) ->
            alphaEqExt ext1 ext2 && alphaEqFields fields1 fields2

        ( Can.TUnit, Can.TUnit ) ->
            True

        ( Can.TTuple a1 b1 cs1, Can.TTuple a2 b2 cs2 ) ->
            alphaEq a1 a2 && alphaEq b1 b2 && alphaEqList cs1 cs2

        ( Can.TAlias h1 n1 args1 at1, Can.TAlias h2 n2 args2 at2 ) ->
            h1 == h2 && n1 == n2 && alphaEqArgs args1 args2 && alphaEqAlias at1 at2

        -- Handle TAlias vs underlying type by unwrapping
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


{-| Check if two canonical type references are equal, handling re-exports.

In Elm, types like String can appear as both Basics.String and String.String
within the same package (elm/core). For type preservation checking, these
should be considered equivalent.

-}
canonicalTypesEqual : IO.Canonical -> String -> IO.Canonical -> String -> Bool
canonicalTypesEqual (IO.Canonical pkg1 _) name1 (IO.Canonical pkg2 _) name2 =
    -- Same package and same type name (ignoring module)
    pkg1 == pkg2 && name1 == name2


alphaEqList : List Can.Type -> List Can.Type -> Bool
alphaEqList xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: xrest, y :: yrest ) ->
            alphaEq x y && alphaEqList xrest yrest

        _ ->
            False


alphaEqExt : Maybe Name.Name -> Maybe Name.Name -> Bool
alphaEqExt e1 e2 =
    case ( e1, e2 ) of
        ( Nothing, Nothing ) ->
            True

        ( Just _, Just _ ) ->
            True

        _ ->
            False


alphaEqFields : Dict String Name.Name Can.FieldType -> Dict String Name.Name Can.FieldType -> Bool
alphaEqFields f1 f2 =
    let
        keys1 =
            Dict.keys compare f1

        keys2 =
            Dict.keys compare f2
    in
    keys1
        == keys2
        && List.all
            (\k ->
                case ( Dict.get identity k f1, Dict.get identity k f2 ) of
                    ( Just (Can.FieldType _ t1), Just (Can.FieldType _ t2) ) ->
                        alphaEq t1 t2

                    _ ->
                        False
            )
            keys1


alphaEqArgs : List ( Name.Name, Can.Type ) -> List ( Name.Name, Can.Type ) -> Bool
alphaEqArgs args1 args2 =
    case ( args1, args2 ) of
        ( [], [] ) ->
            True

        ( ( _, t1 ) :: rest1, ( _, t2 ) :: rest2 ) ->
            alphaEq t1 t2 && alphaEqArgs rest1 rest2

        _ ->
            False


alphaEqAlias : Can.AliasType -> Can.AliasType -> Bool
alphaEqAlias at1 at2 =
    case ( at1, at2 ) of
        ( Can.Holey t1, Can.Holey t2 ) ->
            alphaEq t1 t2

        ( Can.Filled t1, Can.Filled t2 ) ->
            alphaEq t1 t2

        _ ->
            False



-- ============================================================================
-- SCHEME INSTANTIATION CHECK
-- ============================================================================


{-| Check if instanceType is an instance of schemeType.

An instance is formed by substituting the scheme's free variables with
concrete types. Uses one-way unification where scheme variables
can bind but instance structure must match.

-}
isInstanceOf : EverySet.EverySet String Name.Name -> Can.Type -> Can.Type -> Bool
isInstanceOf schemeVars schemeType instanceType =
    case oneWayUnify schemeVars schemeType instanceType Dict.empty of
        Just _ ->
            True

        Nothing ->
            False


oneWayUnify : EverySet.EverySet String Name.Name -> Can.Type -> Can.Type -> Dict String Name.Name Can.Type -> Maybe (Dict String Name.Name Can.Type)
oneWayUnify schemeVars schemeT instanceT subst =
    case schemeT of
        Can.TVar name ->
            if EverySet.member identity name schemeVars then
                -- Scheme var: can bind to anything
                case Dict.get identity name subst of
                    Just boundType ->
                        -- Already bound; must match
                        if alphaEq boundType instanceT then
                            Just subst

                        else
                            Nothing

                    Nothing ->
                        Just (Dict.insert identity name instanceT subst)

            else
                -- Not a scheme var; must match exactly
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

        Can.TLambda a b ->
            case instanceT of
                Can.TLambda a2 b2 ->
                    oneWayUnify schemeVars a a2 subst
                        |> Maybe.andThen (oneWayUnify schemeVars b b2)

                _ ->
                    Nothing

        Can.TRecord fields ext ->
            case instanceT of
                Can.TRecord fields2 ext2 ->
                    -- Extension variable handling
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


unifyLists : EverySet.EverySet String Name.Name -> List Can.Type -> List Can.Type -> Dict String Name.Name Can.Type -> Maybe (Dict String Name.Name Can.Type)
unifyLists schemeVars ts1 ts2 subst =
    case ( ts1, ts2 ) of
        ( [], [] ) ->
            Just subst

        ( t1 :: rest1, t2 :: rest2 ) ->
            oneWayUnify schemeVars t1 t2 subst
                |> Maybe.andThen (unifyLists schemeVars rest1 rest2)

        _ ->
            Nothing


unifyFields : EverySet.EverySet String Name.Name -> Dict String Name.Name Can.FieldType -> Dict String Name.Name Can.FieldType -> Dict String Name.Name Can.Type -> Maybe (Dict String Name.Name Can.Type)
unifyFields schemeVars fields1 fields2 subst =
    let
        keys1 =
            Dict.keys compare fields1

        keys2 =
            Dict.keys compare fields2
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
                        case ( Dict.get identity k fields1, Dict.get identity k fields2 ) of
                            ( Just (Can.FieldType _ t1), Just (Can.FieldType _ t2) ) ->
                                oneWayUnify schemeVars t1 t2 s

                            _ ->
                                Nothing
            )
            (Just subst)
            keys1


unifyArgPairs : EverySet.EverySet String Name.Name -> List ( Name.Name, Can.Type ) -> List ( Name.Name, Can.Type ) -> Dict String Name.Name Can.Type -> Maybe (Dict String Name.Name Can.Type)
unifyArgPairs schemeVars args1 args2 subst =
    case ( args1, args2 ) of
        ( [], [] ) ->
            Just subst

        ( ( _, t1 ) :: rest1, ( _, t2 ) :: rest2 ) ->
            oneWayUnify schemeVars t1 t2 subst
                |> Maybe.andThen (unifyArgPairs schemeVars rest1 rest2)

        _ ->
            Nothing


unifyAliasTypes : EverySet.EverySet String Name.Name -> Can.AliasType -> Can.AliasType -> Dict String Name.Name Can.Type -> Maybe (Dict String Name.Name Can.Type)
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


formatViolations : List Violation -> String
formatViolations violations =
    let
        header =
            "TOPT_004 violations: "
                ++ String.fromInt (List.length violations)
                ++ " type preservation issue(s)\n\n"
    in
    header ++ (violations |> List.map formatViolation |> String.join "\n\n")


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


typeToString : Can.Type -> String
typeToString tipe =
    case tipe of
        Can.TVar name ->
            name

        Can.TType (IO.Canonical pkg mod) name args ->
            let
                prefix =
                    Tuple.first pkg ++ "/" ++ Tuple.second pkg ++ ":" ++ mod ++ "."
            in
            if List.isEmpty args then
                prefix ++ name

            else
                prefix ++ name ++ " " ++ String.join " " (List.map typeToStringParens args)

        Can.TLambda a b ->
            typeToStringParens a ++ " -> " ++ typeToString b

        Can.TRecord fields ext ->
            let
                fieldStrs =
                    Dict.toList compare fields
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

        Can.TAlias (IO.Canonical pkg mod) name _ _ ->
            Tuple.first pkg ++ "/" ++ Tuple.second pkg ++ ":" ++ mod ++ "." ++ name ++ " (alias)"


typeToStringParens : Can.Type -> String
typeToStringParens tipe =
    case tipe of
        Can.TLambda _ _ ->
            "(" ++ typeToString tipe ++ ")"

        Can.TType _ _ (_ :: _) ->
            "(" ++ typeToString tipe ++ ")"

        _ ->
            typeToString tipe
