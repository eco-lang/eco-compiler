module Compiler.LocalOpt.Typed.Module exposing
    ( Annotations, MResult
    , optimizeTyped
    )

{-| Builds the typed local graph of one module, the form in which a module's
code goes on to monomorphization and native code generation.

A local graph (`TOpt.LocalGraph`) is a table of nodes keyed by global name,
together with the module's `main`, a count of how often each record field name
is used, and the type annotations of its top-level names. Definition and port
nodes, and every expression, carry a meta: a canonical type (`tipe`) and, where
one is known, the type checker's solver variable for it (`tvar`).

`optimizeTyped` fills the graph from a type-checked module, one kind of
declaration at a time:

  - A record type alias whose record is closed becomes a function definition
    that builds the record. Other aliases add nothing.
  - Each constructor of a custom type becomes a `Ctor`, `Box` or `Enum` node,
    as the type's constructor options say, holding the constructor's function
    type.
  - An effect manager adds a `Manager` node named `$fx$`, and `Link` nodes to
    it named `command`, `subscription` or both.
  - A port becomes a `PortIncoming` or `PortOutgoing` node holding its decoder
    or encoder.
  - An ordinary top-level definition becomes a `TrackedDefine`. A recursive
    group becomes one `Cycle` node under a combined name, plus a `Link` to it
    under each member's own name.

Constructors and record alias constructors have no annotation from the type
checker, so one is built for each and added to the graph's `annotations`.

The node's `tipe` is the definition's annotation, its generic type rather than
any instance. A value's `tvar` is its body's solver variable; a function's is
the solver variable of its whole type, taken from the `annotationVars`
argument, and the body's when the function has none there.

`main` is checked here: it must be a `VirtualDom.Node` or a `Platform.Program`
whose flags can be decoded. A `Node` main is recorded as static; a `Program`'s
flags decoder becomes the graph's `main`.

Once every node is built, lambda boundaries are normalized as
`Compiler.LocalOpt.Typed.NormalizeLambdaBoundaries` describes, and the graph's
`varSupers` map is computed as `TOpt.computeVarSupers` describes.

A missing annotation for a definition or port is treated as impossible and
crashes the compiler.


# Types

@docs Annotations, MResult


# Optimization

@docs optimizeTyped

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeVars as Vars
import Compiler.AST.TypedCanonical as TCan exposing (ExprTypes, ExprVars)
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.Utils.Type as Type
import Compiler.Canonicalize.Effects as Effects
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.EcoEnvironment as EcoEnvironment
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
import Utils.Crash



-- ====== TYPE HELPERS ======


{-| Returns what is left of `tipe` after removing `n` argument types from the
front of it.

It stops early at anything that is not a `Can.TLambda`, including an alias
standing for a function type, and returns that.

-}
peelFunctionType : Int -> Can.Type Name -> Can.Type Name
peelFunctionType n tipe =
    if n <= 0 then
        tipe

    else
        case tipe of
            Can.TLambda _ _ result ->
                peelFunctionType (n - 1) result

            _ ->
                tipe



-- ====== OPTIMIZE ======


{-| A result of building a module's graph: a value, or the module errors that
stopped it, with any warnings and info gathered along the way.
-}
type alias MResult i w a =
    ReportingResult.RResult i w E.Error a


{-| The type annotation of each top-level name of a module, keyed by name.

Inferred types are included alongside written ones: an annotation here does not
mean the source had one.

-}
type alias Annotations =
    Dict Name.Name (Can.Annotation Name)


{-| Builds the typed local graph of a type-checked module, as the module
docstring describes, or fails with the module's errors.

`annotations` must hold an annotation for every top-level definition and port;
it becomes the graph's `annotations`, with constructor and record alias
constructor annotations added. `exprTypes` and `exprVars` give the type and
solver variable of each expression. `kernelEnv` gives the types of kernel
functions. `annotationVars` gives the solver variable of each top-level
function's type. `allSchemeRoots` is stored in the graph unchanged.

Fails with `BadCycle` when `main` is in a recursive group, `BadType` when
`main` has a type it cannot be, and `BadFlags` when a program's flags cannot be
decoded. Warns `MissingTypeAnnotation` for each top-level definition outside a
recursive group that was written without an annotation.

-}
optimizeTyped : Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name Vars.Variable -> SolverRoots.AllSchemeRoots -> TCan.Module -> MResult i (List W.Warning) (TOpt.LocalGraph Name)
optimizeTyped annotations exprTypes exprVars kernelEnv annotationVars allSchemeRoots (TCan.Module tData) =
    TOpt.LocalGraph
        { main = Nothing
        , nodes = Data.Map.empty
        , fields = Dict.empty
        , annotations = annotations
        , schemeRoots = allSchemeRoots
        , varSupers = Dict.empty
        }
        |> addAliases tData.name tData.aliases
        |> addUnions tData.name tData.unions
        |> addEffects tData.name annotations tData.effects
        |> addDecls tData.name annotations exprTypes exprVars kernelEnv annotationVars tData.decls
        |> ReportingResult.map LambdaNorm.normalizeLocalGraph
        |> ReportingResult.map withComputedVarSupers



-- ====== Var Supers ======


{-| Returns `graph` with its `varSupers` map computed from the graph itself, as
`TOpt.computeVarSupers` describes.
-}
withComputedVarSupers : TOpt.LocalGraph Name -> TOpt.LocalGraph Name
withComputedVarSupers ((TOpt.LocalGraph data) as graph) =
    TOpt.LocalGraph { data | varSupers = TOpt.computeVarSupers graph }



-- ====== Union Types ======


{-| A local graph's node table, keyed by global name.
-}
type alias TypedNodes =
    Data.Map.Dict String TOpt.Global (TOpt.Node Name)


{-| Returns the graph with a node and an annotation added for every
constructor of every custom type in `unions`.
-}
addUnions : ModuleName.Canonical -> Dict Name.Name Can.Union -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
addUnions home unions (TOpt.LocalGraph data) =
    let
        ( nodes1, ann1 ) =
            Dict.foldr (addUnion home) ( data.nodes, data.annotations ) unions
    in
    TOpt.LocalGraph { data | nodes = nodes1, annotations = ann1 }


{-| Returns the node table and annotations with each constructor of one
custom type added.
-}
addUnion : ModuleName.Canonical -> Name.Name -> Can.Union -> ( TypedNodes, TOpt.Annotations Name ) -> ( TypedNodes, TOpt.Annotations Name )
addUnion home typeName (Can.Union unionData) nodesAndAnn =
    List.foldl (addCtorNode home typeName unionData) nodesAndAnn unionData.alts


{-| Returns the node table and annotations with one constructor added.

Its type is a function from the constructor's arguments to the custom type
applied to its type variables, and its annotation quantifies over those
variables. The node is a `Ctor`, a `Box` or an `Enum` as the type's
constructor options say.

-}
addCtorNode : ModuleName.Canonical -> Name.Name -> Can.UnionData -> Can.Ctor -> ( TypedNodes, TOpt.Annotations Name ) -> ( TypedNodes, TOpt.Annotations Name )
addCtorNode home typeName unionData (Can.Ctor c) ( nodes, ann ) =
    let
        resultType : Can.Type Name
        resultType =
            Can.TType home typeName (List.map Can.TVar unionData.vars)

        ctorType : Can.Type Name
        ctorType =
            List.foldr Can.tLambda resultType c.args

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


{-| Returns the graph with a constructor added for every alias in `aliases`
that names a closed record.
-}
addAliases : ModuleName.Canonical -> Dict Name.Name Can.Alias -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
addAliases home aliases graph =
    Dict.foldr (addAlias home) graph aliases


{-| Returns the graph with a constructor added for one alias, if the alias names
a closed record, and unchanged otherwise.

The constructor is a `Define` of a function taking one argument per field, in
the order `Can.fieldsToList` gives, and returning the record. It is given an
annotation quantified over the alias's type variables, and each field name's
use count goes up by one.

-}
addAlias : ModuleName.Canonical -> Name.Name -> Can.Alias -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
addAlias home name (Can.Alias vars tipe) ((TOpt.LocalGraph data) as graph) =
    case tipe of
        Can.TRecord fields Nothing ->
            let
                fieldList : List ( Name.Name, Can.Type Name )
                fieldList =
                    Can.fieldsToList fields

                funcType : Can.Type Name
                funcType =
                    List.foldr
                        (\( _, fieldType ) acc -> Can.tLambda fieldType acc)
                        tipe
                        fieldList

                argNamesWithTypes : List ( Name.Name, Can.Type Name )
                argNamesWithTypes =
                    fieldList

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
                    TOpt.Function Nothing argNamesWithTypes bodyRecord { tipe = funcType, tvar = Nothing }

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


{-| Returns `fields` with the use count of `name` raised by one.
-}
addRecordCtorField : Name.Name -> Can.FieldType Name -> Dict Name.Name Int -> Dict Name.Name Int
addRecordCtorField name _ fields =
    Dict.update name (\v -> Just (Maybe.withDefault 0 v + 1)) fields



-- ====== Effects ======


{-| Returns the graph with the nodes for a module's effects added: a node for
each port, or for an effect manager its `$fx$` `Manager` node and a `Link` to
it under `command`, `subscription` or both, as the manager's kind says.
-}
addEffects : ModuleName.Canonical -> Annotations -> Can.Effects -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
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


{-| Returns the graph with a node added for one port: a `PortIncoming` holding
the decoder of its payload, or a `PortOutgoing` holding the encoder. Its type
is the port's annotation, and a port with no annotation crashes the compiler.
-}
addPort : ModuleName.Canonical -> Annotations -> Name.Name -> Can.Port -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
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


{-| Returns the graph with `node` added under `name` and the field use counts in
`fields` added to the graph's.
-}
addToGraph : TOpt.Global -> TOpt.Node Name -> Dict Name.Name Int -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
addToGraph name node fields (TOpt.LocalGraph data) =
    TOpt.LocalGraph
        { data
            | nodes = Data.Map.insert TOpt.toComparableGlobal name node data.nodes
            , fields = mergeFieldCounts fields data.fields
        }



-- ====== Value Declarations ======


{-| Returns the graph with every declaration in `decls` added, in order, or the
first error one of them raises.
-}
addDecls : ModuleName.Canonical -> Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name Vars.Variable -> TCan.Decls -> TOpt.LocalGraph Name -> MResult i (List W.Warning) (TOpt.LocalGraph Name)
addDecls home annotations exprTypes exprVars kernelEnv annotationVars decls graph =
    ReportingResult.loop (addDeclsHelp home annotations exprTypes exprVars kernelEnv annotationVars) ( decls, graph )


{-| Adds the first declaration of `decls` to the graph and returns the
declarations still to add, or the finished graph at the end of the list.

A recursive group containing `main` fails with `BadCycle`.

-}
addDeclsHelp : ModuleName.Canonical -> Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name Vars.Variable -> ( TCan.Decls, TOpt.LocalGraph Name ) -> MResult i (List W.Warning) (ReportingResult.Step ( TCan.Decls, TOpt.LocalGraph Name ) (TOpt.LocalGraph Name))
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


{-| Returns the region of the name of the definition called `main` in `defs`,
if there is one.
-}
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


{-| Returns the name a definition defines.
-}
defToName : TCan.Def -> Name.Name
defToName def =
    case def of
        TCan.Def (A.At _ name) _ _ ->
            name

        TCan.TypedDef (A.At _ name) _ _ _ _ ->
            name



-- ====== Single Definitions ======


{-| Returns the graph with one non-recursive top-level definition added.

A definition written without a type annotation also produces a
`MissingTypeAnnotation` warning carrying its annotation from `annotations`.

-}
addDef : ModuleName.Canonical -> Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name Vars.Variable -> TCan.Def -> TOpt.LocalGraph Name -> MResult i (List W.Warning) (TOpt.LocalGraph Name)
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


{-| Returns the graph with a definition's node added, after checking it first
when the definition is `main`.

`main` is accepted when its type, with every alias expanded, is a
`VirtualDom.Node` of one argument or a `Platform.Program`. A program whose
flags are eco/system's `Environment`, as `EcoEnvironment.isEnvironmentFlags`
decides, gets `System`'s environment decoder as its flags decoder, with no
check of the flags type. Any other program's flags must pass
`Effects.checkPayload`, and are decoded by a decoder built for them. The
graph's `main` is set, and the globals that `main` needs are added to the
dependencies of its node.

-}
addDefHelp : A.Region -> Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name Vars.Variable -> ModuleName.Canonical -> Name.Name -> List Can.Pattern -> TCan.Expr -> TOpt.LocalGraph Name -> MResult i (List W.Warning) (TOpt.LocalGraph Name)
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
                if hm == ModuleName.platform && nm == Name.program && EcoEnvironment.isEnvironmentFlags tipe then
                    -- The environment decoder ignores the host's JSON and builds the
                    -- Environment, so no payload check applies.
                    Names.registerGlobal A.zero
                        EcoEnvironment.systemHome
                        EcoEnvironment.environmentDecoderName
                        (Can.TType ModuleName.jsonDecode "Decoder" [ flags ])
                        Nothing
                        |> Names.map (TOpt.Dynamic message)
                        |> Names.run
                        |> addMain
                        |> ReportingResult.ok

                else if hm == ModuleName.platform && nm == Name.program then
                    case Effects.checkPayload flags of
                        Ok () ->
                            Port.toFlagsDecoder flags |> Names.map (TOpt.Dynamic message) |> Names.run |> addMain |> ReportingResult.ok

                        Err ( subType, invalidPayload ) ->
                            ReportingResult.throw (E.BadFlags region subType invalidPayload)

                else
                    ReportingResult.throw (E.BadType region tipe)

            _ ->
                ReportingResult.throw (E.BadType region tipe)


{-| Returns the graph with a `TrackedDefine` node added for one top-level
definition, depending on the globals its body uses and on `mainDeps`.

A definition with arguments becomes a `TrackedFunction`. An argument pattern
other than a variable or alias is bound to a generated name, an alias pattern to
its alias name, and the body is wrapped in a `Destruct`
for each variable the pattern binds; every such variable is in scope, with its
type, while the body is optimized.

The node's type is the definition's annotation, and its solver variable is as
the module docstring describes. A definition with no annotation crashes the
compiler.

-}
addDefNode : ModuleName.Canonical -> Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name Vars.Variable -> A.Region -> Name.Name -> List Can.Pattern -> TCan.Expr -> EverySet String TOpt.Global -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
addDefNode home annotations exprTypes exprVars kernelEnv annotationVars region name args body mainDeps graph =
    let
        defType : Can.Type Name
        defType =
            case Dict.get name annotations of
                Just (Can.Forall _ t) ->
                    t

                Nothing ->
                    Utils.Crash.crash "Module.addDefNode: no annotation"

        bodyTvar : Maybe Vars.Variable
        bodyTvar =
            case A.toValue body of
                TCan.TypedExpr info ->
                    info.tvar

        -- A function's body variable is that of its result, not of the whole function.
        nodeTvar : Maybe Vars.Variable
        nodeTvar =
            case args of
                [] ->
                    bodyTvar

                _ ->
                    case Dict.get name annotationVars of
                        Just var ->
                            Just var

                        Nothing ->
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
                                        bodyType =
                                            peelFunctionType (List.length args) defType

                                        -- Each argument's bound name and type, generated or not.
                                        argBindings =
                                            List.map (\( A.At _ n, t ) -> ( n, t )) argNamesWithTypes

                                        destructorBindings =
                                            List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructors

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
                                                TOpt.TrackedFunction Nothing argNamesWithTypes wrappedBody { tipe = defType, tvar = nodeTvar }
                                            )
                                )
    in
    addToGraph (TOpt.Global home name) (TOpt.TrackedDefine region def (EverySet.union deps mainDeps) { tipe = defType, tvar = nodeTvar }) fields graph


