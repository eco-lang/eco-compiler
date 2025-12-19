module Compiler.Optimize.Typed.Expression exposing
    ( Annotations, Cycle
    , optimize, optimizePotentialTailCall
    , destructArgs
    )

{-| Typed expression optimization.

Optimizes canonical expressions to typed optimized expressions while preserving
full type information. Unlike the regular Expression optimizer, this maintains
Can.Type annotations on every expression node and tracks local variable types
through a context, enabling type-aware optimizations and backends that need
type information.

Key features:

  - Every expression carries its Can.Type
  - Local variable types tracked through Names context
  - Function types decomposed for argument and return types
  - Tail call optimization with type preservation


# Types

@docs Annotations, Cycle


# Optimization

@docs optimize, optimizePotentialTailCall


# Destructuring

@docs destructArgs

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Optimize.Typed.Case as Case
import Compiler.Optimize.Typed.KernelTypes as KernelTypes
import Compiler.Optimize.Typed.Names as Names
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Utils.Crash exposing (crash)
import Utils.Main as Utils


{-| Result of destructuring a pattern with type and bindings.
Used to return all the information from pattern destructuring.
-}
type alias DestructResult =
    { locName : A.Located Name
    , tipe : Can.Type
    , destructors : List TOpt.Destructor
    , bindings : List ( Name, Can.Type )
    }



-- OPTIMIZE


{-| Set of names that form a recursive cycle.
Used to identify and optimize mutually recursive definitions during optimization.
-}
type alias Cycle =
    EverySet String Name


{-| Type annotations for top-level definitions.
Maps definition names to their canonical type annotations, used for type-aware optimization.
-}
type alias Annotations =
    TOpt.Annotations


{-| Optimize a canonical expression to a typed optimized expression.
Converts a canonical expression to a typed optimized form while preserving full type information.
Tracks dependencies and maintains type context for all subexpressions.
-}
optimize : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> Can.Expr -> Names.Tracker TOpt.Expr
optimize kernelEnv cycle annotations (A.At region expression) =
    case expression of
        Can.VarLocal name ->
            Names.getVarType name
                |> Names.map
                    (\maybeType ->
                        let
                            tipe =
                                case maybeType of
                                    Just t ->
                                        t

                                    Nothing ->
                                        crash ("Unknown variable: " ++ name)
                        in
                        TOpt.TrackedVarLocal region name tipe
                    )

        Can.VarTopLevel home name ->
            let
                tipe : Can.Type
                tipe =
                    lookupAnnotationType name annotations
            in
            if EverySet.member identity name cycle then
                Names.pure (TOpt.VarCycle region home name tipe)

            else
                Names.registerGlobal region home name tipe

        Can.VarKernel home name ->
            -- Look up the kernel type from the module's kernel type environment.
            -- This gives us real function types derived from the Elm aliases.
            let
                tipe : Can.Type
                tipe =
                    case KernelTypes.lookup home name kernelEnv of
                        Just t ->
                            t

                        Nothing ->
                            -- Fallback to placeholder during rollout.
                            -- Once all kernel aliases are covered, this could be a crash.
                            Can.TVar ("kernel_" ++ home ++ "_" ++ name)
            in
            Names.registerKernel home (TOpt.VarKernel region home name tipe)

        Can.VarForeign home name annotation ->
            let
                tipe : Can.Type
                tipe =
                    annotationType annotation
            in
            Names.registerGlobal region home name tipe

        Can.VarCtor opts home name index annotation ->
            let
                tipe : Can.Type
                tipe =
                    annotationType annotation
            in
            Names.registerCtor region home (A.At region name) index opts tipe

        Can.VarDebug home name annotation ->
            let
                tipe : Can.Type
                tipe =
                    annotationType annotation
            in
            Names.registerDebug name home region tipe

        Can.VarOperator _ home name annotation ->
            let
                tipe : Can.Type
                tipe =
                    annotationType annotation
            in
            Names.registerGlobal region home name tipe

        Can.Chr chr ->
            Names.registerKernel Name.utils (TOpt.Chr region chr charType)

        Can.Str str ->
            Names.pure (TOpt.Str region str stringType)

        Can.Int int ->
            Names.pure (TOpt.Int region int intType)

        Can.Float float ->
            Names.pure (TOpt.Float region float floatType)

        Can.List entries ->
            Names.traverse (optimize kernelEnv cycle annotations) entries
                |> Names.andThen
                    (\items ->
                        let
                            elemType : Can.Type
                            elemType =
                                case items of
                                    first :: _ ->
                                        TOpt.typeOf first

                                    [] ->
                                        -- Empty list - element type is unknown
                                        Can.TVar "a"

                            listType : Can.Type
                            listType =
                                Can.TType ModuleName.list "List" [ elemType ]
                        in
                        Names.registerKernel Name.list (TOpt.List region items listType)
                    )

        Can.Negate expr ->
            Names.registerGlobal region ModuleName.basics Name.negate negateType
                |> Names.andThen
                    (\func ->
                        optimize kernelEnv cycle annotations expr
                            |> Names.map
                                (\arg ->
                                    let
                                        resultType : Can.Type
                                        resultType =
                                            TOpt.typeOf arg
                                    in
                                    TOpt.Call region func [ arg ] resultType
                                )
                    )

        Can.Binop _ home name annotation left right ->
            let
                opType : Can.Type
                opType =
                    annotationType annotation
            in
            Names.registerGlobal region home name opType
                |> Names.andThen
                    (\optFunc ->
                        optimize kernelEnv cycle annotations left
                            |> Names.andThen
                                (\optLeft ->
                                    optimize kernelEnv cycle annotations right
                                        |> Names.map
                                            (\optRight ->
                                                let
                                                    leftType : Can.Type
                                                    leftType =
                                                        TOpt.typeOf optLeft

                                                    rightType : Can.Type
                                                    rightType =
                                                        TOpt.typeOf optRight

                                                    resultType : Can.Type
                                                    resultType =
                                                        computeBinopResultType opType leftType rightType
                                                in
                                                TOpt.Call region optFunc [ optLeft, optRight ] resultType
                                            )
                                )
                    )

        Can.Lambda args body ->
            destructArgs annotations args
                |> Names.andThen
                    (\( typedArgNames, destructors, bindings ) ->
                        let
                            -- Extend context with all bindings (includes nested pattern variables)
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                            allBindings : List ( Name, Can.Type )
                            allBindings =
                                argTypes ++ bindings
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv cycle annotations body)
                            |> Names.map
                                (\obody ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf obody

                                        funcType : Can.Type
                                        funcType =
                                            buildFunctionType (List.map Tuple.second typedArgNames) bodyType
                                    in
                                    TOpt.TrackedFunction typedArgNames (List.foldr (wrapDestruct bodyType) obody destructors) funcType
                                )
                    )

        Can.Call func args ->
            optimize kernelEnv cycle annotations func
                |> Names.andThen
                    (\optFunc ->
                        Names.traverse (optimize kernelEnv cycle annotations) args
                            |> Names.map
                                (\optArgs ->
                                    let
                                        funcType : Can.Type
                                        funcType =
                                            TOpt.typeOf optFunc

                                        resultType : Can.Type
                                        resultType =
                                            getCallResultType funcType (List.length optArgs)
                                    in
                                    TOpt.Call region optFunc optArgs resultType
                                )
                    )

        Can.If branches finally ->
            let
                optimizeBranch : ( Can.Expr, Can.Expr ) -> Names.Tracker ( TOpt.Expr, TOpt.Expr )
                optimizeBranch ( condition, branch ) =
                    optimize kernelEnv cycle annotations condition
                        |> Names.andThen
                            (\expr ->
                                optimize kernelEnv cycle annotations branch
                                    |> Names.map (Tuple.pair expr)
                            )
            in
            Names.traverse optimizeBranch branches
                |> Names.andThen
                    (\optimizedBranches ->
                        optimize kernelEnv cycle annotations finally
                            |> Names.map
                                (\ofinally ->
                                    let
                                        resultType : Can.Type
                                        resultType =
                                            TOpt.typeOf ofinally
                                    in
                                    TOpt.If optimizedBranches ofinally resultType
                                )
                    )

        Can.Let def body ->
            optimizeDefAndBody kernelEnv cycle annotations def body

        Can.LetRec defs body ->
            case defs of
                [ def ] ->
                    optimizePotentialTailCallDef kernelEnv cycle annotations def
                        |> Names.andThen
                            (\tailCallDef ->
                                let
                                    -- Extract name and type from the optimized def,
                                    -- instead of using annotations.
                                    ( defName, defType ) =
                                        case tailCallDef of
                                            TOpt.Def _ name _ t ->
                                                ( name, t )

                                            TOpt.TailDef _ name _ _ t ->
                                                ( name, t )
                                in
                                Names.withVarType defName
                                    defType
                                    (optimize kernelEnv cycle annotations body)
                                    |> Names.map
                                        (\obody ->
                                            let
                                                bodyType : Can.Type
                                                bodyType =
                                                    TOpt.typeOf obody
                                            in
                                            TOpt.Let tailCallDef obody bodyType
                                        )
                            )

                _ ->
                    optimizeLetRecDefs kernelEnv cycle annotations defs body

        Can.LetDestruct pattern expr body ->
            -- First optimize the expression to get its type
            optimize kernelEnv cycle annotations expr
                |> Names.andThen
                    (\oexpr ->
                        let
                            exprType : Can.Type
                            exprType =
                                TOpt.typeOf oexpr
                        in
                        -- Now destruct with the known expression type and collect all bindings
                        destructWithKnownTypeAndBindings exprType pattern
                            |> Names.andThen
                                (\( A.At nameRegion name, destructs, bindings ) ->
                                    let
                                        -- Include root name and all nested bindings
                                        allBindings : List ( Name, Can.Type )
                                        allBindings =
                                            ( name, exprType ) :: bindings
                                    in
                                    Names.withVarTypes allBindings
                                        (optimize kernelEnv cycle annotations body)
                                        |> Names.map
                                            (\obody ->
                                                let
                                                    bodyType : Can.Type
                                                    bodyType =
                                                        TOpt.typeOf obody
                                                in
                                                TOpt.Let (TOpt.Def nameRegion name oexpr exprType)
                                                    (List.foldr (wrapDestruct bodyType) obody destructs)
                                                    bodyType
                                            )
                                )
                    )

        Can.Case expr branches ->
            Names.generate
                |> Names.andThen
                    (\temp ->
                        optimize kernelEnv cycle annotations expr
                            |> Names.andThen
                                (\oexpr ->
                                    let
                                        scrutineeType : Can.Type
                                        scrutineeType =
                                            TOpt.typeOf oexpr

                                        -- Define optimizeBranch inside so it can access scrutineeType
                                        optimizeBranch : Name -> Can.CaseBranch -> Names.Tracker ( Can.Pattern, TOpt.Expr )
                                        optimizeBranch root (Can.CaseBranch pattern branch) =
                                            destructCaseWithType scrutineeType root pattern
                                                |> Names.andThen
                                                    (\( destructors, andThenings ) ->
                                                        Names.withVarTypes andThenings
                                                            (optimize kernelEnv cycle annotations branch)
                                                            |> Names.map
                                                                (\obranch ->
                                                                    let
                                                                        branchType : Can.Type
                                                                        branchType =
                                                                            TOpt.typeOf obranch
                                                                    in
                                                                    ( pattern, List.foldr (wrapDestruct branchType) obranch destructors )
                                                                )
                                                    )
                                    in
                                    case oexpr of
                                        TOpt.VarLocal root tipe ->
                                            Names.withVarType root
                                                tipe
                                                (Names.traverse (optimizeBranch root) branches)
                                                |> Names.map (Case.optimize temp root)

                                        TOpt.TrackedVarLocal _ root tipe ->
                                            Names.withVarType root
                                                tipe
                                                (Names.traverse (optimizeBranch root) branches)
                                                |> Names.map (Case.optimize temp root)

                                        _ ->
                                            Names.withVarType temp
                                                scrutineeType
                                                (Names.traverse (optimizeBranch temp) branches)
                                                |> Names.map
                                                    (\obranches ->
                                                        let
                                                            caseExpr : TOpt.Expr
                                                            caseExpr =
                                                                Case.optimize temp temp obranches

                                                            caseType : Can.Type
                                                            caseType =
                                                                TOpt.typeOf caseExpr
                                                        in
                                                        TOpt.Let (TOpt.Def region temp oexpr scrutineeType) caseExpr caseType
                                                    )
                                )
                    )

        Can.Accessor field ->
            -- Accessor is a function: { r | field : a } -> a
            let
                -- We don't know the exact record type, so use a type variable
                fieldVar : Can.Type
                fieldVar =
                    Can.TVar "a"

                recordVar : Can.Type
                recordVar =
                    Can.TRecord (Dict.singleton identity field (Can.FieldType 0 fieldVar)) (Just "r")

                accessorType : Can.Type
                accessorType =
                    Can.TLambda recordVar fieldVar
            in
            Names.registerField field (TOpt.Accessor region field accessorType)

        Can.Access record (A.At fieldPosition field) ->
            optimize kernelEnv cycle annotations record
                |> Names.andThen
                    (\optRecord ->
                        let
                            recordType : Can.Type
                            recordType =
                                TOpt.typeOf optRecord

                            fieldType : Can.Type
                            fieldType =
                                getFieldType field recordType
                        in
                        Names.registerField field (TOpt.Access optRecord fieldPosition field fieldType)
                    )

        Can.Update record updates ->
            Names.mapTraverse A.toValue A.compareLocated (optimizeUpdate kernelEnv cycle annotations) updates
                |> Names.andThen
                    (\optUpdates ->
                        optimize kernelEnv cycle annotations record
                            |> Names.andThen
                                (\optRecord ->
                                    let
                                        recordType : Can.Type
                                        recordType =
                                            TOpt.typeOf optRecord
                                    in
                                    Names.registerFieldDict (Utils.mapMapKeys identity A.compareLocated A.toValue updates)
                                        (TOpt.Update region optRecord optUpdates recordType)
                                )
                    )

        Can.Record fields ->
            Names.mapTraverse A.toValue A.compareLocated (optimize kernelEnv cycle annotations) fields
                |> Names.andThen
                    (\optFields ->
                        let
                            fieldTypes : Dict String Name Can.FieldType
                            fieldTypes =
                                Dict.map
                                    (\_ expr -> Can.FieldType 0 (TOpt.typeOf expr))
                                    (Utils.mapMapKeys identity A.compareLocated A.toValue optFields)

                            recordType : Can.Type
                            recordType =
                                Can.TRecord fieldTypes Nothing
                        in
                        Names.registerFieldDict (Utils.mapMapKeys identity A.compareLocated A.toValue fields)
                            (TOpt.TrackedRecord region optFields recordType)
                    )

        Can.Unit ->
            Names.registerKernel Name.utils (TOpt.Unit unitType)

        Can.Tuple a b cs ->
            optimize kernelEnv cycle annotations a
                |> Names.andThen
                    (\optA ->
                        optimize kernelEnv cycle annotations b
                            |> Names.andThen
                                (\optB ->
                                    Names.traverse (optimize kernelEnv cycle annotations) cs
                                        |> Names.andThen
                                            (\optCs ->
                                                let
                                                    tupleType : Can.Type
                                                    tupleType =
                                                        Can.TTuple
                                                            (TOpt.typeOf optA)
                                                            (TOpt.typeOf optB)
                                                            (List.map TOpt.typeOf optCs)
                                                in
                                                Names.registerKernel Name.utils (TOpt.Tuple region optA optB optCs tupleType)
                                            )
                                )
                    )

        Can.Shader src (Shader.Types attributes uniforms varyings) ->
            let
                -- Build record types for attributes, uniforms, and varyings
                toFieldType : Name -> Shader.Type -> Can.FieldType
                toFieldType _ shaderTipe =
                    Can.FieldType 0 (shaderTypeToCanType shaderTipe)

                attributeFields : Dict String Name Can.FieldType
                attributeFields =
                    Dict.map toFieldType attributes

                uniformFields : Dict String Name Can.FieldType
                uniformFields =
                    Dict.map toFieldType uniforms

                varyingFields : Dict String Name Can.FieldType
                varyingFields =
                    Dict.map toFieldType varyings

                attributeType : Can.Type
                attributeType =
                    Can.TRecord attributeFields Nothing

                uniformType : Can.Type
                uniformType =
                    Can.TRecord uniformFields Nothing

                varyingType : Can.Type
                varyingType =
                    Can.TRecord varyingFields Nothing

                shaderType : Can.Type
                shaderType =
                    Can.TType ModuleName.webgl "Shader" [ attributeType, uniformType, varyingType ]
            in
            Names.pure
                (TOpt.Shader src
                    (EverySet.fromList identity (Dict.keys compare attributes))
                    (EverySet.fromList identity (Dict.keys compare uniforms))
                    shaderType
                )



