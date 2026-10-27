module Compiler.LocalOpt.Erased.Module exposing
    ( optimize
    , Annotations, MResult
    )

{-| Turns one type-checked module into the graph of definitions that the
JavaScript backend generates code from, without type information.

That graph is an `Opt.LocalGraph`: one node per global of the module, each
node holding its optimized code and the set of globals it depends on, together
with the module's `main` if it has one and a count of how often each record
field name is used. The dependency sets are what let later phases keep only
what is reachable; the field counts are kept for the backend.

Every kind of declaration contributes nodes. A record type alias becomes a
function that builds the record; any other alias contributes nothing. Each
constructor of a custom type becomes a node saying how its values are
represented. An effect manager contributes a `$fx$` manager node, with its
`command` and `subscription` functions linked to it. A port becomes a node
carrying the generated decoder or encoder for its payload. A value declaration
becomes a definition node, and a group of mutually recursive declarations
becomes a single cycle node that each member links to.

`main` is checked here rather than by the type checker. It must have type
`VirtualDom.Node msg` or `Platform.Program flags model msg` after dealiasing,
its flags must be a type that can come from JavaScript (except eco/system's
`System.Environment` flags, which are accepted unchecked and built by the
environment decoder instead of decoded from JSON), and it may not be part of a
recursive group. A violation is reported as an error from this phase.

Expression bodies are optimized by `Compiler.LocalOpt.Erased.Expression`, and
the dependencies and field counts are collected by the tracker in
`Compiler.LocalOpt.Erased.Names`.


# Optimization

@docs optimize


# Types

@docs Annotations, MResult

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.AST.Utils.Type as Type
import Compiler.Canonicalize.Effects as Effects
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.EcoEnvironment as EcoEnvironment
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Erased.Expression as Expr
import Compiler.LocalOpt.Erased.Names as Names
import Compiler.LocalOpt.Erased.Port as Port
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Main as E
import Compiler.Reporting.Result as ReportingResult
import Compiler.Reporting.Warning as W
import Data.Map
import Data.Set as EverySet exposing (EverySet)
import Dict exposing (Dict)
import Utils.Crash exposing (crash)



-- ====== Optimization ======


{-| The outcome of optimizing a module: the result, or a `Compiler.Reporting.Error.Main`
error, with warnings of type `w` collected either way.
-}
type alias MResult i w a =
    ReportingResult.RResult i w E.Error a


{-| The type of each top-level definition of the module, keyed by name,
whether it was written in the source or inferred.

`optimize` looks up `main` and every unannotated definition outside a recursive
group here, and crashes if one is missing.

-}
type alias Annotations =
    Dict Name.Name (Can.Annotation Name)


{-| Builds the graph of the module from its aliases, custom types, effects and
declarations, using `annotations` for the types of `main` and of unannotated
definitions.

Each top-level definition outside a recursive group that has no written
annotation adds a `MissingTypeAnnotation` warning. The result is an error when
`main` has a type other than `VirtualDom.Node msg` or `Platform.Program flags
model msg` (after dealiasing), when its flags (other than `System.Environment`)
cannot come from JavaScript, or when it is part of a recursive group.

-}
optimize : Annotations -> Can.Module -> MResult i (List W.Warning) Opt.LocalGraph
optimize annotations (Can.Module canData) =
    Opt.LocalGraph Nothing Data.Map.empty Dict.empty |> addAliases canData.name canData.aliases |> addUnions canData.name canData.unions |> addEffects canData.name canData.effects |> addDecls canData.name annotations canData.decls



-- ====== Union Types ======


{-| The nodes of a graph, keyed by global.
-}
type alias Nodes =
    Data.Map.Dict String Opt.Global Opt.Node


{-| Adds a node for every constructor of every custom type in `unions`.
-}
addUnions : ModuleName.Canonical -> Dict Name.Name Can.Union -> Opt.LocalGraph -> Opt.LocalGraph
addUnions home unions (Opt.LocalGraph main nodes fields) =
    Opt.LocalGraph main (Dict.foldr (\_ -> addUnion home) nodes unions) fields


{-| Adds a node for every constructor of one custom type.
-}
addUnion : ModuleName.Canonical -> Can.Union -> Nodes -> Nodes
addUnion home (Can.Union unionData) nodes =
    List.foldl (addCtorNode home unionData.opts) nodes unionData.alts


{-| Adds the node for one constructor, chosen by how the type's values are
represented (`opts`): a `Ctor` with its index and argument count, a `Box` for
a type whose values are represented by their single argument, or an `Enum`
with its index.
-}
addCtorNode : ModuleName.Canonical -> Can.CtorOpts -> Can.Ctor -> Nodes -> Nodes
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


{-| Adds a record-building function for every alias in `aliases` whose body is
a closed record; other aliases add nothing.
-}
addAliases : ModuleName.Canonical -> Dict Name.Name Can.Alias -> Opt.LocalGraph -> Opt.LocalGraph
addAliases home aliases graph =
    Dict.foldr (addAlias home) graph aliases


{-| Adds, when the alias is a record without an extension, a function named
after it that takes the fields as arguments, in the order `Can.fieldsToList`
gives, and returns the record. Each field name's use count goes up by one.
-}
addAlias : ModuleName.Canonical -> Name.Name -> Can.Alias -> Opt.LocalGraph -> Opt.LocalGraph
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


{-| Adds one to the use count of the field `name`.
-}
addRecordCtorField : Name.Name -> Can.FieldType Name -> Dict Name.Name Int -> Dict Name.Name Int
addRecordCtorField name _ fields =
    Dict.update name (\v -> Just (Maybe.withDefault 0 v + 1)) fields



-- ====== Effects ======


{-| Adds the nodes for the module's effects: one per port, or, for an effect
manager, a `$fx$` `Manager` node and a `Link` to it from `command`,
`subscription` or both, according to what the manager provides.
-}
addEffects : ModuleName.Canonical -> Can.Effects -> Opt.LocalGraph -> Opt.LocalGraph
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

                newNodes : Data.Map.Dict String Opt.Global Opt.Node
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


{-| Adds the node for one port: for an incoming port, the decoder of its
payload from JavaScript; for an outgoing one, the encoder of its payload to
JavaScript.
-}
addPort : ModuleName.Canonical -> Name.Name -> Can.Port -> Opt.LocalGraph -> Opt.LocalGraph
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


{-| Adds `node` under the global `name` and adds `fields` to the graph's
field use counts.
-}
addToGraph : Opt.Global -> Opt.Node -> Dict Name.Name Int -> Opt.LocalGraph -> Opt.LocalGraph
addToGraph name node fields (Opt.LocalGraph main nodes fieldCounts) =
    Opt.LocalGraph
        main
        (Data.Map.insert Opt.toComparableGlobal name node nodes)
        (mergeFieldCounts fields fieldCounts)


{-| Returns the field use counts of `a` and `b` added together.
-}
mergeFieldCounts : Dict Name.Name Int -> Dict Name.Name Int -> Dict Name.Name Int
mergeFieldCounts a b =
    Dict.foldl (\k v acc -> Dict.update k (\mv -> Just (Maybe.withDefault 0 mv + v)) acc) b a



-- ====== Value Declarations ======


{-| Adds every declaration in `decls` to the graph, stopping at the first error.
-}
addDecls : ModuleName.Canonical -> Annotations -> Can.Decls -> Opt.LocalGraph -> MResult i (List W.Warning) Opt.LocalGraph
addDecls home annotations decls graph =
    ReportingResult.loop (addDeclsHelp home annotations) ( decls, graph )


{-| Adds the first declaration in `decls` and returns the rest to continue with,
or the finished graph when none remain.

A recursive group that contains `main` is a `BadCycle` error.

-}
addDeclsHelp : ModuleName.Canonical -> Annotations -> ( Can.Decls, Opt.LocalGraph ) -> MResult i (List W.Warning) (ReportingResult.Step ( Can.Decls, Opt.LocalGraph ) Opt.LocalGraph)
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


{-| Returns the region of the name of the definition called `main` in `defs`,
if there is one.
-}
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


{-| Returns the name a definition defines.
-}
defToName : Can.Def -> Name.Name
defToName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name



-- ====== Single Definitions ======


{-| Adds one definition that is not part of a recursive group.

A definition without a written annotation adds a `MissingTypeAnnotation`
warning carrying its type from `annotations`.

-}
addDef : ModuleName.Canonical -> Annotations -> Can.Def -> Opt.LocalGraph -> MResult i (List W.Warning) Opt.LocalGraph
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


{-| Adds the definition `name`, and for `main` also sets the graph's main.

A `main` of type `VirtualDom.Node msg` after dealiasing is static and depends
on the `VirtualDom` kernel. A `main` of type `Platform.Program flags model msg`
is dynamic and carries a decoder for its flags; when the flags are
`System.Environment`, that decoder is the eco/system environment decoder and
the flags are not checked. Any other type of `main` is a `BadType` error, and
flags that cannot come from JavaScript are a `BadFlags` error.

-}
addDefHelp : A.Region -> Annotations -> ModuleName.Canonical -> Name.Name -> List Can.Pattern -> Can.Expr -> Opt.LocalGraph -> MResult i w Opt.LocalGraph
addDefHelp region annotations home name args body ((Opt.LocalGraph _ nodes fieldCounts) as graph) =
    if name /= Name.main_ then
        ReportingResult.ok (addDefNode home region name args body EverySet.empty graph)

    else
        let
            (Can.Forall _ tipe) =
                findAnnotation name annotations

            addMain : ( EverySet String Opt.Global, Dict Name.Name Int, Opt.Main ) -> Opt.LocalGraph
            addMain ( deps, fields, main ) =
                Opt.LocalGraph (Just main) nodes (mergeFieldCounts fields fieldCounts) |> addDefNode home region name args body deps
        in
        case Type.deepDealias tipe of
            Can.TType hm nm [ _ ] ->
                if hm == ModuleName.virtualDom && nm == Name.node then
                    Names.registerKernel "Elm" Name.virtualDom Opt.Static |> Names.run |> addMain |> ReportingResult.ok

                else
                    ReportingResult.throw (E.BadType region tipe)

            Can.TType hm nm [ flags, _, message ] ->
                if hm == ModuleName.platform && nm == Name.program && EcoEnvironment.isEnvironmentFlags tipe then
                    -- The environment decoder ignores the host JSON and builds the
                    -- Environment, so no payload check applies.
                    Names.registerGlobal A.zero EcoEnvironment.systemHome EcoEnvironment.environmentDecoderName
                        |> Names.map (Opt.Dynamic message)
                        |> Names.run
                        |> addMain
                        |> ReportingResult.ok

                else if hm == ModuleName.platform && nm == Name.program then
                    case Effects.checkPayload flags of
                        Ok () ->
                            Port.toFlagsDecoder flags |> Names.map (Opt.Dynamic message) |> Names.run |> addMain |> ReportingResult.ok

                        Err ( subType, invalidPayload ) ->
                            ReportingResult.throw (E.BadFlags region subType invalidPayload)

                else
                    ReportingResult.throw (E.BadType region tipe)

            _ ->
                ReportingResult.throw (E.BadType region tipe)


{-| Adds a `TrackedDefine` node for the definition `name`, whose dependencies
are those of its body together with `mainDeps`.

With arguments, the node holds a function whose arguments that are patterns
are destructured at the start of the body.

-}
addDefNode : ModuleName.Canonical -> A.Region -> Name.Name -> List Can.Pattern -> Can.Expr -> EverySet String Opt.Global -> Opt.LocalGraph -> Opt.LocalGraph
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


{-| The optimized members of a recursive group collected so far: the
zero-argument definitions as `values` and the others as `functions`, each list
with the latest member first.
-}
type State
    = State
        { values : List ( Name.Name, Opt.Expr )
        , functions : List Opt.Def
        }


{-| Adds a recursive group as one `Cycle` node, named by `Name.fromManyNames` of
the members' names, and a `Link` to it under each member's name.

References to the zero-argument members inside the group are compiled as
cycle references; references to the function members stay global references.
No `MissingTypeAnnotation` warning is issued for members of a group.

-}
addRecDefs : ModuleName.Canonical -> List Can.Def -> Opt.LocalGraph -> Opt.LocalGraph
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

        links : Data.Map.Dict String Opt.Global Opt.Node
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
        (mergeFieldCounts fields fieldCounts)


{-| Returns the name a definition defines.
-}
toName : Can.Def -> Name.Name
toName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name


{-| Adds the name of `def` to `names` when it takes no arguments.
-}
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


{-| Adds `link` under the global named by `def`.
-}
addLink : ModuleName.Canonical -> Opt.Node -> Can.Def -> Data.Map.Dict String Opt.Global Opt.Node -> Data.Map.Dict String Opt.Global Opt.Node
addLink home link def links =
    case def of
        Can.Def (A.At _ name) _ _ ->
            Data.Map.insert Opt.toComparableGlobal (Opt.Global home name) link links

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            Data.Map.insert Opt.toComparableGlobal (Opt.Global home name) link links


{-| Optimizes one member of a recursive group and adds it to `state`.
-}
addRecDef : EverySet String Name.Name -> State -> Can.Def -> Names.Tracker State
addRecDef cycle state def =
    case def of
        Can.Def (A.At region name) args body ->
            addRecDefHelp cycle region state name args body

        Can.TypedDef (A.At region name) _ args body _ ->
            addRecDefHelp cycle region state name (List.map Tuple.first args) body


{-| Optimizes one member of a recursive group, given its name, arguments and
body, and adds it to `state`: a zero-argument member as a value, any other as
a function, which becomes a tail-call loop when it calls itself with all its
arguments in tail position.
-}
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


{-| Returns the annotation of `name`, and crashes when `annotations` has none.
-}
findAnnotation : Name.Name -> Annotations -> Can.Annotation Name
findAnnotation name annotations =
    case Dict.get name annotations of
        Just ann ->
            ann

        Nothing ->
            crash ("findAnnotation: " ++ name ++ " not found")
