module Compiler.Optimize.Typed.Expression exposing
    ( Cycle
    , optimize
    , destructArgs
    , Annotations, optimizePotentialTailCall
    )

{-| Optimizes TypedCanonical expressions into TypedOptimized expressions.

This module transforms TypedCanonical AST (where every expression has its type)
into TypedOptimized representation suitable for code generation. Each TOpt.Expr
carries its canonical type.

@docs Cycle, Annotations
@docs optimize, optimizePotentialTailCall
@docs destructArgs

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedCanonical as TCan exposing (ExprTypes)
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
import Utils.Crash as Crash
import Utils.Main as Utils



-- TYPES


{-| Set of names that participate in a recursive definition cycle.
-}
type alias Cycle =
    EverySet String Name.Name


{-| Dictionary mapping variable names to their type annotations.

Used to look up types during optimization for kernel function typing
and other type-directed optimizations.

-}
type alias Annotations =
    Dict String Name Can.Annotation



-- OPTIMIZE


{-| Transforms a TypedCanonical expression into a TypedOptimized expression.

Takes the kernel type environment, annotations, expression types map, cycle names,
and a typed expression. The type of the expression is taken from the TypedCanonical node.

The `exprTypes` parameter is needed to convert subexpressions (which are still
`Can.Expr`) back to `TCan.Expr` when recursing.

-}
optimize : KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes -> Cycle -> TCan.Expr -> Names.Tracker TOpt.Expr
optimize kernelEnv annotations exprTypes cycle (A.At region texpr) =
    case texpr of
        TCan.TypedExpr { expr, tipe } ->
            optimizeExpr kernelEnv annotations exprTypes cycle region tipe expr


optimizeExpr : KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes -> Cycle -> A.Region -> Can.Type -> Can.Expr_ -> Names.Tracker TOpt.Expr
optimizeExpr kernelEnv annotations exprTypes cycle region tipe expr =
    case expr of
        Can.VarLocal name ->
            Names.lookupLocalType name
                |> Names.map (\localType -> TOpt.TrackedVarLocal region name localType)
                |> catchMissing (Names.pure (TOpt.TrackedVarLocal region name tipe))

        Can.VarTopLevel home name ->
            let
                defType =
                    lookupAnnotationType name annotations
            in
            if EverySet.member identity name cycle then
                Names.pure (TOpt.VarCycle region home name defType)

            else
                Names.registerGlobal region home name defType

        Can.VarKernel home name ->
            let
                kernelType : Can.Type
                kernelType =
                    case KernelTypes.lookup home name kernelEnv of
                        Just t ->
                            t

                        Nothing ->
                            Crash.crash "Typed.Expression.optimizeExpr"
                                ("Missing kernel type for " ++ home ++ "." ++ name)
            in
            Names.registerKernel home (TOpt.VarKernel region home name kernelType)

        Can.VarForeign home name _ ->
            let
                foreignType =
                    tipe
            in
            Names.registerGlobal region home name foreignType

        Can.VarCtor opts home name index _ ->
            Names.registerCtor region home (A.At region name) index opts tipe

        Can.VarDebug home name _ ->
            Names.registerDebug name home region tipe

        Can.VarOperator _ home name (Can.Forall _ funcType) ->
            Names.registerGlobal region home name funcType

        Can.Chr chr ->
            Names.registerKernel Name.utils (TOpt.Chr region chr (Can.TType ModuleName.basics "Char" []))

        Can.Str str ->
            Names.pure (TOpt.Str region str (Can.TType ModuleName.basics "String" []))

        Can.Int int ->
            Names.pure (TOpt.Int region int (Can.TType ModuleName.basics "Int" []))

        Can.Float float ->
            Names.pure (TOpt.Float region float (Can.TType ModuleName.basics "Float" []))

        Can.List entries ->
            Names.traverse (optimize kernelEnv annotations exprTypes cycle << TCan.toTypedExpr exprTypes) entries
                |> Names.andThen (\optEntries -> Names.registerKernel Name.list (TOpt.List region optEntries tipe))

        Can.Negate subExpr ->
            let
                numberType =
                    tipe
            in
            Names.registerGlobal region ModuleName.basics Name.negate (Can.TLambda numberType numberType)
                |> Names.andThen
                    (\func ->
                        optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes subExpr)
                            |> Names.map (\optSub -> TOpt.Call region func [ optSub ] tipe)
                    )

        -- Binop: use the annotation from the constructor
        Can.Binop _ home name (Can.Forall _ funcType) left right ->
            let
                optimizeArg =
                    optimize kernelEnv annotations exprTypes cycle << TCan.toTypedExpr exprTypes
            in
            Names.registerGlobal region home name funcType
                |> Names.andThen
                    (\optFunc ->
                        optimizeArg left
                            |> Names.andThen
                                (\optLeft ->
                                    optimizeArg right
                                        |> Names.map
                                            (\optRight ->
                                                TOpt.Call region optFunc [ optLeft, optRight ] tipe
                                            )
                                )
                    )

        Can.Lambda args body ->
            destructArgs annotations args
                |> Names.andThen
                    (\( argNamesWithTypes, destructors ) ->
                        let
                            -- Root argument bindings (e.g., "_v0" for a tuple pattern)
                            argBindings =
                                List.map (\( A.At _ n, t ) -> ( n, t )) argNamesWithTypes

                            -- Extract bindings from destructors (e.g., "a", "b" from tuple (a, b))
                            destructorBindings =
                                List.map (\(TOpt.Destructor n _ t) -> ( n, t )) destructors

                            -- Combine all bindings so pattern variables are in scope
                            allBindings =
                                argBindings ++ destructorBindings

                            -- Compute body type by peeling off arg types from function type
                            bodyType =
                                peelFunctionType (List.length args) tipe
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes body))
                            |> Names.map
                                (\obody ->
                                    let
                                        wrappedBody =
                                            List.foldr (wrapDestruct bodyType) obody destructors
                                    in
                                    TOpt.TrackedFunction argNamesWithTypes wrappedBody tipe
                                )
                    )

        Can.Call func args ->
            let
                optimizeArg =
                    optimize kernelEnv annotations exprTypes cycle << TCan.toTypedExpr exprTypes
            in
            optimizeArg func
                |> Names.andThen
                    (\optFunc ->
                        Names.traverse optimizeArg args
                            |> Names.map (\optArgs -> TOpt.Call region optFunc optArgs tipe)
                    )

        Can.If branches final ->
            let
                optimizeBranch : ( Can.Expr, Can.Expr ) -> Names.Tracker ( TOpt.Expr, TOpt.Expr )
                optimizeBranch ( condition, thenExpr ) =
                    let
                        optCond =
                            optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes condition)

                        optThen =
                            optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes thenExpr)
                    in
                    optCond
                        |> Names.andThen (\c -> optThen |> Names.map (\t -> ( c, t )))
            in
            Names.traverse optimizeBranch branches
                |> Names.andThen
                    (\optBranches ->
                        optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes final)
                            |> Names.map (\optFinal -> TOpt.If optBranches optFinal tipe)
                    )

        Can.Let def body ->
            -- Add the let-bound variable to scope BEFORE optimizing the body
            let
                ( defName, defType ) =
                    getDefNameAndType exprTypes def
            in
            Names.withVarTypes [ ( defName, defType ) ]
                (optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes body))
                |> Names.andThen (optimizeDef kernelEnv annotations exprTypes cycle def tipe)

        Can.LetRec defs body ->
            -- For LetRec, all definitions are mutually recursive, so add all names to scope
            let
                defBindings =
                    List.map (getDefNameAndType exprTypes) defs
            in
            case defs of
                [ def ] ->
                    Names.withVarTypes defBindings
                        (optimizePotentialTailCallDef kernelEnv annotations exprTypes cycle def)
                        |> Names.andThen
                            (\tailCallDef ->
                                Names.withVarTypes defBindings
                                    (optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes body))
                                    |> Names.map (\obody -> TOpt.Let tailCallDef obody tipe)
                            )

                _ ->
                    Names.withVarTypes defBindings
                        (List.foldl
                            (\def bod ->
                                Names.andThen (optimizeDef kernelEnv annotations exprTypes cycle def tipe) bod
                            )
                            (optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes body))
                            defs
                        )

        Can.LetDestruct pattern boundExpr body ->
            destruct annotations pattern
                |> Names.andThen
                    (\( ( A.At nameRegion name, patternType ), destructs ) ->
                        optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes boundExpr)
                            |> Names.andThen
                                (\oBoundExpr ->
                                    let
                                        -- Add pattern bindings to scope
                                        destructorBindings =
                                            List.map (\(TOpt.Destructor n _ t) -> ( n, t )) destructs

                                        allBindings =
                                            ( name, patternType ) :: destructorBindings
                                    in
                                    Names.withVarTypes allBindings
                                        (optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes body))
                                        |> Names.map
                                            (\obody ->
                                                let
                                                    boundExprType =
                                                        TOpt.typeOf oBoundExpr
                                                in
                                                TOpt.Let
                                                    (TOpt.Def nameRegion name oBoundExpr boundExprType)
                                                    (List.foldr (wrapDestruct tipe) obody destructs)
                                                    tipe
                                            )
                                )
                    )

        Can.Case scrutinee branches ->
            let
                optimizeBranch : Name -> Can.CaseBranch -> Names.Tracker ( Can.Pattern, TOpt.Expr )
                optimizeBranch root (Can.CaseBranch pattern branch) =
                    destructCase root pattern
                        |> Names.andThen
                            (\destructors ->
                                let
                                    -- Extract bindings from destructors for scope
                                    destructorBindings =
                                        List.map (\(TOpt.Destructor n _ t) -> ( n, t )) destructors
                                in
                                Names.withVarTypes destructorBindings
                                    (optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes branch))
                                    |> Names.map
                                        (\obranch ->
                                            ( pattern, List.foldr (wrapDestruct tipe) obranch destructors )
                                        )
                            )
            in
            Names.generate
                |> Names.andThen
                    (\temp ->
                        optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes scrutinee)
                            |> Names.andThen
                                (\optScrutinee ->
                                    case optScrutinee of
                                        TOpt.VarLocal root _ ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (\optBranches -> Case.optimize temp root optBranches tipe)

                                        TOpt.TrackedVarLocal _ root _ ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (\optBranches -> Case.optimize temp root optBranches tipe)

                                        _ ->
                                            Names.traverse (optimizeBranch temp) branches
                                                |> Names.map
                                                    (\optBranches ->
                                                        let
                                                            scrutineeType =
                                                                TOpt.typeOf optScrutinee
                                                        in
                                                        TOpt.Let
                                                            (TOpt.Def region temp optScrutinee scrutineeType)
                                                            (Case.optimize temp temp optBranches tipe)
                                                            tipe
                                                    )
                                )
                    )

        Can.Accessor field ->
            Names.registerField field (TOpt.Accessor region field tipe)

        Can.Access recordExpr (A.At _ field) ->
            optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes recordExpr)
                |> Names.andThen
                    (\optRecord ->
                        Names.registerField field (TOpt.Access optRecord region field tipe)
                    )

        Can.Update recordExpr fieldUpdates ->
            let
                optimizeFieldUpdate : ( A.Located Name, Can.FieldUpdate ) -> Names.Tracker ( A.Located Name, TOpt.Expr )
                optimizeFieldUpdate ( locName, Can.FieldUpdate _ fieldExpr ) =
                    optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes fieldExpr)
                        |> Names.map (\optExpr -> ( locName, optExpr ))

                fieldUpdateList =
                    Dict.toList A.compareLocated fieldUpdates
            in
            optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes recordExpr)
                |> Names.andThen
                    (\optRecord ->
                        Names.traverse optimizeFieldUpdate fieldUpdateList
                            |> Names.andThen
                                (\optUpdates ->
                                    let
                                        optUpdatesDict =
                                            Dict.fromList A.toValue optUpdates
                                    in
                                    Names.registerFieldDict (Utils.mapMapKeys identity A.compareLocated A.toValue fieldUpdates)
                                        (TOpt.Update region optRecord optUpdatesDict tipe)
                                )
                    )

        Can.Record fields ->
            let
                optimizeField : ( A.Located Name, Can.Expr ) -> Names.Tracker ( A.Located Name, TOpt.Expr )
                optimizeField ( locName, fieldExpr ) =
                    optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes fieldExpr)
                        |> Names.map (\optExpr -> ( locName, optExpr ))

                fieldList : List ( A.Located Name, Can.Expr )
                fieldList =
                    Dict.toList A.compareLocated fields
            in
            Names.traverse optimizeField fieldList
                |> Names.andThen
                    (\optFields ->
                        let
                            optFieldsDict =
                                Dict.fromList A.toValue optFields
                        in
                        Names.registerFieldDict (Utils.mapMapKeys identity A.compareLocated A.toValue fields) (TOpt.TrackedRecord region optFieldsDict tipe)
                    )

        Can.Unit ->
            Names.registerKernel Name.utils (TOpt.Unit Can.TUnit)

        Can.Tuple a b cs ->
            let
                optimizeArg =
                    optimize kernelEnv annotations exprTypes cycle << TCan.toTypedExpr exprTypes
            in
            optimizeArg a
                |> Names.andThen
                    (\optA ->
                        optimizeArg b
                            |> Names.andThen
                                (\optB ->
                                    Names.traverse optimizeArg cs
                                        |> Names.andThen
                                            (\optCs ->
                                                Names.registerKernel Name.utils (TOpt.Tuple region optA optB optCs tipe)
                                            )
                                )
                    )

        Can.Shader src (Shader.Types attributes uniforms _) ->
            Names.pure (TOpt.Shader src (EverySet.fromList identity (Dict.keys compare attributes)) (EverySet.fromList identity (Dict.keys compare uniforms)) tipe)


