module Compiler.Canonicalize.Module exposing
    ( MResult
    , canonicalize
    )

{-| Canonicalization is the step that turns a parsed module into one in which
every name is resolved, and this module is where that step starts for a whole
module.

Given the package the module belongs to and the interfaces of the modules it
can import, `canonicalize` builds the name environment (imports first, then the
module's own types and values), canonicalizes every top-level value, then the
module's effects (ports or an effect manager), then its export list. Each step
runs only if the one before it succeeded. Infix declarations are collected as
they are. Warnings, such as unused variables, come back alongside the result.

Every expression and pattern node gets an id from one counter that starts fresh
for the module and runs through the top-level values in source order, so ids
are unique within the module. How each node takes its id is owned by
`Compiler.Canonicalize.Expression` and `Compiler.Canonicalize.Pattern`.

Most of the file is the ordering of the top-level values into `Can.Decls`,
which rests on two kinds of reference. A _direct_ use of a name is evaluated as
soon as the definition is; a _delayed_ use sits inside a lambda or a local
function and is evaluated only when that is called. Ordering then takes two
phases.

Phase one groups the values by every name each body uses, direct or delayed,
into strongly connected components (as `Compiler.Graph` defines them). A value
in no cycle becomes `Can.Declare`, and a cyclic group becomes `Can.DeclareRec`,
which type inference checks together. The result is in dependency order, not
source order.

Phase two looks inside each cyclic group for a cycle that can never finish
evaluating. A definition with parameters contributes no edges here, because
its body runs only when it is called. A definition without parameters
contributes the names its body uses directly. Any cycle left is reported as
`RecursiveDecl`, so only a cycle of zero-argument values referring to one
another directly is an error.


# Results

@docs MResult


# Canonicalization

@docs canonicalize

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Effects as Effects
import Compiler.Canonicalize.Environment as Env
import Compiler.Canonicalize.Environment.Dups as Dups
import Compiler.Canonicalize.Environment.Foreign as Foreign
import Compiler.Canonicalize.Environment.Local as Local
import Compiler.Canonicalize.Expression as Expr
import Compiler.Canonicalize.Ids as Ids
import Compiler.Canonicalize.Pattern as Pattern
import Compiler.Canonicalize.Type as Type
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Graph as Graph
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Compiler.Reporting.Warning as W
import Dict exposing (Dict)
import Utils.Crash exposing (crash)



-- ====== RESULT ======


{-| A canonicalization computation: a `Compiler.Reporting.Result.RResult` whose
errors are canonicalization errors, with `i` the info it carries and `w` the
warnings it collects.
-}
type alias MResult i w a =
    ReportingResult.RResult i w Error.Error a



-- ====== MODULES ======


{-| Returns the canonical form of `modul`, a module of package `pkg`, resolving
its imports against `ifaces`, which is keyed by raw module name.

The steps run in order: the environment from the imports, the module's own
types and values, the top-level values, the effects, and the export list. The
first step that fails ends the computation, so errors from later steps are not
reported. The top-level values are in dependency order, as the module
documentation describes.

-}
canonicalize : Pkg.Name -> Dict ModuleName.Raw I.Interface -> Src.Module -> MResult i (List W.Warning) Can.Module
canonicalize pkg ifaces ((Src.Module srcData) as modul) =
    let
        home : ModuleName.Canonical
        home =
            ModuleName.Canonical pkg (Src.getName modul)

        cbinops : Dict Name Can.Binop
        cbinops =
            Dict.fromList (List.map canonicalizeBinop srcData.infixes)
    in
    Foreign.createInitialEnv home ifaces srcData.imports
        |> ReportingResult.andThen (Local.add modul)
        |> ReportingResult.andThen
            (\( env, cunions, caliases ) ->
                canonicalizeValues env srcData.values
                    |> ReportingResult.andThen
                        (\cvalues ->
                            Effects.canonicalize env srcData.values cunions srcData.effects
                                |> ReportingResult.andThen
                                    (\ceffects ->
                                        canonicalizeExports srcData.values cunions caliases cbinops ceffects srcData.exports
                                            |> ReportingResult.map
                                                (\cexports ->
                                                    Can.Module
                                                        { name = home
                                                        , exports = cexports
                                                        , docs = srcData.docs
                                                        , decls = cvalues
                                                        , unions = cunions
                                                        , aliases = caliases
                                                        , binops = cbinops
                                                        , effects = ceffects
                                                        }
                                                )
                                    )
                        )
            )



-- ====== CANONICALIZE BINOP ======


{-| Returns the operator name of an infix declaration, paired with its
associativity, precedence and the name of the function that implements it.
-}
canonicalizeBinop : A.Located Src.Infix -> ( Name, Can.Binop )
canonicalizeBinop (A.At _ (Src.Infix data)) =
    let
        ( _, op ) =
            data.op

        ( _, associativity ) =
            data.associativity

        ( _, precedence ) =
            data.precedence

        ( _, func ) =
            data.name
    in
    ( op, Can.Binop_ associativity precedence func )



-- ====== DECLARATIONS CYCLE DETECTION ======


{-| Returns the top-level `values` canonicalized in `env` and ordered into
`Can.Decls` by the two phases the module documentation describes.

Node ids are numbered from `Ids.initialIdState`, through the values in source
order.

-}
canonicalizeValues : Env.Env -> List (A.Located Src.Value) -> MResult i (List W.Warning) Can.Decls
canonicalizeValues env values =
    traverseValuesWithState env Ids.initialIdState values
        |> ReportingResult.andThen (\( nodes, _ ) -> detectCycles (Graph.stronglyConnComp nodes))


{-| Returns the phase-one node of each of `values`, in source order, and the id
state after the last of them, numbering each value's nodes from where the
previous value stopped.
-}
traverseValuesWithState :
    Env.Env
    -> Ids.IdState
    -> List (A.Located Src.Value)
    -> MResult i (List W.Warning) ( List NodeOne, Ids.IdState )
traverseValuesWithState env state values =
    case values of
        [] ->
            ReportingResult.ok ( [], state )

        value :: rest ->
            toNodeOne env state value
                |> ReportingResult.andThen
                    (\( node, newState ) ->
                        traverseValuesWithState env newState rest
                            |> ReportingResult.map
                                (\( restNodes, finalState ) ->
                                    ( node :: restNodes, finalState )
                                )
                    )


{-| Returns the declarations for phase-one components `sccs`, in the order
given. An acyclic component becomes `Can.Declare`. A cyclic one is checked by
phase two and becomes `Can.DeclareRec`. Every bad cycle within the first
phase-one component that has one is reported, and later components are not
checked.
-}
detectCycles : List (Graph.SCC NodeTwo) -> MResult i w Can.Decls
detectCycles sccs =
    case sccs of
        [] ->
            ReportingResult.ok Can.SaveTheEnvironment

        scc :: otherSccs ->
            case scc of
                Graph.AcyclicSCC ( def, _, _ ) ->
                    ReportingResult.map (Can.Declare def) (detectCycles otherSccs)

                Graph.CyclicSCC subNodes ->
                    ReportingResult.traverse detectBadCycles (Graph.stronglyConnComp subNodes)
                        |> ReportingResult.andThen
                            (\defs ->
                                case defs of
                                    [] ->
                                        detectCycles otherSccs

                                    d :: ds ->
                                        ReportingResult.map (Can.DeclareRec d ds) (detectCycles otherSccs)
                            )


{-| Returns the definition of a phase-two component that has no cycle, and
throws `RecursiveDecl` naming every definition of one that has.

A phase-two edge is a direct use by a zero-argument definition, so a cycle here
is a set of values whose evaluation would need one another's values first.

-}
detectBadCycles : Graph.SCC Can.Def -> MResult i w Can.Def
detectBadCycles scc =
    case scc of
        Graph.AcyclicSCC def ->
            ReportingResult.ok def

        Graph.CyclicSCC [] ->
            crash "The definition of Data.Graph.SCC should not allow empty CyclicSCC!"

        Graph.CyclicSCC (def :: defs) ->
            let
                (A.At region name) =
                    extractDefName def

                names : List Name
                names =
                    List.map (extractDefName >> A.toValue) defs
            in
            ReportingResult.throw (Error.RecursiveDecl region name names)


{-| Returns the located name of a definition, typed or not.
-}
extractDefName : Can.Def -> A.Located Name
extractDefName def =
    case def of
        Can.Def name _ _ ->
            name

        Can.TypedDef name _ _ _ _ ->
            name



-- ====== CYCLE DETECTION SETUP ======


{-| A node of the phase-one graph: the definition's phase-two node, its name,
and every name its body uses, directly or delayed.

The names are the ones the body mentions, not their transitive closure.

-}
type alias NodeOne =
    ( NodeTwo, Name.Name, List Name.Name )


{-| A node of the phase-two graph: the canonical definition, its name, and the
names it depends on directly. A definition with parameters has none, as
`toNodeTwo` decides.
-}
type alias NodeTwo =
    ( Can.Def, Name, List Name )


{-| Returns the phase-one node for the top-level `value` canonicalized in `env`,
with the id state after it, numbering its nodes from `idState`.

It throws `TooLarge` when the definition has more parameters than
`Compiler.Data.HeapLimits.maxStageArity`. A top-level definition captures
nothing, so its parameters alone decide this.

-}
toNodeOne : Env.Env -> Ids.IdState -> A.Located Src.Value -> MResult i (List W.Warning) ( NodeOne, Ids.IdState )
toNodeOne env idState ((A.At _ (Src.Value valueData)) as value) =
    let
        ( _, A.At nameRegion name ) =
            valueData.name
    in
    case Expr.tooManyParams nameRegion (Error.TooManyParams name) valueData.args of
        Just err ->
            ReportingResult.throw err

        Nothing ->
            toNodeOneHelp env idState value


{-| Returns what `toNodeOne` returns, for a definition whose parameter count is
within the limit.

An annotated definition becomes `Can.TypedDef`, its parameters typed from the
annotation, and an unannotated one becomes `Can.Def`. The parameters' bindings
are checked for unused names, which come back as warnings.

-}
toNodeOneHelp : Env.Env -> Ids.IdState -> A.Located Src.Value -> MResult i (List W.Warning) ( NodeOne, Ids.IdState )
toNodeOneHelp env idState (A.At _ (Src.Value valueData)) =
    let
        ( _, (A.At _ name) as aname ) =
            valueData.name

        srcArgs =
            valueData.args

        ( _, body ) =
            valueData.body
    in
    case valueData.tipe of
        Nothing ->
            Pattern.verifyWithIds (Error.DPFuncArgs name)
                (Pattern.traverseWithIds env idState (List.map Src.c1Value srcArgs))
                |> ReportingResult.andThen
                    (\( args, argBindings, stateAfterArgs ) ->
                        Env.addLocals argBindings env
                            |> ReportingResult.andThen
                                (\newEnv ->
                                    Expr.verifyBindingsWithIds W.Pattern
                                        argBindings
                                        (Expr.canonicalizeWithIds newEnv stateAfterArgs body)
                                        |> ReportingResult.map
                                            (\( ( cbody, finalState ), freeLocals ) ->
                                                let
                                                    def : Can.Def
                                                    def =
                                                        Can.Def aname args cbody
                                                in
                                                ( ( toNodeTwo name srcArgs def freeLocals
                                                  , name
                                                  , Dict.keys freeLocals
                                                  )
                                                , finalState
                                                )
                                            )
                                )
                    )

        Just ( _, ( _, srcType ) ) ->
            Type.toAnnotation env srcType
                |> ReportingResult.andThen
                    (\(Can.Forall freeVars tipe) ->
                        Pattern.verifyWithIds (Error.DPFuncArgs name)
                            (Expr.gatherTypedArgsWithIds env name idState (List.map Src.c1Value srcArgs) tipe Index.first [])
                            |> ReportingResult.andThen
                                (\( ( args, resultType ), argBindings, stateAfterArgs ) ->
                                    Env.addLocals argBindings env
                                        |> ReportingResult.andThen
                                            (\newEnv ->
                                                Expr.verifyBindingsWithIds W.Pattern
                                                    argBindings
                                                    (Expr.canonicalizeWithIds newEnv stateAfterArgs body)
                                                    |> ReportingResult.map
                                                        (\( ( cbody, finalState ), freeLocals ) ->
                                                            let
                                                                def : Can.Def
                                                                def =
                                                                    Can.TypedDef aname freeVars args cbody resultType
                                                            in
                                                            ( ( toNodeTwo name srcArgs def freeLocals
                                                              , name
                                                              , Dict.keys freeLocals
                                                              )
                                                            , finalState
                                                            )
                                                        )
                                            )
                                )
                    )


{-| Returns the phase-two node for `def`. When `args` is empty, its edges are
the names in `freeLocals` with at least one direct use; otherwise it has none,
because a function's body runs only when the function is called.
-}
toNodeTwo : Name -> List arg -> Can.Def -> Expr.FreeLocals -> NodeTwo
toNodeTwo name args def freeLocals =
    case args of
        [] ->
            ( def, name, Dict.foldr addDirects [] freeLocals )

        _ ->
            ( def, name, [] )


{-| Returns `directDeps` with `name` added in front when its uses include at
least one direct use.
-}
addDirects : Name -> Expr.Uses -> List Name -> List Name
addDirects name (Expr.Uses { direct }) directDeps =
    if direct > 0 then
        name :: directDeps

    else
        directDeps



-- ====== CANONICALIZE EXPORTS ======


{-| Returns the module's exports. `exposing (..)` exports everything. An explicit
list is checked item by item against the module's `values`, `unions`,
`aliases`, `binops` and ports, and naming the same item twice is
`ExportDuplicate`.
-}
canonicalizeExports :
    List (A.Located Src.Value)
    -> Dict Name union
    -> Dict Name alias
    -> Dict Name binop
    -> Can.Effects
    -> A.Located Src.Exposing
    -> MResult i w Can.Exports
canonicalizeExports values unions aliases binops effects (A.At region exposing_) =
    case exposing_ of
        Src.Open _ _ ->
            ReportingResult.ok (Can.ExportEverything region)

        Src.Explicit (A.At _ exposeds) ->
            let
                names : Dict Name ()
                names =
                    Dict.fromList (List.map valueToName values)
            in
            ReportingResult.traverse (checkExposed names unions aliases binops effects) (List.map Src.c2Value exposeds)
                |> ReportingResult.andThen
                    (\infos ->
                        Dups.detect Error.ExportDuplicate (Dups.unions infos)
                            |> ReportingResult.map (\dm -> Can.Export dm)
                    )


{-| Returns the name of a top-level value declaration, as a key for a set of
names.
-}
valueToName : A.Located Src.Value -> ( Name, () )
valueToName (A.At _ (Src.Value v)) =
    let
        ( _, A.At _ name ) =
            v.name
    in
    ( name, () )


{-| Returns the export for one item of an explicit exposing list, or the error
that rejects it.

A lower-case name must be a value or a port, and the error for one that is
neither suggests both. An operator must be declared infix in the module. A type
name must be a union or an alias, and `Alias(..)` is `ExportOpenAlias`.

-}
checkExposed :
    Dict Name value
    -> Dict Name union
    -> Dict Name alias
    -> Dict Name binop
    -> Can.Effects
    -> Src.Exposed
    -> MResult i w (Dups.Tracker (A.Located Can.Export))
checkExposed values unions aliases binops effects exposed =
    case exposed of
        Src.Lower (A.At region name) ->
            if Dict.member name values then
                ok name region Can.ExportValue

            else
                case checkPorts effects name of
                    Nothing ->
                        ok name region Can.ExportPort

                    Just ports ->
                        ReportingResult.throw (Error.ExportNotFound region Error.BadVar name (ports ++ Dict.keys values))

        Src.Operator region name ->
            if Dict.member name binops then
                ok name region Can.ExportBinop

            else
                ReportingResult.throw (Error.ExportNotFound region Error.BadOp name (Dict.keys binops))

        Src.Upper (A.At region name) ( _, Src.Public dotDotRegion ) ->
            if Dict.member name unions then
                ok name region Can.ExportUnionOpen

            else if Dict.member name aliases then
                ReportingResult.throw (Error.ExportOpenAlias dotDotRegion name)

            else
                ReportingResult.throw (Error.ExportNotFound region Error.BadType name (Dict.keys unions ++ Dict.keys aliases))

        Src.Upper (A.At region name) ( _, Src.Private ) ->
            if Dict.member name unions then
                ok name region Can.ExportUnionClosed

            else if Dict.member name aliases then
                ok name region Can.ExportAlias

            else
                ReportingResult.throw (Error.ExportNotFound region Error.BadType name (Dict.keys unions ++ Dict.keys aliases))


{-| Returns `Nothing` when `name` is a port of `effects`, and otherwise `Just`
the module's port names, as suggestions for an error. The sense is inverted on
purpose: `Nothing` is the success.
-}
checkPorts : Can.Effects -> Name -> Maybe (List Name)
checkPorts effects name =
    case effects of
        Can.NoEffects ->
            Just []

        Can.Ports ports ->
            if Dict.member name ports then
                Nothing

            else
                Just (Dict.keys ports)

        Can.Manager _ _ _ _ ->
            Just []


{-| Returns a successful check of one exported item, recorded under `name` for
duplicate detection.
-}
ok : Name -> A.Region -> Can.Export -> MResult i w (Dups.Tracker (A.Located Can.Export))
ok name region export =
    ReportingResult.ok (Dups.one name region (A.At region export))
