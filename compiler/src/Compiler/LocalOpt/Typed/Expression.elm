module Compiler.LocalOpt.Typed.Expression exposing
    ( Cycle, Annotations
    , optimize, optimizePotentialTailCall
    , destructArgs
    )

{-| Optimizes TypedCanonical expressions into TypedOptimized expressions.

This module transforms TypedCanonical AST (where every expression has its type)
into TypedOptimized representation suitable for code generation. Each (TOpt.Expr Name)
carries a Can.Type Name annotation.

@docs Cycle, Annotations
@docs optimize, optimizePotentialTailCall
@docs destructArgs

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.TypedCanonical as TCan exposing (ExprTypes, ExprVars)
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.Utils.Shader as Shader
import Compiler.AST.Utils.Type as Type
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Typed.Case as Case
import Compiler.LocalOpt.Typed.Names as Names
import Compiler.Reporting.Annotation as A
import Compiler.Type.KernelTypes as KernelTypes
import Compiler.TypedCanonical.Build as TCanBuild
import Data.Map
import Data.Set as EverySet exposing (EverySet)
import Dict exposing (Dict)
import System.TypeCheck.IO as IO
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
    Dict Name (Can.Annotation Name)



-- ====== TYPE HELPERS ======


{-| Build a function type from argument types and a result type.
-}
buildFunctionType : List (Can.Type Name) -> Can.Type Name -> Can.Type Name
buildFunctionType argTypes resultType =
    List.foldr Can.TLambda resultType argTypes


{-| Peel n argument types from a function type to get the result type.
-}
peelFunctionType : Int -> Can.Type Name -> Can.Type Name
peelFunctionType n tipe =
    if n <= 0 then
        tipe

    else
        case tipe of
            Can.TLambda _ result ->
                peelFunctionType (n - 1) result

            _ ->
                tipe


{-| The canonical `Bool` type.
-}
boolType : Can.Type Name
boolType =
    Can.TType ModuleName.basics "Bool" []


{-| Match `compare a b` (either as `Basics.compare` or as the kernel ref
`Elm.Kernel.Utils.compare`) and return the two argument expressions. Both
faces can occur because canonicalization sometimes routes `Basics.compare`
references through the kernel directly.
-}
matchCompareCall : Can.Expr -> Maybe ( Can.Expr, Can.Expr )
matchCompareCall (A.At _ info) =
    case info.node of
        Can.Call (A.At _ funcInfo) [ a, b ] ->
            case funcInfo.node of
                Can.VarTopLevel callHome callName ->
                    if callHome == ModuleName.basics && callName == "compare" then
                        Just ( a, b )

                    else
                        Nothing

                Can.VarKernel _ kernelHome kernelName ->
                    if kernelHome == Name.utils && kernelName == "compare" then
                        Just ( a, b )

                    else
                        Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Match three case branches against the `Order` constructors LT/EQ/GT
(zero‑arg) in any order. Returns the bodies in canonical (LT, EQ, GT)
order. Rejects wildcards / aliases / variable patterns since collapsing
constructors would change which branch fires under the rewrite.
-}
matchOrderBranches : List Can.CaseBranch -> Maybe ( Can.Expr, Can.Expr, Can.Expr )
matchOrderBranches branches =
    let
        classify : Can.CaseBranch -> Maybe ( Name, Can.Expr )
        classify (Can.CaseBranch (A.At _ patInfo) body) =
            case patInfo.node of
                Can.PCtor patData ->
                    if patData.home == ModuleName.basics && patData.type_ == "Order" && List.isEmpty patData.args then
                        case patData.name of
                            "LT" ->
                                Just ( "LT", body )

                            "EQ" ->
                                Just ( "EQ", body )

                            "GT" ->
                                Just ( "GT", body )

                            _ ->
                                Nothing

                    else
                        Nothing

                _ ->
                    Nothing
    in
    case List.map classify branches of
        [ Just ( n1, e1 ), Just ( n2, e2 ), Just ( n3, e3 ) ] ->
            let
                pick : Name -> Maybe Can.Expr
                pick target =
                    if n1 == target then
                        Just e1

                    else if n2 == target then
                        Just e2

                    else if n3 == target then
                        Just e3

                    else
                        Nothing
            in
            Maybe.map3 (\a b c -> ( a, b, c )) (pick "LT") (pick "EQ") (pick "GT")

        _ ->
            Nothing


{-| Build the rewritten expression for `case compare a b of LT -> e1 ; EQ -> e2 ; GT -> e3`.
The result is

    let _vN = a in
    let _vM = b in
    if Basics.lt _vN _vM then e1
    else if Basics.eq _vN _vM then e2
    else e3

Binding `a` and `b` to fresh names prevents double-evaluation under the two
synthesized comparisons. After monomorphization, `Basics.lt`/`Basics.eq`
collapse through their kernel-call bodies into `Utils.lt`/`Utils.equal`,
which dispatch to primitive intrinsics for Int/Float/Char and stay as kernel
calls for Strings and other comparables — still a win because the `Order`
allocation is gone.

The `optimizeBranch` argument is the optimizer to use for branch bodies; the
caller picks `optimize` or its tail-position variant so we don't lose tail
calls inside `e1`/`e2`/`e3`.

-}
applyCompareToOrderRewrite :
    (Can.Expr -> Names.Tracker (TOpt.Expr Name))
    -> (Can.Expr -> Names.Tracker (TOpt.Expr Name))
    -> ExprTypes
    -> A.Region
    -> Can.Type Name
    -> Maybe IO.Variable
    -> Can.Expr
    -> Can.Expr
    -> Can.Expr
    -> Can.Expr
    -> Can.Expr
    -> Names.Tracker (TOpt.Expr Name)