-- HELPER FUNCTIONS


charType : Can.Type
charType =
    Can.TType ModuleName.char "Char" []


stringType : Can.Type
stringType =
    Can.TType ModuleName.string "String" []


intType : Can.Type
intType =
    Can.TType ModuleName.basics "Int" []


floatType : Can.Type
floatType =
    Can.TType ModuleName.basics "Float" []


{-| Check if a canonical type is a concrete numeric primitive (Int or Float).
-}
isConcreteNumberType : Can.Type -> Bool
isConcreteNumberType tipe =
    case tipe of
        Can.TType home typeName [] ->
            home == ModuleName.basics
                && (typeName == Name.int || typeName == Name.float)

        _ ->
            False


boolType : Can.Type
boolType =
    Can.TType ModuleName.basics "Bool" []


{-| Convert a GLSL shader type to a canonical Elm type.
-}
shaderTypeToCanType : Shader.Type -> Can.Type
shaderTypeToCanType shaderType =
    case shaderType of
        Shader.Int ->
            intType

        Shader.Float ->
            floatType

        Shader.V2 ->
            Can.TType ModuleName.vector2 "Vec2" []

        Shader.V3 ->
            Can.TType ModuleName.vector3 "Vec3" []

        Shader.V4 ->
            Can.TType ModuleName.vector4 "Vec4" []

        Shader.M4 ->
            Can.TType ModuleName.matrix4 "Mat4" []

        Shader.Texture ->
            Can.TType ModuleName.texture "Texture" []

        Shader.Bool ->
            boolType