{-| Catch a missing local type error and use a fallback.
-}
catchMissing : Names.Tracker a -> Names.Tracker a -> Names.Tracker a
catchMissing fallback tracker =
    -- In a proper implementation, we'd catch the error
    -- For now, just use the tracker
    tracker


{-| Look up the type of a top-level definition from annotations.
-}
lookupAnnotationType : Name -> Annotations -> Can.Type
lookupAnnotationType name annotations =
    case Dict.get identity name annotations of
        Just (Can.Forall _ tipe) ->
            tipe

        Nothing ->
            Can.TVar "?"



-- TAIL CALL OPTIMIZATION


{-| Optimize an expression in tail position.
This function detects tail calls to the function being defined and converts them
to TailCall nodes for efficient tail call elimination.
-}
optimizeTail :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> Cycle
    -> Name
    -> List ( A.Located Name, Can.Type )
    -> Can.Type
    -> TCan.Expr
    -> Names.Tracker TOpt.Expr
optimizeTail kernelEnv annotations exprTypes cycle rootName argNames resultType (A.At region texpr) =
    case texpr of
        TCan.TypedExpr { expr, tipe } ->
            optimizeTailExpr kernelEnv annotations exprTypes cycle rootName argNames resultType region tipe expr


optimizeTailExpr :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> Cycle
    -> Name
    -> List ( A.Located Name, Can.Type )
    -> Can.Type
    -> A.Region
    -> Can.Type
    -> Can.Expr_
    -> Names.Tracker TOpt.Expr