applyCompareToOrderRewrite optimizeBranch optimizeArg exprTypes region tipe tvar a b ltBody eqBody gtBody =
    let
        argType : Can.Type Name
        argType =
            case Array.get (A.toValue a).id exprTypes |> Maybe.andThen identity of
                Just t ->
                    t

                Nothing ->
                    Utils.Crash.crash "applyCompareToOrderRewrite: missing type for compare argument"

        funcType : Can.Type Name
        funcType =
            Can.TLambda argType (Can.TLambda argType boolType)

        meta : { tipe : Can.Type Name, tvar : Maybe IO.Variable }
        meta =
            { tipe = tipe, tvar = tvar }

        boolMeta : { tipe : Can.Type Name, tvar : Maybe IO.Variable }
        boolMeta =
            { tipe = boolType, tvar = Nothing }

        argMeta : { tipe : Can.Type Name, tvar : Maybe IO.Variable }
        argMeta =
            { tipe = argType, tvar = Nothing }
    in
    Names.generate
        |> Names.andThen
            (\tmpA ->
                Names.generate
                    |> Names.andThen
                        (\tmpB ->
                            optimizeArg a
                                |> Names.andThen
                                    (\optA ->
                                        optimizeArg b
                                            |> Names.andThen
                                                (\optB ->
                                                    optimizeBranch ltBody
                                                        |> Names.andThen
                                                            (\optLT ->
                                                                optimizeBranch eqBody
                                                                    |> Names.andThen
                                                                        (\optEQ ->
                                                                            optimizeBranch gtBody
                                                                                |> Names.andThen
                                                                                    (\optGT ->
                                                                                        Names.registerGlobal region ModuleName.basics "lt" funcType Nothing
                                                                                            |> Names.andThen
                                                                                                (\ltFn ->
                                                                                                    Names.registerGlobal region ModuleName.basics "eq" funcType Nothing
                                                                                                        |> Names.map
                                                                                                            (\eqFn ->
                                                                                                                let
                                                                                                                    varA =
                                                                                                                        TOpt.VarLocal tmpA argMeta

                                                                                                                    varB =
                                                                                                                        TOpt.VarLocal tmpB argMeta

                                                                                                                    ltCall =
                                                                                                                        TOpt.Call region ltFn [ varA, varB ] boolMeta

                                                                                                                    eqCall =
                                                                                                                        TOpt.Call region eqFn [ varA, varB ] boolMeta

                                                                                                                    ifExpr =
                                                                                                                        TOpt.If [ ( ltCall, optLT ), ( eqCall, optEQ ) ] optGT meta

                                                                                                                    wrapB =
                                                                                                                        TOpt.Let (TOpt.Def region tmpB optB argType) ifExpr meta
                                                                                                                in
                                                                                                                TOpt.Let (TOpt.Def region tmpA optA argType) wrapB meta
                                                                                                            )
                                                                                                )
                                                                                    )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


{-| Synthesize a TypedOptimized `Bool` literal carrying consistent Meta.
Threading the outer `tvar` keeps the synthesized node mapped to the same
solver variable as the surrounding expression.
-}
boolLit : A.Region -> Bool -> Maybe IO.Variable -> TOpt.Expr Name
boolLit region value tv =
    TOpt.Bool region value { tipe = boolType, tvar = tv }


{-| Find the solver tvar for a local variable by scanning a Canonical
expression for `VarLocal name` occurrences.

Used to recover the _function_ type variable for locally-defined functions:

  - LetRec single-def: scan the RHS body for self-calls.
  - Non-recursive let: scan the continuation body for uses of the bound name.

Returns the tvar from the first `VarLocal name` found, which is the binder's
solver variable for the full (possibly polymorphic) function type.

Note: canonicalization forbids name shadowing, so all VarLocal occurrences
of targetName within a scope refer to the same binding.

-}
findVarLocalTvar : Name -> ExprVars -> Can.Expr -> Maybe IO.Variable
findVarLocalTvar targetName exprVars (A.At _ info) =
    case info.node of
        Can.VarLocal name ->
            if name == targetName then
                Array.get info.id exprVars |> Maybe.andThen identity

            else
                Nothing

        -- Leaf nodes: no sub-expressions to search
        Can.VarTopLevel _ _ ->
            Nothing

        Can.VarKernel _ _ _ ->
            Nothing

        Can.VarForeign _ _ _ ->
            Nothing

        Can.VarCtor _ _ _ _ _ ->
            Nothing

        Can.VarDebug _ _ _ ->
            Nothing

        Can.VarOperator _ _ _ _ ->
            Nothing

        Can.Chr _ ->
            Nothing

        Can.Str _ ->
            Nothing

        Can.Int _ ->
            Nothing

        Can.Float _ ->
            Nothing

        Can.Accessor _ ->
            Nothing

        Can.Unit ->
            Nothing

        Can.Shader _ _ ->
            Nothing

        -- Single sub-expression
        Can.Negate e ->
            findVarLocalTvar targetName exprVars e

        Can.Lambda _ body ->
            findVarLocalTvar targetName exprVars body

        Can.Access recordExpr _ ->
            findVarLocalTvar targetName exprVars recordExpr

        -- Two sub-expressions
        Can.Binop _ _ _ _ left right ->
            firstJust2 targetName exprVars left right

        -- Function call
        Can.Call func args ->
            case findVarLocalTvar targetName exprVars func of
                Just v ->
                    Just v

                Nothing ->
                    firstJustList targetName exprVars args

        -- Lists, tuples, records
        Can.List entries ->
            firstJustList targetName exprVars entries

        Can.Tuple a b rest ->
            case findVarLocalTvar targetName exprVars a of
                Just v ->
                    Just v

                Nothing ->
                    case findVarLocalTvar targetName exprVars b of
                        Just v ->
                            Just v

                        Nothing ->
                            firstJustList targetName exprVars rest

        Can.Record fields ->
            firstJustList targetName exprVars (Data.Map.values A.compareLocated fields)

        Can.Update recordExpr fieldUpdates ->
            case findVarLocalTvar targetName exprVars recordExpr of
                Just v ->
                    Just v

                Nothing ->
                    firstJustList targetName
                        exprVars
                        (List.map (\(Can.FieldUpdate _ e) -> e) (Data.Map.values A.compareLocated fieldUpdates))

        -- Control flow
        Can.If branches final ->
            let
                tryBranch ( cond, branchExpr ) =
                    case findVarLocalTvar targetName exprVars cond of
                        Just v ->
                            Just v

                        Nothing ->
                            findVarLocalTvar targetName exprVars branchExpr
            in
            case firstJustMap tryBranch branches of
                Just v ->
                    Just v

                Nothing ->
                    findVarLocalTvar targetName exprVars final

        Can.Case scrutinee branches ->
            case findVarLocalTvar targetName exprVars scrutinee of
                Just v ->
                    Just v

                Nothing ->
                    firstJustMap
                        (\(Can.CaseBranch _ branchExpr) ->
                            findVarLocalTvar targetName exprVars branchExpr
                        )
                        branches

        -- Let expressions (no shadow concern — canonicalization forbids shadowing)
        Can.Let def body ->
            case findVarLocalTvarInDef targetName exprVars def of
                Just v ->
                    Just v

                Nothing ->
                    findVarLocalTvar targetName exprVars body

        Can.LetRec defs body ->
            case firstJustMap (findVarLocalTvarInDef targetName exprVars) defs of
                Just v ->
                    Just v

                Nothing ->
                    findVarLocalTvar targetName exprVars body

        Can.LetDestruct _ boundExpr body ->
            firstJust2 targetName exprVars boundExpr body


findVarLocalTvarInDef : Name -> ExprVars -> Can.Def -> Maybe IO.Variable
findVarLocalTvarInDef targetName exprVars def =
    case def of
        Can.Def _ _ body ->
            findVarLocalTvar targetName exprVars body

        Can.TypedDef _ _ _ body _ ->
            findVarLocalTvar targetName exprVars body


{-| Helper: return first Just from two expressions
-}
firstJust2 : Name -> ExprVars -> Can.Expr -> Can.Expr -> Maybe IO.Variable
firstJust2 targetName exprVars a b =
    case findVarLocalTvar targetName exprVars a of
        Just v ->
            Just v

        Nothing ->
            findVarLocalTvar targetName exprVars b


{-| Helper: return first Just from a list of expressions
-}
firstJustList : Name -> ExprVars -> List Can.Expr -> Maybe IO.Variable
firstJustList targetName exprVars exprs =
    case exprs of
        [] ->
            Nothing

        e :: rest ->
            case findVarLocalTvar targetName exprVars e of
                Just v ->
                    Just v

                Nothing ->
                    firstJustList targetName exprVars rest


{-| Helper: return first Just from mapping over a list
-}
firstJustMap : (a -> Maybe IO.Variable) -> List a -> Maybe IO.Variable
firstJustMap f list =
    case list of
        [] ->
            Nothing

        x :: rest ->
            case f x of
                Just v ->
                    Just v

                Nothing ->
                    firstJustMap f rest



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
optimize : KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes -> ExprVars -> IO.Canonical -> Cycle -> TCan.Expr -> Names.Tracker (TOpt.Expr Name)
optimize kernelEnv annotations exprTypes exprVars home cycle (A.At region texpr) =
    case texpr of
        TCan.TypedExpr { expr, tipe, tvar } ->
            optimizeExpr kernelEnv annotations exprTypes exprVars home cycle region tipe tvar expr


optimizeExpr : KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes -> ExprVars -> IO.Canonical -> Cycle -> A.Region -> Can.Type Name -> Maybe IO.Variable -> Can.Expr_ -> Names.Tracker (TOpt.Expr Name)
optimizeExpr kernelEnv annotations exprTypes exprVars home cycle region tipe tvar expr =
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
                Names.pure (TOpt.VarCycle region home name { tipe = defType, tvar = tvar })

            else
                Names.lookupLocalType name
                    |> Names.map (\localType -> TOpt.TrackedVarLocal region name { tipe = localType, tvar = tvar })
                    |> catchMissing (Names.pure (TOpt.TrackedVarLocal region name { tipe = tipe, tvar = tvar }))

        Can.VarTopLevel varHome name ->
            let
                defType =
                    lookupAnnotationType name annotations
            in
            if EverySet.member identity name cycle then
                Names.pure (TOpt.VarCycle region varHome name { tipe = defType, tvar = tvar })

            else
                Names.registerGlobal region varHome name tipe tvar

        Can.VarKernel kernelPrefix kernelHome name ->
            -- Use the solver-inferred type (tipe) rather than the kernel env type.
            -- The kernel env stores a single type per kernel (first-usage-wins),
            -- which is wrong for polymorphic kernels used through aliases
            -- (e.g., String.fromFloat vs String.fromInt both alias String.fromNumber).
            Names.registerKernel kernelHome (TOpt.VarKernel region kernelPrefix kernelHome name { tipe = tipe, tvar = tvar })

        Can.VarForeign foreignHome name _ ->
            Names.registerGlobal region foreignHome name tipe tvar

        Can.VarCtor opts ctorHome name index _ ->
            Names.registerCtor region ctorHome (A.At region name) index opts tipe tvar

        Can.VarDebug debugHome name (Can.Forall _ debugType) ->
            -- Use the full function type from the annotation, not the instantiated type
            -- This is needed for the monomorphizer to correctly derive the kernel ABI
            Names.registerDebug name debugHome region debugType tvar

        Can.VarOperator _ opHome name (Can.Forall _ funcType) ->
            Names.registerGlobal region opHome name funcType tvar

        Can.Chr chr ->
            Names.registerKernel Name.utils (TOpt.Chr region chr { tipe = Can.TType ModuleName.basics "Char" [], tvar = tvar })

        Can.Str str ->
            Names.pure (TOpt.Str region str { tipe = Can.TType ModuleName.basics "String" [], tvar = tvar })

        Can.Int int ->
            -- Use the canonical type `tipe` computed by PostSolve / type inference
            Names.pure (TOpt.Int region int { tipe = tipe, tvar = tvar })

        Can.Float float ->
            Names.pure (TOpt.Float region float { tipe = tipe, tvar = tvar })

        Can.List entries ->
            Names.traverse (optimize kernelEnv annotations exprTypes exprVars home cycle << TCanBuild.toTypedExpr exprTypes exprVars) entries
                |> Names.andThen (\optEntries -> Names.registerKernel Name.list (TOpt.List region optEntries { tipe = tipe, tvar = tvar }))

        Can.Negate subExpr ->
            let
                negateType =
                    buildFunctionType [ tipe ] tipe
            in
            Names.registerGlobal region ModuleName.basics Name.negate negateType Nothing
                |> Names.andThen
                    (\func ->
                        optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars subExpr)
                            |> Names.map (\optSub -> TOpt.Call region func [ optSub ] { tipe = tipe, tvar = tvar })
                    )

        -- Binop: use the annotation from the constructor.
        --
        -- (&&) / (||) are rewritten to TOpt.If so that every downstream backend
        -- inherits correct short-circuit evaluation from the If codegen path.
        -- Strict `Basics.and` / `Basics.or` call sites (e.g. `List.foldl (&&)`)
        -- still reach the strict intrinsics via the non-Binop VarOperator path.
        Can.Binop _ binopHome name (Can.Forall _ funcType) left right ->
            let
                optimizeArg =
                    optimize kernelEnv annotations exprTypes exprVars home cycle << TCanBuild.toTypedExpr exprTypes exprVars

                lowerShortCircuit buildBranch =
                    optimizeArg left
                        |> Names.andThen
                            (\optLeft ->
                                optimizeArg right
                                    |> Names.map
                                        (\optRight ->
                                            let
                                                ( cond, thenE, elseE ) =
                                                    buildBranch optLeft optRight
                                            in
                                            TOpt.If [ ( cond, thenE ) ] elseE { tipe = tipe, tvar = tvar }
                                        )
                            )
            in
            if binopHome == ModuleName.basics && name == "and" then
                -- a && b  ==>  if a then b else False
                lowerShortCircuit
                    (\l r -> ( l, r, boolLit region False tvar ))

            else if binopHome == ModuleName.basics && name == "or" then
                -- a || b  ==>  if a then True else b
                lowerShortCircuit
                    (\l r -> ( l, boolLit region True tvar, r ))

            else
                Names.registerGlobal region binopHome name funcType Nothing
                    |> Names.andThen
                        (\optFunc ->
                            optimizeArg left
                                |> Names.andThen
                                    (\optLeft ->
                                        optimizeArg right
                                            |> Names.map
                                                (\optRight ->
                                                    TOpt.Call region optFunc [ optLeft, optRight ] { tipe = tipe, tvar = tvar }
                                                )
                                    )
                        )

        Can.Lambda args body ->
            destructArgs exprTypes exprVars args
                |> Names.andThen
                    (\( argNamesWithTypes, destructors ) ->
                        let
                            -- Root argument bindings (e.g., "_v0" for a tuple pattern)
                            argBindings =
                                List.map (\( A.At _ n, t ) -> ( n, t )) argNamesWithTypes

                            -- Extract bindings from destructors (e.g., "a", "b" from tuple (a, b))
                            destructorBindings =
                                List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructors

                            -- Combine all bindings so pattern variables are in scope
                            allBindings =
                                argBindings ++ destructorBindings

                            -- Compute body type by peeling off arg types from function type
                            bodyType =
                                peelFunctionType (List.length args) tipe
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars body))
                            |> Names.map
                                (\obody ->
                                    let
                                        wrappedBody =
                                            List.foldr (wrapDestruct bodyType) obody destructors
                                    in
                                    TOpt.TrackedFunction argNamesWithTypes wrappedBody { tipe = tipe, tvar = tvar }
                                )
                    )

        Can.Call func args ->
            let
                optimizeArg =
                    optimize kernelEnv annotations exprTypes exprVars home cycle << TCanBuild.toTypedExpr exprTypes exprVars
            in
            optimizeArg func
                |> Names.andThen
                    (\optFunc ->
                        Names.traverse optimizeArg args
                            |> Names.map (\optArgs -> TOpt.Call region optFunc optArgs { tipe = tipe, tvar = tvar })
                    )

        Can.If branches final ->
            let
                optimizeBranch : ( Can.Expr, Can.Expr ) -> Names.Tracker ( TOpt.Expr Name, TOpt.Expr Name )
                optimizeBranch ( condition, thenExpr ) =
                    let
                        optCond =
                            optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars condition)

                        optThen =
                            optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars thenExpr)
                    in
                    optCond
                        |> Names.andThen (\c -> optThen |> Names.map (\t -> ( c, t )))
            in
            Names.traverse optimizeBranch branches
                |> Names.andThen
                    (\optBranches ->
                        optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars final)
                            |> Names.map (\optFinal -> TOpt.If optBranches optFinal { tipe = tipe, tvar = tvar })
                    )

        Can.Let def body ->
            -- Add the let-bound variable to scope BEFORE optimizing the body
            let
                ( defName, defType ) =
                    getDefNameAndType exprTypes def

                defNodeTvar =
                    findVarLocalTvar defName exprVars body
            in
            Names.withVarTypes [ ( defName, defType ) ]
                (optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars body))
                |> Names.andThen (optimizeDef kernelEnv annotations exprTypes exprVars home cycle def tipe defNodeTvar)

        Can.LetRec defs body ->
            -- For LetRec, all definitions are mutually recursive, so add all names to scope
            let
                defBindings =
                    List.map (getDefNameAndType exprTypes) defs
            in
            case defs of
                [ def ] ->
                    Names.withVarTypes defBindings
                        (optimizePotentialTailCallDef kernelEnv annotations exprTypes exprVars home cycle def)
                        |> Names.andThen
                            (\tailCallDef ->
                                Names.withVarTypes defBindings
                                    (optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars body))
                                    |> Names.map (\obody -> TOpt.Let tailCallDef obody { tipe = tipe, tvar = tvar })
                            )

                _ ->
                    Names.withVarTypes defBindings
                        (List.foldl
                            (\def bod ->
                                Names.andThen (optimizeDef kernelEnv annotations exprTypes exprVars home cycle def tipe Nothing) bod
                            )
                            (optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars body))
                            defs
                        )

        Can.LetDestruct pattern boundExpr body ->
            destruct exprTypes exprVars pattern
                |> Names.andThen
                    (\( ( A.At nameRegion name, patternType ), destructs ) ->
                        optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars boundExpr)
                            |> Names.andThen
                                (\oBoundExpr ->
                                    let
                                        -- Add pattern bindings to scope
                                        destructorBindings =
                                            List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructs

                                        allBindings =
                                            ( name, patternType ) :: destructorBindings
                                    in
                                    Names.withVarTypes allBindings
                                        (optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars body))
                                        |> Names.map
                                            (\obody ->
                                                let
                                                    boundExprType =
                                                        TOpt.typeOf oBoundExpr
                                                in
                                                TOpt.Let
                                                    (TOpt.Def nameRegion name oBoundExpr boundExprType)
                                                    (List.foldr (wrapDestruct tipe) obody destructs)
                                                    { tipe = tipe, tvar = tvar }
                                            )
                                )
                    )

        Can.Case scrutinee branches ->
            let
                optimizeBranch : Name -> Can.CaseBranch -> Names.Tracker ( Can.Pattern, TOpt.Expr Name )
                optimizeBranch root (Can.CaseBranch pattern branch) =
                    destructCase exprTypes exprVars root pattern
                        |> Names.andThen
                            (\destructors ->
                                let
                                    -- Extract bindings from destructors for scope
                                    destructorBindings =
                                        List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructors
                                in
                                Names.withVarTypes destructorBindings
                                    (optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars branch))
                                    |> Names.map
                                        (\obranch ->
                                            ( pattern, List.foldr (wrapDestruct tipe) obranch destructors )
                                        )
                            )

                optimizeAsExpr : Can.Expr -> Names.Tracker (TOpt.Expr Name)
                optimizeAsExpr can =
                    optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars can)
            in
            -- Try the `case compare a b of LT/EQ/GT` rewrite first; fall back
            -- to the generic decision-tree path when the scrutinee or branches
            -- don't fit the shape (see matchCompareCall / matchOrderBranches).
            case ( matchCompareCall scrutinee, matchOrderBranches branches ) of
                ( Just ( a, b ), Just ( ltBody, eqBody, gtBody ) ) ->
                    applyCompareToOrderRewrite optimizeAsExpr optimizeAsExpr exprTypes region tipe tvar a b ltBody eqBody gtBody

                _ ->
                    Names.generate
                        |> Names.andThen
                            (\temp ->
                                optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars scrutinee)
                                    |> Names.andThen
                                        (\optScrutinee ->
                                            case optScrutinee of
                                                TOpt.VarLocal root _ ->
                                                    Names.traverse (optimizeBranch root) branches
                                                        |> Names.map (\optBranches -> Case.optimize temp root optBranches tipe tvar)

                                                TOpt.TrackedVarLocal _ root _ ->
                                                    Names.traverse (optimizeBranch root) branches
                                                        |> Names.map (\optBranches -> Case.optimize temp root optBranches tipe tvar)

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
                                                                    (Case.optimize temp temp optBranches tipe tvar)
                                                                    { tipe = tipe, tvar = tvar }
                                                            )
                                        )
                            )

        Can.Accessor field ->
            Names.registerField field (TOpt.Accessor region field { tipe = tipe, tvar = tvar })

        Can.Access recordExpr (A.At _ field) ->
            optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars recordExpr)
                |> Names.andThen
                    (\optRecord ->
                        Names.registerField field (TOpt.Access optRecord region field { tipe = tipe, tvar = tvar })
                    )

        Can.Update recordExpr fieldUpdates ->
            let
                optimizeFieldUpdate : ( A.Located Name, Can.FieldUpdate ) -> Names.Tracker ( A.Located Name, TOpt.Expr Name )
                optimizeFieldUpdate ( locName, Can.FieldUpdate _ fieldExpr ) =
                    optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars fieldExpr)
                        |> Names.map (\optExpr -> ( locName, optExpr ))

                fieldUpdateList =
                    Data.Map.toList A.compareLocated fieldUpdates
            in
            optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars recordExpr)
                |> Names.andThen
                    (\optRecord ->
                        Names.traverse optimizeFieldUpdate fieldUpdateList
                            |> Names.andThen
                                (\optUpdates ->
                                    let
                                        optUpdatesDict =
                                            Data.Map.fromList A.toValue optUpdates
                                    in
                                    Names.registerFieldDict (Utils.dictMapKeys A.compareLocated A.toValue fieldUpdates)
                                        (TOpt.Update region optRecord optUpdatesDict { tipe = tipe, tvar = tvar })
                                )
                    )

        Can.Record fields ->
            let
                optimizeField : ( A.Located Name, Can.Expr ) -> Names.Tracker ( A.Located Name, TOpt.Expr Name )
                optimizeField ( locName, fieldExpr ) =
                    optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars fieldExpr)
                        |> Names.map (\optExpr -> ( locName, optExpr ))

                fieldList : List ( A.Located Name, Can.Expr )
                fieldList =
                    Data.Map.toList A.compareLocated fields
            in
            Names.traverse optimizeField fieldList
                |> Names.andThen
                    (\optFields ->
                        let
                            optFieldsDict =
                                Data.Map.fromList A.toValue optFields
                        in
                        Names.registerFieldDict (Utils.dictMapKeys A.compareLocated A.toValue fields) (TOpt.TrackedRecord region optFieldsDict { tipe = tipe, tvar = tvar })
                    )

        Can.Unit ->
            Names.registerKernel Name.utils (TOpt.Unit { tipe = Can.TUnit, tvar = tvar })

        Can.Tuple a b cs ->
            let
                optimizeArg =
                    optimize kernelEnv annotations exprTypes exprVars home cycle << TCanBuild.toTypedExpr exprTypes exprVars
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
                                                Names.registerKernel Name.utils (TOpt.Tuple region optA optB optCs { tipe = tipe, tvar = tvar })
                                            )
                                )
                    )

        Can.Shader src (Shader.Types attributes uniforms _) ->
            Names.pure (TOpt.Shader src (EverySet.fromList identity (Data.Map.keys compare attributes)) (EverySet.fromList identity (Data.Map.keys compare uniforms)) { tipe = tipe, tvar = tvar })