unitType : Can.Type
unitType =
    Can.TUnit


negateType : Can.Type
negateType =
    -- number -> number
    Can.TLambda (Can.TVar "number") (Can.TVar "number")


annotationType : Can.Annotation -> Can.Type
annotationType (Can.Forall _ tipe) =
    tipe


{-| Look up the canonical type of a top-level definition from its annotation.

IMPORTANT: Only use this for top-level definitions that have module-level annotations.
Do NOT use this for local let/letrec bindings - those must be typed via TOpt.typeOf
on the optimized RHS expression.

-}
lookupAnnotationType : Name -> Annotations -> Can.Type
lookupAnnotationType name annotations =
    case Dict.get identity name annotations of
        Just (Can.Forall _ tipe) ->
            tipe

        Nothing ->
            crash ("Annotation not found: " ++ name)


{-| Get the result type of a function call.
Peels off n TLambda wrappers.
-}
getCallResultType : Can.Type -> Int -> Can.Type
getCallResultType funcType numArgs =
    case ( funcType, numArgs ) of
        ( _, 0 ) ->
            funcType

        ( Can.TLambda _ result, n ) ->
            getCallResultType result (n - 1)

        _ ->
            -- Not enough lambdas - return what we have
            funcType


{-| Compute the result type of a binary operator call.

This refines the old `getCallResultType opType 2` behavior for the common
case of numeric-supertype operators like (+), (-), (\*), (//), etc.

If the operator's result type is the `number` supertype variable
(e.g. `number -> number -> number`) *and* both operands have already been
resolved to a concrete numeric type (`Int` or `Float`), we return that
concrete operand type instead of the abstract `TVar "number"`.

In all other cases, we fall back to `getCallResultType opType 2`.

-}
computeBinopResultType : Can.Type -> Can.Type -> Can.Type -> Can.Type
computeBinopResultType opType leftType rightType =
    let
        fallback : Can.Type
        fallback =
            getCallResultType opType 2
    in
    case opType of
        -- Expect a curried binary function: arg1 -> arg2 -> result
        Can.TLambda _ (Can.TLambda _ result) ->
            case result of
                -- Only special-case when the result is a numeric supertype var
                Can.TVar varName ->
                    if Name.isNumberType varName then
                        -- Only trust the operand type when it's a concrete number
                        if isConcreteNumberType leftType && leftType == rightType then
                            leftType

                        else
                            fallback

                    else
                        fallback

                _ ->
                    fallback

        _ ->
            -- Non-standard operator shapes: keep existing behavior
            fallback


{-| Build a function type from argument types and result type.
-}
buildFunctionType : List Can.Type -> Can.Type -> Can.Type
buildFunctionType argTypes resultType =
    List.foldr Can.TLambda resultType argTypes


{-| Get the type of a field from a record type.
-}
getFieldType : Name -> Can.Type -> Can.Type
getFieldType field recordType =
    case recordType of
        Can.TRecord fields _ ->
            case Dict.get identity field fields of
                Just (Can.FieldType _ tipe) ->
                    tipe

                Nothing ->
                    crash ("Field not found: " ++ field)

        Can.TAlias _ _ _ (Can.Filled tipe) ->
            getFieldType field tipe

        Can.TAlias _ _ args (Can.Holey body) ->
            -- Substitute type parameters and look up field in the expanded body
            let
                substitutedBody : Can.Type
                substitutedBody =
                    substituteTypeVars args body
            in
            getFieldType field substitutedBody

        Can.TVar _ ->
            -- Type variable representing a record - return a placeholder type variable
            -- This happens with extensible records like { a | field : Type }
            Can.TVar ("field_" ++ field)

        _ ->
            crash ("Expected record type for field access: " ++ field)


{-| Substitute type variables in a type according to the given bindings.
-}
substituteTypeVars : List ( Name, Can.Type ) -> Can.Type -> Can.Type
substituteTypeVars bindings tipe =
    case tipe of
        Can.TVar name ->
            case List.filter (\( n, _ ) -> n == name) bindings of
                ( _, replacement ) :: _ ->
                    replacement

                [] ->
                    tipe

        Can.TLambda arg result ->
            Can.TLambda (substituteTypeVars bindings arg) (substituteTypeVars bindings result)

        Can.TType home name args ->
            Can.TType home name (List.map (substituteTypeVars bindings) args)

        Can.TRecord fields ext ->
            Can.TRecord
                (Dict.map (\_ (Can.FieldType idx ft) -> Can.FieldType idx (substituteTypeVars bindings ft)) fields)
                ext

        Can.TUnit ->
            Can.TUnit

        Can.TTuple a b cs ->
            Can.TTuple
                (substituteTypeVars bindings a)
                (substituteTypeVars bindings b)
                (List.map (substituteTypeVars bindings) cs)

        Can.TAlias home name args aliasType ->
            Can.TAlias home
                name
                (List.map (\( n, t ) -> ( n, substituteTypeVars bindings t )) args)
                (case aliasType of
                    Can.Holey body ->
                        Can.Holey (substituteTypeVars bindings body)

                    Can.Filled body ->
                        Can.Filled (substituteTypeVars bindings body)
                )


{-| Get name and type from a top-level definition using module annotations.

IMPORTANT: Only use this for top-level definitions that have module-level annotations.
For local let/letrec bindings, extract the type from the optimized TOpt.Def instead.

-}
getDefNameAndType : Can.Def -> Annotations -> ( Name, Can.Type )
getDefNameAndType def annotations =
    case def of
        Can.Def (A.At _ name) _ _ ->
            ( name, lookupAnnotationType name annotations )

        Can.TypedDef (A.At _ name) _ typedArgs _ resultType ->
            let
                argTypes : List Can.Type
                argTypes =
                    List.map Tuple.second typedArgs

                funcType : Can.Type
                funcType =
                    buildFunctionType argTypes resultType
            in
            ( name, funcType )


{-| Synthesize a function type for a (possibly local) recursive def,
without looking at annotations.

For untyped defs, we build a `TLambda` chain with fresh type variables
for each argument and the result. This is only used to seed the Names
environment so recursive calls have some type; the final def type is
computed later from the optimized RHS via TOpt.typeOf.

-}
synthesizeRecDefType : Can.Def -> Can.Type
synthesizeRecDefType def =
    case def of
        Can.Def (A.At _ name) args _ ->
            let
                -- Use existing pattern heuristics to get argument types.
                argTypes : List Can.Type
                argTypes =
                    List.map (getPatternType Dict.empty) args

                -- Still use a schematic result type; it will be
                -- replaced later by TOpt.typeOf on the optimized RHS.
                resultType : Can.Type
                resultType =
                    Can.TVar ("_rec_result_" ++ name)
            in
            buildFunctionType argTypes resultType

        Can.TypedDef (A.At _ _) _ typedArgs _ resultType ->
            let
                argTypes : List Can.Type
                argTypes =
                    List.map Tuple.second typedArgs
            in
            buildFunctionType argTypes resultType


{-| Wrap a destructor around a body expression.
-}
wrapDestruct : Can.Type -> TOpt.Destructor -> TOpt.Expr -> TOpt.Expr
wrapDestruct bodyType destructor body =
    TOpt.Destruct destructor body bodyType



-- UPDATE


optimizeUpdate : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> Can.FieldUpdate -> Names.Tracker TOpt.Expr
optimizeUpdate kernelEnv cycle annotations (Can.FieldUpdate _ expr) =
    optimize kernelEnv cycle annotations expr



-- DEFINITION


optimizeDefAndBody : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> Can.Def -> Can.Expr -> Names.Tracker TOpt.Expr
optimizeDefAndBody kernelEnv cycle annotations def body =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizeDefHelp kernelEnv cycle annotations region name args expr body

        Can.TypedDef (A.At region name) _ typedArgs expr resultType ->
            optimizeTypedDefHelp kernelEnv cycle annotations region name typedArgs expr resultType body


optimizeDefHelp : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> A.Region -> Name -> List Can.Pattern -> Can.Expr -> Can.Expr -> Names.Tracker TOpt.Expr
optimizeDefHelp kernelEnv cycle annotations region name args expr body =
    case args of
        [] ->
            optimize kernelEnv cycle annotations expr
                |> Names.andThen
                    (\oexpr ->
                        let
                            exprType : Can.Type
                            exprType =
                                TOpt.typeOf oexpr
                        in
                        Names.withVarType name
                            exprType
                            (optimize kernelEnv cycle annotations body)
                            |> Names.map
                                (\obody ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf obody
                                    in
                                    TOpt.Let (TOpt.Def region name oexpr exprType) obody bodyType
                                )
                    )

        _ ->
            destructArgs annotations args
                |> Names.andThen
                    (\( typedArgNames, destructors, bindings ) ->
                        let
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                            allBindings : List ( Name, Can.Type )
                            allBindings =
                                argTypes ++ bindings
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv cycle annotations expr)
                            |> Names.andThen
                                (\oexpr ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf oexpr

                                        funcType : Can.Type
                                        funcType =
                                            buildFunctionType (List.map Tuple.second typedArgNames) bodyType

                                        ofunc : TOpt.Expr
                                        ofunc =
                                            TOpt.TrackedFunction typedArgNames
                                                (List.foldr (wrapDestruct bodyType) oexpr destructors)
                                                funcType
                                    in
                                    Names.withVarType name
                                        funcType
                                        (optimize kernelEnv cycle annotations body)
                                        |> Names.map
                                            (\obody ->
                                                let
                                                    resultType : Can.Type
                                                    resultType =
                                                        TOpt.typeOf obody
                                                in
                                                TOpt.Let (TOpt.Def region name ofunc funcType) obody resultType
                                            )
                                )
                    )