optimizeTailExpr kernelEnv annotations exprTypes cycle rootName argNames resultType region tipe expr =
    case expr of
        Can.Call func callArgs ->
            let
                optimizeArg =
                    optimize kernelEnv annotations exprTypes cycle << TCan.toTypedExpr exprTypes
            in
            Names.traverse optimizeArg callArgs
                |> Names.andThen
                    (\oargs ->
                        let
                            isMatchingName =
                                case (A.toValue func).node of
                                    Can.VarLocal n ->
                                        rootName == n

                                    Can.VarTopLevel _ n ->
                                        rootName == n

                                    _ ->
                                        False
                        in
                        if isMatchingName then
                            case Index.indexedZipWith (\_ ( locName, _ ) arg -> ( A.toValue locName, arg )) argNames oargs of
                                Index.LengthMatch pairs ->
                                    Names.pure (TOpt.TailCall rootName pairs resultType)

                                Index.LengthMismatch _ _ ->
                                    optimizeArg func
                                        |> Names.map (\ofunc -> TOpt.Call region ofunc oargs tipe)

                        else
                            optimizeArg func
                                |> Names.map (\ofunc -> TOpt.Call region ofunc oargs tipe)
                    )

        Can.If branches final ->
            let
                optimizeBranch ( condition, branch ) =
                    optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes condition)
                        |> Names.andThen
                            (\optCond ->
                                optimizeTail kernelEnv annotations exprTypes cycle rootName argNames resultType (TCan.toTypedExpr exprTypes branch)
                                    |> Names.map (\optBranch -> ( optCond, optBranch ))
                            )
            in
            Names.traverse optimizeBranch branches
                |> Names.andThen
                    (\optBranches ->
                        optimizeTail kernelEnv annotations exprTypes cycle rootName argNames resultType (TCan.toTypedExpr exprTypes final)
                            |> Names.map (\optFinal -> TOpt.If optBranches optFinal tipe)
                    )

        Can.Let def body ->
            optimizeTail kernelEnv annotations exprTypes cycle rootName argNames resultType (TCan.toTypedExpr exprTypes body)
                |> Names.andThen (optimizeDef kernelEnv annotations exprTypes cycle def tipe)

        Can.LetRec defs body ->
            case defs of
                [ def ] ->
                    optimizePotentialTailCallDef kernelEnv annotations exprTypes cycle def
                        |> Names.andThen
                            (\tailCallDef ->
                                optimizeTail kernelEnv annotations exprTypes cycle rootName argNames resultType (TCan.toTypedExpr exprTypes body)
                                    |> Names.map (\obody -> TOpt.Let tailCallDef obody tipe)
                            )

                _ ->
                    List.foldl
                        (\def bod ->
                            Names.andThen (optimizeDef kernelEnv annotations exprTypes cycle def tipe) bod
                        )
                        (optimizeTail kernelEnv annotations exprTypes cycle rootName argNames resultType (TCan.toTypedExpr exprTypes body))
                        defs

        Can.LetDestruct pattern boundExpr body ->
            destruct annotations pattern
                |> Names.andThen
                    (\( ( A.At nameRegion name, patternType ), destructs ) ->
                        optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes boundExpr)
                            |> Names.andThen
                                (\oBoundExpr ->
                                    let
                                        destructorBindings =
                                            List.map (\(TOpt.Destructor n _ t) -> ( n, t )) destructs

                                        allBindings =
                                            ( name, patternType ) :: destructorBindings
                                    in
                                    Names.withVarTypes allBindings
                                        (optimizeTail kernelEnv annotations exprTypes cycle rootName argNames resultType (TCan.toTypedExpr exprTypes body))
                                        |> Names.map
                                            (\obody ->
                                                let
                                                    boundExprType =
                                                        TOpt.typeOf oBoundExpr
                                                in
                                                TOpt.Let
                                                    (TOpt.Def nameRegion name oBoundExpr boundExprType)
                                                    (List.foldr (wrapDestruct tipe) obody destructs)
                                                    tipe
                                            )
                                )
                    )

        Can.Case scrutinee branches ->
            let
                optimizeBranch root (Can.CaseBranch pattern branch) =
                    destructCase root pattern
                        |> Names.andThen
                            (\destructors ->
                                let
                                    destructorBindings =
                                        List.map (\(TOpt.Destructor n _ t) -> ( n, t )) destructors
                                in
                                Names.withVarTypes destructorBindings
                                    (optimizeTail kernelEnv annotations exprTypes cycle rootName argNames resultType (TCan.toTypedExpr exprTypes branch))
                                    |> Names.map
                                        (\obranch ->
                                            ( pattern, List.foldr (wrapDestruct tipe) obranch destructors )
                                        )
                            )
            in
            Names.generate
                |> Names.andThen
                    (\temp ->
                        optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes scrutinee)
                            |> Names.andThen
                                (\optScrutinee ->
                                    case optScrutinee of
                                        TOpt.VarLocal root _ ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (\optBranches -> Case.optimize temp root optBranches tipe)

                                        TOpt.TrackedVarLocal _ root _ ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (\optBranches -> Case.optimize temp root optBranches tipe)

                                        _ ->
                                            Names.traverse (optimizeBranch temp) branches
                                                |> Names.map
                                                    (\optBranches ->
                                                        let
                                                            scrutineeType =
                                                                TOpt.typeOf optScrutinee
                                                        in
                                                        TOpt.Let
                                                            (TOpt.Def region temp optScrutinee scrutineeType)
                                                            (Case.optimize temp temp optBranches tipe)
                                                            tipe
                                                    )
                                )
                    )

        -- For other expressions, use regular optimization (not in tail position)
        _ ->
            optimizeExpr kernelEnv annotations exprTypes cycle region tipe expr



