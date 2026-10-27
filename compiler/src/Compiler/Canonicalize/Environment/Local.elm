module Compiler.Canonicalize.Environment.Local exposing (LResult, add)

{-| Before the bodies of a module can be canonicalized, the module's own
top-level values, types and constructors have to be in scope, and this module
puts them there. Adding them is also where a module's declarations are checked
against each other: names declared twice, badly formed type parameters,
recursive type aliases, and types too large for the runtime's heap objects.

`add` extends an environment, which already holds whatever the imports bring
in (see `Compiler.Canonicalize.Environment`), in three steps.

Types come first. Two types of one name are an error, whether each is a union
or an alias. Each union is entered with its arity once its parameters are
checked: no parameter may be named twice, and every type variable its
constructors use must be a parameter, though a parameter may go unused. Aliases
are canonicalized and entered in dependency order, so an alias can refer to one
declared after it; the order comes from the strongly connected components of
the graph in which an alias points at each unqualified type name in its body.
A component holding more than one alias, or an alias that names itself, is
reported as `RecursiveAlias`. An alias's parameters must be exactly the type
variables its body uses, and an alias of a record type may have at most
`HeapLimits.maxRecordFields` fields.

Values come second: the top-level values, plus the ports of a port module or
the `command` and `subscription` names of an effect module.

Constructors come last: those of every union, and one for each alias of a
closed record type, which is a function from the record's fields to the record.
A union constructor may have at most `HeapLimits.maxCtorFields` arguments.
Each union also gets its _constructor options_ (`Can.CtorOpts`) here: `Unbox`
for exactly one constructor with exactly one argument, `Enum` when every
constructor has no arguments, and `Normal` otherwise.

Values, types and constructors are three separate namespaces, each checked
for duplicates on its own, so a type and a constructor may share a name. A
local value or constructor replaces an imported one of the same name rather
than making it ambiguous.

@docs LResult, add

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Environment as Env
import Compiler.Canonicalize.Environment.Dups as Dups
import Compiler.Canonicalize.Type as Type
import Compiler.Data.HeapLimits as HeapLimits
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Graph as Graph
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Dict exposing (Dict)
import Utils.Main as Utils



-- ====== RESULT ======


{-| The result of a step that can fail with a canonicalization error.

This is a name for `ReportingResult.RResult` with the error type fixed, not a
new type.

-}
type alias LResult i w a =
    ReportingResult.RResult i w Error.Error a


{-| The module's canonical union types, keyed by type name.
-}
type alias Unions =
    Dict Name Can.Union


{-| The module's canonical type aliases, keyed by alias name.
-}
type alias Aliases =
    Dict Name Can.Alias


{-| Returns `env` extended with the types, values and constructors that
`module_` declares, together with the module's canonical unions and aliases, or
the errors of the first step that fails.

Types are added first, then values, then constructors, and a local value or
constructor replaces an imported one of the same name. The checks made on the
way are the ones the module documentation lists: duplicate types, values and
constructors, type parameters, recursive aliases, and the field limits.

-}
add : Src.Module -> Env.Env -> LResult i w ( Env.Env, Unions, Aliases )
add module_ env =
    addTypes module_ env
        |> ReportingResult.andThen (addVars module_)
        |> ReportingResult.andThen (addCtors module_)



-- ====== ADD VARS ======


{-| Returns `env` with the module's top-level values, ports and effect-manager
names added as top-level variables, replacing any imported variable of the same
name, or fails with `DuplicateDecl`.
-}
addVars : Src.Module -> Env.Env -> LResult i w Env.Env
addVars module_ env =
    collectVars module_
        |> ReportingResult.map
            (\topLevelVars ->
                let
                    vs2 : Dict Name Env.Var
                    vs2 =
                        Dict.union topLevelVars env.vars
                in
                -- The local map is the first argument, so a local name replaces an imported one.
                { env | vars = vs2 }
            )


{-| Returns the module's top-level values together with its ports or
effect-manager names, each mapped to `TopLevel` at its region, or fails with
`DuplicateDecl` for a name that occurs twice among them.
-}
collectVars : Src.Module -> LResult i w (Dict Name.Name Env.Var)
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


{-| Returns a tracker of the names a module's effects declare: each port's
name, or for an effect module `command` and/or `subscription` at the region of
the manager's corresponding type, or nothing for a module without effects.
-}
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



-- ====== ADD TYPES ======


{-| Returns `env` with the module's unions and aliases added to its types, or
fails with `DuplicateType` when two of them share a name, or with the errors of
the first union or alias that fails.

Unions are added before any alias, so an alias body can name any local union.

-}
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
                    |> ReportingResult.andThen (\ts1 -> { env | types = ts1 } |> addAliases srcData.aliases)
            )