optimizeTypedDefHelp : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> A.Region -> Name -> List ( Can.Pattern, Can.Type ) -> Can.Expr -> Can.Type -> Can.Expr -> Names.Tracker TOpt.Expr
optimizeTypedDefHelp kernelEnv cycle annotations region name typedArgs expr resultType body =
    case typedArgs of
        [] ->
            optimize kernelEnv cycle annotations expr
                |> Names.andThen
                    (\oexpr ->
                        Names.withVarType name
                            resultType
                            (optimize kernelEnv cycle annotations body)
                            |> Names.map
                                (\obody ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf obody
                                    in
                                    TOpt.Let (TOpt.Def region name oexpr resultType) obody bodyType
                                )
                    )

        _ ->
            destructTypedArgs typedArgs
                |> Names.andThen
                    (\( typedArgNames, destructors, bindings ) ->
                        let
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                            allBindings : List ( Name, Can.Type )
                            allBindings =
                                argTypes ++ bindings

                            funcType : Can.Type
                            funcType =
                                buildFunctionType (List.map Tuple.second typedArgNames) resultType
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv cycle annotations expr)
                            |> Names.andThen
                                (\oexpr ->
                                    let
                                        ofunc : TOpt.Expr
                                        ofunc =
                                            TOpt.TrackedFunction typedArgNames
                                                (List.foldr (wrapDestruct resultType) oexpr destructors)
                                                funcType
                                    in
                                    Names.withVarType name
                                        funcType
                                        (optimize kernelEnv cycle annotations body)
                                        |> Names.map
                                            (\obody ->
                                                let
                                                    bodyType : Can.Type
                                                    bodyType =
                                                        TOpt.typeOf obody
                                                in
                                                TOpt.Let (TOpt.Def region name ofunc funcType) obody bodyType
                                            )
                                )
                    )


optimizeLetRecDefs : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> List Can.Def -> Can.Expr -> Names.Tracker TOpt.Expr
optimizeLetRecDefs kernelEnv cycle annotations defs body =
    -- For multiple recursive defs, we add all their types to scope first.
    -- Use synthesizeRecDefType instead of getDefNameAndType to avoid looking
    -- up annotations for local defs.
    let
        defBindings : List ( Name, Can.Type )
        defBindings =
            List.map
                (\d ->
                    case d of
                        Can.Def (A.At _ name) _ _ ->
                            ( name, synthesizeRecDefType d )

                        Can.TypedDef (A.At _ name) _ _ _ _ ->
                            ( name, synthesizeRecDefType d )
                )
                defs
    in
    Names.withVarTypes defBindings
        (List.foldl
            (\def bod ->
                Names.andThen (optimizeRecDefToLet kernelEnv cycle annotations def) bod
            )
            (optimize kernelEnv cycle annotations body)
            defs
        )


optimizeRecDefToLet : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> Can.Def -> TOpt.Expr -> Names.Tracker TOpt.Expr
optimizeRecDefToLet kernelEnv cycle annotations def body =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizeRecDefHelp kernelEnv cycle annotations region name args expr body

        Can.TypedDef (A.At region name) _ typedArgs expr resultType ->
            optimizeTypedRecDefHelp kernelEnv cycle annotations region name typedArgs expr resultType body


optimizeRecDefHelp : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> A.Region -> Name -> List Can.Pattern -> Can.Expr -> TOpt.Expr -> Names.Tracker TOpt.Expr
optimizeRecDefHelp kernelEnv cycle annotations region name args expr body =
    let
        bodyType : Can.Type
        bodyType =
            TOpt.typeOf body
    in
    case args of
        [] ->
            -- No arguments: def type is just the RHS type.
            optimize kernelEnv cycle annotations expr
                |> Names.map
                    (\oexpr ->
                        let
                            defType : Can.Type
                            defType =
                                TOpt.typeOf oexpr
                        in
                        TOpt.Let (TOpt.Def region name oexpr defType) body bodyType
                    )

        _ ->
            destructArgs annotations args
                |> Names.andThen
                    (\( typedArgNames, destructors, bindings ) ->
                        let
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                            allBindings : List ( Name, Can.Type )
                            allBindings =
                                argTypes ++ bindings
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv cycle annotations expr)
                            |> Names.map
                                (\oexpr ->
                                    let
                                        exprType : Can.Type
                                        exprType =
                                            TOpt.typeOf oexpr

                                        funcType : Can.Type
                                        funcType =
                                            buildFunctionType (List.map Tuple.second typedArgNames) exprType

                                        ofunc : TOpt.Expr
                                        ofunc =
                                            TOpt.TrackedFunction typedArgNames
                                                (List.foldr (wrapDestruct exprType) oexpr destructors)
                                                funcType
                                    in
                                    TOpt.Let (TOpt.Def region name ofunc funcType) body bodyType
                                )
                    )


optimizeTypedRecDefHelp : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> A.Region -> Name -> List ( Can.Pattern, Can.Type ) -> Can.Expr -> Can.Type -> TOpt.Expr -> Names.Tracker TOpt.Expr
optimizeTypedRecDefHelp kernelEnv cycle annotations region name typedArgs expr resultType body =
    let
        bodyType : Can.Type
        bodyType =
            TOpt.typeOf body
    in
    case typedArgs of
        [] ->
            optimize kernelEnv cycle annotations expr
                |> Names.map
                    (\oexpr ->
                        TOpt.Let (TOpt.Def region name oexpr resultType) body bodyType
                    )

        _ ->
            destructTypedArgs typedArgs
                |> Names.andThen
                    (\( typedArgNames, destructors, bindings ) ->
                        let
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                            allBindings : List ( Name, Can.Type )
                            allBindings =
                                argTypes ++ bindings

                            funcType : Can.Type
                            funcType =
                                buildFunctionType (List.map Tuple.second typedArgNames) resultType
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv cycle annotations expr)
                            |> Names.map
                                (\oexpr ->
                                    let
                                        ofunc : TOpt.Expr
                                        ofunc =
                                            TOpt.TrackedFunction typedArgNames
                                                (List.foldr (wrapDestruct resultType) oexpr destructors)
                                                funcType
                                    in
                                    TOpt.Let (TOpt.Def region name ofunc funcType) body bodyType
                                )
                    )



-- DESTRUCTURING


