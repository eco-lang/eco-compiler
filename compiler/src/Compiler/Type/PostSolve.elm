module Compiler.Type.PostSolve exposing (postSolve, NodeTypes)

{-| PostSolve phase for fixing Group B expression types and computing kernel types.

This phase runs after the type solver (`runWithIds`) and before `TypedCanonical.fromCanonical`.
It walks the canonical AST to:

1.  Fix "missing" types for Group B expressions (those with unconstrained synthetic vars)
2.  Compute kernel function types (`KernelTypeEnv`) via alias seeding and usage inference

The result is a fixed `nodeTypes` map where all expression IDs have meaningful types,
plus a `kernelEnv` for typed optimization.

@docs postSolve, NodeTypes

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Type.KernelTypes as KernelTypes
import Data.Map as Dict exposing (Dict)


{-| Node types mapping expression/pattern ID to canonical type.
-}
type alias NodeTypes =
    Dict Int Int Can.Type


{-| Run the post-solve phase on a canonical module.

Takes:

  - `annotations`: Top-level type annotations from type checking
  - `canonical`: The canonical module AST
  - `nodeTypes`: Expression/pattern types from the solver (Group B entries are unconstrained)

Returns:

  - `nodeTypes`: Fixed node types with Group B expressions properly typed
  - `kernelEnv`: Kernel function type environment for typed optimization

-}
postSolve :
    Dict String Name Can.Annotation
    -> Can.Module
    -> NodeTypes
    ->
        { nodeTypes : NodeTypes
        , kernelEnv : KernelTypes.KernelTypeEnv
        }
postSolve annotations (Can.Module canData) nodeTypes0 =
    let
        -- Phase 0: Seed kernel env from alias definitions
        kernel0 : KernelTypes.KernelTypeEnv
        kernel0 =
            seedKernelAliases annotations canData.decls

        -- Phase 1: Fix expression types + infer kernel types from usage
        ( nodeTypes1, kernel1 ) =
            postSolveDecls annotations canData.decls nodeTypes0 kernel0
    in
    { nodeTypes = nodeTypes1
    , kernelEnv = kernel1
    }



-- ====== PHASE 0: KERNEL ALIAS SEEDING ======


{-| Seed kernel type environment from alias definitions.

Scans declarations looking for zero-argument definitions whose bodies are
exactly `VarKernel` references. For each, extracts the type annotation
and inserts it into the kernel environment.

-}
seedKernelAliases :
    Dict String Name Can.Annotation
    -> Can.Decls
    -> KernelTypes.KernelTypeEnv
seedKernelAliases annotations decls =
    seedKernelAliasesHelp annotations decls Dict.empty


seedKernelAliasesHelp :
    Dict String Name Can.Annotation
    -> Can.Decls
    -> KernelTypes.KernelTypeEnv
    -> KernelTypes.KernelTypeEnv
seedKernelAliasesHelp annotations decls env =
    case decls of
        Can.Declare def rest ->
            seedKernelAliasesHelp annotations rest (checkDefForAlias annotations def env)

        Can.DeclareRec def defs rest ->
            let
                env1 =
                    checkDefForAlias annotations def env

                env2 =
                    List.foldl (\d e -> checkDefForAlias annotations d e) env1 defs
            in
            seedKernelAliasesHelp annotations rest env2

        Can.SaveTheEnvironment ->
            env


checkDefForAlias :
    Dict String Name Can.Annotation
    -> Can.Def
    -> KernelTypes.KernelTypeEnv
    -> KernelTypes.KernelTypeEnv
checkDefForAlias annotations def env =
    case def of
        Can.Def (A.At _ name) args body ->
            case args of
                [] ->
                    checkKernelAliasBody annotations name body env

                _ ->
                    env

        Can.TypedDef (A.At _ _) _ typedArgs body resultType ->
            case typedArgs of
                [] ->
                    -- For TypedDef with result type, we can use the result type directly
                    let
                        { node } =
                            A.toValue body
                    in
                    case node of
                        Can.VarKernel home kernelName ->
                            KernelTypes.insertFirstUsage home kernelName resultType env

                        _ ->
                            env

                _ ->
                    env


checkKernelAliasBody :
    Dict String Name Can.Annotation
    -> Name
    -> Can.Expr
    -> KernelTypes.KernelTypeEnv
    -> KernelTypes.KernelTypeEnv
checkKernelAliasBody annotations defName (A.At _ exprInfo) env =
    case exprInfo.node of
        Can.VarKernel home kernelName ->
            case Dict.get Basics.identity defName annotations of
                Just (Can.Forall _ tipe) ->
                    KernelTypes.insertFirstUsage home kernelName tipe env

                Nothing ->
                    env

        _ ->
            env



-- ====== PHASE 1: EXPRESSION TRAVERSAL ======


{-| Walk declarations, fixing expression types and inferring kernel types.
-}
postSolveDecls :
    Dict String Name Can.Annotation
    -> Can.Decls
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveDecls annotations decls nodeTypes0 kernel0 =
    case decls of
        Can.Declare def rest ->
            let
                ( nodeTypes1, kernel1 ) =
                    postSolveDef annotations def nodeTypes0 kernel0
            in
            postSolveDecls annotations rest nodeTypes1 kernel1

        Can.DeclareRec def defs rest ->
            let
                ( nodeTypes1, kernel1 ) =
                    postSolveDef annotations def nodeTypes0 kernel0

                ( nodeTypes2, kernel2 ) =
                    List.foldl
                        (\d ( nt, ke ) -> postSolveDef annotations d nt ke)
                        ( nodeTypes1, kernel1 )
                        defs
            in
            postSolveDecls annotations rest nodeTypes2 kernel2

        Can.SaveTheEnvironment ->
            ( nodeTypes0, kernel0 )


{-| Walk a definition, processing its body expression.
-}
postSolveDef :
    Dict String Name Can.Annotation
    -> Can.Def
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveDef annotations def nodeTypes0 kernel0 =
    case def of
        Can.Def _ args body ->
            let
                ( nodeTypes1, kernel1 ) =
                    postSolvePatterns args nodeTypes0 kernel0
            in
            postSolveExpr annotations body nodeTypes1 kernel1

        Can.TypedDef _ _ typedArgs body resultType ->
            case typedArgs of
                [] ->
                    -- Zero-arg typed def: if body is a VarKernel alias, use the
                    -- definition's result type directly. The kernel env may have the
                    -- wrong type when multiple aliases (fromFloat, fromInt) share a
                    -- polymorphic kernel (fromNumber).
                    let
                        bodyInfo =
                            A.toValue body
                    in
                    case bodyInfo.node of
                        Can.VarKernel _ _ ->
                            ( Dict.insert Basics.identity bodyInfo.id resultType nodeTypes0
                            , kernel0
                            )

                        _ ->
                            postSolveExpr annotations body nodeTypes0 kernel0

                _ ->
                    let
                        patterns =
                            List.map Tuple.first typedArgs

                        ( nodeTypes1, kernel1 ) =
                            postSolvePatterns patterns nodeTypes0 kernel0
                    in
                    postSolveExpr annotations body nodeTypes1 kernel1


{-| Walk a list of patterns, processing any nested expressions.
-}
postSolvePatterns :
    List Can.Pattern
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolvePatterns patterns nodeTypes0 kernel0 =
    List.foldl
        (\pat ( nt, ke ) -> postSolvePattern pat nt ke)
        ( nodeTypes0, kernel0 )
        patterns


{-| Process a single pattern (patterns don't contain expressions, but may have nested patterns).
-}
postSolvePattern :
    Can.Pattern
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolvePattern (A.At _ patInfo) nodeTypes0 kernel0 =
    case patInfo.node of
        Can.PAnything ->
            ( nodeTypes0, kernel0 )

        Can.PVar _ ->
            ( nodeTypes0, kernel0 )

        Can.PRecord _ ->
            ( nodeTypes0, kernel0 )

        Can.PAlias pat _ ->
            postSolvePattern pat nodeTypes0 kernel0

        Can.PUnit ->
            ( nodeTypes0, kernel0 )

        Can.PTuple a b cs ->
            let
                ( nt1, ke1 ) =
                    postSolvePattern a nodeTypes0 kernel0

                ( nt2, ke2 ) =
                    postSolvePattern b nt1 ke1
            in
            List.foldl
                (\p ( nt, ke ) -> postSolvePattern p nt ke)
                ( nt2, ke2 )
                cs

        Can.PList pats ->
            List.foldl
                (\p ( nt, ke ) -> postSolvePattern p nt ke)
                ( nodeTypes0, kernel0 )
                pats

        Can.PCons hd tl ->
            let
                ( nt1, ke1 ) =
                    postSolvePattern hd nodeTypes0 kernel0
            in
            postSolvePattern tl nt1 ke1

        Can.PBool _ _ ->
            ( nodeTypes0, kernel0 )

        Can.PChr _ ->
            ( nodeTypes0, kernel0 )

        Can.PStr _ _ ->
            ( nodeTypes0, kernel0 )

        Can.PInt _ ->
            ( nodeTypes0, kernel0 )

        Can.PCtor ctorData ->
            List.foldl
                (\(Can.PatternCtorArg _ _ pat) ( nt, ke ) ->
                    postSolvePattern pat nt ke
                )
                ( nodeTypes0, kernel0 )
                ctorData.args


{-| Main expression traversal.

For Group A expressions (Int, Negate, Binop, Call, If, Case, Access, Update):
we trust the solver's type and just recurse into children.

For Group B expressions: we compute the type structurally and write it to nodeTypes.

For VarKernel: we look up the type from kernelEnv.

For Call with VarKernel callee: we also infer the kernel type from usage.

-}
postSolveExpr :
    Dict String Name Can.Annotation
    -> Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveExpr annotations (A.At _ exprInfo) nodeTypes0 kernel0 =
    let
        exprId =
            exprInfo.id
    in
    case exprInfo.node of
        -- ====== GROUP A: Trust solver's type, just recurse into children ======
        Can.Int _ ->
            ( nodeTypes0, kernel0 )

        Can.Negate subExpr ->
            postSolveExpr annotations subExpr nodeTypes0 kernel0

        Can.Binop _ _ _ opAnnotation left right ->
            postSolveBinop annotations opAnnotation left right nodeTypes0 kernel0

        Can.Call func args ->
            postSolveCall annotations exprId func args nodeTypes0 kernel0

        Can.If branches final ->
            postSolveIf annotations branches final nodeTypes0 kernel0

        Can.Case scrutinee branches ->
            postSolveCase annotations exprId scrutinee branches nodeTypes0 kernel0

        Can.Access record _ ->
            postSolveExpr annotations record nodeTypes0 kernel0

        Can.Update record fields ->
            postSolveUpdate annotations record fields nodeTypes0 kernel0

        -- ====== VARKERNEL: Look up from kernelEnv ======
        Can.VarKernel home name ->
            case KernelTypes.lookup home name kernel0 of
                Just kernelType ->
                    -- Type known: update nodeTypes with the kernel type
                    let
                        nodeTypes1 =
                            Dict.insert Basics.identity exprId kernelType nodeTypes0
                    in
                    ( nodeTypes1, kernel0 )

                Nothing ->
                    -- Type not known yet: don't crash, leave nodeTypes unchanged.
                    -- The type may be inferred later if this is passed as an
                    -- argument to a kernel call (propagated from callee's type).
                    ( nodeTypes0, kernel0 )

        -- ====== GROUP B: Compute type structurally ======
        Can.Str _ ->
            let
                strType =
                    Can.TType ModuleName.string Name.string []

                nodeTypes1 =
                    Dict.insert Basics.identity exprId strType nodeTypes0
            in
            ( nodeTypes1, kernel0 )

        Can.Chr _ ->
            let
                chrType =
                    Can.TType ModuleName.char Name.char []

                nodeTypes1 =
                    Dict.insert Basics.identity exprId chrType nodeTypes0
            in
            ( nodeTypes1, kernel0 )

        Can.Float _ ->
            let
                floatType =
                    Can.TType ModuleName.basics Name.float []

                nodeTypes1 =
                    Dict.insert Basics.identity exprId floatType nodeTypes0
            in
            ( nodeTypes1, kernel0 )

        Can.Unit ->
            let
                nodeTypes1 =
                    Dict.insert Basics.identity exprId Can.TUnit nodeTypes0
            in
            ( nodeTypes1, kernel0 )

        Can.List elems ->
            postSolveList annotations exprId elems nodeTypes0 kernel0

        Can.Tuple a b cs ->
            postSolveTuple annotations exprId a b cs nodeTypes0 kernel0

        Can.Record fields ->
            postSolveRecord annotations exprId fields nodeTypes0 kernel0

        Can.Lambda args body ->
            postSolveLambda annotations exprId args body nodeTypes0 kernel0

        Can.Accessor field ->
            postSolveAccessor annotations exprId field nodeTypes0 kernel0

        Can.Let def body ->
            let
                ( nt1, ke1 ) =
                    postSolveDef annotations def nodeTypes0 kernel0

                ( nt2, ke2 ) =
                    postSolveExpr annotations body nt1 ke1
            in
            -- Let expression type is the body type
            postSolveLetType exprId body nt2 ke2

        Can.LetRec defs body ->
            let
                ( nt1, ke1 ) =
                    List.foldl
                        (\d ( nt, ke ) -> postSolveDef annotations d nt ke)
                        ( nodeTypes0, kernel0 )
                        defs

                ( nt2, ke2 ) =
                    postSolveExpr annotations body nt1 ke1
            in
            -- LetRec expression type is the body type
            postSolveLetType exprId body nt2 ke2

        Can.LetDestruct pat bound body ->
            let
                ( nt1, ke1 ) =
                    postSolvePattern pat nodeTypes0 kernel0

                ( nt2, ke2 ) =
                    postSolveExpr annotations bound nt1 ke1

                ( nt3, ke3 ) =
                    postSolveExpr annotations body nt2 ke2
            in
            -- LetDestruct expression type is the body type
            postSolveLetType exprId body nt3 ke3

        Can.Shader _ _ ->
            -- Keep solver's type for shaders
            ( nodeTypes0, kernel0 )

        -- Variables: trust solver's type
        Can.VarLocal _ ->
            ( nodeTypes0, kernel0 )

        Can.VarTopLevel _ _ ->
            ( nodeTypes0, kernel0 )

        Can.VarForeign _ _ _ ->
            ( nodeTypes0, kernel0 )

        Can.VarCtor _ _ _ _ _ ->
            ( nodeTypes0, kernel0 )

        Can.VarDebug _ _ _ ->
            ( nodeTypes0, kernel0 )

        Can.VarOperator _ _ _ _ ->
            ( nodeTypes0, kernel0 )


{-| Fix Let/LetRec/LetDestruct expression type to match body type.
-}
postSolveLetType :
    Int
    -> Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveLetType exprId body nodeTypes0 kernel0 =
    -- Check if solver already resolved the type for this let expression
    case Dict.get Basics.identity exprId nodeTypes0 of
        Just _ ->
            -- Solver already resolved the type, trust it
            ( nodeTypes0, kernel0 )

        Nothing ->
            -- No solver type available, compute from body
            let
                bodyType =
                    case body of
                        A.At _ info ->
                            Dict.get Basics.identity info.id nodeTypes0
                                |> Maybe.withDefault (Can.TVar "a")

                nodeTypes1 =
                    Dict.insert Basics.identity exprId bodyType nodeTypes0
            in
            ( nodeTypes1, kernel0 )


{-| Handle Call expressions with special logic for kernel usage inference.

IMPORTANT: When the callee is a VarKernel, we must NOT recurse into it first,
because we need to infer its type from the call before we can assign it.
We handle VarKernel specially: recurse into args only, infer the kernel type,
then update both kernelEnv and the VarKernel node's type in nodeTypes.

-}
postSolveCall :
    Dict String Name Can.Annotation
    -> Int
    -> Can.Expr
    -> List Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveCall annotations exprId func args nodeTypes0 kernel0 =
    -- Check if func is VarKernel BEFORE recursing
    case func of
        A.At _ funcInfo ->
            case funcInfo.node of
                Can.VarKernel home name ->
                    -- Direct kernel call: DON'T recurse into func (it's VarKernel)
                    -- Only recurse into args
                    let
                        ( nodeTypes1, kernel1 ) =
                            List.foldl
                                (\arg ( nt, ke ) -> postSolveExpr annotations arg nt ke)
                                ( nodeTypes0, kernel0 )
                                args

                        -- Get arg types
                        argTypes =
                            List.map
                                (\arg ->
                                    case arg of
                                        A.At _ info ->
                                            Dict.get Basics.identity info.id nodeTypes1
                                                |> Maybe.withDefault (Can.TVar "a")
                                )
                                args

                        -- The call's result type is already in nodeTypes from solver (Group A)
                        callResultType =
                            Dict.get Basics.identity exprId nodeTypes1
                                |> Maybe.withDefault (Can.TVar "result")

                        -- Build the full function type for this kernel
                        candidateType =
                            KernelTypes.buildFunctionType argTypes callResultType

                        -- Add to kernel env (first-usage-wins)
                        kernel2 =
                            KernelTypes.insertFirstUsage home name candidateType kernel1

                        -- Now update the VarKernel node's type in nodeTypes
                        -- Use the inferred type (or look up from kernel2 which now has it)
                        kernelNodeType =
                            case KernelTypes.lookup home name kernel2 of
                                Just t ->
                                    t

                                Nothing ->
                                    -- Should never happen since we just inserted it
                                    candidateType

                        nodeTypes2 =
                            Dict.insert Basics.identity funcInfo.id kernelNodeType nodeTypes1

                        -- Propagate types to VarKernel arguments:
                        -- Peel the callee's function type to get expected arg types,
                        -- then for each VarKernel arg, insert that type into kernelEnv.
                        ( inferredArgTypes, _ ) =
                            peelFunctionType kernelNodeType
                    in
                    propagateKernelArgTypes args inferredArgTypes nodeTypes2 kernel2

                Can.VarCtor _ _ _ _ ctorAnnotation ->
                    -- Constructor call: check if any args are VarKernel
                    -- If so, use the constructor's annotation to infer kernel types
                    if hasKernelArg args then
                        postSolveCallWithCtorKernelArgs annotations exprId ctorAnnotation func args nodeTypes0 kernel0

                    else
                        -- No kernel args; recurse normally
                        let
                            ( nodeTypes1, kernel1 ) =
                                postSolveExpr annotations func nodeTypes0 kernel0
                        in
                        List.foldl
                            (\arg ( nt, ke ) -> postSolveExpr annotations arg nt ke)
                            ( nodeTypes1, kernel1 )
                            args

                _ ->
                    -- Non-kernel, non-ctor callee: recurse into both func and args normally
                    let
                        ( nodeTypes1, kernel1 ) =
                            postSolveExpr annotations func nodeTypes0 kernel0
                    in
                    List.foldl
                        (\arg ( nt, ke ) -> postSolveExpr annotations arg nt ke)
                        ( nodeTypes1, kernel1 )
                        args


{-| Handle If expression (Group A - trust solver's type).
-}
postSolveIf :
    Dict String Name Can.Annotation
    -> List ( Can.Expr, Can.Expr )
    -> Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveIf annotations branches final nodeTypes0 kernel0 =
    let
        ( nt1, ke1 ) =
            List.foldl
                (\( cond, thenExpr ) ( nt, ke ) ->
                    let
                        ( nt2, ke2 ) =
                            postSolveExpr annotations cond nt ke
                    in
                    postSolveExpr annotations thenExpr nt2 ke2
                )
                ( nodeTypes0, kernel0 )
                branches
    in
    postSolveExpr annotations final nt1 ke1


{-| Handle Binop expression (Group A - trust solver's type).

Also infers kernel types for VarKernel expressions that appear as
operands to the binary operator. Uses the operator's annotation to
determine the expected types for left and right operands.

-}
postSolveBinop :
    Dict String Name Can.Annotation
    -> Can.Annotation
    -> Can.Expr
    -> Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveBinop annotations opAnnotation left right nodeTypes0 kernel0 =
    let
        -- First, recurse into left and right to process any nested expressions
        ( nt1, ke1 ) =
            postSolveExpr annotations left nodeTypes0 kernel0

        ( nt2, ke2 ) =
            postSolveExpr annotations right nt1 ke1

        -- Check if either operand is a VarKernel
        leftIsKernel =
            isKernelExpr left

        rightIsKernel =
            isKernelExpr right
    in
    if leftIsKernel || rightIsKernel then
        -- Extract expected types from the operator's annotation
        let
            (Can.Forall _ opType) =
                opAnnotation

            ( argTypes, _ ) =
                peelFunctionType opType

            -- Get expected types for left and right (first two args of binop)
            maybeLeftType =
                List.head argTypes

            maybeRightType =
                argTypes |> List.drop 1 |> List.head

            -- Infer kernel type for left if it's a VarKernel
            ( nt3, ke3 ) =
                case ( leftIsKernel, maybeLeftType ) of
                    ( True, Just expectedType ) ->
                        inferBinopKernelType left expectedType nt2 ke2

                    _ ->
                        ( nt2, ke2 )
        in
        case ( rightIsKernel, maybeRightType ) of
            ( True, Just expectedType ) ->
                inferBinopKernelType right expectedType nt3 ke3

            _ ->
                ( nt3, ke3 )

    else
        ( nt2, ke2 )


{-| Infer kernel type from a binop operand.

If the operand is a VarKernel that doesn't have a known type yet,
use the expected type (from the operator's annotation) to infer its type.

-}
inferBinopKernelType :
    Can.Expr
    -> Can.Type
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
inferBinopKernelType operand expectedType nodeTypes kernel =
    case operand of
        A.At _ exprInfo ->
            case exprInfo.node of
                Can.VarKernel home name ->
                    if KernelTypes.hasEntry home name kernel then
                        -- Already have a type for this kernel; don't override
                        ( nodeTypes, kernel )

                    else
                        -- Insert the inferred type for this kernel
                        let
                            ke2 =
                                KernelTypes.insertFirstUsage home name expectedType kernel

                            nt2 =
                                Dict.insert Basics.identity exprInfo.id expectedType nodeTypes
                        in
                        ( nt2, ke2 )

                _ ->
                    ( nodeTypes, kernel )


{-| Handle Case expression (Group A - trust solver's type).

Also infers kernel types for VarKernel expressions that appear directly
as case branch bodies. Since all branches must have the same type as the
case expression, a VarKernel branch body has the case's result type.

-}
postSolveCase :
    Dict String Name Can.Annotation
    -> Int
    -> Can.Expr
    -> List Can.CaseBranch
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveCase annotations caseExprId scrutinee branches nodeTypes0 kernel0 =
    let
        ( nt1, ke1 ) =
            postSolveExpr annotations scrutinee nodeTypes0 kernel0

        -- Get case result type (all branches have this type)
        caseResultType =
            Dict.get Basics.identity caseExprId nt1
                |> Maybe.withDefault (Can.TVar "a")

        stepBranch (Can.CaseBranch pat branchExpr) ( nt, ke ) =
            let
                ( nt2, ke2 ) =
                    postSolvePattern pat nt ke

                ( nt3, ke3 ) =
                    postSolveExpr annotations branchExpr nt2 ke2
            in
            -- Infer kernel type if branch body is VarKernel
            inferBranchKernelType branchExpr caseResultType nt3 ke3
    in
    List.foldl stepBranch ( nt1, ke1 ) branches


{-| Infer kernel type from a case branch body.

If the branch body is a VarKernel that doesn't have a known type yet,
use the expected type (from the case expression) to infer its type.

-}
inferBranchKernelType :
    Can.Expr
    -> Can.Type
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
inferBranchKernelType branchExpr expectedType nodeTypes kernel =
    case branchExpr of
        A.At _ exprInfo ->
            case exprInfo.node of
                Can.VarKernel home name ->
                    if KernelTypes.hasEntry home name kernel then
                        -- Already have a type for this kernel; don't override
                        ( nodeTypes, kernel )

                    else
                        -- Insert the inferred type for this kernel
                        let
                            ke2 =
                                KernelTypes.insertFirstUsage home name expectedType kernel

                            nt2 =
                                Dict.insert Basics.identity exprInfo.id expectedType nodeTypes
                        in
                        ( nt2, ke2 )

                _ ->
                    ( nodeTypes, kernel )


{-| Handle Update expression (Group A - trust solver's type).
-}
postSolveUpdate :
    Dict String Name Can.Annotation
    -> Can.Expr
    -> Dict String (A.Located Name) Can.FieldUpdate
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveUpdate annotations record fields nodeTypes0 kernel0 =
    let
        ( nt1, ke1 ) =
            postSolveExpr annotations record nodeTypes0 kernel0

        fieldList =
            Dict.toList A.compareLocated fields
    in
    List.foldl
        (\( _, Can.FieldUpdate _ fieldExpr ) ( nt, ke ) ->
            postSolveExpr annotations fieldExpr nt ke
        )
        ( nt1, ke1 )
        fieldList


{-| Handle List expression (Group B).
-}
postSolveList :
    Dict String Name Can.Annotation
    -> Int
    -> List Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveList annotations exprId elems nodeTypes0 kernel0 =
    let
        -- Recurse into all elements
        ( nodeTypes1, kernel1 ) =
            List.foldl
                (\e ( nt, ke ) -> postSolveExpr annotations e nt ke)
                ( nodeTypes0, kernel0 )
                elems

        -- Check if solver already resolved the type for this list expression
        -- If so, trust that type rather than computing a new one
        existingType =
            Dict.get Basics.identity exprId nodeTypes1
    in
    case existingType of
        Just _ ->
            -- Solver already resolved the type (e.g., from context constraints)
            -- Trust that type - don't overwrite with computed structural type
            ( nodeTypes1, kernel1 )

        Nothing ->
            -- No solver type available, compute structurally
            let
                elemType =
                    case elems of
                        [] ->
                            -- Empty list: use polymorphic type
                            Can.TVar "a"

                        (A.At _ info) :: _ ->
                            -- Non-empty: use first element's type
                            Dict.get Basics.identity info.id nodeTypes1
                                |> Maybe.withDefault (Can.TVar "a")

                listType =
                    Can.TType ModuleName.list Name.list [ elemType ]

                nodeTypes2 =
                    Dict.insert Basics.identity exprId listType nodeTypes1
            in
            ( nodeTypes2, kernel1 )


{-| Handle Tuple expression (Group B).
-}
postSolveTuple :
    Dict String Name Can.Annotation
    -> Int
    -> Can.Expr
    -> Can.Expr
    -> List Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveTuple annotations exprId a b cs nodeTypes0 kernel0 =
    let
        -- Recurse into all components
        ( nt1, ke1 ) =
            postSolveExpr annotations a nodeTypes0 kernel0

        ( nt2, ke2 ) =
            postSolveExpr annotations b nt1 ke1

        ( nt3, ke3 ) =
            List.foldl
                (\c ( nt, ke ) -> postSolveExpr annotations c nt ke)
                ( nt2, ke2 )
                cs
    in
    -- Check if solver already resolved the type for this tuple expression
    case Dict.get Basics.identity exprId nt3 of
        Just _ ->
            -- Solver already resolved the type, trust it
            ( nt3, ke3 )

        Nothing ->
            -- No solver type available, compute structurally
            let
                -- Get component types
                getType expr nt =
                    case expr of
                        A.At _ info ->
                            Dict.get Basics.identity info.id nt
                                |> Maybe.withDefault (Can.TVar "a")

                aType =
                    getType a nt3

                bType =
                    getType b nt3

                csTypes =
                    List.map (\c -> getType c nt3) cs

                tupleType =
                    Can.TTuple aType bType csTypes

                nodeTypes4 =
                    Dict.insert Basics.identity exprId tupleType nt3
            in
            ( nodeTypes4, ke3 )


{-| Handle Record expression (Group B).
-}
postSolveRecord :
    Dict String Name Can.Annotation
    -> Int
    -> Dict String (A.Located Name) Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveRecord annotations exprId fields nodeTypes0 kernel0 =
    let
        fieldList =
            Dict.toList A.compareLocated fields

        -- Recurse into all field expressions
        ( nodeTypes1, kernel1 ) =
            List.foldl
                (\( _, fieldExpr ) ( nt, ke ) ->
                    postSolveExpr annotations fieldExpr nt ke
                )
                ( nodeTypes0, kernel0 )
                fieldList
    in
    -- Check if solver already resolved the type for this record expression
    case Dict.get Basics.identity exprId nodeTypes1 of
        Just _ ->
            -- Solver already resolved the type, trust it
            ( nodeTypes1, kernel1 )

        Nothing ->
            -- No solver type available, compute structurally
            let
                -- Build field type map (Dict String Name FieldType)
                fieldTypes =
                    List.foldl
                        (\( locatedName, fieldExpr ) acc ->
                            let
                                name =
                                    A.toValue locatedName

                                tipe =
                                    case fieldExpr of
                                        A.At _ info ->
                                            Dict.get Basics.identity info.id nodeTypes1
                                                |> Maybe.withDefault (Can.TVar "a")
                            in
                            Dict.insert Basics.identity name (Can.FieldType 0 tipe) acc
                        )
                        Dict.empty
                        fieldList

                recordType =
                    Can.TRecord fieldTypes Nothing

                nodeTypes2 =
                    Dict.insert Basics.identity exprId recordType nodeTypes1
            in
            ( nodeTypes2, kernel1 )


{-| Handle Lambda expression (Group B).
-}
postSolveLambda :
    Dict String Name Can.Annotation
    -> Int
    -> List Can.Pattern
    -> Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveLambda annotations exprId args body nodeTypes0 kernel0 =
    let
        -- First recurse into patterns and body
        ( nodeTypes1, kernel1 ) =
            postSolvePatterns args nodeTypes0 kernel0

        ( nodeTypes2, kernel2 ) =
            postSolveExpr annotations body nodeTypes1 kernel1
    in
    -- Check if solver already resolved the type for this lambda expression
    case Dict.get Basics.identity exprId nodeTypes2 of
        Just _ ->
            -- Solver already resolved the type, trust it
            ( nodeTypes2, kernel2 )

        Nothing ->
            -- No solver type available, compute structurally
            let
                -- Get arg types from pattern IDs
                argTypes =
                    List.map
                        (\pat ->
                            case pat of
                                A.At _ info ->
                                    Dict.get Basics.identity info.id nodeTypes2
                                        |> Maybe.withDefault (Can.TVar "a")
                        )
                        args

                -- Get body type
                bodyType =
                    case body of
                        A.At _ info ->
                            Dict.get Basics.identity info.id nodeTypes2
                                |> Maybe.withDefault (Can.TVar "b")

                -- Build function type: arg1 -> arg2 -> ... -> bodyType
                funcType =
                    List.foldr Can.TLambda bodyType argTypes

                nodeTypes3 =
                    Dict.insert Basics.identity exprId funcType nodeTypes2
            in
            ( nodeTypes3, kernel2 )


{-| Handle Accessor expression (Group B).

An accessor like `.field` has type `{ ext | field : a } -> a`.

-}
postSolveAccessor :
    Dict String Name Can.Annotation
    -> Int
    -> Name
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveAccessor _ exprId field nodeTypes0 kernel0 =
    -- Check if solver already resolved the type for this accessor expression
    case Dict.get Basics.identity exprId nodeTypes0 of
        Just _ ->
            -- Solver already resolved the type, trust it
            ( nodeTypes0, kernel0 )

        Nothing ->
            -- No solver type available, compute structurally
            let
                -- Accessor type is a function from record to field type
                fieldType =
                    Can.TVar "a"

                recordType =
                    Can.TRecord
                        (Dict.singleton Basics.identity field (Can.FieldType 0 fieldType))
                        (Just "ext")

                accessorType =
                    Can.TLambda recordType fieldType

                nodeTypes1 =
                    Dict.insert Basics.identity exprId accessorType nodeTypes0
            in
            ( nodeTypes1, kernel0 )



-- ====== KERNEL ARGUMENT TYPE INFERENCE ======


{-| Check if any argument in a list is a direct VarKernel expression.
-}
hasKernelArg : List Can.Expr -> Bool
hasKernelArg args =
    List.any isKernelExpr args


isKernelExpr : Can.Expr -> Bool
isKernelExpr (A.At _ info) =
    case info.node of
        Can.VarKernel _ _ ->
            True

        _ ->
            False


{-| Propagate inferred types to VarKernel arguments.

Given a list of arguments and their expected types (from peeling the callee's
function type), for each VarKernel argument:

  - Insert its type into kernelEnv
  - Update its type in nodeTypes

This handles the pattern where a kernel function is passed as an argument
to another kernel call.

-}
propagateKernelArgTypes :
    List Can.Expr
    -> List Can.Type
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
propagateKernelArgTypes args expectedTypes nodeTypes0 kernel0 =
    let
        -- Pair args with their expected types (use Nothing for excess args)
        argsWithTypes =
            List.map2 Tuple.pair args expectedTypes
                ++ List.map (\arg -> ( arg, Can.TVar "a" )) (List.drop (List.length expectedTypes) args)

        processArg ( arg, expectedType ) ( nt, ke ) =
            case arg of
                A.At _ argInfo ->
                    case argInfo.node of
                        Can.VarKernel argHome argName ->
                            if KernelTypes.hasEntry argHome argName ke then
                                -- Already have a type for this kernel; don't override
                                ( nt, ke )

                            else
                                -- Insert the inferred type for this kernel arg
                                let
                                    ke2 =
                                        KernelTypes.insertFirstUsage argHome argName expectedType ke

                                    nt2 =
                                        Dict.insert Basics.identity argInfo.id expectedType nt
                                in
                                ( nt2, ke2 )

                        _ ->
                            -- Not a VarKernel; already processed
                            ( nt, ke )
    in
    List.foldl processArg ( nodeTypes0, kernel0 ) argsWithTypes


{-| Type variable substitution map.
-}
type alias Subst =
    Dict String Name Can.Type


{-| Unify a scheme type (with TVars) against a concrete type to extract substitutions.

This is a one-way unifier: TVars in the scheme get bound to corresponding
parts of the concrete type. Returns Nothing if types are incompatible.

-}
unifySchemeToType : Can.Type -> Can.Type -> Maybe Subst
unifySchemeToType scheme concrete =
    unifyHelp Dict.empty scheme concrete


unifyHelp : Subst -> Can.Type -> Can.Type -> Maybe Subst
unifyHelp subst schemeType concreteType =
    case ( schemeType, concreteType ) of
        ( Can.TVar v, t ) ->
            case Dict.get Basics.identity v subst of
                Nothing ->
                    Just (Dict.insert Basics.identity v t subst)

                Just existing ->
                    if existing == t then
                        Just subst

                    else
                        Nothing

        ( Can.TType home1 name1 args1, Can.TType home2 name2 args2 ) ->
            if home1 == home2 && name1 == name2 && List.length args1 == List.length args2 then
                unifyList subst args1 args2

            else
                Nothing

        ( Can.TLambda arg1 res1, Can.TLambda arg2 res2 ) ->
            case unifyHelp subst arg1 arg2 of
                Nothing ->
                    Nothing

                Just subst1 ->
                    unifyHelp subst1 res1 res2

        ( Can.TTuple a1 b1 cs1, Can.TTuple a2 b2 cs2 ) ->
            if List.length cs1 == List.length cs2 then
                case unifyHelp subst a1 a2 of
                    Nothing ->
                        Nothing

                    Just subst1 ->
                        case unifyHelp subst1 b1 b2 of
                            Nothing ->
                                Nothing

                            Just subst2 ->
                                unifyList subst2 cs1 cs2

            else
                Nothing

        ( Can.TUnit, Can.TUnit ) ->
            Just subst

        ( Can.TRecord fields1 ext1, Can.TRecord fields2 ext2 ) ->
            -- For records, try to unify field types
            -- This is simplified; full record unification is more complex
            if ext1 == ext2 then
                let
                    fieldList1 =
                        Dict.toList compare fields1

                    fieldList2 =
                        Dict.toList compare fields2
                in
                if List.length fieldList1 == List.length fieldList2 then
                    unifyFieldList subst fieldList1 fieldList2

                else
                    Nothing

            else
                Nothing

        ( Can.TAlias _ _ _ (Can.Filled realType1), t2 ) ->
            unifyHelp subst realType1 t2

        ( t1, Can.TAlias _ _ _ (Can.Filled realType2) ) ->
            unifyHelp subst t1 realType2

        _ ->
            -- For other cases, require structural equality
            if schemeType == concreteType then
                Just subst

            else
                Nothing


unifyList : Subst -> List Can.Type -> List Can.Type -> Maybe Subst
unifyList subst list1 list2 =
    case ( list1, list2 ) of
        ( [], [] ) ->
            Just subst

        ( h1 :: t1, h2 :: t2 ) ->
            case unifyHelp subst h1 h2 of
                Nothing ->
                    Nothing

                Just subst1 ->
                    unifyList subst1 t1 t2

        _ ->
            Nothing


unifyFieldList : Subst -> List ( Name, Can.FieldType ) -> List ( Name, Can.FieldType ) -> Maybe Subst
unifyFieldList subst list1 list2 =
    case ( list1, list2 ) of
        ( [], [] ) ->
            Just subst

        ( ( name1, Can.FieldType _ type1 ) :: t1, ( name2, Can.FieldType _ type2 ) :: t2 ) ->
            if name1 == name2 then
                case unifyHelp subst type1 type2 of
                    Nothing ->
                        Nothing

                    Just subst1 ->
                        unifyFieldList subst1 t1 t2

            else
                Nothing

        _ ->
            Nothing


{-| Apply a substitution to a type, replacing TVars with their bound types.
-}
applySubst : Subst -> Can.Type -> Can.Type
applySubst subst tipe =
    case tipe of
        Can.TVar v ->
            Dict.get Basics.identity v subst
                |> Maybe.withDefault tipe

        Can.TType home name args ->
            Can.TType home name (List.map (applySubst subst) args)

        Can.TLambda arg res ->
            Can.TLambda (applySubst subst arg) (applySubst subst res)

        Can.TTuple a b cs ->
            Can.TTuple
                (applySubst subst a)
                (applySubst subst b)
                (List.map (applySubst subst) cs)

        Can.TRecord fields ext ->
            Can.TRecord
                (Dict.map (\_ (Can.FieldType idx t) -> Can.FieldType idx (applySubst subst t)) fields)
                ext

        Can.TAlias home name args aliasType ->
            Can.TAlias home
                name
                (List.map (\( n, t ) -> ( n, applySubst subst t )) args)
                (case aliasType of
                    Can.Holey t ->
                        Can.Holey (applySubst subst t)

                    Can.Filled t ->
                        Can.Filled (applySubst subst t)
                )

        Can.TUnit ->
            tipe


{-| Peel TLambdas off a function type, returning the list of argument types
and the final result type.

    peelFunctionType (A -> B -> C) == ( [A, B], C )

-}
peelFunctionType : Can.Type -> ( List Can.Type, Can.Type )
peelFunctionType tipe =
    case tipe of
        Can.TLambda arg res ->
            let
                ( restArgs, finalResult ) =
                    peelFunctionType res
            in
            ( arg :: restArgs, finalResult )

        _ ->
            ( [], tipe )


{-| Handle Call where callee is a VarCtor and some arguments may be VarKernel.

We extract the constructor's type from its annotation, unify with the call's
result type to get substitutions, then use those to infer kernel argument types.

-}
postSolveCallWithCtorKernelArgs :
    Dict String Name Can.Annotation
    -> Int
    -> Can.Annotation
    -> Can.Expr
    -> List Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveCallWithCtorKernelArgs annotations exprId ctorAnnotation funcExpr args nodeTypes0 kernel0 =
    let
        -- Extract the constructor's function type from its annotation
        (Can.Forall _ ctorType) =
            ctorAnnotation

        -- Peel the constructor type into argument types and result type
        ( ctorArgTypes, ctorResType ) =
            peelFunctionType ctorType

        -- Get the call's result type from nodeTypes (Group A - solver computed it)
        maybeCallType =
            Dict.get Basics.identity exprId nodeTypes0

        -- Try to compute substitution from unifying ctor result with call result
        maybeSubst =
            case maybeCallType of
                Just callType ->
                    unifySchemeToType ctorResType callType

                Nothing ->
                    Nothing
    in
    case maybeSubst of
        Just subst ->
            -- We have a substitution; process each argument
            processCtorArgs annotations subst ctorArgTypes args funcExpr nodeTypes0 kernel0

        Nothing ->
            -- Couldn't compute substitution; fall back to normal processing
            let
                ( nodeTypes1, kernel1 ) =
                    postSolveExpr annotations funcExpr nodeTypes0 kernel0
            in
            List.foldl
                (\arg ( nt, ke ) -> postSolveExpr annotations arg nt ke)
                ( nodeTypes1, kernel1 )
                args


{-| Process constructor arguments, inferring types for any VarKernel args.
-}
processCtorArgs :
    Dict String Name Can.Annotation
    -> Subst
    -> List Can.Type
    -> List Can.Expr
    -> Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
processCtorArgs annotations subst ctorArgTypes args funcExpr nodeTypes0 kernel0 =
    let
        -- First, post-solve the callee (the VarCtor itself)
        ( nodeTypes1, kernel1 ) =
            postSolveExpr annotations funcExpr nodeTypes0 kernel0

        -- Now process each argument, pairing with expected types
        processArg : ( Can.Expr, Maybe Can.Type ) -> ( NodeTypes, KernelTypes.KernelTypeEnv ) -> ( NodeTypes, KernelTypes.KernelTypeEnv )
        processArg ( arg, maybeExpectedType ) ( nt, ke ) =
            case arg of
                A.At _ argInfo ->
                    case argInfo.node of
                        Can.VarKernel home name ->
                            if KernelTypes.hasEntry home name ke then
                                -- Already have a type for this kernel; recurse normally
                                postSolveExpr annotations arg nt ke

                            else
                                -- Try to infer from expected type
                                case maybeExpectedType of
                                    Just expectedType ->
                                        let
                                            kernelType =
                                                applySubst subst expectedType

                                            ke2 =
                                                KernelTypes.insertFirstUsage home name kernelType ke

                                            nt2 =
                                                Dict.insert Basics.identity argInfo.id kernelType nt
                                        in
                                        ( nt2, ke2 )

                                    Nothing ->
                                        -- No expected type; recurse normally (may crash later)
                                        postSolveExpr annotations arg nt ke

                        _ ->
                            -- Not a VarKernel; recurse normally
                            postSolveExpr annotations arg nt ke

        -- Pair args with their expected types (if we have enough ctor arg types)
        argsWithTypes =
            List.map2 (\arg t -> ( arg, Just t )) args ctorArgTypes
                ++ List.map (\arg -> ( arg, Nothing )) (List.drop (List.length ctorArgTypes) args)
    in
    List.foldl processArg ( nodeTypes1, kernel1 ) argsWithTypes
