module Compiler.Optimize.Typed.Expression exposing
    ( Cycle, Annotations
    , optimize, optimizePotentialTailCall
    , destructArgs
    )

{-| Optimizes TypedCanonical expressions into TypedOptimized expressions.

This module transforms TypedCanonical AST (where every expression has its type)
into TypedOptimized representation suitable for code generation. Each TOpt.Expr
carries a Can.Type annotation.

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
import System.TypeCheck.IO as IO
import Data.Set as EverySet exposing (EverySet)
import Utils.Crash
import Utils.Main as Utils



-- ====== TYPES ======


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



-- ====== TYPE HELPERS ======


{-| Build a function type from argument types and a result type.
-}
buildFunctionType : List Can.Type -> Can.Type -> Can.Type
buildFunctionType argTypes resultType =
    List.foldr Can.TLambda resultType argTypes


{-| Peel n argument types from a function type to get the result type.
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



-- ====== OPTIMIZE ======


{-| Transforms a TypedCanonical expression into a TypedOptimized expression.

Takes the kernel type environment, annotations, expression types map, home module,
cycle names, and a typed expression. The type of the expression is taken from the
TypedCanonical node.

The `exprTypes` parameter is needed to convert subexpressions (which are still
`Can.Expr`) back to `TCan.Expr` when recursing.

The `home` parameter is needed to create `VarCycle` references for local recursive
definitions.

-}
optimize : KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes -> IO.Canonical -> Cycle -> TCan.Expr -> Names.Tracker TOpt.Expr
optimize kernelEnv annotations exprTypes home cycle (A.At region texpr) =
    case texpr of
        TCan.TypedExpr { expr, tipe } ->
            optimizeExpr kernelEnv annotations exprTypes home cycle region tipe expr


optimizeExpr : KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes -> IO.Canonical -> Cycle -> A.Region -> Can.Type -> Can.Expr_ -> Names.Tracker TOpt.Expr
optimizeExpr kernelEnv annotations exprTypes home cycle region tipe expr =
    case expr of
        Can.VarLocal name ->
            -- Check if this local variable is part of a recursive cycle
            if EverySet.member identity name cycle then
                -- For local recursive definitions, create a VarCycle reference
                -- to ensure it gets properly linked to the global cycle node
                let
                    defType =
                        lookupAnnotationType name annotations
                in
                Names.pure (TOpt.VarCycle region home name defType)

            else
                Names.lookupLocalType name
                    |> Names.map (\localType -> TOpt.TrackedVarLocal region name localType)
                    |> catchMissing (Names.pure (TOpt.TrackedVarLocal region name tipe))

        Can.VarTopLevel varHome name ->
            let
                defType =
                    lookupAnnotationType name annotations
            in
            if EverySet.member identity name cycle then
                Names.pure (TOpt.VarCycle region varHome name defType)

            else
                Names.registerGlobal region varHome name defType

        Can.VarKernel kernelHome name ->
            let
                kernelType : Can.Type
                kernelType =
                    case KernelTypes.lookup kernelHome name kernelEnv of
                        Just t ->
                            t

                        Nothing ->
                            Utils.Crash.crash
                                ("Typed.Expression.optimizeExpr: Missing kernel type for " ++ kernelHome ++ "." ++ name)
            in
            Names.registerKernel kernelHome (TOpt.VarKernel region kernelHome name kernelType)

        Can.VarForeign foreignHome name _ ->
            Names.registerGlobal region foreignHome name tipe

        Can.VarCtor opts ctorHome name index _ ->
            Names.registerCtor region ctorHome (A.At region name) index opts tipe

        Can.VarDebug debugHome name (Can.Forall _ debugType) ->
            -- Use the full function type from the annotation, not the instantiated type
            -- This is needed for the monomorphizer to correctly derive the kernel ABI
            Names.registerDebug name debugHome region debugType

        Can.VarOperator _ opHome name (Can.Forall _ funcType) ->
            Names.registerGlobal region opHome name funcType

        Can.Chr chr ->
            Names.registerKernel Name.utils (TOpt.Chr region chr (Can.TType ModuleName.basics "Char" []))

        Can.Str str ->
            Names.pure (TOpt.Str region str (Can.TType ModuleName.basics "String" []))

        Can.Int int ->
            -- Use the canonical type `tipe` computed by PostSolve / type inference
            Names.pure (TOpt.Int region int tipe)

        Can.Float float ->
            Names.pure (TOpt.Float region float tipe)

        Can.List entries ->
            Names.traverse (optimize kernelEnv annotations exprTypes home cycle << TCan.toTypedExpr exprTypes) entries
                |> Names.andThen (\optEntries -> Names.registerKernel Name.list (TOpt.List region optEntries tipe))

        Can.Negate subExpr ->
            let
                negateType =
                    buildFunctionType [ tipe ] tipe
            in
            Names.registerGlobal region ModuleName.basics Name.negate negateType
                |> Names.andThen
                    (\func ->
                        optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes subExpr)
                            |> Names.map (\optSub -> TOpt.Call region func [ optSub ] tipe)
                    )

        -- Binop: use the annotation from the constructor
        Can.Binop _ binopHome name (Can.Forall _ funcType) left right ->
            let
                optimizeArg =
                    optimize kernelEnv annotations exprTypes home cycle << TCan.toTypedExpr exprTypes
            in
            Names.registerGlobal region binopHome name funcType
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
            destructArgs exprTypes args
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
                            (optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes body))
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
                    optimize kernelEnv annotations exprTypes home cycle << TCan.toTypedExpr exprTypes
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
                            optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes condition)

                        optThen =
                            optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes thenExpr)
                    in
                    optCond
                        |> Names.andThen (\c -> optThen |> Names.map (\t -> ( c, t )))
            in
            Names.traverse optimizeBranch branches
                |> Names.andThen
                    (\optBranches ->
                        optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes final)
                            |> Names.map (\optFinal -> TOpt.If optBranches optFinal tipe)
                    )

        Can.Let def body ->
            -- Add the let-bound variable to scope BEFORE optimizing the body
            let
                ( defName, defType ) =
                    getDefNameAndType exprTypes def
            in
            Names.withVarTypes [ ( defName, defType ) ]
                (optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes body))
                |> Names.andThen (optimizeDef kernelEnv annotations exprTypes home cycle def tipe)

        Can.LetRec defs body ->
            -- For LetRec, all definitions are mutually recursive, so add all names to scope
            let
                defBindings =
                    List.map (getDefNameAndType exprTypes) defs
            in
            case defs of
                [ def ] ->
                    Names.withVarTypes defBindings
                        (optimizePotentialTailCallDef kernelEnv annotations exprTypes home cycle def)
                        |> Names.andThen
                            (\tailCallDef ->
                                Names.withVarTypes defBindings
                                    (optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes body))
                                    |> Names.map (\obody -> TOpt.Let tailCallDef obody tipe)
                            )

                _ ->
                    Names.withVarTypes defBindings
                        (List.foldl
                            (\def bod ->
                                Names.andThen (optimizeDef kernelEnv annotations exprTypes home cycle def tipe) bod
                            )
                            (optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes body))
                            defs
                        )

        Can.LetDestruct pattern boundExpr body ->
            destruct exprTypes pattern
                |> Names.andThen
                    (\( ( A.At nameRegion name, patternType ), destructs ) ->
                        optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes boundExpr)
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
                                        (optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes body))
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
                    destructCase exprTypes root pattern
                        |> Names.andThen
                            (\destructors ->
                                let
                                    -- Extract bindings from destructors for scope
                                    destructorBindings =
                                        List.map (\(TOpt.Destructor n _ t) -> ( n, t )) destructors
                                in
                                Names.withVarTypes destructorBindings
                                    (optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes branch))
                                    |> Names.map
                                        (\obranch ->
                                            ( pattern, List.foldr (wrapDestruct tipe) obranch destructors )
                                        )
                            )
            in
            Names.generate
                |> Names.andThen
                    (\temp ->
                        optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes scrutinee)
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
            optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes recordExpr)
                |> Names.andThen
                    (\optRecord ->
                        Names.registerField field (TOpt.Access optRecord region field tipe)
                    )

        Can.Update recordExpr fieldUpdates ->
            let
                optimizeFieldUpdate : ( A.Located Name, Can.FieldUpdate ) -> Names.Tracker ( A.Located Name, TOpt.Expr )
                optimizeFieldUpdate ( locName, Can.FieldUpdate _ fieldExpr ) =
                    optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes fieldExpr)
                        |> Names.map (\optExpr -> ( locName, optExpr ))

                fieldUpdateList =
                    Dict.toList A.compareLocated fieldUpdates
            in
            optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes recordExpr)
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
                    optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes fieldExpr)
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
                    optimize kernelEnv annotations exprTypes home cycle << TCan.toTypedExpr exprTypes
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
catchMissing _ tracker =
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
            Utils.Crash.crash "Expression.lookupAnnotationType: no annotation"