-- DEFINITIONS (inside let expressions)


{-| Extract the name and type of a definition for scope management.

For TypedDef, builds the function type from explicit arg types and result type.
For Def, looks up pattern and expression types from exprTypes.

-}
getDefNameAndType : ExprTypes -> Can.Def -> ( Name, Can.Type )
getDefNameAndType exprTypes def =
    case def of
        Can.Def (A.At _ name) args (A.At _ bodyInfo) ->
            let
                -- Get argument types by looking up each pattern's type
                argTypes =
                    List.map
                        (\(A.At _ patInfo) ->
                            case Dict.get identity patInfo.id exprTypes of
                                Just t ->
                                    t

                                Nothing ->
                                    Can.TVar "?"
                        )
                        args

                -- Get body type
                bodyType =
                    case Dict.get identity bodyInfo.id exprTypes of
                        Just t ->
                            t

                        Nothing ->
                            Can.TVar "?"
            in
            ( name, buildFunctionType argTypes bodyType )

        Can.TypedDef (A.At _ name) _ typedArgs _ resultType ->
            let
                argTypes =
                    List.map Tuple.second typedArgs
            in
            ( name, buildFunctionType argTypes resultType )


{-| Optimize a definition inside a let expression.
-}
optimizeDef :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> Cycle
    -> Can.Def
    -> Can.Type
    -> TOpt.Expr
    -> Names.Tracker TOpt.Expr