{-| Returns `expr` wrapped in a `Destruct` that binds `destructor`, typed
`bodyType` and keeping `expr`'s solver variable.
-}
wrapDestruct : Can.Type Name -> TOpt.Destructor Name -> TOpt.Expr Name -> TOpt.Expr Name
wrapDestruct bodyType destructor expr =
    TOpt.Destruct destructor expr { tipe = bodyType, tvar = TOpt.tvarOf expr }



-- ====== Recursive Definitions ======


{-| The definitions of a recursive group optimized so far, split into values
(definitions with no arguments) and functions, each list newest first.
-}
type State
    = State
        { values : List ( Name.Name, TOpt.Expr Name )
        , functions : List (TOpt.Def Name)
        }


{-| Returns the graph with a recursive group added: one `Cycle` node holding
every member, under a name combined from the members' names, and a `Link` to it
under each member's own name.

Only the members with no arguments are in the cycle set given to the
optimizer, so only references to them are treated as references into the
cycle.

-}
addRecDefs : ModuleName.Canonical -> Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name Vars.Variable -> List TCan.Def -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
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


{-| Returns the name a definition defines.
-}
toName : TCan.Def -> Name.Name
toName def =
    case def of
        TCan.Def (A.At _ name) _ _ ->
            name

        TCan.TypedDef (A.At _ name) _ _ _ _ ->
            name