-- ====== TAIL CALL OPTIMIZATION ======


{-| Optimize an expression in tail position.
This function detects tail calls to the function being defined and converts them
to TailCall nodes for efficient tail call elimination.
-}
optimizeTail :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> IO.Canonical
    -> Cycle
    -> Name
    -> List ( A.Located Name, Can.Type )
    -> Can.Type
    -> TCan.Expr
    -> Names.Tracker TOpt.Expr
optimizeTail kernelEnv annotations exprTypes home cycle rootName argNames resultType (A.At region texpr) =
    case texpr of
        TCan.TypedExpr { expr, tipe } ->
            optimizeTailExpr kernelEnv annotations exprTypes home cycle rootName argNames resultType region tipe expr


optimizeTailExpr :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> IO.Canonical
    -> Cycle
    -> Name
    -> List ( A.Located Name, Can.Type )
    -> Can.Type
    -> A.Region
    -> Can.Type
    -> Can.Expr_
    -> Names.Tracker TOpt.Expr
optimizeTailExpr kernelEnv annotations exprTypes home cycle rootName argNames resultType region tipe expr =
    case expr of
        Can.Call func callArgs ->
            let
                optimizeArg =
                    optimize kernelEnv annotations exprTypes home cycle << TCan.toTypedExpr exprTypes
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
                    optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes condition)
                        |> Names.andThen
                            (\optCond ->
                                optimizeTail kernelEnv annotations exprTypes home cycle rootName argNames resultType (TCan.toTypedExpr exprTypes branch)
                                    |> Names.map (\optBranch -> ( optCond, optBranch ))
                            )
            in
            Names.traverse optimizeBranch branches
                |> Names.andThen
                    (\optBranches ->
                        optimizeTail kernelEnv annotations exprTypes home cycle rootName argNames resultType (TCan.toTypedExpr exprTypes final)
                            |> Names.map (\optFinal -> TOpt.If optBranches optFinal tipe)
                    )

        Can.Let def body ->
            -- Add the let-bound variable to scope BEFORE optimizing the body
            let
                ( defName, defType ) =
                    getDefNameAndType exprTypes def
            in
            Names.withVarTypes [ ( defName, defType ) ]
                (optimizeTail kernelEnv annotations exprTypes home cycle rootName argNames resultType (TCan.toTypedExpr exprTypes body))
                |> Names.andThen (optimizeDef kernelEnv annotations exprTypes home cycle def tipe)

        Can.LetRec defs body ->
            -- For LetRec, all definitions are mutually recursive, so add all names to scope
            let
                defBindings =
                    List.map (getDefNameAndType exprTypes) defs
            in
            case defs of
                [ def ] ->
                    Names.withVarTypes defBindings
                        (optimizePotentialTailCallDef kernelEnv annotations exprTypes home cycle def)
                        |> Names.andThen
                            (\tailCallDef ->
                                Names.withVarTypes defBindings
                                    (optimizeTail kernelEnv annotations exprTypes home cycle rootName argNames resultType (TCan.toTypedExpr exprTypes body))
                                    |> Names.map (\obody -> TOpt.Let tailCallDef obody tipe)
                            )

                _ ->
                    Names.withVarTypes defBindings
                        (List.foldl
                            (\def bod ->
                                Names.andThen (optimizeDef kernelEnv annotations exprTypes home cycle def tipe) bod
                            )
                            (optimizeTail kernelEnv annotations exprTypes home cycle rootName argNames resultType (TCan.toTypedExpr exprTypes body))
                            defs
                        )

        Can.LetDestruct pattern boundExpr body ->
            destruct exprTypes pattern
                |> Names.andThen
                    (\( ( A.At nameRegion name, patternType ), destructs ) ->
                        optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes boundExpr)
                            |> Names.andThen
                                (\oBoundExpr ->
                                    let
                                        destructorBindings =
                                            List.map (\(TOpt.Destructor n _ t) -> ( n, t )) destructs

                                        allBindings =
                                            ( name, patternType ) :: destructorBindings
                                    in
                                    Names.withVarTypes allBindings
                                        (optimizeTail kernelEnv annotations exprTypes home cycle rootName argNames resultType (TCan.toTypedExpr exprTypes body))
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
                    destructCase exprTypes root pattern
                        |> Names.andThen
                            (\destructors ->
                                let
                                    destructorBindings =
                                        List.map (\(TOpt.Destructor n _ t) -> ( n, t )) destructors
                                in
                                Names.withVarTypes destructorBindings
                                    (optimizeTail kernelEnv annotations exprTypes home cycle rootName argNames resultType (TCan.toTypedExpr exprTypes branch))
                                    |> Names.map
                                        (\obranch ->
                                            ( pattern, List.foldr (wrapDestruct tipe) obranch destructors )
                                        )
                            )
            in
            Names.generate
                |> Names.andThen
                    (\temp ->
                        optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes scrutinee)
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
            optimizeExpr kernelEnv annotations exprTypes home cycle region tipe expr



-- ====== LET DEFINITIONS ======


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
                                    Utils.Crash.crash "Expression.extractDefNameAndType: arg type"
                        )
                        args

                -- Get body type
                bodyType =
                    case Dict.get identity bodyInfo.id exprTypes of
                        Just t ->
                            t

                        Nothing ->
                            Utils.Crash.crash "Expression.extractDefNameAndType: body type"
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
    -> IO.Canonical
    -> Cycle
    -> Can.Def
    -> Can.Type
    -> TOpt.Expr
    -> Names.Tracker TOpt.Expr