{-| Convert function argument patterns into destructors with type information.
Returns a list of argument names with their types, destructors, and all bindings.
-}
destructArgs : Annotations -> List Can.Pattern -> Names.Tracker ( List ( A.Located Name, Can.Type ), List TOpt.Destructor, List ( Name, Can.Type ) )
destructArgs annotations args =
    Names.traverse (destruct annotations) args
        |> Names.map
            (\results ->
                let
                    ( argPairs, allDestructors, allBindings ) =
                        List.foldr
                            (\result ( pairs, dss, bss ) ->
                                ( ( result.locName, result.tipe ) :: pairs
                                , result.destructors ++ dss
                                , result.bindings ++ bss
                                )
                            )
                            ( [], [], [] )
                            results
                in
                ( argPairs, allDestructors, allBindings )
            )


destructTypedArgs : List ( Can.Pattern, Can.Type ) -> Names.Tracker ( List ( A.Located Name, Can.Type ), List TOpt.Destructor, List ( Name, Can.Type ) )
destructTypedArgs typedArgs =
    Names.traverse destructTypedArg typedArgs
        |> Names.map
            (\results ->
                List.foldr
                    (\( n, ds, bs ) ( ns, dss, bss ) -> ( n :: ns, ds ++ dss, bs ++ bss ))
                    ( [], [], [] )
                    results
            )


destructTypedArg : ( Can.Pattern, Can.Type ) -> Names.Tracker ( ( A.Located Name, Can.Type ), List TOpt.Destructor, List ( Name, Can.Type ) )
destructTypedArg ( pattern, tipe ) =
    destructPatternWithTypeAndBindings tipe pattern
        |> Names.map (\result -> ( ( result.locName, result.tipe ), result.destructors, result.bindings ))


destructCase : Can.Type -> Name -> Can.Pattern -> Names.Tracker ( List TOpt.Destructor, List ( Name, Can.Type ) )
destructCase scrutineeType rootName pattern =
    -- Use the scrutinee type directly instead of trying to infer from pattern.
    -- This fixes crashes for wildcards, variables, tuples, and constructors.
    destructHelpCollectBindings (TOpt.Root rootName) scrutineeType pattern ( [], [] )
        |> Names.map (\( revDs, andThenings ) -> ( List.reverse revDs, andThenings ))


{-| Destruct a case pattern with a known type from the scrutinee.
This is the preferred version that avoids trying to infer types from patterns.
-}
destructCaseWithType : Can.Type -> Name -> Can.Pattern -> Names.Tracker ( List TOpt.Destructor, List ( Name, Can.Type ) )
destructCaseWithType scrutineeType rootName pattern =
    destructHelpCollectBindings (TOpt.Root rootName) scrutineeType pattern ( [], [] )
        |> Names.map (\( revDs, andThenings ) -> ( List.reverse revDs, andThenings ))


{-| Destructure a pattern, returning root name, type, destructors, and all bindings.
-}
destruct : Annotations -> Can.Pattern -> Names.Tracker DestructResult
destruct annotations pattern =
    let
        patternType : Can.Type
        patternType =
            getPatternType annotations pattern
    in
    destructPatternWithTypeAndBindings patternType pattern


destructWithType : Can.Type -> Can.Pattern -> Names.Tracker ( A.Located Name, List TOpt.Destructor )
destructWithType tipe ((A.At region ptrn) as pattern) =
    case ptrn of
        Can.PVar name ->
            Names.pure ( A.At region name, [] )

        Can.PAlias subPattern name ->
            destructHelp (TOpt.Root name) tipe subPattern []
                |> Names.map (\revDs -> ( A.At region name, List.reverse revDs ))

        _ ->
            Names.generate
                |> Names.andThen
                    (\name ->
                        destructHelp (TOpt.Root name) tipe pattern []
                            |> Names.map (\revDs -> ( A.At region name, List.reverse revDs ))
                    )


{-| Like destruct but takes the known type instead of inferring it.
Used when we already have the expression type from the RHS.
-}
destructWithKnownType : Can.Type -> Can.Pattern -> Names.Tracker ( A.Located Name, List TOpt.Destructor )
destructWithKnownType tipe ((A.At region ptrn) as pattern) =
    case ptrn of
        Can.PVar name ->
            Names.pure ( A.At region name, [] )

        Can.PAlias subPattern name ->
            destructHelp (TOpt.Root name) tipe subPattern []
                |> Names.map (\revDs -> ( A.At region name, List.reverse revDs ))

        _ ->
            Names.generate
                |> Names.andThen
                    (\name ->
                        destructHelp (TOpt.Root name) tipe pattern []
                            |> Names.map (\revDs -> ( A.At region name, List.reverse revDs ))
                    )


{-| Destructure a pattern with a known type and collect all bindings.
Returns the root name, type, destructors, and all nested bindings.
-}
destructPatternWithTypeAndBindings : Can.Type -> Can.Pattern -> Names.Tracker DestructResult
destructPatternWithTypeAndBindings tipe ((A.At region ptrn) as pattern) =
    case ptrn of
        Can.PVar name ->
            -- Simple variable: no destructors, one binding
            Names.pure
                { locName = A.At region name
                , tipe = tipe
                , destructors = []
                , bindings = [ ( name, tipe ) ]
                }

        Can.PAlias subPattern name ->
            -- Alias binds the alias name and any nested bindings
            destructHelpCollectBindings (TOpt.Root name) tipe subPattern ( [], [] )
                |> Names.map
                    (\( revDs, nestedBindings ) ->
                        { locName = A.At region name
                        , tipe = tipe
                        , destructors = List.reverse revDs
                        , bindings = ( name, tipe ) :: nestedBindings
                        }
                    )

        _ ->
            -- Complex pattern: generate a synthetic root name
            Names.generate
                |> Names.andThen
                    (\name ->
                        destructHelpCollectBindings (TOpt.Root name) tipe pattern ( [], [] )
                            |> Names.map
                                (\( revDs, nestedBindings ) ->
                                    { locName = A.At region name
                                    , tipe = tipe
                                    , destructors = List.reverse revDs
                                    , bindings = ( name, tipe ) :: nestedBindings
                                    }
                                )
                    )


{-| Like destructWithKnownType but also returns all bindings.
-}
destructWithKnownTypeAndBindings : Can.Type -> Can.Pattern -> Names.Tracker ( A.Located Name, List TOpt.Destructor, List ( Name, Can.Type ) )
destructWithKnownTypeAndBindings tipe pattern =
    destructPatternWithTypeAndBindings tipe pattern
        |> Names.map (\result -> ( result.locName, result.destructors, result.bindings ))


{-| Try to infer type from pattern structure.
This is a best-effort approach for patterns. For patterns where the type
cannot be inferred (wildcards, variables, etc.), we use a type variable
as a placeholder. Type checking has already happened, so these types
will be properly constrained in context.
-}
getPatternType : Annotations -> Can.Pattern -> Can.Type
getPatternType _ (A.At _ pattern) =
    case pattern of
        Can.PAnything ->
            -- Wildcard can be any type
            Can.TVar "_pattern"

        Can.PVar name ->
            -- Variable pattern - use name-based type variable
            Can.TVar name

        Can.PRecord _ ->
            -- Record pattern - use placeholder record type
            Can.TVar "_record"

        Can.PAlias subPattern _ ->
            -- Alias pattern - try to get type from sub-pattern (subPattern is already A.Located Pattern_)
            getPatternType Dict.empty subPattern

        Can.PUnit ->
            unitType

        Can.PTuple a b otherPatterns ->
            -- Tuple pattern - recursively get element types (third element is List Pattern for 3+ tuples)
            let
                aType =
                    getPatternType Dict.empty a

                bType =
                    getPatternType Dict.empty b

                otherTypes =
                    List.map (getPatternType Dict.empty) otherPatterns
            in
            Can.TTuple aType bType otherTypes

        Can.PList _ ->
            -- List pattern - element type unknown
            Can.TType ModuleName.list "List" [ Can.TVar "_elem" ]

        Can.PCons _ _ ->
            -- Cons pattern - element type unknown
            Can.TType ModuleName.list "List" [ Can.TVar "_elem" ]

        Can.PChr _ ->
            charType

        Can.PStr _ _ ->
            stringType

        Can.PInt _ ->
            intType

        Can.PBool _ _ ->
            Can.TType ModuleName.basics "Bool" []

        Can.PCtor { home, type_, union } ->
            -- Constructor pattern - use the type from the constructor info
            case union of
                Can.Union data ->
                    Can.TType home type_ (List.map (\_ -> Can.TVar "_") data.vars)


{-| Destructure a pattern to produce a list of destructors.
This is now a thin wrapper around destructHelpCollectBindings that discards the bindings.
-}
destructHelp : TOpt.Path -> Can.Type -> Can.Pattern -> List TOpt.Destructor -> Names.Tracker (List TOpt.Destructor)
destructHelp path tipe pattern revDs =
    destructHelpCollectBindings path tipe pattern ( revDs, [] )
        |> Names.map Tuple.first


