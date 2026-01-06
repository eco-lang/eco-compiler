module Compiler.Optimize.Typed.Module exposing
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
import Compiler.AST.TypedCanonical as TCan exposing (ExprTypes)
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.Utils.Type as Type
import Compiler.Canonicalize.Effects as Effects
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Optimize.Typed.Expression as Expr
import Compiler.Optimize.Typed.KernelTypes as KernelTypes
import Compiler.Optimize.Typed.Names as Names
import Compiler.Optimize.Typed.Port as Port
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Main as E
import Compiler.Reporting.Result as ReportingResult
import Compiler.Reporting.Warning as W
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO
import Utils.Main as Utils



-- OPTIMIZE


{-| Result type for module optimization operations that can produce errors or warnings.
-}
type alias MResult i w a =
    ReportingResult.RResult i w E.Error a


{-| Type annotations for top-level definitions, mapping names to their canonical type annotations.
-}
type alias Annotations =
    Dict String Name.Name Can.Annotation


{-| Optimize a TypedCanonical module to a typed optimized local graph.

This is the main entry point for typed optimization. It takes a TypedCanonical
module (where every expression already has its type), the expression type map
for converting subexpressions, and produces a TypedOptimized.LocalGraph.

The kernelEnv is computed by the PostSolve phase and passed in from the caller.

-}
optimizeTyped : Annotations -> ExprTypes -> KernelTypes.KernelTypeEnv -> TCan.Module -> MResult i (List W.Warning) TOpt.LocalGraph
optimizeTyped annotations exprTypes kernelEnv (TCan.Module tData) =
    TOpt.LocalGraph
        { main = Nothing
        , nodes = Dict.empty
        , fields = Dict.empty
        , annotations = annotations
        }
        |> addAliases tData.name annotations tData.aliases
        |> addUnions tData.name annotations tData.unions
        |> addEffects tData.name annotations tData.effects
        |> addDecls tData.name annotations exprTypes kernelEnv tData.decls



-- ====== Union Types ======


type alias Nodes =
    Dict (List String) TOpt.Global TOpt.Node


addUnions : IO.Canonical -> Annotations -> Dict String Name.Name Can.Union -> TOpt.LocalGraph -> TOpt.LocalGraph
addUnions home _ unions (TOpt.LocalGraph data) =
    TOpt.LocalGraph { data | nodes = Dict.foldr compare (addUnion home) data.nodes unions }


addUnion : IO.Canonical -> Name.Name -> Can.Union -> Nodes -> Nodes
addUnion home typeName (Can.Union unionData) nodes =
    List.foldl (addCtorNode home typeName unionData) nodes unionData.alts


addCtorNode : IO.Canonical -> Name.Name -> Can.UnionData -> Can.Ctor -> Nodes -> Nodes
addCtorNode home typeName unionData (Can.Ctor c) nodes =
    let
        -- Build the constructor type: arg1 -> arg2 -> ... -> UnionType
        resultType : Can.Type
        resultType =
            Can.TType home typeName (List.map Can.TVar unionData.vars)

        ctorType : Can.Type
        ctorType =
            List.foldr Can.TLambda resultType c.args

        node : TOpt.Node
        node =
            case unionData.opts of
                Can.Normal ->
                    TOpt.Ctor c.index c.numArgs ctorType

                Can.Unbox ->
                    TOpt.Box ctorType

                Can.Enum ->
                    TOpt.Enum c.index ctorType
    in
    Dict.insert TOpt.toComparableGlobal (TOpt.Global home c.name) node nodes



-- ====== Type Aliases ======


addAliases : IO.Canonical -> Annotations -> Dict String Name.Name Can.Alias -> TOpt.LocalGraph -> TOpt.LocalGraph
addAliases home annotations aliases graph =
    Dict.foldr compare (addAlias home annotations) graph aliases