optimizeDef kernelEnv annotations exprTypes home cycle def resultType body =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizeDefHelp kernelEnv annotations exprTypes home cycle region name args expr resultType body

        Can.TypedDef (A.At region name) _ typedArgs expr _ ->
            optimizeDefHelp kernelEnv annotations exprTypes home cycle region name (List.map Tuple.first typedArgs) expr resultType body


optimizeDefHelp :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> IO.Canonical
    -> Cycle
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> Can.Expr
    -> Can.Type
    -> TOpt.Expr
    -> Names.Tracker TOpt.Expr
optimizeDefHelp kernelEnv annotations exprTypes home cycle region name args expr resultType body =
    case args of
        [] ->
            optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes expr)
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
            destructArgs exprTypes args
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
                            (optimize kernelEnv annotations exprTypes home cycle (TCan.toTypedExpr exprTypes expr))
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
    -> IO.Canonical
    -> Cycle
    -> Can.Def
    -> Names.Tracker TOpt.Def
optimizePotentialTailCallDef kernelEnv annotations exprTypes home cycle def =
    case def of
        Can.Def (A.At region name) args body ->
            let
                -- Get the def type from exprTypes (pattern and body types), not annotations
                ( _, defType ) =
                    getDefNameAndType exprTypes def
            in
            optimizePotentialTailCall kernelEnv annotations exprTypes home cycle region name args (TCan.toTypedExpr exprTypes body) defType

        Can.TypedDef (A.At region name) _ typedArgs body defType ->
            optimizePotentialTailCall kernelEnv annotations exprTypes home cycle region name (List.map Tuple.first typedArgs) (TCan.toTypedExpr exprTypes body) defType