destructHelpCollectBindings : TOpt.Path -> Can.Type -> Can.Pattern -> ( List TOpt.Destructor, List ( Name, Can.Type ) ) -> Names.Tracker ( List TOpt.Destructor, List ( Name, Can.Type ) )
destructHelpCollectBindings path tipe (A.At _ pattern) ( revDs, bindings ) =
    case pattern of
        Can.PAnything ->
            Names.pure ( revDs, bindings )

        Can.PVar name ->
            Names.pure ( TOpt.Destructor name path tipe :: revDs, ( name, tipe ) :: bindings )

        Can.PRecord fields ->
            let
                newBindings : List ( Name, Can.Type )
                newBindings =
                    List.map (\f -> ( f, getFieldType f tipe )) fields

                toDestruct : Name -> TOpt.Destructor
                toDestruct name =
                    TOpt.Destructor name (TOpt.Field name path) (getFieldType name tipe)
            in
            Names.registerFieldList fields ( List.map toDestruct fields ++ revDs, newBindings ++ bindings )

        Can.PAlias subPattern name ->
            destructHelpCollectBindings (TOpt.Root name)
                tipe
                subPattern
                ( TOpt.Destructor name path tipe :: revDs, ( name, tipe ) :: bindings )

        Can.PUnit ->
            Names.pure ( revDs, bindings )

        Can.PTuple a b [] ->
            destructTwoCollectBindings path tipe a b ( revDs, bindings )

        Can.PTuple a b [ c ] ->
            let
                ( aType, bType, cType ) =
                    case tipe of
                        Can.TTuple t1 t2 [ t3 ] ->
                            ( t1, t2, t3 )

                        Can.TVar _ ->
                            -- For type variables, infer tuple element types from patterns
                            ( getPatternType Dict.empty a
                            , getPatternType Dict.empty b
                            , getPatternType Dict.empty c
                            )

                        _ ->
                            crash "Type mismatch in 3-tuple pattern"
            in
            case path of
                TOpt.Root _ ->
                    destructHelpCollectBindings (TOpt.Index Index.first path) aType a ( revDs, bindings )
                        |> Names.andThen (destructHelpCollectBindings (TOpt.Index Index.second path) bType b)
                        |> Names.andThen (destructHelpCollectBindings (TOpt.Index Index.third path) cType c)

                _ ->
                    Names.generate
                        |> Names.andThen
                            (\name ->
                                let
                                    newRoot : TOpt.Path
                                    newRoot =
                                        TOpt.Root name
                                in
                                destructHelpCollectBindings (TOpt.Index Index.first newRoot)
                                    aType
                                    a
                                    ( TOpt.Destructor name path tipe :: revDs, ( name, tipe ) :: bindings )
                                    |> Names.andThen (destructHelpCollectBindings (TOpt.Index Index.second newRoot) bType b)
                                    |> Names.andThen (destructHelpCollectBindings (TOpt.Index Index.third newRoot) cType c)
                            )

        Can.PTuple a b cs ->
            let
                ( aType, bType, csTypes ) =
                    case tipe of
                        Can.TTuple t1 t2 ts ->
                            ( t1, t2, ts )

                        Can.TVar _ ->
                            -- For type variables, infer tuple element types from patterns
                            ( getPatternType Dict.empty a
                            , getPatternType Dict.empty b
                            , List.map (getPatternType Dict.empty) cs
                            )

                        _ ->
                            crash "Type mismatch in tuple pattern"
            in
            case path of
                TOpt.Root _ ->
                    List.foldl
                        (\( index, ( arg, argType ) ) accTracker ->
                            accTracker
                                |> Names.andThen (destructHelpCollectBindings (TOpt.ArrayIndex index (TOpt.Field "cs" path)) argType arg)
                        )
                        (destructHelpCollectBindings (TOpt.Index Index.first path) aType a ( revDs, bindings )
                            |> Names.andThen (destructHelpCollectBindings (TOpt.Index Index.second path) bType b)
                        )
                        (List.map2 Tuple.pair (List.range 0 (List.length cs - 1)) (List.map2 Tuple.pair cs csTypes))

                _ ->
                    Names.generate
                        |> Names.andThen
                            (\name ->
                                let
                                    newRoot : TOpt.Path
                                    newRoot =
                                        TOpt.Root name
                                in
                                List.foldl
                                    (\( index, ( arg, argType ) ) accTracker ->
                                        accTracker
                                            |> Names.andThen (destructHelpCollectBindings (TOpt.ArrayIndex index (TOpt.Field "cs" newRoot)) argType arg)
                                    )
                                    (destructHelpCollectBindings (TOpt.Index Index.first newRoot)
                                        aType
                                        a
                                        ( TOpt.Destructor name path tipe :: revDs, ( name, tipe ) :: bindings )
                                        |> Names.andThen (destructHelpCollectBindings (TOpt.Index Index.second newRoot) bType b)
                                    )
                                    (List.map2 Tuple.pair (List.range 0 (List.length cs - 1)) (List.map2 Tuple.pair cs csTypes))
                            )

        Can.PList [] ->
            Names.pure ( revDs, bindings )

        Can.PList (hd :: tl) ->
            destructTwoCollectBindings path tipe hd (A.At (A.Region (A.Position 0 0) (A.Position 0 0)) (Can.PList tl)) ( revDs, bindings )

        Can.PCons hd tl ->
            destructTwoCollectBindings path tipe hd tl ( revDs, bindings )

        Can.PChr _ ->
            Names.pure ( revDs, bindings )

        Can.PStr _ _ ->
            Names.pure ( revDs, bindings )

        Can.PInt _ ->
            Names.pure ( revDs, bindings )

        Can.PBool _ _ ->
            Names.pure ( revDs, bindings )

        Can.PCtor { union, args } ->
            case args of
                [ Can.PatternCtorArg _ argType arg ] ->
                    let
                        (Can.Union unionData) =
                            union
                    in
                    case unionData.opts of
                        Can.Normal ->
                            destructHelpCollectBindings (TOpt.Index Index.first path) argType arg ( revDs, bindings )

                        Can.Unbox ->
                            destructHelpCollectBindings (TOpt.Unbox path) argType arg ( revDs, bindings )

                        Can.Enum ->
                            destructHelpCollectBindings (TOpt.Index Index.first path) argType arg ( revDs, bindings )

                _ ->
                    case path of
                        TOpt.Root _ ->
                            List.foldl
                                (\arg accTracker ->
                                    accTracker |> Names.andThen (destructCtorArgCollectBindings path arg)
                                )
                                (Names.pure ( revDs, bindings ))
                                args

                        _ ->
                            Names.generate
                                |> Names.andThen
                                    (\name ->
                                        List.foldl
                                            (\arg accTracker ->
                                                accTracker |> Names.andThen (destructCtorArgCollectBindings (TOpt.Root name) arg)
                                            )
                                            (Names.pure ( TOpt.Destructor name path tipe :: revDs, ( name, tipe ) :: bindings ))
                                            args
                                    )


{-| Destructure a 2-element pattern (tuple or list cons) while collecting bindings.
-}
destructTwoCollectBindings : TOpt.Path -> Can.Type -> Can.Pattern -> Can.Pattern -> ( List TOpt.Destructor, List ( Name, Can.Type ) ) -> Names.Tracker ( List TOpt.Destructor, List ( Name, Can.Type ) )
destructTwoCollectBindings path tipe a b ( revDs, bindings ) =
    let
        ( aType, bType ) =
            case tipe of
                Can.TTuple t1 t2 [] ->
                    ( t1, t2 )

                Can.TType _ "List" [ elemType ] ->
                    ( elemType, tipe )

                Can.TAlias _ _ _ aliasType ->
                    -- Unwrap type aliases
                    let
                        realType : Can.Type
                        realType =
                            case aliasType of
                                Can.Holey t ->
                                    t

                                Can.Filled t ->
                                    t
                    in
                    case realType of
                        Can.TTuple t1 t2 [] ->
                            ( t1, t2 )

                        Can.TType _ "List" [ elemType ] ->
                            ( elemType, realType )

                        _ ->
                            -- For other aliased types, just use the original type as fallback
                            ( realType, realType )

                Can.TVar _ ->
                    -- For type variables, infer tuple element types from patterns
                    ( getPatternType Dict.empty a, getPatternType Dict.empty b )

                _ ->
                    crash "Type mismatch in destructTwoCollectBindings pattern: expected tuple or list."
    in
    case path of
        TOpt.Root _ ->
            destructHelpCollectBindings (TOpt.Index Index.first path) aType a ( revDs, bindings )
                |> Names.andThen (destructHelpCollectBindings (TOpt.Index Index.second path) bType b)

        _ ->
            Names.generate
                |> Names.andThen
                    (\name ->
                        let
                            newRoot : TOpt.Path
                            newRoot =
                                TOpt.Root name
                        in
                        destructHelpCollectBindings (TOpt.Index Index.first newRoot)
                            aType
                            a
                            ( TOpt.Destructor name path tipe :: revDs, ( name, tipe ) :: bindings )
                            |> Names.andThen (destructHelpCollectBindings (TOpt.Index Index.second newRoot) bType b)
                    )