addAlias : IO.Canonical -> Annotations -> Name.Name -> Can.Alias -> TOpt.LocalGraph -> TOpt.LocalGraph
addAlias home _ name (Can.Alias _ tipe) ((TOpt.LocalGraph data) as graph) =
    case tipe of
        Can.TRecord fields Nothing ->
            let
                -- Build the constructor function type: field1Type -> field2Type -> ... -> recordType
                fieldList : List ( Name.Name, Can.Type )
                fieldList =
                    Can.fieldsToList fields

                funcType : Can.Type
                funcType =
                    List.foldr
                        (\( _, fieldType ) acc -> Can.TLambda fieldType acc)
                        tipe
                        fieldList

                -- Build argument names with types
                argNamesWithTypes : List ( A.Located Name.Name, Can.Type )
                argNamesWithTypes =
                    List.map
                        (\( fieldName, fieldType ) ->
                            ( A.At A.zero fieldName, fieldType )
                        )
                        fieldList

                -- Build record body: { field1 = field1, field2 = field2, ... }
                bodyRecord : TOpt.Expr
                bodyRecord =
                    TOpt.Record
                        (Dict.map
                            (\fieldName (Can.FieldType _ fieldType) ->
                                TOpt.VarLocal fieldName fieldType
                            )
                            fields
                        )
                        tipe

                function : TOpt.Expr
                function =
                    TOpt.TrackedFunction argNamesWithTypes bodyRecord funcType

                node : TOpt.Node
                node =
                    TOpt.Define function EverySet.empty funcType
            in
            TOpt.LocalGraph
                { data
                    | nodes =
                        Dict.insert TOpt.toComparableGlobal (TOpt.Global home name) node data.nodes
                    , fields =
                        Dict.foldr compare addRecordCtorField data.fields fields
                }

        _ ->
            graph


addRecordCtorField : Name.Name -> Can.FieldType -> Dict String Name.Name Int -> Dict String Name.Name Int
addRecordCtorField name _ fields =
    Utils.mapInsertWith identity (+) name 1 fields



-- ====== Effects ======


addEffects : IO.Canonical -> Annotations -> Can.Effects -> TOpt.LocalGraph -> TOpt.LocalGraph
addEffects home annotations effects ((TOpt.LocalGraph data) as graph) =
    case effects of
        Can.NoEffects ->
            graph

        Can.Ports ports ->
            Dict.foldr compare (addPort home annotations) graph ports

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

                link : TOpt.Node
                link =
                    TOpt.Link fx

                newNodes : Nodes
                newNodes =
                    case manager of
                        Can.Cmd _ ->
                            Dict.insert TOpt.toComparableGlobal fx (TOpt.Manager TOpt.Cmd) data.nodes
                                |> Dict.insert TOpt.toComparableGlobal cmd link

                        Can.Sub _ ->
                            Dict.insert TOpt.toComparableGlobal fx (TOpt.Manager TOpt.Sub) data.nodes
                                |> Dict.insert TOpt.toComparableGlobal sub link

                        Can.Fx _ _ ->
                            Dict.insert TOpt.toComparableGlobal fx (TOpt.Manager TOpt.Fx) data.nodes
                                |> Dict.insert TOpt.toComparableGlobal sub link
                                |> Dict.insert TOpt.toComparableGlobal cmd link
            in
            TOpt.LocalGraph { data | nodes = newNodes }


addPort : IO.Canonical -> Annotations -> Name.Name -> Can.Port -> TOpt.LocalGraph -> TOpt.LocalGraph
addPort home annotations name port_ graph =
    case port_ of
        Can.Incoming { payload } ->
            let
                portType : Can.Type
                portType =
                    case Dict.get identity name annotations of
                        Just (Can.Forall _ t) ->
                            t

                        Nothing ->
                            Can.TVar "?"

                ( deps, fields, decoder ) =
                    Names.run (Port.toDecoder payload)

                node : TOpt.Node
                node =
                    TOpt.PortIncoming decoder deps portType
            in
            addToGraph (TOpt.Global home name) node fields graph

        Can.Outgoing { payload } ->
            let
                portType : Can.Type
                portType =
                    case Dict.get identity name annotations of
                        Just (Can.Forall _ t) ->
                            t

                        Nothing ->
                            Can.TVar "?"

                ( deps, fields, encoder ) =
                    Names.run (Port.toEncoder payload)

                node : TOpt.Node
                node =
                    TOpt.PortOutgoing encoder deps portType
            in
            addToGraph (TOpt.Global home name) node fields graph



-- ====== Graph Helper ======


addToGraph : TOpt.Global -> TOpt.Node -> Dict String Name.Name Int -> TOpt.LocalGraph -> TOpt.LocalGraph
addToGraph name node fields (TOpt.LocalGraph data) =
    TOpt.LocalGraph
        { data
            | nodes = Dict.insert TOpt.toComparableGlobal name node data.nodes
            , fields = Utils.mapUnionWith identity compare (+) fields data.fields
        }



-- ====== Value Declarations ======


addDecls : IO.Canonical -> Annotations -> ExprTypes -> KernelTypes.KernelTypeEnv -> TCan.Decls -> TOpt.LocalGraph -> MResult i (List W.Warning) TOpt.LocalGraph
addDecls home annotations exprTypes kernelEnv decls graph =
    ReportingResult.loop (addDeclsHelp home annotations exprTypes kernelEnv) ( decls, graph )


