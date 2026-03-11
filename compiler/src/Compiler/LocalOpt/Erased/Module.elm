module Compiler.LocalOpt.Erased.Module exposing
    ( optimize
    , Annotations, MResult
    )

{-| Optimization phase entry point that transforms canonical AST into optimized representation.

This module serves as the main interface for the optimization phase of the Elm compiler.
It takes a canonicalized module (after type checking) and produces an optimized LocalGraph
suitable for code generation. The optimization process:

1.  Converts type aliases into constructor functions
2.  Registers union type constructors
3.  Handles effect managers (Cmd/Sub/Fx)
4.  Processes port declarations with encoder/decoder generation
5.  Optimizes value declarations and recursive definition groups

The optimization tracks dependencies between globals and field access patterns to enable
dead code elimination and efficient code generation.


# Optimization

@docs optimize


# Types

@docs Annotations, MResult

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.AST.Utils.Type as Type
import Compiler.Canonicalize.Effects as Effects
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Erased.Expression as Expr
import Compiler.LocalOpt.Erased.Names as Names
import Compiler.LocalOpt.Erased.Port as Port
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Main as E
import Compiler.Reporting.Result as ReportingResult
import Compiler.Reporting.Warning as W
import Data.Map
import Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO
import Utils.Crash exposing (crash)



-- ====== Optimization ======


{-| Result type for module optimization, carrying errors and warnings.
-}
type alias MResult i w a =
    ReportingResult.RResult i w E.Error a


{-| Maps definition names to their type annotations from the canonical phase.
-}
type alias Annotations =
    Dict Name.Name Can.Annotation


{-| Optimize a canonical module to produce an optimized local graph.

Processes all declarations, union types, type aliases, and effects in the module.
Returns a LocalGraph containing optimized nodes and field access counts.

-}
optimize : Annotations -> Can.Module -> MResult i (List W.Warning) Opt.LocalGraph
optimize annotations (Can.Module canData) =
    Opt.LocalGraph Nothing Data.Map.empty Dict.empty |> addAliases canData.name canData.aliases |> addUnions canData.name canData.unions |> addEffects canData.name canData.effects |> addDecls canData.name annotations canData.decls



-- ====== Union Types ======


type alias Nodes =
    Data.Map.Dict (List String) Opt.Global Opt.Node



-- Registers all union type constructors in the optimization graph by processing each union type
-- and adding its constructors as optimized nodes.


addUnions : IO.Canonical -> Dict Name.Name Can.Union -> Opt.LocalGraph -> Opt.LocalGraph
addUnions home unions (Opt.LocalGraph main nodes fields) =
    Opt.LocalGraph main (Dict.foldr (\_ -> addUnion home) nodes unions) fields



-- Processes a single union type and adds all its constructor alternatives to the nodes dictionary.


addUnion : IO.Canonical -> Can.Union -> Nodes -> Nodes
addUnion home (Can.Union unionData) nodes =
    List.foldl (addCtorNode home unionData.opts) nodes unionData.alts



-- Creates and registers an optimized node for a union type constructor.
-- The node type depends on constructor options: Normal (with arity), Unbox (newtype wrapper), or Enum.


addCtorNode : IO.Canonical -> Can.CtorOpts -> Can.Ctor -> Nodes -> Nodes
addCtorNode home opts (Can.Ctor c) nodes =
    let
        node : Opt.Node
        node =
            case opts of
                Can.Normal ->
                    Opt.Ctor c.index c.numArgs

                Can.Unbox ->
                    Opt.Box

                Can.Enum ->
                    Opt.Enum c.index
    in
    Data.Map.insert Opt.toComparableGlobal (Opt.Global home c.name) node nodes



-- ====== Type Aliases ======
-- Processes all type aliases and converts record type aliases into constructor functions.
-- Only record aliases generate actual code; other aliases are purely compile-time.


addAliases : IO.Canonical -> Dict Name.Name Can.Alias -> Opt.LocalGraph -> Opt.LocalGraph
addAliases home aliases graph =
    Dict.foldr (addAlias home) graph aliases



-- Converts a single type alias into an optimized node if it's a record type.
-- Record aliases become constructor functions that build records from their fields.


addAlias : IO.Canonical -> Name.Name -> Can.Alias -> Opt.LocalGraph -> Opt.LocalGraph
addAlias home name (Can.Alias _ tipe) ((Opt.LocalGraph main nodes fieldCounts) as graph) =
    case tipe of
        Can.TRecord fields Nothing ->
            let
                function : Opt.Expr
                function =
                    Dict.map (\field _ -> Opt.VarLocal field) fields |> Opt.Record |> Opt.Function (List.map Tuple.first (Can.fieldsToList fields))

                node : Opt.Node
                node =
                    Opt.Define function EverySet.empty
            in
            Opt.LocalGraph
                main
                (Data.Map.insert Opt.toComparableGlobal (Opt.Global home name) node nodes)
                (Dict.foldr addRecordCtorField fieldCounts fields)

        _ ->
            graph



-- Increments the usage count for a record field accessed by a record constructor function.


addRecordCtorField : Name.Name -> Can.FieldType -> Dict Name.Name Int -> Dict Name.Name Int
addRecordCtorField name _ fields =
    Dict.update name (\v -> Just (Maybe.withDefault 0 v + 1)) fields



-- ====== Effects ======
-- Processes module effects including ports and effect managers (Cmd/Sub/Fx).
-- Effect managers register special $fx$ nodes and link command/subscription exports.


addEffects : IO.Canonical -> Can.Effects -> Opt.LocalGraph -> Opt.LocalGraph
addEffects home effects ((Opt.LocalGraph main nodes fields) as graph) =
    case effects of
        Can.NoEffects ->
            graph

        Can.Ports ports ->
            Dict.foldr (addPort home) graph ports

        Can.Manager _ _ _ manager ->
            let
                fx : Opt.Global
                fx =
                    Opt.Global home "$fx$"

                cmd : Opt.Global
                cmd =
                    Opt.Global home "command"

                sub : Opt.Global
                sub =
                    Opt.Global home "subscription"

                link : Opt.Node
                link =
                    Opt.Link fx

                newNodes : Data.Map.Dict (List String) Opt.Global Opt.Node
                newNodes =
                    case manager of
                        Can.Cmd _ ->
                            Data.Map.insert Opt.toComparableGlobal fx (Opt.Manager Opt.Cmd) nodes |> Data.Map.insert Opt.toComparableGlobal cmd link

                        Can.Sub _ ->
                            Data.Map.insert Opt.toComparableGlobal fx (Opt.Manager Opt.Sub) nodes |> Data.Map.insert Opt.toComparableGlobal sub link

                        Can.Fx _ _ ->
                            Data.Map.insert Opt.toComparableGlobal fx (Opt.Manager Opt.Fx) nodes |> Data.Map.insert Opt.toComparableGlobal sub link |> Data.Map.insert Opt.toComparableGlobal cmd link
            in
            Opt.LocalGraph main newNodes fields



-- Converts a port declaration into an optimized node with encoder/decoder.
-- Incoming ports generate decoders for JS→Elm values, outgoing ports generate encoders for Elm→JS.


addPort : IO.Canonical -> Name.Name -> Can.Port -> Opt.LocalGraph -> Opt.LocalGraph
addPort home name port_ graph =
    case port_ of
        Can.Incoming { payload } ->
            let
                ( deps, fields, decoder ) =
                    Names.run (Port.toDecoder payload)

                node : Opt.Node
                node =
                    Opt.PortIncoming decoder deps
            in
            addToGraph (Opt.Global home name) node fields graph

        Can.Outgoing { payload } ->
            let
                ( deps, fields, encoder ) =
                    Names.run (Port.toEncoder payload)

                node : Opt.Node
                node =
                    Opt.PortOutgoing encoder deps
            in
            addToGraph (Opt.Global home name) node fields graph



-- ====== Graph Helper ======
-- Inserts a node into the optimization graph and merges field access counts.


addToGraph : Opt.Global -> Opt.Node -> Data.Map.Dict String Name.Name Int -> Opt.LocalGraph -> Opt.LocalGraph
addToGraph name node fields (Opt.LocalGraph main nodes fieldCounts) =
    Opt.LocalGraph
        main
        (Data.Map.insert Opt.toComparableGlobal name node nodes)
        (mergeFieldCounts (dataMapToDict fields) fieldCounts)


mergeFieldCounts : Dict Name.Name Int -> Dict Name.Name Int -> Dict Name.Name Int
mergeFieldCounts a b =
    Dict.foldl (\k v acc -> Dict.update k (\mv -> Just (Maybe.withDefault 0 mv + v)) acc) b a


dataMapToDict : Data.Map.Dict String Name.Name v -> Dict Name.Name v
dataMapToDict mapDict =
    Dict.fromList (Data.Map.toList compare mapDict)



-- ====== Value Declarations ======
-- Processes all value declarations in the module, handling both single definitions and
-- mutually recursive definition groups.


addDecls : IO.Canonical -> Annotations -> Can.Decls -> Opt.LocalGraph -> MResult i (List W.Warning) Opt.LocalGraph
addDecls home annotations decls graph =
    ReportingResult.loop (addDeclsHelp home annotations) ( decls, graph )



-- Recursively processes declarations, distinguishing between single defs and recursive groups.
-- Rejects recursive groups containing 'main' which must be a single top-level definition.


addDeclsHelp : IO.Canonical -> Annotations -> ( Can.Decls, Opt.LocalGraph ) -> MResult i (List W.Warning) (ReportingResult.Step ( Can.Decls, Opt.LocalGraph ) Opt.LocalGraph)
addDeclsHelp home annotations ( decls, graph ) =
    case decls of
        Can.Declare def subDecls ->
            addDef home annotations def graph
                |> ReportingResult.map (ReportingResult.Loop << Tuple.pair subDecls)

        Can.DeclareRec d ds subDecls ->
            let
                defs : List Can.Def
                defs =
                    d :: ds
            in
            case findMain defs of
                Nothing ->
                    ReportingResult.ok (ReportingResult.Loop ( subDecls, addRecDefs home defs graph ))

                Just region ->
                    E.BadCycle region (defToName d) (List.map defToName ds) |> ReportingResult.throw

        Can.SaveTheEnvironment ->
            ReportingResult.ok (ReportingResult.Done graph)



-- Searches for 'main' in a list of definitions, returning its region if found.
-- Used to detect and reject recursive definitions involving 'main'.


findMain : List Can.Def -> Maybe A.Region
findMain defs =
    case defs of
        [] ->
            Nothing

        def :: rest ->
            case def of
                Can.Def (A.At region name) _ _ ->
                    if name == Name.main_ then
                        Just region

                    else
                        findMain rest

                Can.TypedDef (A.At region name) _ _ _ _ ->
                    if name == Name.main_ then
                        Just region

                    else
                        findMain rest



-- Extracts the name from a definition.


defToName : Can.Def -> Name.Name
defToName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name



-- ====== Single Definitions ======
-- Processes a single value definition, issuing a warning if a type annotation is missing.
-- Handles both regular definitions and 'main' which requires special validation.


addDef : IO.Canonical -> Annotations -> Can.Def -> Opt.LocalGraph -> MResult i (List W.Warning) Opt.LocalGraph
addDef home annotations def graph =
    case def of
        Can.Def (A.At region name) args body ->
            let
                (Can.Forall _ tipe) =
                    findAnnotation name annotations
            in
            ReportingResult.warn (W.MissingTypeAnnotation region name tipe)
                |> ReportingResult.andThen (\_ -> addDefHelp region annotations home name args body graph)

        Can.TypedDef (A.At region name) _ typedArgs body _ ->
            addDefHelp region annotations home name (List.map Tuple.first typedArgs) body graph



-- Optimizes and adds a definition to the graph, with special handling for 'main'.
-- The 'main' function must have a valid Platform.Program or VirtualDom.Node type.


addDefHelp : A.Region -> Annotations -> IO.Canonical -> Name.Name -> List Can.Pattern -> Can.Expr -> Opt.LocalGraph -> MResult i w Opt.LocalGraph
addDefHelp region annotations home name args body ((Opt.LocalGraph _ nodes fieldCounts) as graph) =
    if name /= Name.main_ then
        ReportingResult.ok (addDefNode home region name args body EverySet.empty graph)

    else
        let
            (Can.Forall _ tipe) =
                findAnnotation name annotations

            addMain : ( EverySet (List String) Opt.Global, Data.Map.Dict String Name.Name Int, Opt.Main ) -> Opt.LocalGraph
            addMain ( deps, fields, main ) =
                Opt.LocalGraph (Just main) nodes (mergeFieldCounts (dataMapToDict fields) fieldCounts) |> addDefNode home region name args body deps
        in
        case Type.deepDealias tipe of
            Can.TType hm nm [ _ ] ->
                if hm == ModuleName.virtualDom && nm == Name.node then
                    Names.registerKernel Name.virtualDom Opt.Static |> Names.run |> addMain |> ReportingResult.ok

                else
                    ReportingResult.throw (E.BadType region tipe)

            Can.TType hm nm [ flags, _, message ] ->
                if hm == ModuleName.platform && nm == Name.program then
                    case Effects.checkPayload flags of
                        Ok () ->
                            Port.toFlagsDecoder flags |> Names.map (Opt.Dynamic message) |> Names.run |> addMain |> ReportingResult.ok

                        Err ( subType, invalidPayload ) ->
                            ReportingResult.throw (E.BadFlags region subType invalidPayload)

                else
                    ReportingResult.throw (E.BadType region tipe)

            _ ->
                ReportingResult.throw (E.BadType region tipe)



-- Creates an optimized definition node by transforming arguments and body into optimized form.
-- Functions with arguments get pattern destructuring; zero-arg definitions are plain values.


addDefNode : IO.Canonical -> A.Region -> Name.Name -> List Can.Pattern -> Can.Expr -> EverySet (List String) Opt.Global -> Opt.LocalGraph -> Opt.LocalGraph
addDefNode home region name args body mainDeps graph =
    let
        ( deps, fields, def ) =
            Names.run <|
                case args of
                    [] ->
                        Expr.optimize EverySet.empty body

                    _ ->
                        Expr.destructArgs args
                            |> Names.andThen
                                (\( argNames, destructors ) ->
                                    Expr.optimize EverySet.empty body
                                        |> Names.map
                                            (\obody ->
                                                List.foldr Opt.Destruct obody destructors |> Opt.TrackedFunction argNames
                                            )
                                )
    in
    addToGraph (Opt.Global home name) (Opt.TrackedDefine region def (EverySet.union deps mainDeps)) fields graph



-- ====== Recursive Definitions ======
-- Accumulator for collecting optimized values and functions from a recursive group.


type State
    = State
        { values : List ( Name.Name, Opt.Expr )
        , functions : List Opt.Def
        }



-- Processes a mutually recursive definition group into a single Cycle node.
-- All definitions in the group are linked to a shared cycle that contains the optimized forms.


addRecDefs : IO.Canonical -> List Can.Def -> Opt.LocalGraph -> Opt.LocalGraph
addRecDefs home defs (Opt.LocalGraph main nodes fieldCounts) =
    let
        names : List Name.Name
        names =
            List.reverse (List.map toName defs)

        cycleName : Opt.Global
        cycleName =
            Opt.Global home (Name.fromManyNames names)

        cycle : EverySet String Name.Name
        cycle =
            List.foldr addValueName EverySet.empty defs

        links : Data.Map.Dict (List String) Opt.Global Opt.Node
        links =
            List.foldr (addLink home (Opt.Link cycleName)) Data.Map.empty defs

        ( deps, fields, State { values, functions } ) =
            Names.run <|
                List.foldl (\def -> Names.andThen (\state -> addRecDef cycle state def))
                    (Names.pure (State { values = [], functions = [] }))
                    defs
    in
    Opt.LocalGraph
        main
        (Data.Map.insert Opt.toComparableGlobal cycleName (Opt.Cycle names values functions deps) (Data.Map.union links nodes))
        (mergeFieldCounts (dataMapToDict fields) fieldCounts)



-- Extracts the name from a definition.


toName : Can.Def -> Name.Name
toName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name



-- Adds zero-argument definitions to the value name set for cycle detection.
-- Only values (not functions) are tracked since they may form true cyclic dependencies.


addValueName : Can.Def -> EverySet String Name.Name -> EverySet String Name.Name
addValueName def names =
    case def of
        Can.Def (A.At _ name) args _ ->
            if List.isEmpty args then
                EverySet.insert identity name names

            else
                names

        Can.TypedDef (A.At _ name) _ args _ _ ->
            if List.isEmpty args then
                EverySet.insert identity name names

            else
                names



-- Creates a link node pointing to the shared cycle for each definition in the group.


addLink : IO.Canonical -> Opt.Node -> Can.Def -> Data.Map.Dict (List String) Opt.Global Opt.Node -> Data.Map.Dict (List String) Opt.Global Opt.Node
addLink home link def links =
    case def of
        Can.Def (A.At _ name) _ _ ->
            Data.Map.insert Opt.toComparableGlobal (Opt.Global home name) link links

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            Data.Map.insert Opt.toComparableGlobal (Opt.Global home name) link links



-- Optimizes a single definition within a recursive group, accumulating results in State.


addRecDef : EverySet String Name.Name -> State -> Can.Def -> Names.Tracker State
addRecDef cycle state def =
    case def of
        Can.Def (A.At region name) args body ->
            addRecDefHelp cycle region state name args body

        Can.TypedDef (A.At region name) _ args body _ ->
            addRecDefHelp cycle region state name (List.map Tuple.first args) body



-- Optimizes the body of a recursive definition, distinguishing values from functions.
-- Functions in recursive groups may be eligible for tail-call optimization.


addRecDefHelp : EverySet String Name.Name -> A.Region -> State -> Name.Name -> List Can.Pattern -> Can.Expr -> Names.Tracker State
addRecDefHelp cycle region (State { values, functions }) name args body =
    case args of
        [] ->
            Expr.optimize cycle body
                |> Names.map
                    (\obody ->
                        State
                            { values = ( name, obody ) :: values
                            , functions = functions
                            }
                    )

        _ :: _ ->
            Expr.optimizePotentialTailCall cycle region name args body
                |> Names.map
                    (\odef ->
                        State
                            { values = values
                            , functions = odef :: functions
                            }
                    )



-- ====== Helpers ======


findAnnotation : Name.Name -> Annotations -> Can.Annotation
findAnnotation name annotations =
    case Dict.get name annotations of
        Just ann ->
            ann

        Nothing ->
            crash ("findAnnotation: " ++ name ++ " not found")