{-| Returns `types` with the union added under its name, with its arity, once
its parameters pass `checkUnionFreeVars`.
-}
addUnion : ModuleName.Canonical -> Env.Exposed Env.Type -> A.Located Src.Union -> LResult i w (Env.Exposed Env.Type)
addUnion home types ((A.At _ (Src.Union ( _, A.At _ name ) _ _)) as union) =
    ReportingResult.map
        (\arity ->
            let
                one : Env.Info Env.Type
                one =
                    Env.Specific home (Env.Union arity home)
            in
            Dict.insert name one types
        )
        (checkUnionFreeVars union)



-- ====== ADD TYPE ALIASES ======


{-| Returns `env` with every alias in `aliases` added, taken in the order of
the strongly connected components of their dependency graph, so that each alias
is canonicalized after the aliases it names.
-}
addAliases : List (A.Located Src.Alias) -> Env.Env -> LResult i w Env.Env
addAliases aliases env =
    let
        nodes : List ( A.Located Src.Alias, Name, List Name )
        nodes =
            List.map toNode aliases

        sccs : List (Graph.SCC (A.Located Src.Alias))
        sccs =
            Graph.stronglyConnComp nodes
    in
    Utils.foldM addAlias env sccs


{-| Returns `env` with one strongly connected component of the alias graph
added.

A single alias that does not name itself is checked for its parameters and
record size, canonicalized against `env`, and entered. A cyclic component fails
with `RecursiveAlias`, naming one of its aliases and the others in it, once
that alias's parameters have been checked. An empty cyclic component adds
nothing.

-}
addAlias : Env.Env -> Graph.SCC (A.Located Src.Alias) -> LResult i w Env.Env
addAlias ({ home, vars, types, ctors, binops, q_vars, q_types, q_ctors } as env) scc =
    case scc of
        Graph.AcyclicSCC ((A.At _ (Src.Alias aliasData)) as alias) ->
            let
                ( _, A.At nameRegion name ) =
                    aliasData.name

                ( _, tipe ) =
                    aliasData.tipe
            in
            checkAliasFreeVars alias
                |> ReportingResult.andThen (\args -> checkAliasRecordSize nameRegion name tipe |> ReportingResult.map (\_ -> args))
                |> ReportingResult.andThen
                    (\args ->
                        Type.canonicalize env tipe
                            |> ReportingResult.andThen
                                (\ctype ->
                                    let
                                        one : Env.Info Env.Type
                                        one =
                                            Env.Specific home (Env.Alias (List.length args) home args ctype)

                                        ts1 : Dict Name (Env.Info Env.Type)
                                        ts1 =
                                            Dict.insert name one types
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


{-| Fails with `TooLarge` (`TooManyRecordFields (Just name)`) at the alias name
when the alias's body is a record type, possibly in parentheses, with more than
`HeapLimits.maxRecordFields` fields, and succeeds otherwise. It runs before the
body is canonicalized, so the error names the alias.
-}
checkAliasRecordSize : A.Region -> Name -> Src.Type -> LResult i w ()
checkAliasRecordSize nameRegion name tipe =
    case recordFieldCount tipe of
        Just n ->
            if n > HeapLimits.maxRecordFields then
                ReportingResult.throw (Error.TooLarge nameRegion (Error.TooManyRecordFields (Just name)) n HeapLimits.maxRecordFields)

            else
                ReportingResult.ok ()

        Nothing ->
            ReportingResult.ok ()


{-| Returns the number of fields of a source record type, looking through
parentheses, or `Nothing` if the type is not a record.
-}
recordFieldCount : Src.Type -> Maybe Int
recordFieldCount (A.At _ tipe) =
    case tipe of
        Src.TRecord fields _ _ ->
            Just (List.length fields)

        Src.TParens ( _, inner ) ->
            recordFieldCount inner

        _ ->
            Nothing



-- ====== DETECT TYPE ALIAS CYCLES ======


{-| Returns an alias as a node of the alias dependency graph: the alias, its
name as the key, and the type names its body uses as edges.
-}
toNode : A.Located Src.Alias -> ( A.Located Src.Alias, Name.Name, List Name.Name )
toNode ((A.At _ (Src.Alias aliasData)) as alias) =
    let
        ( _, A.At _ name ) =
            aliasData.name

        ( _, tipe ) =
            aliasData.tipe
    in
    ( alias, name, getEdges tipe [] )


{-| Returns `edges` with every unqualified type name used in a type added.

Qualified names are left out, because a module cannot name its own types
qualified. Names that are not local aliases are kept, and the graph ignores
them.

-}
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



-- ====== CHECK FREE VARIABLES ======


{-| Returns the number of parameters of a union, or fails with
`DuplicateUnionArg` when a parameter is named twice, or with
`TypeVarsUnboundInUnion` when a constructor uses a type variable that is not a
parameter. An unused parameter is allowed.
-}
checkUnionFreeVars : A.Located Src.Union -> LResult i w Int
checkUnionFreeVars (A.At unionRegion (Src.Union ( _, A.At _ name ) args ctors)) =
    let
        addArg : A.Located Name -> Dups.Tracker A.Region -> Dups.Tracker A.Region
        addArg (A.At region arg) dict =
            Dups.insert arg region region dict

        addCtorFreeVars : ( a, List Src.Type ) -> Dict Name A.Region -> Dict Name A.Region
        addCtorFreeVars ( _, tipes ) freeVars =
            List.foldl addFreeVars freeVars tipes
    in
    Dups.detect (Error.DuplicateUnionArg name) (List.foldr addArg Dups.none (List.map Src.c1Value args))
        |> ReportingResult.andThen
            (\boundVars ->
                let
                    freeVars : Dict Name A.Region
                    freeVars =
                        List.foldr addCtorFreeVars Dict.empty (List.map (Src.c2EolValue >> Tuple.mapSecond (List.map Src.c1Value)) ctors)
                in
                case Dict.toList (Dict.diff freeVars boundVars) of
                    [] ->
                        ReportingResult.ok (List.length args)

                    unbound :: unbounds ->
                        Error.TypeVarsUnboundInUnion unionRegion name (List.map (Src.c1Value >> A.toValue) args) unbound unbounds |> ReportingResult.throw
            )


{-| Returns the parameter names of an alias, in order, or fails with
`DuplicateAliasArg` when one is named twice, or with `TypeVarsMessedUpInAlias`
when the parameters are not exactly the type variables the body uses, which
lists the unused parameters and the unbound variables.
-}
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
                    freeVars : Dict Name A.Region
                    freeVars =
                        addFreeVars tipe Dict.empty

                    -- Set equality as equal sizes plus one-way containment, which builds no new dict.
                    sameVars : Bool
                    sameVars =
                        (Dict.size boundVars == Dict.size freeVars)
                            && Dict.foldl (\var _ ok -> ok && Dict.member var freeVars) True boundVars
                in
                if sameVars then
                    ReportingResult.ok (List.map (Src.c1Value >> A.toValue) aliasData.args)

                else
                    ReportingResult.throw <|
                        Error.TypeVarsMessedUpInAlias aliasRegion
                            name
                            (List.map (Src.c1Value >> A.toValue) aliasData.args)
                            (Dict.toList (Dict.diff boundVars freeVars))
                            (Dict.toList (Dict.diff freeVars boundVars))
            )


{-| Returns `freeVars` with every type variable in a type added, including a
record's extension variable, each mapped to the region of an occurrence.
-}
addFreeVars : Src.Type -> Dict Name.Name A.Region -> Dict Name.Name A.Region
addFreeVars (A.At region tipe) freeVars =
    case tipe of
        Src.TLambda ( _, arg ) ( _, result ) ->
            addFreeVars result (addFreeVars arg freeVars)

        Src.TVar name ->
            Dict.insert name region freeVars

        Src.TType _ _ args ->
            List.foldl addFreeVars freeVars (List.map Src.c1Value args)

        Src.TTypeQual _ _ _ args ->
            List.foldl addFreeVars freeVars (List.map Src.c1Value args)

        Src.TRecord fields maybeExt _ ->
            let
                extFreeVars : Dict Name A.Region
                extFreeVars =
                    case maybeExt of
                        Nothing ->
                            freeVars

                        Just ( _, A.At extRegion ext ) ->
                            Dict.insert ext extRegion freeVars
            in
            List.foldl (\( _, ( _, ( _, t ) ) ) fvs -> addFreeVars t fvs) extFreeVars fields

        Src.TUnit ->
            freeVars

        Src.TTuple ( _, a ) ( _, b ) cs ->
            List.foldl addFreeVars (addFreeVars b (addFreeVars a freeVars)) (List.map Src.c2EolValue cs)

        Src.TParens ( _, tipe_ ) ->
            addFreeVars tipe_ freeVars



-- ====== ADD CTORS ======


{-| Returns `env` with the module's union and record-alias constructors added,
replacing imported constructors of the same name, together with the module's
canonical unions and aliases, or fails: first with the errors from
canonicalizing the unions, then with those from the aliases, and, once both
succeed, with `DuplicateCtor`.
-}
addCtors : Src.Module -> Env.Env -> LResult i w ( Env.Env, Unions, Aliases )
addCtors (Src.Module srcData) env =
    ReportingResult.traverse (canonicalizeUnion env) srcData.unions
        |> ReportingResult.andThen
            (\unionInfo ->
                ReportingResult.traverse (canonicalizeAlias env) srcData.aliases
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
                                            cs2 : Dict Name (Env.Info Env.Ctor)
                                            cs2 =
                                                Dict.union ctors env.ctors
                                        in
                                        ReportingResult.ok
                                            ( { env | ctors = cs2 }
                                            , Dict.fromList (List.map Tuple.first unionInfo)
                                            , Dict.fromList (List.map Tuple.first aliasInfo)
                                            )
                                    )
                        )
            )