optimizeDef kernelEnv annotations exprTypes cycle def resultType body =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizeDefHelp kernelEnv annotations exprTypes cycle region name args expr resultType body

        Can.TypedDef (A.At region name) _ typedArgs expr _ ->
            optimizeDefHelp kernelEnv annotations exprTypes cycle region name (List.map Tuple.first typedArgs) expr resultType body


optimizeDefHelp :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> Cycle
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> Can.Expr
    -> Can.Type
    -> TOpt.Expr
    -> Names.Tracker TOpt.Expr
optimizeDefHelp kernelEnv annotations exprTypes cycle region name args expr resultType body =
    case args of
        [] ->
            optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes expr)
                |> Names.map
                    (\oexpr ->
                        let
                            exprType =
                                TOpt.typeOf oexpr
                        in
                        TOpt.Let (TOpt.Def region name oexpr exprType) body resultType
                    )

        _ ->
            -- Function definition: process args first to get bindings, then optimize body with args in scope
            destructArgs annotations args
                |> Names.andThen
                    (\( argNamesWithTypes, destructors ) ->
                        let
                            -- Root argument bindings (e.g., "_v0" for a tuple pattern)
                            argBindings =
                                List.map (\( A.At _ n, t ) -> ( n, t )) argNamesWithTypes

                            -- Extract bindings from destructors (e.g., "a", "b" from tuple (a, b))
                            destructorBindings =
                                List.map (\(TOpt.Destructor n _ t) -> ( n, t )) destructors

                            -- Combine all bindings so pattern variables are in scope
                            allBindings =
                                argBindings ++ destructorBindings
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes expr))
                            |> Names.map
                                (\oexpr ->
                                    let
                                        bodyType =
                                            TOpt.typeOf oexpr

                                        -- Build function type from arg types
                                        argTypes =
                                            List.map Tuple.second argNamesWithTypes

                                        funcType =
                                            buildFunctionType argTypes bodyType

                                        wrappedBody =
                                            List.foldr (wrapDestruct bodyType) oexpr destructors

                                        ofunc =
                                            TOpt.TrackedFunction argNamesWithTypes wrappedBody funcType
                                    in
                                    TOpt.Let (TOpt.Def region name ofunc funcType) body resultType
                                )
                    )