{-| Returns `names` with the definition's name added if it takes no arguments.
-}
addCycleName : TCan.Def -> EverySet String Name.Name -> EverySet String Name.Name
addCycleName def names =
    case def of
        TCan.Def (A.At _ name) args _ ->
            if List.isEmpty args then
                EverySet.insert identity name names

            else
                names

        TCan.TypedDef (A.At _ name) _ args _ _ ->
            if List.isEmpty args then
                EverySet.insert identity name names

            else
                names


{-| Returns `links` with `link` added under the definition's name.
-}
addLink : ModuleName.Canonical -> TOpt.Node Name -> TCan.Def -> TypedNodes -> TypedNodes
addLink home link def links =
    case def of
        TCan.Def (A.At _ name) _ _ ->
            Data.Map.insert TOpt.toComparableGlobal (TOpt.Global home name) link links

        TCan.TypedDef (A.At _ name) _ _ _ _ ->
            Data.Map.insert TOpt.toComparableGlobal (TOpt.Global home name) link links


{-| Returns a computation that optimizes one member of a recursive group and
adds it to `state`: a member with no arguments as a value, any other as a
function that may be a tail-call loop, as `Expr.optimizePotentialTailCall`
decides. A member with no annotation crashes the compiler.
-}
addRecDef : ModuleName.Canonical -> Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name Vars.Variable -> EverySet String Name.Name -> State -> TCan.Def -> Names.Tracker State
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


{-| Returns the annotation of `name`, and crashes the compiler when there is none.
-}
findAnnotation : Name.Name -> Annotations -> Can.Annotation Name
findAnnotation name annotations =
    case Dict.get name annotations of
        Just ann ->
            ann

        Nothing ->
            Utils.Crash.crash ("findAnnotation: " ++ name ++ " not found")


{-| Returns the field use counts of `a` and `b` added together, name by name.
-}
mergeFieldCounts : Dict Name.Name Int -> Dict Name.Name Int -> Dict Name.Name Int
mergeFieldCounts a b =
    Dict.foldl (\k v acc -> Dict.update k (\mv -> Just (Maybe.withDefault 0 mv + v)) acc) b a