{-| Catch a missing local type error and use a fallback.
-}
catchMissing : Names.Tracker a -> Names.Tracker a -> Names.Tracker a
catchMissing _ tracker =
    -- In a proper implementation, we'd catch the error
    -- For now, just use the tracker
    tracker


{-| Look up the type of a top-level definition from annotations.
-}
lookupAnnotationType : Name -> Annotations -> Can.Type Name
lookupAnnotationType name annotations =
    case Dict.get name annotations of
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
    -> ExprVars
    -> IO.Canonical
    -> Cycle
    -> Name
    -> List ( A.Located Name, Can.Type Name )
    -> Can.Type Name
    -> TCan.Expr
    -> Names.Tracker (TOpt.Expr Name)
optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (A.At region texpr) =
    case texpr of
        TCan.TypedExpr { expr, tipe, tvar } ->
            optimizeTailExpr kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType region tipe tvar expr


optimizeTailExpr :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> ExprVars
    -> IO.Canonical
    -> Cycle
    -> Name
    -> List ( A.Located Name, Can.Type Name )
    -> Can.Type Name
    -> A.Region
    -> Can.Type Name
    -> Maybe IO.Variable
    -> Can.Expr_
    -> Names.Tracker (TOpt.Expr Name)
optimizeTailExpr kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType region tipe tvar expr =
    case expr of
        Can.Call func callArgs ->
            let
                optimizeArg =
                    optimize kernelEnv annotations exprTypes exprVars home cycle << TCanBuild.toTypedExpr exprTypes exprVars
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
                                    Names.pure (TOpt.TailCall rootName pairs { tipe = resultType, tvar = tvar })

                                Index.LengthMismatch _ _ ->
                                    optimizeArg func
                                        |> Names.map (\ofunc -> TOpt.Call region ofunc oargs { tipe = tipe, tvar = tvar })

                        else
                            optimizeArg func
                                |> Names.map (\ofunc -> TOpt.Call region ofunc oargs { tipe = tipe, tvar = tvar })
                    )

        Can.If branches final ->
            let
                optimizeBranch ( condition, branch ) =
                    optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars condition)
                        |> Names.andThen
                            (\optCond ->
                                optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars branch)
                                    |> Names.map (\optBranch -> ( optCond, optBranch ))
                            )
            in
            Names.traverse optimizeBranch branches
                |> Names.andThen
                    (\optBranches ->
                        optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars final)
                            |> Names.map (\optFinal -> TOpt.If optBranches optFinal { tipe = tipe, tvar = tvar })
                    )

        Can.Let def body ->
            -- Add the let-bound variable to scope BEFORE optimizing the body
            let
                ( defName, defType ) =
                    getDefNameAndType exprTypes def

                defNodeTvar =
                    findVarLocalTvar defName exprVars body
            in
            Names.withVarTypes [ ( defName, defType ) ]
                (optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars body))
                |> Names.andThen (optimizeDef kernelEnv annotations exprTypes exprVars home cycle def tipe defNodeTvar)

        Can.LetRec defs body ->
            -- For LetRec, all definitions are mutually recursive, so add all names to scope
            let
                defBindings =
                    List.map (getDefNameAndType exprTypes) defs
            in
            case defs of
                [ def ] ->
                    Names.withVarTypes defBindings
                        (optimizePotentialTailCallDef kernelEnv annotations exprTypes exprVars home cycle def)
                        |> Names.andThen
                            (\tailCallDef ->
                                Names.withVarTypes defBindings
                                    (optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars body))
                                    |> Names.map (\obody -> TOpt.Let tailCallDef obody { tipe = tipe, tvar = tvar })
                            )

                _ ->
                    Names.withVarTypes defBindings
                        (List.foldl
                            (\def bod ->
                                Names.andThen (optimizeDef kernelEnv annotations exprTypes exprVars home cycle def tipe Nothing) bod
                            )
                            (optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars body))
                            defs
                        )

        Can.LetDestruct pattern boundExpr body ->
            destruct exprTypes exprVars pattern
                |> Names.andThen
                    (\( ( A.At nameRegion name, patternType ), destructs ) ->
                        optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars boundExpr)
                            |> Names.andThen
                                (\oBoundExpr ->
                                    let
                                        destructorBindings =
                                            List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructs

                                        allBindings =
                                            ( name, patternType ) :: destructorBindings
                                    in
                                    Names.withVarTypes allBindings
                                        (optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars body))
                                        |> Names.map
                                            (\obody ->
                                                let
                                                    boundExprType =
                                                        TOpt.typeOf oBoundExpr
                                                in
                                                TOpt.Let
                                                    (TOpt.Def nameRegion name oBoundExpr boundExprType)
                                                    (List.foldr (wrapDestruct tipe) obody destructs)
                                                    { tipe = tipe, tvar = tvar }
                                            )
                                )
                    )

        Can.Case scrutinee branches ->
            let
                optimizeBranch root (Can.CaseBranch pattern branch) =
                    destructCase exprTypes exprVars root pattern
                        |> Names.andThen
                            (\destructors ->
                                let
                                    destructorBindings =
                                        List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructors
                                in
                                Names.withVarTypes destructorBindings
                                    (optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars branch))
                                    |> Names.map
                                        (\obranch ->
                                            ( pattern, List.foldr (wrapDestruct tipe) obranch destructors )
                                        )
                            )

                optimizeBranchTail : Can.Expr -> Names.Tracker (TOpt.Expr Name)
                optimizeBranchTail can =
                    optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars can)

                optimizeArgExpr : Can.Expr -> Names.Tracker (TOpt.Expr Name)
                optimizeArgExpr can =
                    optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars can)
            in
            -- Same `case compare a b of LT/EQ/GT` rewrite as the non-tail
            -- arm above; branch bodies stay tail-position so TCO inside them
            -- is preserved.
            case ( matchCompareCall scrutinee, matchOrderBranches branches ) of
                ( Just ( a, b ), Just ( ltBody, eqBody, gtBody ) ) ->
                    applyCompareToOrderRewrite optimizeBranchTail optimizeArgExpr exprTypes region tipe tvar a b ltBody eqBody gtBody

                _ ->
                    Names.generate
                        |> Names.andThen
                            (\temp ->
                                optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars scrutinee)
                                    |> Names.andThen
                                        (\optScrutinee ->
                                            case optScrutinee of
                                                TOpt.VarLocal root _ ->
                                                    Names.traverse (optimizeBranch root) branches
                                                        |> Names.map (\optBranches -> Case.optimize temp root optBranches tipe tvar)

                                                TOpt.TrackedVarLocal _ root _ ->
                                                    Names.traverse (optimizeBranch root) branches
                                                        |> Names.map (\optBranches -> Case.optimize temp root optBranches tipe tvar)

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
                                                                    (Case.optimize temp temp optBranches tipe tvar)
                                                                    { tipe = tipe, tvar = tvar }
                                                            )
                                        )
                            )

        -- For other expressions, use regular optimization (not in tail position)
        _ ->
            optimizeExpr kernelEnv annotations exprTypes exprVars home cycle region tipe tvar expr