-- ====== DEFINITIONS ======


{-| Optimize a potentially tail-recursive definition.
-}
optimizePotentialTailCall :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> IO.Canonical
    -> Cycle
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> TCan.Expr
    -> Can.Type
    -> Names.Tracker TOpt.Def
optimizePotentialTailCall kernelEnv annotations exprTypes home cycle region name args body defType =
    destructArgs exprTypes args
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
                    (optimizeTail kernelEnv annotations exprTypes home cycle name argNamesWithTypes bodyType body)
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


{-| Wrap an expression in a Destruct node.
-}
wrapDestruct : Can.Type -> TOpt.Destructor -> TOpt.Expr -> TOpt.Expr
wrapDestruct bodyType destructor expr =
    TOpt.Destruct destructor expr bodyType



-- ====== DESTRUCTURING ======


{-| Look up a pattern's type from the exprTypes dictionary.
Returns Complete if found, ToSolve with location info if not found.
Negative IDs are synthetic patterns that won't have types.
-}
lookupPatternType : ExprTypes -> Int -> String -> Can.Type
lookupPatternType exprTypes patId location =
    if patId < 0 then
        -- Synthetic pattern (negative ID), no type available
        Utils.Crash.crash (location ++ ": synthetic")

    else
        case Dict.get identity patId exprTypes of
            Just t ->
                t

            Nothing ->
                Utils.Crash.crash (location ++ ": not in exprTypes")