{-| Destructure a constructor argument while collecting bindings.
-}
destructCtorArgCollectBindings : TOpt.Path -> Can.PatternCtorArg -> ( List TOpt.Destructor, List ( Name, Can.Type ) ) -> Names.Tracker ( List TOpt.Destructor, List ( Name, Can.Type ) )
destructCtorArgCollectBindings path (Can.PatternCtorArg index argType arg) ( revDs, bindings ) =
    destructHelpCollectBindings (TOpt.Index index path) argType arg ( revDs, bindings )



-- TAIL CALL


{-| Optimize a canonical expression, detecting and converting tail calls.
Analyzes the expression for recursive calls in tail position and converts them to optimized
TailCall nodes. Returns a typed optimized expression with preserved type information.

The defType parameter is the function type (supplied by caller), used to compute returnType.
This avoids calling lookupAnnotationType, which only works for top-level definitions.

-}
optimizePotentialTailCall : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> A.Region -> Name -> Can.Type -> List Can.Pattern -> Can.Expr -> Names.Tracker TOpt.Def
optimizePotentialTailCall kernelEnv cycle annotations region name defType args expr =
    destructArgs annotations args
        |> Names.andThen
            (\( typedArgNames, destructors, bindings ) ->
                let
                    argTypes : List ( Name, Can.Type )
                    argTypes =
                        List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                    -- Include the recursive function's own name so non-tail self-calls can find it
                    allBindings : List ( Name, Can.Type )
                    allBindings =
                        ( name, defType ) :: argTypes ++ bindings

                    returnType : Can.Type
                    returnType =
                        getCallResultType defType (List.length args)
                in
                Names.withVarTypes allBindings
                    (optimizeTail kernelEnv cycle annotations name typedArgNames returnType expr)
                    |> Names.map (toTailDef region name typedArgNames destructors returnType)
            )


{-| Optimize a recursive definition, detecting and preserving tail calls.
Converts self-recursive calls in tail position to TailCall expressions for optimization.

Uses synthesizeRecDefType to create a schematic type for untyped defs, avoiding
lookupAnnotationType which only works for top-level definitions.

-}
optimizePotentialTailCallDef : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> Can.Def -> Names.Tracker TOpt.Def
optimizePotentialTailCallDef kernelEnv cycle annotations def =
    case def of
        Can.Def (A.At region name) args expr ->
            let
                -- Synthesize a schematic type for untyped defs
                defType : Can.Type
                defType =
                    synthesizeRecDefType def
            in
            optimizePotentialTailCall kernelEnv cycle annotations region name defType args expr

        Can.TypedDef (A.At region name) _ typedArgs expr resultType ->
            optimizeTypedPotentialTailCall kernelEnv cycle annotations region name typedArgs expr resultType


optimizeTypedPotentialTailCall : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> A.Region -> Name -> List ( Can.Pattern, Can.Type ) -> Can.Expr -> Can.Type -> Names.Tracker TOpt.Def
optimizeTypedPotentialTailCall kernelEnv cycle annotations region name typedArgs expr resultType =
    destructTypedArgs typedArgs
        |> Names.andThen
            (\( typedArgNames, destructors, bindings ) ->
                let
                    argTypes : List ( Name, Can.Type )
                    argTypes =
                        List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                    -- Compute the function type from typed args and result type
                    defType : Can.Type
                    defType =
                        buildFunctionType (List.map Tuple.second typedArgNames) resultType

                    -- Include the recursive function's own name so non-tail self-calls can find it
                    allBindings : List ( Name, Can.Type )
                    allBindings =
                        ( name, defType ) :: argTypes ++ bindings
                in
                Names.withVarTypes allBindings
                    (optimizeTail kernelEnv cycle annotations name typedArgNames resultType expr)
                    |> Names.map (toTailDef region name typedArgNames destructors resultType)
            )


optimizeTail : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> Name -> List ( A.Located Name, Can.Type ) -> Can.Type -> Can.Expr -> Names.Tracker TOpt.Expr
optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType ((A.At region expression) as locExpr) =
    case expression of
        Can.Call func args ->
            Names.traverse (optimize kernelEnv cycle annotations) args
                |> Names.andThen
                    (\oargs ->
                        let
                            isMatchingName : Bool
                            isMatchingName =
                                case A.toValue func of
                                    Can.VarLocal n ->
                                        rootName == n

                                    Can.VarTopLevel _ n ->
                                        rootName == n

                                    _ ->
                                        False
                        in
                        if isMatchingName then
                            case Index.indexedZipWith (\_ ( a, _ ) b -> ( A.toValue a, b )) typedArgNames oargs of
                                Index.LengthMatch pairs ->
                                    Names.pure (TOpt.TailCall rootName pairs returnType)

                                Index.LengthMismatch _ _ ->
                                    optimize kernelEnv cycle annotations func
                                        |> Names.map
                                            (\ofunc ->
                                                let
                                                    funcType : Can.Type
                                                    funcType =
                                                        TOpt.typeOf ofunc

                                                    resultType : Can.Type
                                                    resultType =
                                                        getCallResultType funcType (List.length oargs)
                                                in
                                                TOpt.Call region ofunc oargs resultType
                                            )

                        else
                            optimize kernelEnv cycle annotations func
                                |> Names.map
                                    (\ofunc ->
                                        let
                                            funcType : Can.Type
                                            funcType =
                                                TOpt.typeOf ofunc

                                            resultType : Can.Type
                                            resultType =
                                                getCallResultType funcType (List.length oargs)
                                        in
                                        TOpt.Call region ofunc oargs resultType
                                    )
                    )

        Can.If branches finally ->
            let
                optimizeBranch : ( Can.Expr, Can.Expr ) -> Names.Tracker ( TOpt.Expr, TOpt.Expr )
                optimizeBranch ( condition, branch ) =
                    optimize kernelEnv cycle annotations condition
                        |> Names.andThen
                            (\optimizeCondition ->
                                optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType branch
                                    |> Names.map (Tuple.pair optimizeCondition)
                            )
            in
            Names.traverse optimizeBranch branches
                |> Names.andThen
                    (\obranches ->
                        optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType finally
                            |> Names.map
                                (\ofinally ->
                                    let
                                        resultType : Can.Type
                                        resultType =
                                            TOpt.typeOf ofinally
                                    in
                                    TOpt.If obranches ofinally resultType
                                )
                    )

        Can.Let def body ->
            case def of
                Can.Def (A.At defRegion defName) defArgs defExpr ->
                    optimizeDefForTail kernelEnv cycle annotations defRegion defName defArgs defExpr
                        |> Names.andThen
                            (\odef ->
                                let
                                    -- Extract type from the optimized def
                                    defType : Can.Type
                                    defType =
                                        case odef of
                                            TOpt.Def _ _ _ t ->
                                                t

                                            TOpt.TailDef _ _ _ _ t ->
                                                t
                                in
                                Names.withVarType defName
                                    defType
                                    (optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType body)
                                    |> Names.map
                                        (\obody ->
                                            let
                                                bodyType : Can.Type
                                                bodyType =
                                                    TOpt.typeOf obody
                                            in
                                            TOpt.Let odef obody bodyType
                                        )
                            )

                Can.TypedDef (A.At defRegion defName) _ defTypedArgs defExpr defResultType ->
                    optimizeTypedDefForTail kernelEnv cycle annotations defRegion defName defTypedArgs defExpr defResultType
                        |> Names.andThen
                            (\odef ->
                                let
                                    -- Extract type from the optimized def
                                    defType : Can.Type
                                    defType =
                                        case odef of
                                            TOpt.Def _ _ _ t ->
                                                t

                                            TOpt.TailDef _ _ _ _ t ->
                                                t
                                in
                                Names.withVarType defName
                                    defType
                                    (optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType body)
                                    |> Names.map
                                        (\obody ->
                                            let
                                                bodyType : Can.Type
                                                bodyType =
                                                    TOpt.typeOf obody
                                            in
                                            TOpt.Let odef obody bodyType
                                        )
                            )

        Can.LetRec defs body ->
            case defs of
                [ def ] ->
                    optimizePotentialTailCallDef kernelEnv cycle annotations def
                        |> Names.andThen
                            (\odef ->
                                let
                                    -- Extract name and type from the optimized def
                                    ( defName, defType ) =
                                        case odef of
                                            TOpt.Def _ name _ t ->
                                                ( name, t )

                                            TOpt.TailDef _ name _ _ t ->
                                                ( name, t )
                                in
                                Names.withVarType defName
                                    defType
                                    (optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType body)
                                    |> Names.map
                                        (\obody ->
                                            let
                                                bodyType : Can.Type
                                                bodyType =
                                                    TOpt.typeOf obody
                                            in
                                            TOpt.Let odef obody bodyType
                                        )
                            )

                _ ->
                    -- Multiple recursive defs - fall back to regular optimization
                    optimizeLetRecDefs kernelEnv cycle annotations defs body

        Can.LetDestruct pattern expr body ->
            -- First optimize the expression to get its type
            optimize kernelEnv cycle annotations expr
                |> Names.andThen
                    (\oexpr ->
                        let
                            exprType : Can.Type
                            exprType =
                                TOpt.typeOf oexpr
                        in
                        -- Now destruct with the known expression type and collect bindings
                        destructWithKnownTypeAndBindings exprType pattern
                            |> Names.andThen
                                (\( A.At dregion dname, destructors, bindings ) ->
                                    let
                                        -- Include root name and all nested bindings
                                        allBindings : List ( Name, Can.Type )
                                        allBindings =
                                            ( dname, exprType ) :: bindings
                                    in
                                    Names.withVarTypes allBindings
                                        (optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType body)
                                        |> Names.map
                                            (\obody ->
                                                let
                                                    bodyType : Can.Type
                                                    bodyType =
                                                        TOpt.typeOf obody
                                                in
                                                TOpt.Let (TOpt.Def dregion dname oexpr exprType)
                                                    (List.foldr (wrapDestruct bodyType) obody destructors)
                                                    bodyType
                                            )
                                )
                    )

        Can.Case expr branches ->
            Names.generate
                |> Names.andThen
                    (\temp ->
                        optimize kernelEnv cycle annotations expr
                            |> Names.andThen
                                (\oexpr ->
                                    let
                                        exprType : Can.Type
                                        exprType =
                                            TOpt.typeOf oexpr

                                        optimizeBranch : Name -> Can.CaseBranch -> Names.Tracker ( Can.Pattern, TOpt.Expr )
                                        optimizeBranch root (Can.CaseBranch pattern branch) =
                                            destructCaseWithType exprType root pattern
                                                |> Names.andThen
                                                    (\( destructors, patternBindings ) ->
                                                        Names.withVarTypes patternBindings
                                                            (optimizeTail kernelEnv cycle annotations rootName typedArgNames returnType branch)
                                                            |> Names.map
                                                                (\obranch ->
                                                                    let
                                                                        branchType : Can.Type
                                                                        branchType =
                                                                            TOpt.typeOf obranch
                                                                    in
                                                                    ( pattern, List.foldr (wrapDestruct branchType) obranch destructors )
                                                                )
                                                    )
                                    in
                                    case oexpr of
                                        TOpt.VarLocal root tipe ->
                                            Names.withVarType root
                                                tipe
                                                (Names.traverse (optimizeBranch root) branches)
                                                |> Names.map (Case.optimize temp root)

                                        TOpt.TrackedVarLocal _ root tipe ->
                                            Names.withVarType root
                                                tipe
                                                (Names.traverse (optimizeBranch root) branches)
                                                |> Names.map (Case.optimize temp root)

                                        _ ->
                                            Names.withVarType temp
                                                exprType
                                                (Names.traverse (optimizeBranch temp) branches)
                                                |> Names.map
                                                    (\obranches ->
                                                        let
                                                            caseExpr : TOpt.Expr
                                                            caseExpr =
                                                                Case.optimize temp temp obranches

                                                            caseType : Can.Type
                                                            caseType =
                                                                TOpt.typeOf caseExpr
                                                        in
                                                        TOpt.Let (TOpt.Def region temp oexpr exprType) caseExpr caseType
                                                    )
                                )
                    )

        _ ->
            optimize kernelEnv cycle annotations locExpr