-- ====== LET DEFINITIONS ======


{-| Extract the name and type of a definition for scope management.

For TypedDef, builds the function type from explicit arg types and result type.
For Def, looks up pattern and expression types from exprTypes.

-}
getDefNameAndType : ExprTypes -> Can.Def -> ( Name, Can.Type Name )
getDefNameAndType exprTypes def =
    case def of
        Can.Def (A.At _ name) args (A.At _ bodyInfo) ->
            let
                -- Get argument types by looking up each pattern's type
                argTypes =
                    List.map
                        (\(A.At _ patInfo) ->
                            case Array.get patInfo.id exprTypes |> Maybe.andThen identity of
                                Just t ->
                                    t

                                Nothing ->
                                    Utils.Crash.crash "Expression.extractDefNameAndType: arg type"
                        )
                        args

                -- Get body type
                bodyType =
                    case Array.get bodyInfo.id exprTypes |> Maybe.andThen identity of
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
    -> ExprVars
    -> IO.Canonical
    -> Cycle
    -> Can.Def
    -> Can.Type Name
    -> Maybe IO.Variable
    -> TOpt.Expr Name
    -> Names.Tracker (TOpt.Expr Name)
optimizeDef kernelEnv annotations exprTypes exprVars home cycle def resultType defNodeTvar body =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizeDefHelp kernelEnv annotations exprTypes exprVars home cycle region name args expr resultType defNodeTvar body

        Can.TypedDef (A.At region name) _ typedArgs expr _ ->
            optimizeDefHelp kernelEnv annotations exprTypes exprVars home cycle region name (List.map Tuple.first typedArgs) expr resultType defNodeTvar body