{-| Optimize a potentially tail-recursive definition from a Can.Def.
For LetRec with a single definition.
-}
optimizePotentialTailCallDef :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> Cycle
    -> Can.Def
    -> Names.Tracker TOpt.Def
optimizePotentialTailCallDef kernelEnv annotations exprTypes cycle def =
    case def of
        Can.Def (A.At region name) args body ->
            let
                defType =
                    lookupAnnotationType name annotations
            in
            optimizePotentialTailCall kernelEnv annotations exprTypes cycle region name args (TCan.toTypedExpr exprTypes body) defType

        Can.TypedDef (A.At region name) _ typedArgs body defType ->
            optimizePotentialTailCall kernelEnv annotations exprTypes cycle region name (List.map Tuple.first typedArgs) (TCan.toTypedExpr exprTypes body) defType



-- DEFINITIONS


{-| Optimize a potentially tail-recursive definition.
-}
optimizePotentialTailCall :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> Cycle
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> TCan.Expr
    -> Can.Type
    -> Names.Tracker TOpt.Def
optimizePotentialTailCall kernelEnv annotations exprTypes cycle region name args body defType =
    destructArgs annotations args
        |> Names.andThen
            (\( argNamesWithTypes, destructors ) ->
                let
                    -- Root argument bindings (e.g., "_v0" for a tuple pattern)
                    argBindings =
                        List.map (\( A.At _ n, t ) -> ( n, t )) argNamesWithTypes

                    -- Extract bindings from destructors (e.g., "a", "b" from tuple (a, b))
                    destructorBindings =
                        List.map (\(TOpt.Destructor n _ t) -> ( n, t )) destructors

                    -- Combine all bindings so pattern variables are in scope
                    allBindings =
                        argBindings ++ destructorBindings

                    bodyType =
                        peelFunctionType (List.length args) defType
                in
                Names.withVarTypes allBindings
                    (optimizeTail kernelEnv annotations exprTypes cycle name argNamesWithTypes bodyType body)
                    |> Names.map
                        (\obody ->
                            let
                                wrappedBody =
                                    List.foldr (wrapDestruct bodyType) obody destructors
                            in
                            if hasTailCall name obody then
                                TOpt.TailDef region name argNamesWithTypes wrappedBody defType

                            else
                                TOpt.Def region name (TOpt.TrackedFunction argNamesWithTypes wrappedBody defType) defType
                        )
            )


