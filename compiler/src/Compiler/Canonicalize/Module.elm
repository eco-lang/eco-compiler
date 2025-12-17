module Compiler.Canonicalize.Module exposing
    ( MResult
    , canonicalize
    )

{-| Canonicalize an entire Elm module, transforming it from source AST to canonical AST.

This module orchestrates the canonicalization of all module components including
value declarations, type definitions, infix operators, exports, and effects. It performs
cycle detection for both type inference and runtime termination analysis.


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
import Compiler.Canonicalize.Pattern as Pattern
import Compiler.Canonicalize.Type as Type
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Parse.SyntaxVersion exposing (SyntaxVersion)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Compiler.Reporting.Warning as W
import Data.Graph as Graph
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO
import Utils.Crash exposing (crash)



-- RESULT


{-| Type alias for canonicalization results that can accumulate errors and warnings.
-}
type alias MResult i w a =
    ReportingResult.RResult i w Error.Error a



-- MODULES


{-| Canonicalize an entire source module into a canonical module.

Transforms a source AST module into a canonical AST module by:

  - Creating the initial environment from imported interfaces
  - Adding local declarations to the environment
  - Canonicalizing all value declarations with cycle detection
  - Canonicalizing effects (ports, managers)
  - Canonicalizing and validating exports

-}
canonicalize : Pkg.Name -> Dict String ModuleName.Raw I.Interface -> Src.Module -> MResult i (List W.Warning) Can.Module
canonicalize pkg ifaces ((Src.Module srcData) as modul) =
    let
        home : IO.Canonical
        home =
            IO.Canonical pkg (Src.getName modul)

        cbinops : Dict String Name Can.Binop
        cbinops =
            Dict.fromList identity (List.map canonicalizeBinop srcData.infixes)
    in
    Foreign.createInitialEnv home ifaces srcData.imports
        |> ReportingResult.andThen (Local.add modul)
        |> ReportingResult.andThen
            (\( env, cunions, caliases ) ->
                canonicalizeValues srcData.syntaxVersion env srcData.values
                    |> ReportingResult.andThen
                        (\cvalues ->
                            Effects.canonicalize srcData.syntaxVersion env srcData.values cunions srcData.effects
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



-- CANONICALIZE BINOP


{-| Convert a source infix operator declaration to a canonical binop.

Extracts the operator name, associativity, precedence, and implementing function name
from the source infix declaration.

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



-- DECLARATIONS / CYCLE DETECTION
--
-- There are two phases of cycle detection:
--
-- 1. Detect cycles using ALL dependencies => needed for type inference
-- 2. Detect cycles using DIRECT dependencies => nonterminating recursion
--


{-| Canonicalize all value declarations in a module with two-phase cycle detection.

First converts each value to a dependency graph node, then detects strongly connected
components to identify mutually recursive definitions.

-}
canonicalizeValues : SyntaxVersion -> Env.Env -> List (A.Located Src.Value) -> MResult i (List W.Warning) Can.Decls
canonicalizeValues syntaxVersion env values =
    ReportingResult.traverse (toNodeOne syntaxVersion env) values
        |> ReportingResult.andThen (\nodes -> detectCycles (Graph.stronglyConnComp nodes))


{-| Detect cycles in phase one of cycle detection using all dependencies.

Processes strongly connected components to identify mutually recursive definitions
that form valid recursive groups for type inference.

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


{-| Detect bad cycles in phase two using direct dependencies.

Checks for cycles that represent nonterminating recursion (direct recursive calls
without intervening function boundaries). Reports an error for any such cycles.

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


{-| Extract the name from a canonical definition for error reporting.
-}
extractDefName : Can.Def -> A.Located Name
extractDefName def =
    case def of
        Can.Def name _ _ ->
            name

        Can.TypedDef name _ _ _ _ ->
            name



-- DECLARATIONS / CYCLE DETECTION SETUP
--
-- toNodeOne and toNodeTwo set up nodes for the two cycle detection phases.
--
-- Phase one nodes track ALL dependencies.
-- This allows us to find cyclic values for type inference.


{-| Phase one dependency graph node tracking all dependencies.

Contains the phase two node, the definition name, and all transitive dependencies.
Used for type inference cycle detection.

-}
type alias NodeOne =
    ( NodeTwo, Name.Name, List Name.Name )



-- Phase two nodes track DIRECT dependencies.
-- This allows us to detect cycles that definitely do not terminate.


{-| Phase two dependency graph node tracking only direct dependencies.

Contains the canonical definition, the definition name, and direct dependencies only.
Used for detecting nonterminating recursion.

-}
type alias NodeTwo =
    ( Can.Def, Name, List Name )


{-| Convert a source value declaration to a phase one dependency graph node.

Canonicalizes the value declaration (handling both typed and untyped definitions),
tracks all free variables as dependencies, and constructs a NodeOne for cycle detection.

-}
toNodeOne : SyntaxVersion -> Env.Env -> A.Located Src.Value -> MResult i (List W.Warning) NodeOne
toNodeOne syntaxVersion env (A.At _ (Src.Value valueData)) =
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
            Pattern.verify (Error.DPFuncArgs name)
                (ReportingResult.traverse (Pattern.canonicalize syntaxVersion env) (List.map Src.c1Value srcArgs))
                |> ReportingResult.andThen
                    (\( args, argBindings ) ->
                        Env.addLocals argBindings env
                            |> ReportingResult.andThen
                                (\newEnv ->
                                    Expr.verifyBindings W.Pattern argBindings (Expr.canonicalize syntaxVersion newEnv body)
                                        |> ReportingResult.map
                                            (\( cbody, freeLocals ) ->
                                                let
                                                    def : Can.Def
                                                    def =
                                                        Can.Def aname args cbody
                                                in
                                                ( toNodeTwo name srcArgs def freeLocals
                                                , name
                                                , Dict.keys compare freeLocals
                                                )
                                            )
                                )
                    )

        Just ( _, ( _, srcType ) ) ->
            Type.toAnnotation syntaxVersion env srcType
                |> ReportingResult.andThen
                    (\(Can.Forall freeVars tipe) ->
                        Pattern.verify (Error.DPFuncArgs name)
                            (Expr.gatherTypedArgs syntaxVersion env name (List.map Src.c1Value srcArgs) tipe Index.first [])
                            |> ReportingResult.andThen
                                (\( ( args, resultType ), argBindings ) ->
                                    Env.addLocals argBindings env
                                        |> ReportingResult.andThen
                                            (\newEnv ->
                                                Expr.verifyBindings W.Pattern argBindings (Expr.canonicalize syntaxVersion newEnv body)
                                                    |> ReportingResult.map
                                                        (\( cbody, freeLocals ) ->
                                                            let
                                                                def : Can.Def
                                                                def =
                                                                    Can.TypedDef aname freeVars args cbody resultType
                                                            in
                                                            ( toNodeTwo name srcArgs def freeLocals
                                                            , name
                                                            , Dict.keys compare freeLocals
                                                            )
                                                        )
                                            )
                                )
                    )


{-| Convert a canonical definition to a phase two dependency graph node.

For functions (definitions with arguments), direct dependencies are empty because the
function body doesn't execute until called. For values (no arguments), direct dependencies
are extracted from free variables that are used directly (not in closures).

-}
toNodeTwo : Name -> List arg -> Can.Def -> Expr.FreeLocals -> NodeTwo
toNodeTwo name args def freeLocals =
    case args of
        [] ->
            ( def, name, Dict.foldr compare addDirects [] freeLocals )

        _ ->
            ( def, name, [] )


{-| Add a name to the direct dependencies list if it has direct uses.

A direct use means the variable is referenced at the top level of the expression,
not within a nested function or closure.

-}
addDirects : Name -> Expr.Uses -> List Name -> List Name
addDirects name (Expr.Uses { direct }) directDeps =
    if direct > 0 then
        name :: directDeps

    else
        directDeps



-- CANONICALIZE EXPORTS


{-| Canonicalize the module's export list, validating all exported items exist.

Handles explicit exports (validating each item) and open exports (exposing everything).
Checks that exported values, types, operators, and ports are actually defined in the module.

-}
canonicalizeExports :
    List (A.Located Src.Value)
    -> Dict String Name union
    -> Dict String Name alias
    -> Dict String Name binop
    -> Can.Effects
    -> A.Located Src.Exposing
    -> MResult i w Can.Exports
canonicalizeExports values unions aliases binops effects (A.At region exposing_) =
    case exposing_ of
        Src.Open _ _ ->
            ReportingResult.ok (Can.ExportEverything region)

        Src.Explicit (A.At _ exposeds) ->
            let
                names : Dict String Name ()
                names =
                    Dict.fromList identity (List.map valueToName values)
            in
            ReportingResult.traverse (checkExposed names unions aliases binops effects) (List.map Src.c2Value exposeds)
                |> ReportingResult.andThen
                    (\infos ->
                        Dups.detect Error.ExportDuplicate (Dups.unions infos)
                            |> ReportingResult.map Can.Export
                    )


{-| Extract the name from a source value declaration for export validation.
-}
valueToName : A.Located Src.Value -> ( Name, () )
valueToName (A.At _ (Src.Value v)) =
    let
        ( _, A.At _ name ) =
            v.name
    in
    ( name, () )


{-| Validate that an exposed item exists in the module.

Checks that the exposed item (value, type, operator, or port) is actually defined
in the module and creates the appropriate canonical export. Reports errors for:

  - Values/ports that don't exist
  - Operators that don't exist
  - Types that don't exist
  - Type aliases exposed with (..) syntax

-}
checkExposed :
    Dict String Name value
    -> Dict String Name union
    -> Dict String Name alias
    -> Dict String Name binop
    -> Can.Effects
    -> Src.Exposed
    -> MResult i w (Dups.Tracker (A.Located Can.Export))
checkExposed values unions aliases binops effects exposed =
    case exposed of
        Src.Lower (A.At region name) ->
            if Dict.member identity name values then
                ok name region Can.ExportValue

            else
                case checkPorts effects name of
                    Nothing ->
                        ok name region Can.ExportPort

                    Just ports ->
                        ReportingResult.throw (Error.ExportNotFound region Error.BadVar name (ports ++ Dict.keys compare values))

        Src.Operator region name ->
            if Dict.member identity name binops then
                ok name region Can.ExportBinop

            else
                ReportingResult.throw (Error.ExportNotFound region Error.BadOp name (Dict.keys compare binops))

        Src.Upper (A.At region name) ( _, Src.Public dotDotRegion ) ->
            if Dict.member identity name unions then
                ok name region Can.ExportUnionOpen

            else if Dict.member identity name aliases then
                ReportingResult.throw (Error.ExportOpenAlias dotDotRegion name)

            else
                ReportingResult.throw (Error.ExportNotFound region Error.BadType name (Dict.keys compare unions ++ Dict.keys compare aliases))

        Src.Upper (A.At region name) ( _, Src.Private ) ->
            if Dict.member identity name unions then
                ok name region Can.ExportUnionClosed

            else if Dict.member identity name aliases then
                ok name region Can.ExportAlias

            else
                ReportingResult.throw (Error.ExportNotFound region Error.BadType name (Dict.keys compare unions ++ Dict.keys compare aliases))


{-| Check if a name is a port in the module's effects.

Returns Nothing if the name is a port, or Just a list of all port names if it's not.
This allows distinguishing between values and ports in export validation.

-}
checkPorts : Can.Effects -> Name -> Maybe (List Name)
checkPorts effects name =
    case effects of
        Can.NoEffects ->
            Just []

        Can.Ports ports ->
            if Dict.member identity name ports then
                Nothing

            else
                Just (Dict.keys compare ports)

        Can.Manager _ _ _ _ ->
            Just []


{-| Create a successful export result with duplicate tracking.

Wraps the export in a duplicate tracker to detect multiple exports of the same name.

-}
ok : Name -> A.Region -> Can.Export -> MResult i w (Dups.Tracker (A.Located Can.Export))
ok name region export =
    ReportingResult.ok (Dups.one name region (A.At region export))