{-| Converts a list of function argument patterns into argument names with types and destructuring operations.
-}
destructArgs : ExprTypes -> List Can.Pattern -> Names.Tracker ( List ( A.Located Name, Can.Type ), List TOpt.Destructor )
destructArgs exprTypes args =
    Names.traverse (destruct exprTypes) args
        |> Names.map List.unzip
        |> Names.map
            (\( argNamesWithTypes, destructorLists ) ->
                ( argNamesWithTypes, List.concat destructorLists )
            )


destruct : ExprTypes -> Can.Pattern -> Names.Tracker ( ( A.Located Name, Can.Type ), List TOpt.Destructor )
destruct exprTypes ((A.At region patternInfo) as pattern) =
    case patternInfo.node of
        Can.PVar name ->
            let
                patType =
                    lookupPatternType exprTypes patternInfo.id "Expression.destruct: PVar"
            in
            Names.pure ( ( A.At region name, patType ), [] )

        Can.PAlias subPattern name ->
            let
                patType =
                    lookupPatternType exprTypes patternInfo.id "Expression.destruct: PAlias"
            in
            destructHelp exprTypes (TOpt.Root name) subPattern []
                |> Names.map (\revDs -> ( ( A.At region name, patType ), List.reverse revDs ))

        _ ->
            Names.generate
                |> Names.andThen
                    (\name ->
                        let
                            patType =
                                lookupPatternType exprTypes patternInfo.id "Expression.destruct: generated"
                        in
                        destructHelp exprTypes (TOpt.Root name) pattern []
                            |> Names.map
                                (\revDs ->
                                    ( ( A.At region name, patType ), List.reverse revDs )
                                )
                    )


destructHelp : ExprTypes -> TOpt.Path -> Can.Pattern -> List TOpt.Destructor -> Names.Tracker (List TOpt.Destructor)
destructHelp exprTypes path pattern revDs =
    destructHelpWithType exprTypes Nothing Nothing path pattern revDs


{-| Internal helper that also threads parent pattern ID for synthetic patterns.
-}
destructHelpWithParent : ExprTypes -> Int -> TOpt.Path -> Can.Pattern -> List TOpt.Destructor -> Names.Tracker (List TOpt.Destructor)
destructHelpWithParent exprTypes parentPatId path pattern revDs =
    destructHelpWithType exprTypes (Just parentPatId) Nothing path pattern revDs