optimizeDefHelp :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> ExprVars
    -> IO.Canonical
    -> Cycle
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> Can.Expr
    -> Can.Type Name
    -> Maybe IO.Variable
    -> TOpt.Expr Name
    -> Names.Tracker (TOpt.Expr Name)
optimizeDefHelp kernelEnv annotations exprTypes exprVars home cycle region name args expr resultType defNodeTvar body =
    let
        -- Extract the definition body's tvar from exprVars
        defBodyTvar : Maybe IO.Variable
        defBodyTvar =
            Array.get (A.toValue expr).id exprVars |> Maybe.andThen identity

        -- Resolve the function tvar with cascading fallbacks:
        --   1. Caller-provided tvar (from continuation-body scan for non-recursive let)
        --   2. Self-call scan of def RHS (for multi-def LetRec with direct self-recursion)
        --   3. defBodyTvar (body/return type — last resort)
        funcTvar : Maybe IO.Variable
        funcTvar =
            case defNodeTvar of
                Just _ ->
                    defNodeTvar

                Nothing ->
                    case findVarLocalTvar name exprVars expr of
                        Just v ->
                            Just v

                        Nothing ->
                            defBodyTvar

        -- The Let expression's tvar is the tvar of the continuation body
        letTvar : Maybe IO.Variable
        letTvar =
            TOpt.tvarOf body
    in
    case args of
        [] ->
            optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars expr)
                |> Names.map
                    (\oexpr ->
                        let
                            exprType =
                                TOpt.typeOf oexpr
                        in
                        TOpt.Let (TOpt.Def region name oexpr exprType) body { tipe = resultType, tvar = letTvar }
                    )

        _ ->
            -- Function definition: process args first to get bindings, then optimize body with args in scope
            destructArgs exprTypes exprVars args
                |> Names.andThen
                    (\( argNamesWithTypes, destructors ) ->
                        let
                            -- Root argument bindings (e.g., "_v0" for a tuple pattern)
                            argBindings =
                                List.map (\( A.At _ n, t ) -> ( n, t )) argNamesWithTypes

                            -- Extract bindings from destructors (e.g., "a", "b" from tuple (a, b))
                            destructorBindings =
                                List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructors

                            -- Combine all bindings so pattern variables are in scope
                            allBindings =
                                argBindings ++ destructorBindings
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars expr))
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
                                            TOpt.TrackedFunction argNamesWithTypes wrappedBody { tipe = funcType, tvar = funcTvar }
                                    in
                                    TOpt.Let (TOpt.Def region name ofunc funcType) body { tipe = resultType, tvar = letTvar }
                                )
                    )