addDeclsHelp :
    IO.Canonical
    -> Annotations
    -> ExprTypes
    -> KernelTypes.KernelTypeEnv
    -> ( TCan.Decls, TOpt.LocalGraph )
    -> MResult i (List W.Warning) (ReportingResult.Step ( TCan.Decls, TOpt.LocalGraph ) TOpt.LocalGraph)
addDeclsHelp home annotations exprTypes kernelEnv ( decls, graph ) =
    case decls of
        TCan.Declare def subDecls ->
            addDef home annotations exprTypes kernelEnv def graph
                |> ReportingResult.map (ReportingResult.Loop << Tuple.pair subDecls)

        TCan.DeclareRec d ds subDecls ->
            let
                defs : List TCan.Def
                defs =
                    d :: ds
            in
            case findMain defs of
                Nothing ->
                    ReportingResult.ok (ReportingResult.Loop ( subDecls, addRecDefs home annotations exprTypes kernelEnv defs graph ))

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


addDef : IO.Canonical -> Annotations -> ExprTypes -> KernelTypes.KernelTypeEnv -> TCan.Def -> TOpt.LocalGraph -> MResult i (List W.Warning) TOpt.LocalGraph
addDef home annotations exprTypes kernelEnv def graph =
    case def of
        TCan.Def (A.At region name) args body ->
            let
                (Can.Forall _ tipe) =
                    Utils.find identity name annotations
            in
            ReportingResult.warn (W.MissingTypeAnnotation region name tipe)
                |> ReportingResult.andThen (\_ -> addDefHelp region annotations exprTypes kernelEnv home name args body graph)

        TCan.TypedDef (A.At region name) _ typedArgs body _ ->
            addDefHelp region annotations exprTypes kernelEnv home name (List.map Tuple.first typedArgs) body graph


addDefHelp :
    A.Region
    -> Annotations
    -> ExprTypes
    -> KernelTypes.KernelTypeEnv
    -> IO.Canonical
    -> Name.Name
    -> List Can.Pattern
    -> TCan.Expr
    -> TOpt.LocalGraph
    -> MResult i w TOpt.LocalGraph
addDefHelp region annotations exprTypes kernelEnv home name args body ((TOpt.LocalGraph data) as graph) =
    if name /= Name.main_ then
        ReportingResult.ok (addDefNode home annotations exprTypes kernelEnv region name args body EverySet.empty graph)

    else
        let
            (Can.Forall _ tipe) =
                Utils.find identity name annotations

            addMain : ( EverySet (List String) TOpt.Global, Dict String Name.Name Int, TOpt.Main ) -> TOpt.LocalGraph
            addMain ( deps, fields, main ) =
                TOpt.LocalGraph
                    { data
                        | main = Just main
                        , fields = Utils.mapUnionWith identity compare (+) fields data.fields
                    }
                    |> addDefNode home annotations exprTypes kernelEnv region name args body deps
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


addDefNode :
    IO.Canonical
    -> Annotations
    -> ExprTypes
    -> KernelTypes.KernelTypeEnv
    -> A.Region
    -> Name.Name
    -> List Can.Pattern
    -> TCan.Expr
    -> EverySet (List String) TOpt.Global
    -> TOpt.LocalGraph
    -> TOpt.LocalGraph
addDefNode home annotations exprTypes kernelEnv region name args body mainDeps graph =
    let
        -- Get the def type from annotations
        defType : Can.Type
        defType =
            case Dict.get identity name annotations of
                Just (Can.Forall _ t) ->
                    t

                Nothing ->
                    Can.TVar "?"

        ( deps, fields, def ) =
            Names.run <|
                case args of
                    [] ->
                        Expr.optimize kernelEnv annotations exprTypes EverySet.empty body

                    _ ->
                        Expr.destructArgs annotations args
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
                                            List.map (\(TOpt.Destructor n _ t) -> ( n, t )) destructors

                                        -- Combine all bindings so pattern variables are in scope
                                        allBindings =
                                            argBindings ++ destructorBindings
                                    in
                                    Names.withVarTypes allBindings
                                        (Expr.optimize kernelEnv annotations exprTypes EverySet.empty body)
                                        |> Names.map
                                            (\obody ->
                                                let
                                                    wrappedBody =
                                                        List.foldr (wrapDestruct bodyType) obody destructors
                                                in
                                                TOpt.TrackedFunction argNamesWithTypes wrappedBody defType
                                            )
                                )
    in
    addToGraph (TOpt.Global home name) (TOpt.TrackedDefine region def (EverySet.union deps mainDeps) defType) fields graph


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