{-| Destructure a pattern with optional type hint and parent pattern ID.

When destructuring constructor arguments, we have access to the argument's type
from PatternCtorArg. This type hint is used when creating destructors for PVar
patterns, allowing the type system to track the actual field types instead of
using placeholder ToSolve types.

The optional parent pattern ID is used for synthetic patterns (like list tails)
that have negative IDs and can't be looked up directly. We use the parent's ID
to look up the container type.

This is critical for correct code generation: when a constructor like Circle Int
stores its Int field unboxed, the destructor needs to know the field type is Int
so that eco.project can read the value with the correct unboxed flag.

-}
destructHelpWithType : ExprTypes -> Maybe Int -> Maybe Can.Type -> TOpt.Path -> Can.Pattern -> List TOpt.Destructor -> Names.Tracker (List TOpt.Destructor)
destructHelpWithType exprTypes maybeParentPatId maybeType path (A.At region patternInfo) revDs =
    let
        -- Use parent pattern ID if provided and current pattern is synthetic
        effectivePatId =
            if patternInfo.id < 0 then
                Maybe.withDefault patternInfo.id maybeParentPatId

            else
                patternInfo.id
    in
    case patternInfo.node of
        Can.PAnything ->
            Names.pure revDs

        Can.PVar name ->
            -- Use the type hint if available, then try exprTypes lookup, then ToSolve
            let
                varType =
                    case maybeType of
                        Just t ->
                            t

                        Nothing ->
                            lookupPatternType exprTypes effectivePatId "Expression.destructHelpWithType: PVar"
            in
            Names.pure (TOpt.Destructor name path varType :: revDs)

        Can.PRecord fields ->
            let
                -- For record fields, we need to look up each field's type from the pattern
                -- The pattern itself has a record type, but we need to extract field types
                toDestruct : Name -> TOpt.Destructor
                toDestruct name =
                    -- Try to get record field type from pattern's type
                    let
                        fieldType =
                            case Dict.get identity effectivePatId exprTypes of
                                Just (Can.TRecord fieldDict _) ->
                                    case Dict.get identity name fieldDict of
                                        Just (Can.FieldType _ t) ->
                                            t

                                        Nothing ->
                                            Utils.Crash.crash ("Expression.destructHelpWithType: PRecord field " ++ name ++ " not in type")

                                _ ->
                                    lookupPatternType exprTypes effectivePatId ("Expression.destructHelpWithType: PRecord " ++ name)
                    in
                    TOpt.Destructor name (TOpt.Field name path) fieldType
            in
            Names.registerFieldList fields (List.map toDestruct fields ++ revDs)

        Can.PAlias subPattern name ->
            let
                aliasType =
                    lookupPatternType exprTypes effectivePatId "Expression.destructHelpWithType: PAlias"
            in
            (TOpt.Destructor name path aliasType :: revDs) |> destructHelp exprTypes (TOpt.Root name) subPattern

        Can.PUnit ->
            Names.pure revDs

        Can.PTuple a b [] ->
            destructTwo exprTypes effectivePatId TOpt.HintTuple2 path a b revDs

        Can.PTuple a b [ c ] ->
            case path of
                TOpt.Root _ ->
                    destructHelp exprTypes (TOpt.Index Index.first TOpt.HintTuple3 path) a revDs
                        |> Names.andThen (destructHelp exprTypes (TOpt.Index Index.second TOpt.HintTuple3 path) b)
                        |> Names.andThen (destructHelp exprTypes (TOpt.Index Index.third TOpt.HintTuple3 path) c)

                _ ->
                    Names.generate
                        |> Names.andThen
                            (\name ->
                                let
                                    newRoot =
                                        TOpt.Root name

                                    genType =
                                        lookupPatternType exprTypes effectivePatId "Expression.destructHelpWithType: PTuple3 gen"
                                in
                                destructHelp exprTypes (TOpt.Index Index.first TOpt.HintTuple3 newRoot) a (TOpt.Destructor name path genType :: revDs)
                                    |> Names.andThen (destructHelp exprTypes (TOpt.Index Index.second TOpt.HintTuple3 newRoot) b)
                                    |> Names.andThen (destructHelp exprTypes (TOpt.Index Index.third TOpt.HintTuple3 newRoot) c)
                            )

        Can.PTuple a b cs ->
            case path of
                TOpt.Root _ ->
                    List.foldl (\( index, arg ) -> Names.andThen (destructHelp exprTypes (TOpt.ArrayIndex index (TOpt.Field "cs" path)) arg))
                        (destructHelp exprTypes (TOpt.Index Index.first TOpt.HintCustom path) a revDs
                            |> Names.andThen (destructHelp exprTypes (TOpt.Index Index.second TOpt.HintCustom path) b)
                        )
                        (List.indexedMap Tuple.pair cs)

                _ ->
                    Names.generate
                        |> Names.andThen
                            (\name ->
                                let
                                    newRoot =
                                        TOpt.Root name

                                    genType =
                                        lookupPatternType exprTypes effectivePatId "Expression.destructHelpWithType: PTupleN gen"
                                in
                                List.foldl (\( index, arg ) -> Names.andThen (destructHelp exprTypes (TOpt.ArrayIndex index (TOpt.Field "cs" newRoot)) arg))
                                    (destructHelp exprTypes (TOpt.Index Index.first TOpt.HintCustom newRoot) a (TOpt.Destructor name path genType :: revDs)
                                        |> Names.andThen (destructHelp exprTypes (TOpt.Index Index.second TOpt.HintCustom newRoot) b)
                                    )
                                    (List.indexedMap Tuple.pair cs)
                            )

        Can.PList [] ->
            Names.pure revDs

        Can.PList (hd :: tl) ->
            -- Use placeholder ID (-1) for synthesized patterns, but pass parent pattern ID (effectivePatId)
            destructTwo exprTypes effectivePatId TOpt.HintList path hd (A.At region { id = -1, node = Can.PList tl }) revDs

        Can.PCons hd tl ->
            destructTwo exprTypes effectivePatId TOpt.HintList path hd tl revDs

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
                [ Can.PatternCtorArg _ argType arg ] ->
                    let
                        (Can.Union unionData) =
                            union
                    in
                    case unionData.opts of
                        Can.Normal ->
                            destructHelpWithType exprTypes Nothing (Just argType) (TOpt.Index Index.first TOpt.HintCustom path) arg revDs

                        Can.Unbox ->
                            destructHelpWithType exprTypes Nothing (Just argType) (TOpt.Unbox path) arg revDs

                        Can.Enum ->
                            destructHelpWithType exprTypes Nothing (Just argType) (TOpt.Index Index.first TOpt.HintCustom path) arg revDs

                _ ->
                    case path of
                        TOpt.Root _ ->
                            List.foldl (\arg -> Names.andThen (\revDs_ -> destructCtorArg exprTypes path revDs_ arg))
                                (Names.pure revDs)
                                args

                        _ ->
                            Names.generate
                                |> Names.andThen
                                    (\name ->
                                        let
                                            genType =
                                                lookupPatternType exprTypes effectivePatId "Expression.destructHelpWithType: PCtor gen"
                                        in
                                        List.foldl (\arg -> Names.andThen (\revDs_ -> destructCtorArg exprTypes (TOpt.Root name) revDs_ arg))
                                            (Names.pure (TOpt.Destructor name path genType :: revDs))
                                            args
                                    )


