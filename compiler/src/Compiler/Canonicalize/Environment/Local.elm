module Compiler.Canonicalize.Environment.Local exposing (LResult, add)

{-| Add locally-defined declarations to the canonicalization environment.

This module processes declarations within the current module to add:
- Top-level value declarations
- Type aliases and union types
- Constructors for unions and record type aliases
- Validation for duplicate names and cyclic type aliases

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Environment as Env
import Compiler.Canonicalize.Environment.Dups as Dups
import Compiler.Canonicalize.Type as Type
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Parse.SyntaxVersion exposing (SyntaxVersion)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Data.Graph as Graph
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO
import Utils.Main as Utils



-- RESULT


{-| Result type for local environment operations that can fail with canonicalization errors.
-}
type alias LResult i w a =
    ReportingResult.RResult i w Error.Error a


{-| Canonicalized union type definitions.
-}
type alias Unions =
    Dict String Name Can.Union


{-| Canonicalized type alias definitions.
-}
type alias Aliases =
    Dict String Name Can.Alias


{-| Add all local declarations from a module to the environment.

Processes the module's declarations in order:
1. Types (unions and aliases) - validates names and detects cycles
2. Values (top-level declarations and ports)
3. Constructors (from unions and record aliases)

Returns the updated environment along with canonicalized unions and aliases.

-}
add : Src.Module -> Env.Env -> LResult i w ( Env.Env, Unions, Aliases )
add module_ env =
    addTypes module_ env
        |> ReportingResult.andThen (addVars module_)
        |> ReportingResult.andThen (addCtors module_)



-- ADD VARS


addVars : Src.Module -> Env.Env -> LResult i w Env.Env
addVars module_ env =
    collectVars module_
        |> ReportingResult.map
            (\topLevelVars ->
                let
                    vs2 : Dict String Name Env.Var
                    vs2 =
                        Dict.union topLevelVars env.vars
                in
                -- Use union to overwrite foreign stuff.
                { env | vars = vs2 }
            )


collectVars : Src.Module -> LResult i w (Dict String Name.Name Env.Var)
collectVars (Src.Module srcData) =
    let
        addDecl : A.Located Src.Value -> Dups.Tracker Env.Var -> Dups.Tracker Env.Var
        addDecl (A.At _ (Src.Value v)) =
            let
                ( _, A.At region name ) =
                    v.name
            in
            Dups.insert name region (Env.TopLevel region)
    in
    List.foldl addDecl (toEffectDups srcData.effects) srcData.values |> Dups.detect Error.DuplicateDecl


toEffectDups : Src.Effects -> Dups.Tracker Env.Var
toEffectDups effects =
    case effects of
        Src.NoEffects ->
            Dups.none

        Src.Ports ports ->
            let
                addPort : Src.Port -> Dups.Tracker Env.Var -> Dups.Tracker Env.Var
                addPort (Src.Port _ ( _, A.At region name ) _) =
                    Dups.insert name region (Env.TopLevel region)
            in
            List.foldl addPort Dups.none ports

        Src.Manager _ manager ->
            case manager of
                Src.Cmd ( _, ( _, A.At region _ ) ) ->
                    Dups.one "command" region (Env.TopLevel region)

                Src.Sub ( _, ( _, A.At region _ ) ) ->
                    Dups.one "subscription" region (Env.TopLevel region)

                Src.Fx ( _, ( _, A.At regionCmd _ ) ) ( _, ( _, A.At regionSub _ ) ) ->
                    Dups.union
                        (Dups.one "command" regionCmd (Env.TopLevel regionCmd))
                        (Dups.one "subscription" regionSub (Env.TopLevel regionSub))



-- ADD TYPES


addTypes : Src.Module -> Env.Env -> LResult i w Env.Env
addTypes (Src.Module srcData) env =
    let
        addAliasDups : A.Located Src.Alias -> Dups.Tracker () -> Dups.Tracker ()
        addAliasDups (A.At _ (Src.Alias data)) =
            let
                ( _, A.At region name ) =
                    data.name
            in
            Dups.insert name region ()

        addUnionDups : A.Located Src.Union -> Dups.Tracker () -> Dups.Tracker ()
        addUnionDups (A.At _ (Src.Union ( _, A.At region name ) _ _)) =
            Dups.insert name region ()

        typeNameDups : Dups.Tracker ()
        typeNameDups =
            List.foldl addUnionDups (List.foldl addAliasDups Dups.none srcData.aliases) srcData.unions
    in
    Dups.detect Error.DuplicateType typeNameDups
        |> ReportingResult.andThen
            (\_ ->
                Utils.foldM (addUnion env.home) env.types srcData.unions
                    |> ReportingResult.andThen (\ts1 -> { env | types = ts1 } |> addAliases srcData.syntaxVersion srcData.aliases)
            )


addUnion : IO.Canonical -> Env.Exposed Env.Type -> A.Located Src.Union -> LResult i w (Env.Exposed Env.Type)
addUnion home types ((A.At _ (Src.Union ( _, A.At _ name ) _ _)) as union) =
    ReportingResult.map
        (\arity ->
            let
                one : Env.Info Env.Type
                one =
                    Env.Specific home (Env.Union arity home)
            in
            Dict.insert identity name one types
        )
        (checkUnionFreeVars union)



-- ADD TYPE ALIASES


addAliases : SyntaxVersion -> List (A.Located Src.Alias) -> Env.Env -> LResult i w Env.Env
addAliases syntaxVersion aliases env =
    let
        nodes : List ( A.Located Src.Alias, Name, List Name )
        nodes =
            List.map toNode aliases

        sccs : List (Graph.SCC (A.Located Src.Alias))
        sccs =
            Graph.stronglyConnComp nodes
    in
    Utils.foldM (addAlias syntaxVersion) env sccs


addAlias : SyntaxVersion -> Env.Env -> Graph.SCC (A.Located Src.Alias) -> LResult i w Env.Env
addAlias syntaxVersion ({ home, vars, types, ctors, binops, q_vars, q_types, q_ctors } as env) scc =
    case scc of
        Graph.AcyclicSCC ((A.At _ (Src.Alias aliasData)) as alias) ->
            let
                ( _, A.At _ name ) =
                    aliasData.name

                ( _, tipe ) =
                    aliasData.tipe
            in
            checkAliasFreeVars alias
                |> ReportingResult.andThen
                    (\args ->
                        Type.canonicalize syntaxVersion env tipe
                            |> ReportingResult.andThen
                                (\ctype ->
                                    let
                                        one : Env.Info Env.Type
                                        one =
                                            Env.Specific home (Env.Alias (List.length args) home args ctype)

                                        ts1 : Dict String Name (Env.Info Env.Type)
                                        ts1 =
                                            Dict.insert identity name one types
                                    in
                                    ReportingResult.ok (Env.Env home vars ts1 ctors binops q_vars q_types q_ctors)
                                )
                    )

        Graph.CyclicSCC [] ->
            ReportingResult.ok env

        Graph.CyclicSCC (((A.At _ (Src.Alias aliasData)) as alias) :: others) ->
            let
                ( _, A.At region name1 ) =
                    aliasData.name

                ( _, tipe ) =
                    aliasData.tipe
            in
            checkAliasFreeVars alias
                |> ReportingResult.andThen
                    (\args ->
                        let
                            toName : A.Located Src.Alias -> Name
                            toName (A.At _ (Src.Alias ad)) =
                                let
                                    ( _, A.At _ name ) =
                                        ad.name
                                in
                                name
                        in
                        ReportingResult.throw (Error.RecursiveAlias region name1 args tipe (List.map toName others))
                    )



-- DETECT TYPE ALIAS CYCLES


toNode : A.Located Src.Alias -> ( A.Located Src.Alias, Name.Name, List Name.Name )
toNode ((A.At _ (Src.Alias aliasData)) as alias) =
    let
        ( _, A.At _ name ) =
            aliasData.name

        ( _, tipe ) =
            aliasData.tipe
    in
    ( alias, name, getEdges tipe [] )


getEdges : Src.Type -> List Name.Name -> List Name.Name
getEdges (A.At _ tipe) edges =
    case tipe of
        Src.TLambda ( _, arg ) ( _, result ) ->
            getEdges result (getEdges arg edges)

        Src.TVar _ ->
            edges

        Src.TType _ name args ->
            List.foldl getEdges (name :: edges) (List.map Src.c1Value args)

        Src.TTypeQual _ _ _ args ->
            List.foldl getEdges edges (List.map Src.c1Value args)

        Src.TRecord fields _ _ ->
            List.foldl (\( _, ( _, ( _, t ) ) ) es -> getEdges t es) edges fields

        Src.TUnit ->
            edges

        Src.TTuple ( _, a ) ( _, b ) cs ->
            List.foldl getEdges (getEdges b (getEdges a edges)) (List.map Src.c2EolValue cs)

        Src.TParens ( _, tipe_ ) ->
            getEdges tipe_ edges



-- CHECK FREE VARIABLES


checkUnionFreeVars : A.Located Src.Union -> LResult i w Int
checkUnionFreeVars (A.At unionRegion (Src.Union ( _, A.At _ name ) args ctors)) =
    let
        addArg : A.Located Name -> Dups.Tracker A.Region -> Dups.Tracker A.Region
        addArg (A.At region arg) dict =
            Dups.insert arg region region dict

        addCtorFreeVars : ( a, List Src.Type ) -> Dict String Name A.Region -> Dict String Name A.Region
        addCtorFreeVars ( _, tipes ) freeVars =
            List.foldl addFreeVars freeVars tipes
    in
    Dups.detect (Error.DuplicateUnionArg name) (List.foldr addArg Dups.none (List.map Src.c1Value args))
        |> ReportingResult.andThen
            (\boundVars ->
                let
                    freeVars : Dict String Name A.Region
                    freeVars =
                        List.foldr addCtorFreeVars Dict.empty (List.map (Src.c2EolValue >> Tuple.mapSecond (List.map Src.c1Value)) ctors)
                in
                case Dict.toList compare (Dict.diff freeVars boundVars) of
                    [] ->
                        ReportingResult.ok (List.length args)

                    unbound :: unbounds ->
                        Error.TypeVarsUnboundInUnion unionRegion name (List.map (Src.c1Value >> A.toValue) args) unbound unbounds |> ReportingResult.throw
            )


checkAliasFreeVars : A.Located Src.Alias -> LResult i w (List Name.Name)
checkAliasFreeVars (A.At aliasRegion (Src.Alias aliasData)) =
    let
        ( _, A.At _ name ) =
            aliasData.name

        ( _, tipe ) =
            aliasData.tipe

        addArg : Src.C1 (A.Located Name) -> Dups.Tracker A.Region -> Dups.Tracker A.Region
        addArg ( _, A.At region arg ) dict =
            Dups.insert arg region region dict
    in
    Dups.detect (Error.DuplicateAliasArg name) (List.foldr addArg Dups.none aliasData.args)
        |> ReportingResult.andThen
            (\boundVars ->
                let
                    freeVars : Dict String Name A.Region
                    freeVars =
                        addFreeVars tipe Dict.empty

                    overlap : Int
                    overlap =
                        Dict.size (Dict.intersection compare boundVars freeVars)
                in
                if Dict.size boundVars == overlap && Dict.size freeVars == overlap then
                    ReportingResult.ok (List.map (Src.c1Value >> A.toValue) aliasData.args)

                else
                    ReportingResult.throw <|
                        Error.TypeVarsMessedUpInAlias aliasRegion
                            name
                            (List.map (Src.c1Value >> A.toValue) aliasData.args)
                            (Dict.toList compare (Dict.diff boundVars freeVars))
                            (Dict.toList compare (Dict.diff freeVars boundVars))
            )


addFreeVars : Src.Type -> Dict String Name.Name A.Region -> Dict String Name.Name A.Region
addFreeVars (A.At region tipe) freeVars =
    case tipe of
        Src.TLambda ( _, arg ) ( _, result ) ->
            addFreeVars result (addFreeVars arg freeVars)

        Src.TVar name ->
            Dict.insert identity name region freeVars

        Src.TType _ _ args ->
            List.foldl addFreeVars freeVars (List.map Src.c1Value args)

        Src.TTypeQual _ _ _ args ->
            List.foldl addFreeVars freeVars (List.map Src.c1Value args)

        Src.TRecord fields maybeExt _ ->
            let
                extFreeVars : Dict String Name A.Region
                extFreeVars =
                    case maybeExt of
                        Nothing ->
                            freeVars

                        Just ( _, A.At extRegion ext ) ->
                            Dict.insert identity ext extRegion freeVars
            in
            List.foldl (\( _, ( _, ( _, t ) ) ) fvs -> addFreeVars t fvs) extFreeVars fields

        Src.TUnit ->
            freeVars

        Src.TTuple ( _, a ) ( _, b ) cs ->
            List.foldl addFreeVars (addFreeVars b (addFreeVars a freeVars)) (List.map Src.c2EolValue cs)

        Src.TParens ( _, tipe_ ) ->
            addFreeVars tipe_ freeVars



-- ADD CTORS


addCtors : Src.Module -> Env.Env -> LResult i w ( Env.Env, Unions, Aliases )
addCtors (Src.Module srcData) env =
    ReportingResult.traverse (canonicalizeUnion srcData.syntaxVersion env) srcData.unions
        |> ReportingResult.andThen
            (\unionInfo ->
                ReportingResult.traverse (canonicalizeAlias srcData.syntaxVersion env) srcData.aliases
                    |> ReportingResult.andThen
                        (\aliasInfo ->
                            (Dups.detect Error.DuplicateCtor <|
                                Dups.union
                                    (Dups.unions (List.map Tuple.second unionInfo))
                                    (Dups.unions (List.map Tuple.second aliasInfo))
                            )
                                |> ReportingResult.andThen
                                    (\ctors ->
                                        let
                                            cs2 : Dict String Name (Env.Info Env.Ctor)
                                            cs2 =
                                                Dict.union ctors env.ctors
                                        in
                                        ReportingResult.ok
                                            ( { env | ctors = cs2 }
                                            , Dict.fromList identity (List.map Tuple.first unionInfo)
                                            , Dict.fromList identity (List.map Tuple.first aliasInfo)
                                            )
                                    )
                        )
            )


type alias CtorDups =
    Dups.Tracker (Env.Info Env.Ctor)



-- CANONICALIZE ALIAS


canonicalizeAlias : SyntaxVersion -> Env.Env -> A.Located Src.Alias -> LResult i w ( ( Name.Name, Can.Alias ), CtorDups )
canonicalizeAlias syntaxVersion ({ home } as env) (A.At _ (Src.Alias aliasData)) =
    let
        ( _, A.At region name ) =
            aliasData.name

        ( _, tipe ) =
            aliasData.tipe

        vars : List Name
        vars =
            List.map (Src.c1Value >> A.toValue) aliasData.args
    in
    Type.canonicalize syntaxVersion env tipe
        |> ReportingResult.andThen
            (\ctipe ->
                ReportingResult.ok
                    ( ( name, Can.Alias vars ctipe )
                    , case ctipe of
                        Can.TRecord fields Nothing ->
                            Dups.one name region (Env.Specific home (toRecordCtor home name vars fields))

                        _ ->
                            Dups.none
                    )
            )


toRecordCtor : IO.Canonical -> Name.Name -> List Name.Name -> Dict String Name.Name Can.FieldType -> Env.Ctor
toRecordCtor home name vars fields =
    let
        avars : List ( Name, Can.Type )
        avars =
            List.map (\var -> ( var, Can.TVar var )) vars

        alias : Can.Type
        alias =
            List.foldr
                (\( _, t1 ) t2 -> Can.TLambda t1 t2)
                (Can.TAlias home name avars (Can.Filled (Can.TRecord fields Nothing)))
                (Can.fieldsToList fields)
    in
    Env.RecordCtor home vars alias



-- CANONICALIZE UNION


canonicalizeUnion : SyntaxVersion -> Env.Env -> A.Located Src.Union -> LResult i w ( ( Name.Name, Can.Union ), CtorDups )
canonicalizeUnion syntaxVersion ({ home } as env) (A.At _ (Src.Union ( _, A.At _ name ) avars ctors)) =
    ReportingResult.indexedTraverse (canonicalizeCtor syntaxVersion env) (List.map (Tuple.mapSecond (List.map Src.c1Value)) (List.map Src.c2EolValue ctors))
        |> ReportingResult.andThen
            (\cctors ->
                let
                    vars : List Name
                    vars =
                        List.map (Src.c1Value >> A.toValue) avars

                    alts : List Can.Ctor
                    alts =
                        List.map A.toValue cctors

                    union : Can.Union
                    union =
                        Can.Union { vars = vars, alts = alts, numAlts = List.length alts, opts = toOpts ctors }
                in
                ReportingResult.ok ( ( name, union ), Dups.unions (List.map (toCtor home name union) cctors) )
            )


canonicalizeCtor : SyntaxVersion -> Env.Env -> Index.ZeroBased -> ( A.Located Name.Name, List Src.Type ) -> LResult i w (A.Located Can.Ctor)
canonicalizeCtor syntaxVersion env index ( A.At region ctor, tipes ) =
    ReportingResult.traverse (Type.canonicalize syntaxVersion env) tipes
        |> ReportingResult.andThen
            (\ctipes ->
                Can.Ctor { name = ctor, index = index, numArgs = List.length ctipes, args = ctipes } |> A.At region |> ReportingResult.ok
            )


toOpts : List (Src.C2Eol ( A.Located Name.Name, List (Src.C1 Src.Type) )) -> Can.CtorOpts
toOpts ctors =
    case ctors of
        [ ( _, ( _, [ _ ] ) ) ] ->
            Can.Unbox

        _ ->
            if List.all (List.isEmpty << Tuple.second) (List.map Src.c2EolValue ctors) then
                Can.Enum

            else
                Can.Normal


toCtor : IO.Canonical -> Name.Name -> Can.Union -> A.Located Can.Ctor -> CtorDups
toCtor home typeName union (A.At region (Can.Ctor c)) =
    Env.Ctor home typeName union c.index c.args |> Env.Specific home |> Dups.one c.name region