{-| Optimize a potentially tail-recursive definition from a Can.Def.
For LetRec with a single definition.
-}
optimizePotentialTailCallDef :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> ExprVars
    -> IO.Canonical
    -> Cycle
    -> Can.Def
    -> Names.Tracker (TOpt.Def Name)
optimizePotentialTailCallDef kernelEnv annotations exprTypes exprVars home cycle def =
    case def of
        Can.Def (A.At region name) args body ->
            let
                ( _, defType ) =
                    getDefNameAndType exprTypes def

                localAnnotationVars =
                    case findVarLocalTvar name exprVars body of
                        Just v ->
                            Dict.singleton name v

                        Nothing ->
                            Dict.empty
            in
            optimizePotentialTailCall kernelEnv annotations exprTypes exprVars home cycle region name args (TCanBuild.toTypedExpr exprTypes exprVars body) defType localAnnotationVars

        Can.TypedDef (A.At region name) _ typedArgs body defType ->
            let
                localAnnotationVars =
                    case findVarLocalTvar name exprVars body of
                        Just v ->
                            Dict.singleton name v

                        Nothing ->
                            Dict.empty
            in
            optimizePotentialTailCall kernelEnv annotations exprTypes exprVars home cycle region name (List.map Tuple.first typedArgs) (TCanBuild.toTypedExpr exprTypes exprVars body) defType localAnnotationVars



-- ====== DEFINITIONS ======


{-| Optimize a potentially tail-recursive definition.
-}
optimizePotentialTailCall :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> ExprVars
    -> IO.Canonical
    -> Cycle
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> TCan.Expr
    -> Can.Type Name
    -> Dict Name IO.Variable
    -> Names.Tracker (TOpt.Def Name)
