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
import Compiler.AST.TypedCanonical as TCan exposing (ExprTypes)
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.Utils.Type as Type
import Compiler.Canonicalize.Effects as Effects
import Compiler.Data.Name as Name
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
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO
import Utils.Crash
import Utils.Main as Utils



-- ====== TYPE HELPERS ======


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
        |> ReportingResult.map (LambdaNorm.normalizeLocalGraph >> finalizeLocalGraph)



-- ====== FINALIZATION ======
--
-- These functions convert from TypedLocalGraph (IncompleteType) to
-- CanonLocalGraph (Can.Type) for downstream consumers.


{-| Convert a TypedLocalGraph to a CanonLocalGraph by mapping all IncompleteType
annotations back to Can.Type using toCanonicalPreservingUnknown.
-}
finalizeLocalGraph : TOpt.LocalGraph -> TOpt.LocalGraph
finalizeLocalGraph (TOpt.LocalGraph data) =
    TOpt.LocalGraph
        { main = Maybe.map finalizeMain data.main
        , nodes = Dict.map (\_ -> finalizeNode) data.nodes
        , fields = data.fields
        , annotations = data.annotations
        }


finalizeMain : TOpt.Main -> TOpt.Main
finalizeMain main_ =
    case main_ of
        TOpt.Static ->
            TOpt.Static

        TOpt.Dynamic msgType decoder ->
            TOpt.Dynamic msgType (finalizeExpr decoder)


finalizeNode : TOpt.Node -> TOpt.Node
finalizeNode node =
    let
        fin =
            identity
    in
    case node of
        TOpt.Define expr deps itype ->
            TOpt.Define (finalizeExpr expr) deps (fin itype)

        TOpt.TrackedDefine region expr deps itype ->
            TOpt.TrackedDefine region (finalizeExpr expr) deps (fin itype)

        TOpt.Ctor index arity tipe ->
            TOpt.Ctor index arity (fin tipe)

        TOpt.Enum index tipe ->
            TOpt.Enum index (fin tipe)

        TOpt.Box tipe ->
            TOpt.Box (fin tipe)

        TOpt.Link global ->
            TOpt.Link global

        TOpt.Cycle names values functions deps ->
            TOpt.Cycle names
                (List.map (Tuple.mapSecond finalizeExpr) values)
                (List.map finalizeDef functions)
                deps

        TOpt.Manager effectsType ->
            TOpt.Manager effectsType

        TOpt.Kernel chunks deps ->
            TOpt.Kernel chunks deps

        TOpt.PortIncoming decoder deps tipe ->
            TOpt.PortIncoming (finalizeExpr decoder) deps (fin tipe)

        TOpt.PortOutgoing encoder deps tipe ->
            TOpt.PortOutgoing (finalizeExpr encoder) deps (fin tipe)


finalizeDef : TOpt.Def -> TOpt.Def
finalizeDef def =
    case def of
        TOpt.Def region name expr itype ->
            TOpt.Def region name (finalizeExpr expr) itype

        TOpt.TailDef region name args body itype ->
            let
                finalizeArg ( locName, argType ) =
                    ( locName, argType )
            in
            TOpt.TailDef region name (List.map finalizeArg args) (finalizeExpr body) itype