destructTwo : ExprTypes -> Int -> TOpt.ContainerHint -> TOpt.Path -> Can.Pattern -> Can.Pattern -> List TOpt.Destructor -> Names.Tracker (List TOpt.Destructor)
destructTwo exprTypes parentPatId hint path a b revDs =
    case path of
        TOpt.Root _ ->
            -- Thread the parent pattern ID through for synthetic patterns
            destructHelpWithParent exprTypes parentPatId (TOpt.Index Index.first hint path) a revDs
                |> Names.andThen (destructHelpWithParent exprTypes parentPatId (TOpt.Index Index.second hint path) b)

        _ ->
            Names.generate
                |> Names.andThen
                    (\name ->
                        let
                            newRoot =
                                TOpt.Root name

                            -- For the generated binding, use the parent pattern's type
                            -- since that's the container type (tuple/list) being destructured
                            genType =
                                lookupPatternType exprTypes parentPatId "Expression.destructTwo: generated"
                        in
                        destructHelpWithParent exprTypes parentPatId (TOpt.Index Index.first hint newRoot) a (TOpt.Destructor name path genType :: revDs)
                            |> Names.andThen (destructHelpWithParent exprTypes parentPatId (TOpt.Index Index.second hint newRoot) b)
                    )


destructCtorArg : ExprTypes -> TOpt.Path -> List TOpt.Destructor -> Can.PatternCtorArg -> Names.Tracker (List TOpt.Destructor)
destructCtorArg exprTypes path revDs (Can.PatternCtorArg index argType arg) =
    destructHelpWithType exprTypes Nothing (Just argType) (TOpt.Index index TOpt.HintCustom path) arg revDs


{-| Destructure a case pattern into a list of destructors.
This is used when processing case branches.
-}
destructCase : ExprTypes -> Name -> Can.Pattern -> Names.Tracker (List TOpt.Destructor)
destructCase exprTypes rootName pattern =
    destructHelp exprTypes (TOpt.Root rootName) pattern []
        |> Names.map List.reverse