optimizePotentialTailCall kernelEnv annotations exprTypes exprVars home cycle region name args body defType annotationVars =
    let
        -- Extract the body's tvar from the TCan.Expr
        bodyTvar : Maybe IO.Variable
        bodyTvar =
            case A.toValue body of
                TCan.TypedExpr info ->
                    info.tvar

        -- For function definitions, look up the annotation-level solver variable
        -- from the solver's Env to get the full function type variable.
        nodeTvar : Maybe IO.Variable
        nodeTvar =
            case Dict.get name annotationVars of
                Just var ->
                    Just var

                Nothing ->
                    bodyTvar
    in
    destructArgs exprTypes exprVars args
        |> Names.andThen
            (\( argNamesWithTypes, destructors ) ->
                let
                    -- Root argument bindings (e.g., "_v0" for a tuple pattern)
                    argBindings =
                        List.map (\( A.At _ n, t ) -> ( n, t )) argNamesWithTypes

                    -- Extract bindings from destructors (e.g., "a", "b" from tuple (a, b))
                    destructorBindings =
                        List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructors

                    -- Combine all bindings so pattern variables are in scope
                    allBindings =
                        argBindings ++ destructorBindings

                    bodyType =
                        peelFunctionType (List.length args) defType
                in
                Names.withVarTypes allBindings
                    (optimizeTail kernelEnv annotations exprTypes exprVars home cycle name argNamesWithTypes bodyType body)
                    |> Names.map
                        (\obody ->
                            let
                                wrappedBody =
                                    List.foldr (wrapDestruct bodyType) obody destructors
                            in
                            if hasTailCall name obody then
                                TOpt.TailDef region name argNamesWithTypes wrappedBody defType nodeTvar

                            else
                                TOpt.Def region name (TOpt.TrackedFunction argNamesWithTypes wrappedBody { tipe = defType, tvar = nodeTvar }) defType
                        )
            )


{-| Check if an expression contains a tail call to the given function.
-}
hasTailCall : Name -> TOpt.Expr Name -> Bool
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
decidecHasTailCall : Name -> TOpt.Decider (TOpt.Choice Name) -> Bool
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
wrapDestruct : Can.Type Name -> TOpt.Destructor Name -> TOpt.Expr Name -> TOpt.Expr Name
wrapDestruct bodyType destructor expr =
    TOpt.Destruct destructor expr { tipe = bodyType, tvar = TOpt.tvarOf expr }



-- ====== DESTRUCTURING ======


{-| Look up a pattern's type from the exprTypes dictionary.
Returns Complete if found, ToSolve with location info if not found.
Negative IDs are synthetic patterns that won't have types.
-}
lookupPatternType : ExprTypes -> Int -> String -> Can.Type Name
lookupPatternType exprTypes patId location =
    if patId < 0 then
        -- Synthetic pattern (negative ID), no type available
        Utils.Crash.crash (location ++ ": synthetic")

    else
        case Array.get patId exprTypes |> Maybe.andThen identity of
            Just t ->
                t

            Nothing ->
                Utils.Crash.crash (location ++ ": not in exprTypes")


{-| Look up a pattern's type variable from the exprVars dictionary.
Returns Nothing for synthetic patterns (negative IDs).
-}
lookupPatternVar : ExprVars -> Int -> Maybe IO.Variable
lookupPatternVar exprVars patId =
    if patId < 0 then
        Nothing

    else
        Array.get patId exprVars |> Maybe.andThen identity


{-| Build a Meta record for a destructor, combining type and optional type variable.
-}
makeDestructorMeta : ExprTypes -> ExprVars -> Int -> Can.Type Name -> TOpt.Meta Name
makeDestructorMeta _ exprVars patId tipe =
    { tipe = tipe, tvar = lookupPatternVar exprVars patId }


{-| Converts a list of function argument patterns into argument names with types and destructuring operations.
-}
destructArgs : ExprTypes -> ExprVars -> List Can.Pattern -> Names.Tracker ( List ( A.Located Name, Can.Type Name ), List (TOpt.Destructor Name) )
destructArgs exprTypes exprVars args =
    Names.traverse (destruct exprTypes exprVars) args
        |> Names.map List.unzip
        |> Names.map
            (\( argNamesWithTypes, destructorLists ) ->
                ( argNamesWithTypes, List.concat destructorLists )
            )


destruct : ExprTypes -> ExprVars -> Can.Pattern -> Names.Tracker ( ( A.Located Name, Can.Type Name ), List (TOpt.Destructor Name) )
destruct exprTypes exprVars ((A.At region patternInfo) as pattern) =
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
            destructHelp exprTypes exprVars (TOpt.Root name) subPattern []
                |> Names.map (\revDs -> ( ( A.At region name, patType ), List.reverse revDs ))

        _ ->
            Names.generate
                |> Names.andThen
                    (\name ->
                        let
                            patType =
                                lookupPatternType exprTypes patternInfo.id "Expression.destruct: generated"
                        in
                        destructHelp exprTypes exprVars (TOpt.Root name) pattern []
                            |> Names.map
                                (\revDs ->
                                    ( ( A.At region name, patType ), List.reverse revDs )
                                )
                    )


destructHelp : ExprTypes -> ExprVars -> TOpt.Path -> Can.Pattern -> List (TOpt.Destructor Name) -> Names.Tracker (List (TOpt.Destructor Name))
destructHelp exprTypes exprVars path pattern revDs =
    destructHelpWithType exprTypes exprVars Nothing Nothing path pattern revDs