finalizeExpr : TOpt.Expr -> TOpt.Expr
finalizeExpr expr =
    let
        fin =
            identity

        finArg ( name, itype ) =
            ( name, fin itype )

        finLocArg ( locName, itype ) =
            ( locName, fin itype )
    in
    case expr of
        TOpt.Bool region value itype ->
            TOpt.Bool region value (fin itype)

        TOpt.Chr region value itype ->
            TOpt.Chr region value (fin itype)

        TOpt.Str region value itype ->
            TOpt.Str region value (fin itype)

        TOpt.Int region value itype ->
            TOpt.Int region value (fin itype)

        TOpt.Float region value itype ->
            TOpt.Float region value (fin itype)

        TOpt.VarLocal name itype ->
            TOpt.VarLocal name (fin itype)

        TOpt.TrackedVarLocal region name itype ->
            TOpt.TrackedVarLocal region name (fin itype)

        TOpt.VarGlobal region global itype ->
            TOpt.VarGlobal region global (fin itype)

        TOpt.VarEnum region global index itype ->
            TOpt.VarEnum region global index (fin itype)

        TOpt.VarBox region global itype ->
            TOpt.VarBox region global (fin itype)

        TOpt.VarCycle region home name itype ->
            TOpt.VarCycle region home name (fin itype)

        TOpt.VarDebug region name home unhandledName itype ->
            TOpt.VarDebug region name home unhandledName (fin itype)

        TOpt.VarKernel region home name itype ->
            TOpt.VarKernel region home name (fin itype)

        TOpt.List region entries itype ->
            TOpt.List region (List.map finalizeExpr entries) (fin itype)

        TOpt.Function args body itype ->
            TOpt.Function (List.map finArg args) (finalizeExpr body) (fin itype)

        TOpt.TrackedFunction args body itype ->
            TOpt.TrackedFunction (List.map finLocArg args) (finalizeExpr body) (fin itype)

        TOpt.Call region func args itype ->
            TOpt.Call region (finalizeExpr func) (List.map finalizeExpr args) (fin itype)

        TOpt.TailCall name args itype ->
            TOpt.TailCall name (List.map (Tuple.mapSecond finalizeExpr) args) (fin itype)

        TOpt.If branches final itype ->
            TOpt.If
                (List.map (\( cond, branch ) -> ( finalizeExpr cond, finalizeExpr branch )) branches)
                (finalizeExpr final)
                (fin itype)

        TOpt.Let def body itype ->
            TOpt.Let (finalizeDef def) (finalizeExpr body) (fin itype)

        TOpt.Destruct destructor body itype ->
            TOpt.Destruct (finalizeDestructor destructor) (finalizeExpr body) (fin itype)

        TOpt.Case label root decider jumps itype ->
            TOpt.Case label
                root
                (finalizeDecider decider)
                (List.map (Tuple.mapSecond finalizeExpr) jumps)
                (fin itype)

        TOpt.Accessor region field itype ->
            TOpt.Accessor region field (fin itype)

        TOpt.Access record region field itype ->
            TOpt.Access (finalizeExpr record) region field (fin itype)

        TOpt.Update region record fields itype ->
            TOpt.Update region (finalizeExpr record) (Dict.map (\_ -> finalizeExpr) fields) (fin itype)

        TOpt.Record fields itype ->
            TOpt.Record (Dict.map (\_ -> finalizeExpr) fields) (fin itype)

        TOpt.TrackedRecord region fields itype ->
            TOpt.TrackedRecord region (Dict.map (\_ -> finalizeExpr) fields) (fin itype)

        TOpt.Unit itype ->
            TOpt.Unit (fin itype)

        TOpt.Tuple region a b cs itype ->
            TOpt.Tuple region (finalizeExpr a) (finalizeExpr b) (List.map finalizeExpr cs) (fin itype)

        TOpt.Shader src attrs uniforms itype ->
            TOpt.Shader src attrs uniforms (fin itype)


finalizeDestructor : TOpt.Destructor -> TOpt.Destructor
finalizeDestructor (TOpt.Destructor name path itype) =
    TOpt.Destructor name path itype


finalizeDecider : TOpt.Decider TOpt.Choice -> TOpt.Decider TOpt.Choice
finalizeDecider decider =
    case decider of
        TOpt.Leaf choice ->
            TOpt.Leaf (finalizeChoice choice)

        TOpt.Chain tests success failure ->
            TOpt.Chain tests (finalizeDecider success) (finalizeDecider failure)

        TOpt.FanOut path edges fallback ->
            TOpt.FanOut path (List.map (Tuple.mapSecond finalizeDecider) edges) (finalizeDecider fallback)


finalizeChoice : TOpt.Choice -> TOpt.Choice
finalizeChoice choice =
    case choice of
        TOpt.Inline expr ->
            TOpt.Inline (finalizeExpr expr)

        TOpt.Jump target ->
            TOpt.Jump target



-- ====== Union Types ======


type alias TypedNodes =
    Dict (List String) TOpt.Global TOpt.Node


