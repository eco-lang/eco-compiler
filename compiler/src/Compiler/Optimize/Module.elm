module Compiler.Optimize.Module exposing
    ( Annotations
    , MResult
    , optimize
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
import Compiler.Optimize.Expression as Expr
import Compiler.Optimize.Names as Names
import Compiler.Optimize.Port as Port
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Main as E
import Compiler.Reporting.Result as ReportingResult
import Compiler.Reporting.Warning as W
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO
import Utils.Main as Utils



-- ====== Optimization ======


{-| Result type for module optimization, carrying errors and warnings.
-}
type alias MResult i w a =
    ReportingResult.RResult i w E.Error a


{-| Maps definition names to their type annotations from the canonical phase.
-}
type alias Annotations =
    Dict String Name.Name Can.Annotation


{-| Optimize a canonical module to produce an optimized local graph.

Processes all declarations, union types, type aliases, and effects in the module.
Returns a LocalGraph containing optimized nodes and field access counts.

-}
optimize : Annotations -> Can.Module -> MResult i (List W.Warning) Opt.LocalGraph
optimize annotations (Can.Module canData) =
    Opt.LocalGraph Nothing Dict.empty Dict.empty |> addAliases canData.name canData.aliases |> addUnions canData.name canData.unions |> addEffects canData.name canData.effects |> addDecls canData.name annotations canData.decls



-- ====== Union Types ======


type alias Nodes =
    Dict (List String) Opt.Global Opt.Node


-- Registers all union type constructors in the optimization graph.
addUnions : IO.Canonical -> Dict String Name.Name Can.Union -> Opt.LocalGraph -> Opt.LocalGraph
addUnions home unions (Opt.LocalGraph main nodes fields) =
    Opt.LocalGraph main (Dict.foldr compare (\_ -> addUnion home) nodes unions) fields


addUnion : IO.Canonical -> Can.Union -> Nodes -> Nodes
addUnion home (Can.Union unionData) nodes =
    List.foldl (addCtorNode home unionData.opts) nodes unionData.alts


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
    Dict.insert Opt.toComparableGlobal (Opt.Global home c.name) node nodes



-- ====== Type Aliases ======


-- Converts record type aliases into constructor functions.
addAliases : IO.Canonical -> Dict String Name.Name Can.Alias -> Opt.LocalGraph -> Opt.LocalGraph
addAliases home aliases graph =
    Dict.foldr compare (addAlias home) graph aliases


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
                (Dict.insert Opt.toComparableGlobal (Opt.Global home name) node nodes)
                (Dict.foldr compare addRecordCtorField fieldCounts fields)

        _ ->
            graph


addRecordCtorField : Name.Name -> Can.FieldType -> Dict String Name.Name Int -> Dict String Name.Name Int
addRecordCtorField name _ fields =
    Utils.mapInsertWith identity (+) name 1 fields



-- ADD EFFECTS


addEffects : IO.Canonical -> Can.Effects -> Opt.LocalGraph -> Opt.LocalGraph
addEffects home effects ((Opt.LocalGraph main nodes fields) as graph) =
    case effects of
        Can.NoEffects ->
            graph

        Can.Ports ports ->
            Dict.foldr compare (addPort home) graph ports

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

                newNodes : Dict (List String) Opt.Global Opt.Node
                newNodes =
                    case manager of
                        Can.Cmd _ ->
                            Dict.insert Opt.toComparableGlobal fx (Opt.Manager Opt.Cmd) nodes |> Dict.insert Opt.toComparableGlobal cmd link

                        Can.Sub _ ->
                            Dict.insert Opt.toComparableGlobal fx (Opt.Manager Opt.Sub) nodes |> Dict.insert Opt.toComparableGlobal sub link

                        Can.Fx _ _ ->
                            Dict.insert Opt.toComparableGlobal fx (Opt.Manager Opt.Fx) nodes |> Dict.insert Opt.toComparableGlobal sub link |> Dict.insert Opt.toComparableGlobal cmd link
            in
            Opt.LocalGraph main newNodes fields


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



-- HELPER


addToGraph : Opt.Global -> Opt.Node -> Dict String Name.Name Int -> Opt.LocalGraph -> Opt.LocalGraph
addToGraph name node fields (Opt.LocalGraph main nodes fieldCounts) =
    Opt.LocalGraph
        main
        (Dict.insert Opt.toComparableGlobal name node nodes)
        (Utils.mapUnionWith identity compare (+) fields fieldCounts)



-- ADD DECLS


addDecls : IO.Canonical -> Annotations -> Can.Decls -> Opt.LocalGraph -> MResult i (List W.Warning) Opt.LocalGraph
addDecls home annotations decls graph =
    ReportingResult.loop (addDeclsHelp home annotations) ( decls, graph )


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


defToName : Can.Def -> Name.Name
defToName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name



-- ADD DEFS


addDef : IO.Canonical -> Annotations -> Can.Def -> Opt.LocalGraph -> MResult i (List W.Warning) Opt.LocalGraph
addDef home annotations def graph =
    case def of
        Can.Def (A.At region name) args body ->
            let
                (Can.Forall _ tipe) =
                    Utils.find identity name annotations
            in
            ReportingResult.warn (W.MissingTypeAnnotation region name tipe)
                |> ReportingResult.andThen (\_ -> addDefHelp region annotations home name args body graph)

        Can.TypedDef (A.At region name) _ typedArgs body _ ->
            addDefHelp region annotations home name (List.map Tuple.first typedArgs) body graph


addDefHelp : A.Region -> Annotations -> IO.Canonical -> Name.Name -> List Can.Pattern -> Can.Expr -> Opt.LocalGraph -> MResult i w Opt.LocalGraph
addDefHelp region annotations home name args body ((Opt.LocalGraph _ nodes fieldCounts) as graph) =
    if name /= Name.main_ then
        ReportingResult.ok (addDefNode home region name args body EverySet.empty graph)

    else
        let
            (Can.Forall _ tipe) =
                Utils.find identity name annotations

            addMain : ( EverySet (List String) Opt.Global, Dict String Name.Name Int, Opt.Main ) -> Opt.LocalGraph
            addMain ( deps, fields, main ) =
                Opt.LocalGraph (Just main) nodes (Utils.mapUnionWith identity compare (+) fields fieldCounts) |> addDefNode home region name args body deps
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



-- ADD RECURSIVE DEFS


type State
    = State
        { values : List ( Name.Name, Opt.Expr )
        , functions : List Opt.Def
        }


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

        links : Dict (List String) Opt.Global Opt.Node
        links =
            List.foldr (addLink home (Opt.Link cycleName)) Dict.empty defs

        ( deps, fields, State { values, functions } ) =
            Names.run <|
                List.foldl (\def -> Names.andThen (\state -> addRecDef cycle state def))
                    (Names.pure (State { values = [], functions = [] }))
                    defs
    in
    Opt.LocalGraph
        main
        (Dict.insert Opt.toComparableGlobal cycleName (Opt.Cycle names values functions deps) (Dict.union links nodes))
        (Utils.mapUnionWith identity compare (+) fields fieldCounts)


toName : Can.Def -> Name.Name
toName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name


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


addLink : IO.Canonical -> Opt.Node -> Can.Def -> Dict (List String) Opt.Global Opt.Node -> Dict (List String) Opt.Global Opt.Node
addLink home link def links =
    case def of
        Can.Def (A.At _ name) _ _ ->
            Dict.insert Opt.toComparableGlobal (Opt.Global home name) link links

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            Dict.insert Opt.toComparableGlobal (Opt.Global home name) link links



-- ADD RECURSIVE DEFS


addRecDef : EverySet String Name.Name -> State -> Can.Def -> Names.Tracker State
addRecDef cycle state def =
    case def of
        Can.Def (A.At region name) args body ->
            addRecDefHelp cycle region state name args body

        Can.TypedDef (A.At region name) _ args body _ ->
            addRecDefHelp cycle region state name (List.map Tuple.first args) body


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