{-| A tracker of constructor names, each with the environment entry it adds.
-}
type alias CtorDups =
    Dups.Tracker (Env.Info Env.Ctor)



-- ====== CANONICALIZE ALIAS ======


{-| Returns an alias's canonical form under its name, and a tracker holding its
record constructor when the body is a closed record, or nothing otherwise.
-}
canonicalizeAlias : Env.Env -> A.Located Src.Alias -> LResult i w ( ( Name.Name, Can.Alias ), CtorDups )
canonicalizeAlias ({ home } as env) (A.At _ (Src.Alias aliasData)) =
    let
        ( _, A.At region name ) =
            aliasData.name

        ( _, tipe ) =
            aliasData.tipe

        vars : List Name
        vars =
            List.map (Src.c1Value >> A.toValue) aliasData.args
    in
    Type.canonicalize env tipe
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


{-| Returns the constructor of a record alias. Its type is a curried function
taking the record's fields in `Can.fieldsToList` order and returning the alias
applied to its own parameters, with the record as its body.
-}
toRecordCtor : ModuleName.Canonical -> Name.Name -> List Name.Name -> Dict Name.Name (Can.FieldType Name) -> Env.Ctor
toRecordCtor home name vars fields =
    let
        avars : List ( Name, Can.Type Name )
        avars =
            List.map (\var -> ( var, Can.TVar var )) vars

        alias : Can.Type Name
        alias =
            List.foldr
                (\( _, t1 ) t2 -> Can.tLambda t1 t2)
                (Can.TAlias home name avars (Can.Filled (Can.TRecord fields Nothing)))
                (Can.fieldsToList fields)
    in
    Env.RecordCtor home vars alias