{-| Check if an expression contains a tail call to the given function.
-}
hasTailCall : Name -> TOpt.Expr -> Bool
hasTailCall funcName expr =
    case expr of
        TOpt.TailCall callName _ _ ->
            callName == funcName

        TOpt.If branches final _ ->
            List.any (\( _, branch ) -> hasTailCall funcName branch) branches
                || hasTailCall funcName final

        TOpt.Let _ body _ ->
            hasTailCall funcName body

        TOpt.Destruct _ body _ ->
            hasTailCall funcName body

        TOpt.Case _ _ decider jumps _ ->
            decidecHasTailCall funcName decider || List.any (\( _, branch ) -> hasTailCall funcName branch) jumps

        _ ->
            False


{-| Check if a decider contains a tail call to the given function.
This is needed to detect tail calls in inlined Case branches.
-}
decidecHasTailCall : Name -> TOpt.Decider TOpt.Choice -> Bool
decidecHasTailCall funcName decider =
    case decider of
        TOpt.Leaf choice ->
            case choice of
                TOpt.Inline expr ->
                    hasTailCall funcName expr

                TOpt.Jump _ ->
                    False

        TOpt.Chain _ success failure ->
            decidecHasTailCall funcName success || decidecHasTailCall funcName failure

        TOpt.FanOut _ tests fallback ->
            decidecHasTailCall funcName fallback || List.any (Tuple.second >> decidecHasTailCall funcName) tests


{-| Peel n argument types from a function type.
-}
peelFunctionType : Int -> Can.Type -> Can.Type
peelFunctionType n tipe =
    if n <= 0 then
        tipe

    else
        case tipe of
            Can.TLambda _ result ->
                peelFunctionType (n - 1) result

            _ ->
                tipe


{-| Build a function type from argument types and result type.

    buildFunctionType [Int, String] Bool  =>  Int -> String -> Bool

-}
buildFunctionType : List Can.Type -> Can.Type -> Can.Type
buildFunctionType argTypes resultType =
    List.foldr Can.TLambda resultType argTypes


{-| Wrap an expression in a Destruct node.
-}
wrapDestruct : Can.Type -> TOpt.Destructor -> TOpt.Expr -> TOpt.Expr
wrapDestruct bodyType destructor expr =
    TOpt.Destruct destructor expr bodyType



-- DESTRUCTURING


{-| Converts a list of function argument patterns into argument names with types and destructuring operations.
-}
destructArgs : Annotations -> List Can.Pattern -> Names.Tracker ( List ( A.Located Name, Can.Type ), List TOpt.Destructor )
destructArgs annotations args =
    Names.traverse (destruct annotations) args
        |> Names.map List.unzip
        |> Names.map
            (\( argNamesWithTypes, destructorLists ) ->
                ( argNamesWithTypes, List.concat destructorLists )
            )


destruct : Annotations -> Can.Pattern -> Names.Tracker ( ( A.Located Name, Can.Type ), List TOpt.Destructor )
destruct annotations ((A.At region patternInfo) as pattern) =
    case patternInfo.node of
        Can.PVar name ->
            -- Type would come from pattern inference, use placeholder
            Names.pure ( ( A.At region name, Can.TVar "?" ), [] )

        Can.PAlias subPattern name ->
            destructHelp (TOpt.Root name) subPattern []
                |> Names.map (\revDs -> ( ( A.At region name, Can.TVar "?" ), List.reverse revDs ))

        _ ->
            Names.generate
                |> Names.andThen
                    (\name ->
                        destructHelp (TOpt.Root name) pattern []
                            |> Names.map
                                (\revDs ->
                                    ( ( A.At region name, Can.TVar "?" ), List.reverse revDs )
                                )
                    )