addUnions : IO.Canonical -> Annotations -> Dict String Name.Name Can.Union -> TOpt.LocalGraph -> TOpt.LocalGraph
addUnions home _ unions (TOpt.LocalGraph data) =
    TOpt.LocalGraph { data | nodes = Dict.foldr compare (addUnion home) data.nodes unions }


addUnion : IO.Canonical -> Name.Name -> Can.Union -> TypedNodes -> TypedNodes
addUnion home typeName (Can.Union unionData) nodes =
    List.foldl (addCtorNode home typeName unionData) nodes unionData.alts


addCtorNode : IO.Canonical -> Name.Name -> Can.UnionData -> Can.Ctor -> TypedNodes -> TypedNodes
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

                -- Build argument names with types (without A.Located wrapper for Function)
                argNamesWithTypes : List ( Name.Name, Can.Type )
                argNamesWithTypes =
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
                    TOpt.Function argNamesWithTypes bodyRecord funcType

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

                newNodes : TypedNodes
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
                            Utils.Crash.crash "Module.addPort: Incoming no annotation"

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
                            Utils.Crash.crash "Module.addPort: Outgoing no annotation"

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
                    Utils.Crash.crash "Module.addDefNode: no annotation"

        ( deps, fields, def ) =
            Names.run <|
                case args of
                    [] ->
                        Expr.optimize kernelEnv annotations exprTypes home EverySet.empty body

                    _ ->
                        Expr.destructArgs exprTypes args
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
                                        (Expr.optimize kernelEnv annotations exprTypes home EverySet.empty body)
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
            List.foldr addCycleName EverySet.empty defs

        links : TypedNodes
        links =
            List.foldr (addLink home (TOpt.Link cycleName)) Dict.empty defs

        ( deps, fields, State { values, functions } ) =
            Names.run <|
                List.foldl (\def -> Names.andThen (\state -> addRecDef home annotations exprTypes kernelEnv cycle state def))
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


addLink : IO.Canonical -> TOpt.Node -> TCan.Def -> TypedNodes -> TypedNodes
addLink home link def links =
    case def of
        TCan.Def (A.At _ name) _ _ ->
            Dict.insert TOpt.toComparableGlobal (TOpt.Global home name) link links

        TCan.TypedDef (A.At _ name) _ _ _ _ ->
            Dict.insert TOpt.toComparableGlobal (TOpt.Global home name) link links


addRecDef : IO.Canonical -> Annotations -> ExprTypes -> KernelTypes.KernelTypeEnv -> EverySet String Name.Name -> State -> TCan.Def -> Names.Tracker State
addRecDef home annotations exprTypes kernelEnv cycle (State state) def =
    case def of
        TCan.Def (A.At region name) args body ->
            let
                defType : Can.Type
                defType =
                    case Dict.get identity name annotations of
                        Just (Can.Forall _ t) ->
                            t

                        Nothing ->
                            Utils.Crash.crash "Module.addCycleDef: Def no annotation"
            in
            case args of
                [] ->
                    Expr.optimize kernelEnv annotations exprTypes home cycle body
                        |> Names.map (\obody -> State { state | values = ( name, obody ) :: state.values })

                _ ->
                    Expr.optimizePotentialTailCall kernelEnv annotations exprTypes home cycle region name args body defType
                        |> Names.map (\odef -> State { state | functions = odef :: state.functions })

        TCan.TypedDef (A.At region name) _ typedArgs body _ ->
            let
                defType : Can.Type
                defType =
                    case Dict.get identity name annotations of
                        Just (Can.Forall _ t) ->
                            t

                        Nothing ->
                            Utils.Crash.crash "Module.addCycleDef: TypedDef no annotation"
            in
            case typedArgs of
                [] ->
                    Expr.optimize kernelEnv annotations exprTypes home cycle body
                        |> Names.map (\obody -> State { state | values = ( name, obody ) :: state.values })

                _ ->
                    Expr.optimizePotentialTailCall kernelEnv annotations exprTypes home cycle region name (List.map Tuple.first typedArgs) body defType
                        |> Names.map (\odef -> State { state | functions = odef :: state.functions })