{-| Internal helper that also threads parent pattern ID for synthetic patterns.
-}
destructHelpWithParent : ExprTypes -> ExprVars -> Int -> TOpt.Path -> Can.Pattern -> List (TOpt.Destructor Name) -> Names.Tracker (List (TOpt.Destructor Name))
destructHelpWithParent exprTypes exprVars parentPatId path pattern revDs =
    destructHelpWithType exprTypes exprVars (Just parentPatId) Nothing path pattern revDs


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
destructHelpWithType : ExprTypes -> ExprVars -> Maybe Int -> Maybe (Can.Type Name) -> TOpt.Path -> Can.Pattern -> List (TOpt.Destructor Name) -> Names.Tracker (List (TOpt.Destructor Name))
destructHelpWithType exprTypes exprVars maybeParentPatId maybeType path (A.At region patternInfo) revDs =
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
            Names.pure (TOpt.Destructor name path (makeDestructorMeta exprTypes exprVars effectivePatId varType) :: revDs)

        Can.PRecord fields ->
            let
                -- For record fields, we need to look up each field's type from the pattern
                -- The pattern itself has a record type, but we need to extract field types
                toDestruct : Name -> TOpt.Destructor Name
                toDestruct name =
                    -- Try to get record field type from pattern's type
                    let
                        fieldType =
                            case Maybe.map Type.iteratedDealias (Array.get effectivePatId exprTypes |> Maybe.andThen identity) of
                                Just (Can.TRecord fieldDict _) ->
                                    case Dict.get name fieldDict of
                                        Just (Can.FieldType _ t) ->
                                            t

                                        Nothing ->
                                            Utils.Crash.crash ("Expression.destructHelpWithType: PRecord field " ++ name ++ " not in type")

                                _ ->
                                    lookupPatternType exprTypes effectivePatId ("Expression.destructHelpWithType: PRecord " ++ name)
                    in
                    TOpt.Destructor name (TOpt.Field name path) { tipe = fieldType, tvar = Nothing }
            in
            Names.registerFieldList fields (List.map toDestruct fields ++ revDs)

        Can.PAlias subPattern name ->
            let
                aliasType =
                    lookupPatternType exprTypes effectivePatId "Expression.destructHelpWithType: PAlias"
            in
            (TOpt.Destructor name path (makeDestructorMeta exprTypes exprVars effectivePatId aliasType) :: revDs) |> destructHelp exprTypes exprVars (TOpt.Root name) subPattern

        Can.PUnit ->
            Names.pure revDs

        Can.PTuple a b [] ->
            destructTwo exprTypes exprVars effectivePatId TOpt.HintTuple2 path a b revDs

        Can.PTuple a b [ c ] ->
            case path of
                TOpt.Root _ ->
                    destructHelp exprTypes exprVars (TOpt.Index Index.first TOpt.HintTuple3 path) a revDs
                        |> Names.andThen (destructHelp exprTypes exprVars (TOpt.Index Index.second TOpt.HintTuple3 path) b)
                        |> Names.andThen (destructHelp exprTypes exprVars (TOpt.Index Index.third TOpt.HintTuple3 path) c)

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
                                destructHelp exprTypes exprVars (TOpt.Index Index.first TOpt.HintTuple3 newRoot) a (TOpt.Destructor name path (makeDestructorMeta exprTypes exprVars effectivePatId genType) :: revDs)
                                    |> Names.andThen (destructHelp exprTypes exprVars (TOpt.Index Index.second TOpt.HintTuple3 newRoot) b)
                                    |> Names.andThen (destructHelp exprTypes exprVars (TOpt.Index Index.third TOpt.HintTuple3 newRoot) c)
                            )

        Can.PTuple _ _ _ ->
            -- Elm only supports tuples up to size 3 (handled by PTuple2/PTuple3 above).
            -- This case should never be reached for valid Elm code.
            Utils.Crash.crash "Expression.destructHelpWithType: PTuple with more than 3 elements is not supported in Elm"

        Can.PList [] ->
            Names.pure revDs

        Can.PList (hd :: tl) ->
            -- Use placeholder ID (-1) for synthesized patterns, but pass parent pattern ID (effectivePatId)
            destructTwo exprTypes exprVars effectivePatId TOpt.HintList path hd (A.At region { id = -1, node = Can.PList tl }) revDs

        Can.PCons hd tl ->
            destructTwo exprTypes exprVars effectivePatId TOpt.HintList path hd tl revDs

        Can.PChr _ ->
            Names.pure revDs

        Can.PStr _ _ ->
            Names.pure revDs

        Can.PInt _ ->
            Names.pure revDs

        Can.PBool _ _ ->
            Names.pure revDs

        Can.PCtor { union, name, args } ->
            case args of
                [ Can.PatternCtorArg _ _ arg ] ->
                    let
                        (Can.Union unionData) =
                            union

                        -- Look up the inferred type from exprTypes instead of using argType
                        patternId =
                            (A.toValue arg).id

                        actualType =
                            case Array.get patternId exprTypes |> Maybe.andThen identity of
                                Just t ->
                                    Just t

                                Nothing ->
                                    Utils.Crash.crash
                                        ("destructHelpWithType PCtor singleton: Pattern ID "
                                            ++ String.fromInt patternId
                                            ++ " not found in exprTypes for constructor "
                                            ++ name
                                            ++ ". This is a compiler bug."
                                        )
                    in
                    case unionData.opts of
                        Can.Normal ->
                            destructHelpWithType exprTypes exprVars Nothing actualType (TOpt.Index Index.first (TOpt.HintCustom name) path) arg revDs

                        Can.Unbox ->
                            destructHelpWithType exprTypes exprVars Nothing actualType (TOpt.Unbox path) arg revDs

                        Can.Enum ->
                            destructHelpWithType exprTypes exprVars Nothing actualType (TOpt.Index Index.first (TOpt.HintCustom name) path) arg revDs

                _ ->
                    case path of
                        TOpt.Root _ ->
                            List.foldl (\arg -> Names.andThen (\revDs_ -> destructCtorArg exprTypes exprVars name path revDs_ arg))
                                (Names.pure revDs)
                                args

                        _ ->
                            Names.generate
                                |> Names.andThen
                                    (\genName ->
                                        let
                                            genType =
                                                lookupPatternType exprTypes effectivePatId "Expression.destructHelpWithType: PCtor gen"
                                        in
                                        List.foldl (\arg -> Names.andThen (\revDs_ -> destructCtorArg exprTypes exprVars name (TOpt.Root genName) revDs_ arg))
                                            (Names.pure (TOpt.Destructor genName path (makeDestructorMeta exprTypes exprVars effectivePatId genType) :: revDs))
                                            args
                                    )


destructTwo : ExprTypes -> ExprVars -> Int -> TOpt.ContainerHint -> TOpt.Path -> Can.Pattern -> Can.Pattern -> List (TOpt.Destructor Name) -> Names.Tracker (List (TOpt.Destructor Name))
destructTwo exprTypes exprVars parentPatId hint path a b revDs =
    case path of
        TOpt.Root _ ->
            -- Thread the parent pattern ID through for synthetic patterns
            destructHelpWithParent exprTypes exprVars parentPatId (TOpt.Index Index.first hint path) a revDs
                |> Names.andThen (destructHelpWithParent exprTypes exprVars parentPatId (TOpt.Index Index.second hint path) b)

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
                        destructHelpWithParent exprTypes exprVars parentPatId (TOpt.Index Index.first hint newRoot) a (TOpt.Destructor name path (makeDestructorMeta exprTypes exprVars parentPatId genType) :: revDs)
                            |> Names.andThen (destructHelpWithParent exprTypes exprVars parentPatId (TOpt.Index Index.second hint newRoot) b)
                    )


destructCtorArg : ExprTypes -> ExprVars -> Name -> TOpt.Path -> List (TOpt.Destructor Name) -> Can.PatternCtorArg -> Names.Tracker (List (TOpt.Destructor Name))
destructCtorArg exprTypes exprVars ctorName path revDs (Can.PatternCtorArg index _ arg) =
    let
        patternId =
            (A.toValue arg).id

        actualType =
            case Array.get patternId exprTypes |> Maybe.andThen identity of
                Just t ->
                    Just t

                Nothing ->
                    -- Pattern IDs from canonicalization must be in exprTypes.
                    -- If missing, this indicates a compiler bug in earlier phases.
                    Utils.Crash.crash
                        ("destructCtorArg: Pattern ID "
                            ++ String.fromInt patternId
                            ++ " not found in exprTypes for constructor "
                            ++ ctorName
                            ++ ". This is a compiler bug."
                        )
    in
    destructHelpWithType exprTypes exprVars Nothing actualType (TOpt.Index index (TOpt.HintCustom ctorName) path) arg revDs


{-| Destructure a case pattern into a list of destructors.
This is used when processing case branches.
-}
destructCase : ExprTypes -> ExprVars -> Name -> Can.Pattern -> Names.Tracker (List (TOpt.Destructor Name))
destructCase exprTypes exprVars rootName pattern =
    destructHelp exprTypes exprVars (TOpt.Root rootName) pattern []
        |> Names.map List.reverse