destructHelp : TOpt.Path -> Can.Pattern -> List TOpt.Destructor -> Names.Tracker (List TOpt.Destructor)
destructHelp path (A.At region patternInfo) revDs =
    case patternInfo.node of
        Can.PAnything ->
            Names.pure revDs

        Can.PVar name ->
            Names.pure (TOpt.Destructor name path (Can.TVar "?") :: revDs)

        Can.PRecord fields ->
            let
                toDestruct : Name -> TOpt.Destructor
                toDestruct name =
                    TOpt.Destructor name (TOpt.Field name path) (Can.TVar "?")
            in
            Names.registerFieldList fields (List.map toDestruct fields ++ revDs)

        Can.PAlias subPattern name ->
            (TOpt.Destructor name path (Can.TVar "?") :: revDs) |> destructHelp (TOpt.Root name) subPattern

        Can.PUnit ->
            Names.pure revDs

        Can.PTuple a b [] ->
            destructTwo path a b revDs

        Can.PTuple a b [ c ] ->
            case path of
                TOpt.Root _ ->
                    destructHelp (TOpt.Index Index.first path) a revDs
                        |> Names.andThen (destructHelp (TOpt.Index Index.second path) b)
                        |> Names.andThen (destructHelp (TOpt.Index Index.third path) c)

                _ ->
                    Names.generate
                        |> Names.andThen
                            (\name ->
                                let
                                    newRoot =
                                        TOpt.Root name
                                in
                                destructHelp (TOpt.Index Index.first newRoot) a (TOpt.Destructor name path (Can.TVar "?") :: revDs)
                                    |> Names.andThen (destructHelp (TOpt.Index Index.second newRoot) b)
                                    |> Names.andThen (destructHelp (TOpt.Index Index.third newRoot) c)
                            )

        Can.PTuple a b cs ->
            case path of
                TOpt.Root _ ->
                    List.foldl (\( index, arg ) -> Names.andThen (destructHelp (TOpt.ArrayIndex index (TOpt.Field "cs" path)) arg))
                        (destructHelp (TOpt.Index Index.first path) a revDs
                            |> Names.andThen (destructHelp (TOpt.Index Index.second path) b)
                        )
                        (List.indexedMap Tuple.pair cs)

                _ ->
                    Names.generate
                        |> Names.andThen
                            (\name ->
                                let
                                    newRoot =
                                        TOpt.Root name
                                in
                                List.foldl (\( index, arg ) -> Names.andThen (destructHelp (TOpt.ArrayIndex index (TOpt.Field "cs" newRoot)) arg))
                                    (destructHelp (TOpt.Index Index.first newRoot) a (TOpt.Destructor name path (Can.TVar "?") :: revDs)
                                        |> Names.andThen (destructHelp (TOpt.Index Index.second newRoot) b)
                                    )
                                    (List.indexedMap Tuple.pair cs)
                            )

        Can.PList [] ->
            Names.pure revDs

        Can.PList (hd :: tl) ->
            -- Use placeholder ID (-1) for synthesized patterns
            destructTwo path hd (A.At region { id = -1, node = Can.PList tl }) revDs

        Can.PCons hd tl ->
            destructTwo path hd tl revDs

        Can.PChr _ ->
            Names.pure revDs

        Can.PStr _ _ ->
            Names.pure revDs

        Can.PInt _ ->
            Names.pure revDs

        Can.PBool _ _ ->
            Names.pure revDs

        Can.PCtor { union, args } ->
            case args of
                [ Can.PatternCtorArg _ _ arg ] ->
                    let
                        (Can.Union unionData) =
                            union
                    in
                    case unionData.opts of
                        Can.Normal ->
                            destructHelp (TOpt.Index Index.first path) arg revDs

                        Can.Unbox ->
                            destructHelp (TOpt.Unbox path) arg revDs

                        Can.Enum ->
                            destructHelp (TOpt.Index Index.first path) arg revDs

                _ ->
                    case path of
                        TOpt.Root _ ->
                            List.foldl (\arg -> Names.andThen (\revDs_ -> destructCtorArg path revDs_ arg))
                                (Names.pure revDs)
                                args

                        _ ->
                            Names.generate
                                |> Names.andThen
                                    (\name ->
                                        List.foldl (\arg -> Names.andThen (\revDs_ -> destructCtorArg (TOpt.Root name) revDs_ arg))
                                            (Names.pure (TOpt.Destructor name path (Can.TVar "?") :: revDs))
                                            args
                                    )


destructTwo : TOpt.Path -> Can.Pattern -> Can.Pattern -> List TOpt.Destructor -> Names.Tracker (List TOpt.Destructor)
destructTwo path a b revDs =
    case path of
        TOpt.Root _ ->
            destructHelp (TOpt.Index Index.first path) a revDs
                |> Names.andThen (destructHelp (TOpt.Index Index.second path) b)

        _ ->
            Names.generate
                |> Names.andThen
                    (\name ->
                        let
                            newRoot =
                                TOpt.Root name
                        in
                        destructHelp (TOpt.Index Index.first newRoot) a (TOpt.Destructor name path (Can.TVar "?") :: revDs)
                            |> Names.andThen (destructHelp (TOpt.Index Index.second newRoot) b)
                    )


destructCtorArg : TOpt.Path -> List TOpt.Destructor -> Can.PatternCtorArg -> Names.Tracker (List TOpt.Destructor)
destructCtorArg path revDs (Can.PatternCtorArg index _ arg) =
    destructHelp (TOpt.Index index path) arg revDs


{-| Destructure a case pattern into a list of destructors.
This is used when processing case branches.
-}
destructCase : Name -> Can.Pattern -> Names.Tracker (List TOpt.Destructor)
destructCase rootName pattern =
    destructHelp (TOpt.Root rootName) pattern []
        |> Names.map List.reverse