{-| Optimize a local definition for tail call context.
Infers the type from the optimized RHS - does not use module annotations.
-}
optimizeDefForTail : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> A.Region -> Name -> List Can.Pattern -> Can.Expr -> Names.Tracker TOpt.Def
optimizeDefForTail kernelEnv cycle annotations region name args expr =
    case args of
        [] ->
            -- Simple value binding: infer its type from the RHS
            optimize kernelEnv cycle annotations expr
                |> Names.map
                    (\oexpr ->
                        let
                            exprType : Can.Type
                            exprType =
                                TOpt.typeOf oexpr
                        in
                        TOpt.Def region name oexpr exprType
                    )

        _ ->
            -- Function binding: infer arg and return types from patterns + RHS
            destructArgs annotations args
                |> Names.andThen
                    (\( typedArgNames, destructors, bindings ) ->
                        let
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                            allBindings : List ( Name, Can.Type )
                            allBindings =
                                argTypes ++ bindings
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv cycle annotations expr)
                            |> Names.map
                                (\oexpr ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf oexpr

                                        funcType : Can.Type
                                        funcType =
                                            buildFunctionType (List.map Tuple.second typedArgNames) bodyType

                                        ofunc : TOpt.Expr
                                        ofunc =
                                            TOpt.TrackedFunction typedArgNames
                                                (List.foldr (wrapDestruct bodyType) oexpr destructors)
                                                funcType
                                    in
                                    TOpt.Def region name ofunc funcType
                                )
                    )


optimizeTypedDefForTail : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> A.Region -> Name -> List ( Can.Pattern, Can.Type ) -> Can.Expr -> Can.Type -> Names.Tracker TOpt.Def
optimizeTypedDefForTail kernelEnv cycle annotations region name typedArgs expr resultType =
    case typedArgs of
        [] ->
            optimize kernelEnv cycle annotations expr
                |> Names.map (\oexpr -> TOpt.Def region name oexpr resultType)

        _ ->
            destructTypedArgs typedArgs
                |> Names.andThen
                    (\( typedArgNames, destructors, bindings ) ->
                        let
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                            allBindings : List ( Name, Can.Type )
                            allBindings =
                                argTypes ++ bindings

                            funcType : Can.Type
                            funcType =
                                buildFunctionType (List.map Tuple.second typedArgNames) resultType
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv cycle annotations expr)
                            |> Names.map
                                (\oexpr ->
                                    let
                                        ofunc : TOpt.Expr
                                        ofunc =
                                            TOpt.TrackedFunction typedArgNames
                                                (List.foldr (wrapDestruct resultType) oexpr destructors)
                                                funcType
                                    in
                                    TOpt.Def region name ofunc funcType
                                )
                    )



-- DETECT TAIL CALLS


toTailDef : A.Region -> Name -> List ( A.Located Name, Can.Type ) -> List TOpt.Destructor -> Can.Type -> TOpt.Expr -> TOpt.Def
toTailDef region name typedArgNames destructors returnType body =
    if hasTailCall body then
        TOpt.TailDef region name typedArgNames (List.foldr (wrapDestruct returnType) body destructors) returnType

    else
        let
            funcType : Can.Type
            funcType =
                buildFunctionType (List.map Tuple.second typedArgNames) returnType
        in
        TOpt.Def region name (TOpt.TrackedFunction typedArgNames (List.foldr (wrapDestruct returnType) body destructors) funcType) funcType


hasTailCall : TOpt.Expr -> Bool
hasTailCall expression =
    case expression of
        TOpt.TailCall _ _ _ ->
            True

        TOpt.If branches finally _ ->
            hasTailCall finally || List.any (Tuple.second >> hasTailCall) branches

        TOpt.Let _ body _ ->
            hasTailCall body

        TOpt.Destruct _ body _ ->
            hasTailCall body

        TOpt.Case _ _ decider jumps _ ->
            deciderHasTailCall decider || List.any (Tuple.second >> hasTailCall) jumps

        _ ->
            False


deciderHasTailCall : TOpt.Decider TOpt.Choice -> Bool
deciderHasTailCall decider =
    case decider of
        TOpt.Leaf choice ->
            case choice of
                TOpt.Inline expr ->
                    hasTailCall expr

                TOpt.Jump _ ->
                    False

        TOpt.Chain _ success failure ->
            deciderHasTailCall success || deciderHasTailCall failure

        TOpt.FanOut _ tests fallback ->
            deciderHasTailCall fallback || List.any (Tuple.second >> deciderHasTailCall) tests
