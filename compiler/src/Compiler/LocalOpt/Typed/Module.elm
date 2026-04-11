module Compiler.LocalOpt.Typed.Module exposing
    ( Annotations, MResult
    , optimizeTyped
    )

{-| Typed module optimization.

Converts a canonical module to a TypedOptimized.LocalGraph, preserving full
type information on every expression.


# Types

@docs Annotations, MResult


# Optimization

@docs optimizeTyped

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedCanonical as TCan exposing (ExprTypes, ExprVars)
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.Utils.Type as Type
import Compiler.Canonicalize.Effects as Effects
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Typed.Expression as Expr
import Compiler.LocalOpt.Typed.Names as Names
import Compiler.LocalOpt.Typed.NormalizeLambdaBoundaries as LambdaNorm
import Compiler.LocalOpt.Typed.Port as Port
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Main as E
import Compiler.Reporting.Result as ReportingResult
import Compiler.Reporting.Warning as W
import Compiler.Type.KernelTypes as KernelTypes
import Compiler.Type.SolverRoots as SolverRoots
import Data.Map
import Data.Set as EverySet exposing (EverySet)
import Dict exposing (Dict)
import System.TypeCheck.IO as IO
import Utils.Crash



-- ====== TYPE HELPERS ======


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



-- ====== OPTIMIZE ======


{-| Result type for module optimization operations that can produce errors or warnings.
-}
type alias MResult i w a =
    ReportingResult.RResult i w E.Error a


{-| Type annotations for top-level definitions, mapping names to their canonical type annotations.
-}
type alias Annotations =
    Dict Name.Name (Can.Annotation Name)


{-| Optimize a TypedCanonical module to a typed optimized local graph.

This is the main entry point for typed optimization. It takes a TypedCanonical
module (where every expression already has its type), the expression type map
for converting subexpressions, and produces a TypedOptimized.LocalGraph.

The kernelEnv is computed by the PostSolve phase and passed in from the caller.

-}
optimizeTyped : Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name IO.Variable -> SolverRoots.AllSchemeRoots -> TCan.Module -> MResult i (List W.Warning) (TOpt.LocalGraph Name)
optimizeTyped annotations exprTypes exprVars kernelEnv annotationVars allSchemeRoots (TCan.Module tData) =
    TOpt.LocalGraph
        { main = Nothing
        , nodes = Data.Map.empty
        , fields = Dict.empty
        , annotations = annotations
        , schemeRoots = allSchemeRoots
        }
        |> addAliases tData.name annotations tData.aliases
        |> addUnions tData.name annotations tData.unions
        |> addEffects tData.name annotations tData.effects
        |> addDecls tData.name annotations exprTypes exprVars kernelEnv annotationVars tData.decls
        |> ReportingResult.map LambdaNorm.normalizeLocalGraph



-- ====== Union Types ======


type alias TypedNodes =
    Data.Map.Dict String TOpt.Global (TOpt.Node Name)


addUnions : IO.Canonical -> Annotations -> Dict Name.Name Can.Union -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
addUnions home _ unions (TOpt.LocalGraph data) =
    let
        ( nodes1, ann1 ) =
            Dict.foldr (addUnion home) ( data.nodes, data.annotations ) unions
    in
    TOpt.LocalGraph { data | nodes = nodes1, annotations = ann1 }


addUnion : IO.Canonical -> Name.Name -> Can.Union -> ( TypedNodes, TOpt.Annotations Name ) -> ( TypedNodes, TOpt.Annotations Name )
addUnion home typeName (Can.Union unionData) nodesAndAnn =
    List.foldl (addCtorNode home typeName unionData) nodesAndAnn unionData.alts


addCtorNode : IO.Canonical -> Name.Name -> Can.UnionData -> Can.Ctor -> ( TypedNodes, TOpt.Annotations Name ) -> ( TypedNodes, TOpt.Annotations Name )
addCtorNode home typeName unionData (Can.Ctor c) ( nodes, ann ) =
    let
        -- Build the constructor type: arg1 -> arg2 -> ... -> UnionType
        resultType : Can.Type Name
        resultType =
            Can.TType home typeName (List.map Can.TVar unionData.vars)

        ctorType : Can.Type Name
        ctorType =
            List.foldr Can.TLambda resultType c.args

        node : TOpt.Node Name
        node =
            case unionData.opts of
                Can.Normal ->
                    TOpt.Ctor c.index c.numArgs ctorType

                Can.Unbox ->
                    TOpt.Box ctorType

                Can.Enum ->
                    TOpt.Enum c.index ctorType

        freeVars : Can.FreeVars
        freeVars =
            List.foldl (\v dict -> Dict.insert v () dict) Dict.empty unionData.vars

        ctorAnn : Can.Annotation Name
        ctorAnn =
            Can.Forall freeVars ctorType

        nodes1 =
            Data.Map.insert TOpt.toComparableGlobal (TOpt.Global home c.name) node nodes

        ann1 =
            Dict.insert c.name ctorAnn ann
    in
    ( nodes1, ann1 )



-- ====== Type Aliases ======


addAliases : IO.Canonical -> Annotations -> Dict Name.Name Can.Alias -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
addAliases home annotations aliases graph =
    Dict.foldr (addAlias home annotations) graph aliases


addAlias : IO.Canonical -> Annotations -> Name.Name -> Can.Alias -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
addAlias home _ name (Can.Alias vars tipe) ((TOpt.LocalGraph data) as graph) =
    case tipe of
        Can.TRecord fields Nothing ->
            let
                -- Build the constructor function type: field1Type -> field2Type -> ... -> recordType
                fieldList : List ( Name.Name, Can.Type Name )
                fieldList =
                    Can.fieldsToList fields

                funcType : Can.Type Name
                funcType =
                    List.foldr
                        (\( _, fieldType ) acc -> Can.TLambda fieldType acc)
                        tipe
                        fieldList

                -- Build argument names with types (without A.Located wrapper for Function)
                argNamesWithTypes : List ( Name.Name, Can.Type Name )
                argNamesWithTypes =
                    fieldList

                -- Build record body: { field1 = field1, field2 = field2, ... }
                bodyRecord : TOpt.Expr Name
                bodyRecord =
                    TOpt.Record
                        (Dict.map
                            (\fieldName (Can.FieldType _ fieldType) ->
                                TOpt.VarLocal fieldName { tipe = fieldType, tvar = Nothing }
                            )
                            fields
                        )
                        { tipe = tipe, tvar = Nothing }

                function : TOpt.Expr Name
                function =
                    TOpt.Function argNamesWithTypes bodyRecord { tipe = funcType, tvar = Nothing }

                node : TOpt.Node Name
                node =
                    TOpt.Define function EverySet.empty { tipe = funcType, tvar = Nothing }

                freeVars : Can.FreeVars
                freeVars =
                    List.foldl (\v dict -> Dict.insert v () dict) Dict.empty vars

                aliasAnn : Can.Annotation Name
                aliasAnn =
                    Can.Forall freeVars funcType
            in
            TOpt.LocalGraph
                { data
                    | nodes =
                        Data.Map.insert TOpt.toComparableGlobal (TOpt.Global home name) node data.nodes
                    , fields =
                        Dict.foldr addRecordCtorField data.fields fields
                    , annotations =
                        Dict.insert name aliasAnn data.annotations
                }

        _ ->
            graph


addRecordCtorField : Name.Name -> Can.FieldType Name -> Dict Name.Name Int -> Dict Name.Name Int
addRecordCtorField name _ fields =
    Dict.update name (\v -> Just (Maybe.withDefault 0 v + 1)) fields



-- ====== Effects ======


addEffects : IO.Canonical -> Annotations -> Can.Effects -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
addEffects home annotations effects ((TOpt.LocalGraph data) as graph) =
    case effects of
        Can.NoEffects ->
            graph

        Can.Ports ports ->
            Dict.foldr (addPort home annotations) graph ports

        Can.Manager _ _ _ manager ->
            let
                fx : TOpt.Global
                fx =
                    TOpt.Global home "$fx$"

                cmd : TOpt.Global
                cmd =
                    TOpt.Global home "command"

                sub : TOpt.Global
                sub =
                    TOpt.Global home "subscription"

                link : TOpt.Node Name
                link =
                    TOpt.Link fx

                newNodes : TypedNodes
                newNodes =
                    case manager of
                        Can.Cmd _ ->
                            Data.Map.insert TOpt.toComparableGlobal fx (TOpt.Manager TOpt.Cmd) data.nodes
                                |> Data.Map.insert TOpt.toComparableGlobal cmd link

                        Can.Sub _ ->
                            Data.Map.insert TOpt.toComparableGlobal fx (TOpt.Manager TOpt.Sub) data.nodes
                                |> Data.Map.insert TOpt.toComparableGlobal sub link

                        Can.Fx _ _ ->
                            Data.Map.insert TOpt.toComparableGlobal fx (TOpt.Manager TOpt.Fx) data.nodes
                                |> Data.Map.insert TOpt.toComparableGlobal sub link
                                |> Data.Map.insert TOpt.toComparableGlobal cmd link
            in
            TOpt.LocalGraph { data | nodes = newNodes }


addPort : IO.Canonical -> Annotations -> Name.Name -> Can.Port -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
addPort home annotations name port_ graph =
    case port_ of
        Can.Incoming { payload } ->
            let
                portType : Can.Type Name
                portType =
                    case Dict.get name annotations of
                        Just (Can.Forall _ t) ->
                            t

                        Nothing ->
                            Utils.Crash.crash "Module.addPort: Incoming no annotation"

                ( deps, fields, decoder ) =
                    Names.run (Port.toDecoder payload)

                node : TOpt.Node Name
                node =
                    TOpt.PortIncoming decoder deps { tipe = portType, tvar = Nothing }
            in
            addToGraph (TOpt.Global home name) node fields graph

        Can.Outgoing { payload } ->
            let
                portType : Can.Type Name
                portType =
                    case Dict.get name annotations of
                        Just (Can.Forall _ t) ->
                            t

                        Nothing ->
                            Utils.Crash.crash "Module.addPort: Outgoing no annotation"

                ( deps, fields, encoder ) =
                    Names.run (Port.toEncoder payload)

                node : TOpt.Node Name
                node =
                    TOpt.PortOutgoing encoder deps { tipe = portType, tvar = Nothing }
            in
            addToGraph (TOpt.Global home name) node fields graph



-- ====== Graph Helper ======


addToGraph : TOpt.Global -> TOpt.Node Name -> Dict Name.Name Int -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
addToGraph name node fields (TOpt.LocalGraph data) =
    TOpt.LocalGraph
        { data
            | nodes = Data.Map.insert TOpt.toComparableGlobal name node data.nodes
            , fields = mergeFieldCounts fields data.fields
        }



-- ====== Value Declarations ======


addDecls : IO.Canonical -> Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name IO.Variable -> TCan.Decls -> TOpt.LocalGraph Name -> MResult i (List W.Warning) (TOpt.LocalGraph Name)
addDecls home annotations exprTypes exprVars kernelEnv annotationVars decls graph =
    ReportingResult.loop (addDeclsHelp home annotations exprTypes exprVars kernelEnv annotationVars) ( decls, graph )


addDeclsHelp : IO.Canonical -> Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name IO.Variable -> ( TCan.Decls, TOpt.LocalGraph Name ) -> MResult i (List W.Warning) (ReportingResult.Step ( TCan.Decls, TOpt.LocalGraph Name ) (TOpt.LocalGraph Name))
addDeclsHelp home annotations exprTypes exprVars kernelEnv annotationVars ( decls, graph ) =
    case decls of
        TCan.Declare def subDecls ->
            addDef home annotations exprTypes exprVars kernelEnv annotationVars def graph
                |> ReportingResult.map (ReportingResult.Loop << Tuple.pair subDecls)

        TCan.DeclareRec d ds subDecls ->
            let
                defs : List TCan.Def
                defs =
                    d :: ds
            in
            case findMain defs of
                Nothing ->
                    ReportingResult.ok (ReportingResult.Loop ( subDecls, addRecDefs home annotations exprTypes exprVars kernelEnv annotationVars defs graph ))

                Just region ->
                    E.BadCycle region (defToName d) (List.map defToName ds) |> ReportingResult.throw

        TCan.SaveTheEnvironment ->
            ReportingResult.ok (ReportingResult.Done graph)


findMain : List TCan.Def -> Maybe A.Region
findMain defs =
    case defs of
        [] ->
            Nothing

        def :: rest ->
            case def of
                TCan.Def (A.At region name) _ _ ->
                    if name == Name.main_ then
                        Just region

                    else
                        findMain rest

                TCan.TypedDef (A.At region name) _ _ _ _ ->
                    if name == Name.main_ then
                        Just region

                    else
                        findMain rest


defToName : TCan.Def -> Name.Name
defToName def =
    case def of
        TCan.Def (A.At _ name) _ _ ->
            name

        TCan.TypedDef (A.At _ name) _ _ _ _ ->
            name



-- ====== Single Definitions ======


addDef : IO.Canonical -> Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name IO.Variable -> TCan.Def -> TOpt.LocalGraph Name -> MResult i (List W.Warning) (TOpt.LocalGraph Name)
addDef home annotations exprTypes exprVars kernelEnv annotationVars def graph =
    case def of
        TCan.Def (A.At region name) args body ->
            let
                (Can.Forall _ tipe) =
                    findAnnotation name annotations
            in
            ReportingResult.warn (W.MissingTypeAnnotation region name tipe)
                |> ReportingResult.andThen (\_ -> addDefHelp region annotations exprTypes exprVars kernelEnv annotationVars home name args body graph)

        TCan.TypedDef (A.At region name) _ typedArgs body _ ->
            addDefHelp region annotations exprTypes exprVars kernelEnv annotationVars home name (List.map Tuple.first typedArgs) body graph


addDefHelp : A.Region -> Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name IO.Variable -> IO.Canonical -> Name.Name -> List Can.Pattern -> TCan.Expr -> TOpt.LocalGraph Name -> MResult i (List W.Warning) (TOpt.LocalGraph Name)
addDefHelp region annotations exprTypes exprVars kernelEnv annotationVars home name args body ((TOpt.LocalGraph data) as graph) =
    if name /= Name.main_ then
        ReportingResult.ok (addDefNode home annotations exprTypes exprVars kernelEnv annotationVars region name args body EverySet.empty graph)

    else
        let
            (Can.Forall _ tipe) =
                findAnnotation name annotations

            addMain : ( EverySet String TOpt.Global, Dict Name.Name Int, TOpt.Main Name ) -> TOpt.LocalGraph Name
            addMain ( deps, fields, main ) =
                TOpt.LocalGraph
                    { data
                        | main = Just main
                        , fields = mergeFieldCounts fields data.fields
                    }
                    |> addDefNode home annotations exprTypes exprVars kernelEnv annotationVars region name args body deps
        in
        case Type.deepDealias tipe of
            Can.TType hm nm [ _ ] ->
                if hm == ModuleName.virtualDom && nm == Name.node then
                    Names.registerKernel Name.virtualDom TOpt.Static |> Names.run |> addMain |> ReportingResult.ok

                else
                    ReportingResult.throw (E.BadType region tipe)

            Can.TType hm nm [ flags, _, message ] ->
                if hm == ModuleName.platform && nm == Name.program then
                    case Effects.checkPayload flags of
                        Ok () ->
                            Port.toFlagsDecoder flags |> Names.map (TOpt.Dynamic message) |> Names.run |> addMain |> ReportingResult.ok

                        Err ( subType, invalidPayload ) ->
                            ReportingResult.throw (E.BadFlags region subType invalidPayload)

                else
                    ReportingResult.throw (E.BadType region tipe)

            _ ->
                ReportingResult.throw (E.BadType region tipe)


addDefNode : IO.Canonical -> Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name IO.Variable -> A.Region -> Name.Name -> List Can.Pattern -> TCan.Expr -> EverySet String TOpt.Global -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
addDefNode home annotations exprTypes exprVars kernelEnv annotationVars region name args body mainDeps graph =
    let
        -- Get the def type from annotations
        defType : Can.Type Name
        defType =
            case Dict.get name annotations of
                Just (Can.Forall _ t) ->
                    t

                Nothing ->
                    Utils.Crash.crash "Module.addDefNode: no annotation"

        -- Extract tvar from the body expression (TCan.Expr = A.Located TCan.Expr_)
        bodyTvar : Maybe IO.Variable
        bodyTvar =
            case A.toValue body of
                TCan.TypedExpr info ->
                    info.tvar

        -- For value definitions (no args), bodyTvar correctly represents the definition's type.
        -- For function definitions (with args), look up the annotation-level solver variable
        -- from the solver's Env. This gives us the full function type variable.
        nodeTvar : Maybe IO.Variable
        nodeTvar =
            case args of
                [] ->
                    bodyTvar

                _ ->
                    case Dict.get name annotationVars of
                        Just var ->
                            Just var

                        Nothing ->
                            -- Fallback to bodyTvar if not found (shouldn't happen for user defs)
                            bodyTvar

        ( deps, fields, def ) =
            Names.run <|
                case args of
                    [] ->
                        Expr.optimize kernelEnv annotations exprTypes exprVars home EverySet.empty body

                    _ ->
                        Expr.destructArgs exprTypes exprVars args
                            |> Names.andThen
                                (\( argNamesWithTypes, destructors ) ->
                                    let
                                        -- Compute body type by peeling off arg types from function type
                                        bodyType =
                                            peelFunctionType (List.length args) defType

                                        -- Root argument bindings (e.g., "_v0" for tuple patterns)
                                        argBindings =
                                            List.map (\( A.At _ n, t ) -> ( n, t )) argNamesWithTypes

                                        -- Extract bindings from destructors (e.g., "x", "y" from tuple (x, y))
                                        destructorBindings =
                                            List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructors

                                        -- Combine all bindings so pattern variables are in scope
                                        allBindings =
                                            argBindings ++ destructorBindings
                                    in
                                    Names.withVarTypes allBindings
                                        (Expr.optimize kernelEnv annotations exprTypes exprVars home EverySet.empty body)
                                        |> Names.map
                                            (\obody ->
                                                let
                                                    wrappedBody =
                                                        List.foldr (wrapDestruct bodyType) obody destructors
                                                in
                                                TOpt.TrackedFunction argNamesWithTypes wrappedBody { tipe = defType, tvar = nodeTvar }
                                            )
                                )
    in
    addToGraph (TOpt.Global home name) (TOpt.TrackedDefine region def (EverySet.union deps mainDeps) { tipe = defType, tvar = nodeTvar }) fields graph


{-| Wrap an expression in a Destruct node.
-}
wrapDestruct : Can.Type Name -> TOpt.Destructor Name -> TOpt.Expr Name -> TOpt.Expr Name
wrapDestruct bodyType destructor expr =
    TOpt.Destruct destructor expr { tipe = bodyType, tvar = TOpt.tvarOf expr }



-- ====== Recursive Definitions ======


type State
    = State
        { values : List ( Name.Name, TOpt.Expr Name )
        , functions : List (TOpt.Def Name)
        }


addRecDefs : IO.Canonical -> Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name IO.Variable -> List TCan.Def -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
addRecDefs home annotations exprTypes exprVars kernelEnv annotationVars defs (TOpt.LocalGraph data) =
    let
        names : List Name.Name
        names =
            List.reverse (List.map toName defs)

        cycleName : TOpt.Global
        cycleName =
            TOpt.Global home (Name.fromManyNames names)

        cycle : EverySet String Name.Name
        cycle =
            List.foldr addCycleName EverySet.empty defs

        links : TypedNodes
        links =
            List.foldr (addLink home (TOpt.Link cycleName)) Data.Map.empty defs

        ( deps, fields, State { values, functions } ) =
            Names.run <|
                List.foldl (\def -> Names.andThen (\state -> addRecDef home annotations exprTypes exprVars kernelEnv annotationVars cycle state def))
                    (Names.pure (State { values = [], functions = [] }))
                    defs
    in
    TOpt.LocalGraph
        { data
            | nodes =
                Data.Map.insert TOpt.toComparableGlobal cycleName (TOpt.Cycle names values functions deps) (Data.Map.union links data.nodes)
            , fields =
                mergeFieldCounts fields data.fields
        }


toName : TCan.Def -> Name.Name
toName def =
    case def of
        TCan.Def (A.At _ name) _ _ ->
            name

        TCan.TypedDef (A.At _ name) _ _ _ _ ->
            name


addCycleName : TCan.Def -> EverySet String Name.Name -> EverySet String Name.Name
addCycleName def names =
    case def of
        TCan.Def (A.At _ name) args _ ->
            -- Only add zero-argument definitions (values) to the cycle set.
            -- Functions are not tracked since they don't form true cyclic dependencies.
            if List.isEmpty args then
                EverySet.insert identity name names

            else
                names

        TCan.TypedDef (A.At _ name) _ args _ _ ->
            if List.isEmpty args then
                EverySet.insert identity name names

            else
                names


addLink : IO.Canonical -> TOpt.Node Name -> TCan.Def -> TypedNodes -> TypedNodes
addLink home link def links =
    case def of
        TCan.Def (A.At _ name) _ _ ->
            Data.Map.insert TOpt.toComparableGlobal (TOpt.Global home name) link links

        TCan.TypedDef (A.At _ name) _ _ _ _ ->
            Data.Map.insert TOpt.toComparableGlobal (TOpt.Global home name) link links


addRecDef : IO.Canonical -> Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name IO.Variable -> EverySet String Name.Name -> State -> TCan.Def -> Names.Tracker State
addRecDef home annotations exprTypes exprVars kernelEnv annotationVars cycle (State state) def =
    case def of
        TCan.Def (A.At region name) args body ->
            let
                defType : Can.Type Name
                defType =
                    case Dict.get name annotations of
                        Just (Can.Forall _ t) ->
                            t

                        Nothing ->
                            Utils.Crash.crash "Module.addCycleDef: Def no annotation"
            in
            case args of
                [] ->
                    Expr.optimize kernelEnv annotations exprTypes exprVars home cycle body
                        |> Names.map (\obody -> State { state | values = ( name, obody ) :: state.values })

                _ ->
                    Expr.optimizePotentialTailCall kernelEnv annotations exprTypes exprVars home cycle region name args body defType annotationVars
                        |> Names.map (\odef -> State { state | functions = odef :: state.functions })

        TCan.TypedDef (A.At region name) _ typedArgs body _ ->
            let
                defType : Can.Type Name
                defType =
                    case Dict.get name annotations of
                        Just (Can.Forall _ t) ->
                            t

                        Nothing ->
                            Utils.Crash.crash "Module.addCycleDef: TypedDef no annotation"
            in
            case typedArgs of
                [] ->
                    Expr.optimize kernelEnv annotations exprTypes exprVars home cycle body
                        |> Names.map (\obody -> State { state | values = ( name, obody ) :: state.values })

                _ ->
                    Expr.optimizePotentialTailCall kernelEnv annotations exprTypes exprVars home cycle region name (List.map Tuple.first typedArgs) body defType annotationVars
                        |> Names.map (\odef -> State { state | functions = odef :: state.functions })



-- ====== Helpers ======


findAnnotation : Name.Name -> Annotations -> Can.Annotation Name
findAnnotation name annotations =
    case Dict.get name annotations of
        Just ann ->
            ann

        Nothing ->
            Utils.Crash.crash ("findAnnotation: " ++ name ++ " not found")


mergeFieldCounts : Dict Name.Name Int -> Dict Name.Name Int -> Dict Name.Name Int
mergeFieldCounts a b =
    Dict.foldl (\k v acc -> Dict.update k (\mv -> Just (Maybe.withDefault 0 mv + v)) acc) b a
