module Compiler.Type.PostSolve exposing (postSolve)

{-| PostSolve phase for fixing Group B expression types and computing kernel types.

This phase runs after the type solver (`runWithIds`) and before `TypedCanonical.fromCanonical`.
It walks the canonical AST to:

1. Fix "missing" types for Group B expressions (those with unconstrained synthetic vars)
2. Compute kernel function types (`KernelTypeEnv`) via alias seeding and usage inference

The result is a fixed `nodeTypes` map where all expression IDs have meaningful types,
plus a `kernelEnv` for typed optimization.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Optimize.Typed.KernelTypes as KernelTypes
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Utils.Crash exposing (crash)


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

        Can.TypedDef (A.At _ name) _ typedArgs body resultType ->
            case typedArgs of
                [] ->
                    -- For TypedDef with result type, we can use the result type directly
                    case A.toValue body of
                        { node } ->
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
                    postSolvePatterns annotations args nodeTypes0 kernel0
            in
            postSolveExpr annotations body nodeTypes1 kernel1

        Can.TypedDef _ _ typedArgs body _ ->
            let
                patterns =
                    List.map Tuple.first typedArgs

                ( nodeTypes1, kernel1 ) =
                    postSolvePatterns annotations patterns nodeTypes0 kernel0
            in
            postSolveExpr annotations body nodeTypes1 kernel1


{-| Walk a list of patterns, processing any nested expressions.
-}
postSolvePatterns :
    Dict String Name Can.Annotation
    -> List Can.Pattern
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolvePatterns annotations patterns nodeTypes0 kernel0 =
    List.foldl
        (\pat ( nt, ke ) -> postSolvePattern annotations pat nt ke)
        ( nodeTypes0, kernel0 )
        patterns


{-| Process a single pattern (patterns don't contain expressions, but may have nested patterns).
-}
postSolvePattern :
    Dict String Name Can.Annotation
    -> Can.Pattern
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolvePattern annotations (A.At _ patInfo) nodeTypes0 kernel0 =
    case patInfo.node of
        Can.PAnything ->
            ( nodeTypes0, kernel0 )

        Can.PVar _ ->
            ( nodeTypes0, kernel0 )

        Can.PRecord _ ->
            ( nodeTypes0, kernel0 )

        Can.PAlias pat _ ->
            postSolvePattern annotations pat nodeTypes0 kernel0

        Can.PUnit ->
            ( nodeTypes0, kernel0 )

        Can.PTuple a b cs ->
            let
                ( nt1, ke1 ) =
                    postSolvePattern annotations a nodeTypes0 kernel0

                ( nt2, ke2 ) =
                    postSolvePattern annotations b nt1 ke1
            in
            List.foldl
                (\p ( nt, ke ) -> postSolvePattern annotations p nt ke)
                ( nt2, ke2 )
                cs

        Can.PList pats ->
            List.foldl
                (\p ( nt, ke ) -> postSolvePattern annotations p nt ke)
                ( nodeTypes0, kernel0 )
                pats

        Can.PCons hd tl ->
            let
                ( nt1, ke1 ) =
                    postSolvePattern annotations hd nodeTypes0 kernel0
            in
            postSolvePattern annotations tl nt1 ke1

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
                    postSolvePattern annotations pat nt ke
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
postSolveExpr annotations ((A.At _ exprInfo) as expr) nodeTypes0 kernel0 =
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

        Can.Binop _ _ _ _ left right ->
            let
                ( nt1, ke1 ) =
                    postSolveExpr annotations left nodeTypes0 kernel0
            in
            postSolveExpr annotations right nt1 ke1

        Can.Call func args ->
            postSolveCall annotations exprId func args nodeTypes0 kernel0

        Can.If branches final ->
            postSolveIf annotations branches final nodeTypes0 kernel0

        Can.Case scrutinee branches ->
            postSolveCase annotations scrutinee branches nodeTypes0 kernel0

        Can.Access record _ ->
            postSolveExpr annotations record nodeTypes0 kernel0

        Can.Update record fields ->
            postSolveUpdate annotations record fields nodeTypes0 kernel0

        -- ====== VARKERNEL: Look up from kernelEnv ======
        Can.VarKernel home name ->
            let
                kernelType =
                    case KernelTypes.lookup home name kernel0 of
                        Just t ->
                            t

                        Nothing ->
                            crash
                                ("PostSolve: No kernel type for "
                                    ++ home
                                    ++ "."
                                    ++ name
                                    ++ ". Kernel must be aliased or called directly."
                                )

                nodeTypes1 =
                    Dict.insert Basics.identity exprId kernelType nodeTypes0
            in
            ( nodeTypes1, kernel0 )

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
                    postSolvePattern annotations pat nodeTypes0 kernel0

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
    let
        -- First post-solve func and args
        ( nodeTypes1, kernel1 ) =
            postSolveExpr annotations func nodeTypes0 kernel0

        ( nodeTypes2, kernel2 ) =
            List.foldl
                (\arg ( nt, ke ) -> postSolveExpr annotations arg nt ke)
                ( nodeTypes1, kernel1 )
                args
    in
    -- Check if func is VarKernel for usage-based inference
    case func of
        A.At _ funcInfo ->
            case funcInfo.node of
                Can.VarKernel home name ->
                    -- Direct kernel call: infer full function type from args and result
                    let
                        argTypes =
                            List.map
                                (\arg ->
                                    case arg of
                                        A.At _ info ->
                                            Dict.get Basics.identity info.id nodeTypes2
                                                |> Maybe.withDefault (Can.TVar "a")
                                )
                                args

                        -- The call's result type is already in nodeTypes from solver (Group A)
                        callResultType =
                            Dict.get Basics.identity exprId nodeTypes2
                                |> Maybe.withDefault (Can.TVar "result")

                        candidateType =
                            KernelTypes.buildFunctionType argTypes callResultType

                        kernel3 =
                            KernelTypes.insertFirstUsage home name candidateType kernel2
                    in
                    ( nodeTypes2, kernel3 )

                _ ->
                    ( nodeTypes2, kernel2 )


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


{-| Handle Case expression (Group A - trust solver's type).
-}
postSolveCase :
    Dict String Name Can.Annotation
    -> Can.Expr
    -> List Can.CaseBranch
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveCase annotations scrutinee branches nodeTypes0 kernel0 =
    let
        ( nt1, ke1 ) =
            postSolveExpr annotations scrutinee nodeTypes0 kernel0

        stepBranch (Can.CaseBranch pat branchExpr) ( nt, ke ) =
            let
                ( nt2, ke2 ) =
                    postSolvePattern annotations pat nt ke
            in
            postSolveExpr annotations branchExpr nt2 ke2
    in
    List.foldl stepBranch ( nt1, ke1 ) branches


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

        -- Get element type
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
            postSolvePatterns annotations args nodeTypes0 kernel0

        ( nodeTypes2, kernel2 ) =
            postSolveExpr annotations body nodeTypes1 kernel1

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