-- ====== CANONICALIZE UNION ======


{-| Returns a union's canonical form under its name, and a tracker of its
constructors, which are numbered from zero in declaration order.
-}
canonicalizeUnion : Env.Env -> A.Located Src.Union -> LResult i w ( ( Name.Name, Can.Union ), CtorDups )
canonicalizeUnion ({ home } as env) (A.At _ (Src.Union ( _, A.At _ name ) avars ctors)) =
    ReportingResult.indexedTraverse (canonicalizeCtor env) (List.map (Tuple.mapSecond (List.map Src.c1Value)) (List.map Src.c2EolValue ctors))
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


{-| Returns a constructor with its argument types canonicalized and `index` as
its position in the union, or fails with `TooLarge` at the constructor when it
has more than `HeapLimits.maxCtorFields` arguments.
-}
canonicalizeCtor : Env.Env -> Index.ZeroBased -> ( A.Located Name.Name, List Src.Type ) -> LResult i w (A.Located Can.Ctor)
canonicalizeCtor env index ( A.At region ctor, tipes ) =
    if List.length tipes > HeapLimits.maxCtorFields then
        -- A custom-type value holds at most maxCtorFields fields on the heap.
        ReportingResult.throw (Error.TooLarge region (Error.TooManyCtorFields ctor) (List.length tipes) HeapLimits.maxCtorFields)

    else
        ReportingResult.traverse (Type.canonicalize env) tipes
            |> ReportingResult.andThen
                (\ctipes ->
                    Can.Ctor { name = ctor, index = index, numArgs = List.length ctipes, args = ctipes } |> A.At region |> ReportingResult.ok
                )


{-| Returns a union's constructor options: `Unbox` for exactly one constructor
with exactly one argument, `Enum` when no constructor has an argument, and
`Normal` otherwise.
-}
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


{-| Returns a tracker holding one union constructor under its name, with the
environment entry that refers to it.
-}
toCtor : ModuleName.Canonical -> Name.Name -> Can.Union -> A.Located Can.Ctor -> CtorDups
toCtor home typeName union (A.At region (Can.Ctor c)) =
    Env.Ctor home typeName union c.index c.args |> Env.Specific home |> Dups.one c.name region