{-| Wrap an expression in a Destruct node.
-}
wrapDestruct : Can.Type -> TOpt.Destructor -> TOpt.Expr -> TOpt.Expr
wrapDestruct bodyType destructor expr =
    TOpt.Destruct destructor expr bodyType



-- ====== Recursive Definitions ======


type State
    = State
        { values : List ( Name.Name, TOpt.Expr )
        , functions : List TOpt.Def
        }


addRecDefs : IO.Canonical -> Annotations -> ExprTypes -> KernelTypes.KernelTypeEnv -> List TCan.Def -> TOpt.LocalGraph -> TOpt.LocalGraph
addRecDefs home annotations exprTypes kernelEnv defs (TOpt.LocalGraph data) =
    let
        names : List Name.Name
        names =
            List.reverse (List.map toName defs)

        cycleName : TOpt.Global
        cycleName =
            TOpt.Global home (Name.fromManyNames names)

        cycle : EverySet String Name.Name
        cycle =
            List.foldr addValueName EverySet.empty defs

        links : Nodes
        links =
            List.foldr (addLink home (TOpt.Link cycleName)) Dict.empty defs

        ( deps, fields, State { values, functions } ) =
            Names.run <|
                List.foldl (\def -> Names.andThen (\state -> addRecDef annotations exprTypes kernelEnv cycle state def))
                    (Names.pure (State { values = [], functions = [] }))
                    defs
    in
    TOpt.LocalGraph
        { data
            | nodes =
                Dict.insert TOpt.toComparableGlobal cycleName (TOpt.Cycle names values functions deps) (Dict.union links data.nodes)
            , fields =
                Utils.mapUnionWith identity compare (+) fields data.fields
        }


toName : TCan.Def -> Name.Name
toName def =
    case def of
        TCan.Def (A.At _ name) _ _ ->
            name

        TCan.TypedDef (A.At _ name) _ _ _ _ ->
            name


addValueName : TCan.Def -> EverySet String Name.Name -> EverySet String Name.Name
addValueName def names =
    case def of
        TCan.Def (A.At _ name) [] _ ->
            EverySet.insert identity name names

        TCan.Def _ _ _ ->
            names

        TCan.TypedDef (A.At _ name) _ [] _ _ ->
            EverySet.insert identity name names

        TCan.TypedDef _ _ _ _ _ ->
            names


addLink : IO.Canonical -> TOpt.Node -> TCan.Def -> Nodes -> Nodes
addLink home link def links =
    case def of
        TCan.Def (A.At _ name) _ _ ->
            Dict.insert TOpt.toComparableGlobal (TOpt.Global home name) link links

        TCan.TypedDef (A.At _ name) _ _ _ _ ->
            Dict.insert TOpt.toComparableGlobal (TOpt.Global home name) link links


addRecDef : Annotations -> ExprTypes -> KernelTypes.KernelTypeEnv -> EverySet String Name.Name -> State -> TCan.Def -> Names.Tracker State
addRecDef annotations exprTypes kernelEnv cycle (State state) def =
    case def of
        TCan.Def (A.At region name) args body ->
            let
                defType : Can.Type
                defType =
                    case Dict.get identity name annotations of
                        Just (Can.Forall _ t) ->
                            t

                        Nothing ->
                            Can.TVar "?"
            in
            case args of
                [] ->
                    Expr.optimize kernelEnv annotations exprTypes cycle body
                        |> Names.map (\obody -> State { state | values = ( name, obody ) :: state.values })

                _ ->
                    Expr.optimizePotentialTailCall kernelEnv annotations exprTypes cycle region name args body defType
                        |> Names.map (\odef -> State { state | functions = odef :: state.functions })

        TCan.TypedDef (A.At region name) _ typedArgs body _ ->
            let
                defType : Can.Type
                defType =
                    case Dict.get identity name annotations of
                        Just (Can.Forall _ t) ->
                            t

                        Nothing ->
                            Can.TVar "?"
            in
            case typedArgs of
                [] ->
                    Expr.optimize kernelEnv annotations exprTypes cycle body
                        |> Names.map (\obody -> State { state | values = ( name, obody ) :: state.values })

                _ ->
                    Expr.optimizePotentialTailCall kernelEnv annotations exprTypes cycle region name (List.map Tuple.first typedArgs) body defType
                        |> Names.map (\odef -> State { state | functions = odef :: state.functions })
