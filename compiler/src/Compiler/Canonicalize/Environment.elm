module Compiler.Canonicalize.Environment exposing
    ( EResult
    , Env, Exposed, Qualified
    , Info(..), Var(..), Type(..), Ctor(..), Binop(..), BinopData
    , addLocals, mergeInfo
    , findType, findTypeQual, findCtor, findCtorQual, findBinop
    )

{-| Canonicalization resolves every name a module mentions to its _home_, the
module that defines it, so it needs a record of what each name in scope
currently means. This module defines that record, the environment `Env`, and
the lookups canonicalization makes in it.

A name can be in scope in two ways. An _exposed_ name is written bare, as
`Just`. A _qualified_ name is written with a prefix, as `Maybe.Just`, where the
prefix is an import's alias or, without one, its module name. The environment
keeps the two apart: one table per kind of name for exposed names, and for
qualified names one table per prefix. Values, types and constructors can be
written either way; operators are only ever exposed.

Two imports can bring in one name from two different modules. That name is
_ambiguous_. Ambiguity is not an error until the name is used, so the
environment records it, as an `Info` holding every home, and the lookup that
meets it reports the error. `mergeInfo` is how two entries for one name are
combined.

Values are kept apart from the other kinds of name because a module's own
definitions and the variables bound inside its expressions live in the same
table as the imported values. A value is _foreign_ when it is imported,
_top-level_ when the module defines it, and _local_ when it is bound inside an
expression, by an argument, a pattern or a `let`.
`addLocals` adds local names, and it is where shadowing is checked.

The environment is built elsewhere: `Compiler.Canonicalize.Environment.Foreign`
builds it from the imports, and `Compiler.Canonicalize.Environment.Local` adds
the module's own declarations.


# Results

@docs EResult


# Environment

@docs Env, Exposed, Qualified


# Name Information

@docs Info, Var, Type, Ctor, Binop, BinopData


# Environment Operations

@docs addLocals, mergeInfo


# Lookup Operations

@docs findType, findTypeQual, findCtor, findCtorQual, findBinop

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Binop as Binop
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.ModuleName exposing (Canonical)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Data.Set as EverySet
import Dict exposing (Dict)



-- ====== RESULT ======


{-| A `Compiler.Reporting.Result` computation whose errors are canonicalization
errors, the result type of every lookup here.
-}
type alias EResult i w a =
    ReportingResult.RResult i w Error.Error a



-- ====== ENVIRONMENT ======


{-| Everything a module can refer to at one point in its source, and what each
name means there.

`home` is the module being canonicalized. `vars` holds every value that can be
written bare: imported, top-level and local alike, as `Var` describes. The
qualified values in `q_vars` carry only their type annotations, because a
qualified name is always foreign.

-}
type alias Env =
    { home : Canonical
    , vars : Dict Name.Name Var
    , types : Exposed Type
    , ctors : Exposed Ctor
    , binops : Exposed Binop
    , q_vars : Qualified (Can.Annotation Name)
    , q_types : Qualified Type
    , q_ctors : Qualified Ctor
    }


{-| The names of one kind that can be written bare, each with what it means.
-}
type alias Exposed a =
    Dict Name.Name (Info a)


{-| The names of one kind that can be written with a prefix, grouped by the
prefix. A prefix shared by two imports holds the names of both.
-}
type alias Qualified a =
    Dict Name.Name (Dict Name.Name (Info a))



-- ====== INFO ======


{-| What one name in scope refers to: one definition, or several from different
modules.

`Specific` carries the home of the definition and the definition itself.

`Ambiguous` carries the homes of every definition the name could mean, and no
definition, because using the name is an error.

-}
type Info a
    = Specific Canonical a
    | Ambiguous Canonical (OneOrMore.OneOrMore Canonical)


{-| Combines two entries for one name into the entry that means both.

Two `Specific` entries with the same home give the first unchanged. Any other
pair gives an `Ambiguous` entry listing the homes of `info1` and then those of
`info2`. The list is not deduplicated, so merging an `Ambiguous` entry with a
home it already holds lists that home twice.

-}
mergeInfo : Info a -> Info a -> Info a
mergeInfo info1 info2 =
    case info1 of
        Specific h1 _ ->
            case info2 of
                Specific h2 _ ->
                    if h1 == h2 then
                        info1

                    else
                        Ambiguous h1 (OneOrMore.one h2)

                Ambiguous h2 hs2 ->
                    Ambiguous h1 (OneOrMore.more (OneOrMore.one h2) hs2)

        Ambiguous h1 hs1 ->
            case info2 of
                Specific h2 _ ->
                    Ambiguous h1 (OneOrMore.more hs1 (OneOrMore.one h2))

                Ambiguous h2 hs2 ->
                    Ambiguous h1 (OneOrMore.more hs1 (OneOrMore.more (OneOrMore.one h2) hs2))



-- ====== VARIABLES ======


{-| What a value name written bare refers to.

`Local` is a name bound inside an expression, and `TopLevel` a name the module
binds at its top level. Each carries the region where the name is bound, which
a `Shadowing` error reports.

`Foreign` is an imported value, with its home and its type annotation.

`Foreigns` is an imported name that two or more modules expose, with all their
homes; it is the value counterpart of an ambiguous `Info`.

-}
type Var
    = Local A.Region
    | TopLevel A.Region
    | Foreign Canonical (Can.Annotation Name)
    | Foreigns Canonical (OneOrMore.OneOrMore Canonical)



-- ====== TYPES ======


{-| What a type name refers to: a type alias or a custom type, with what is
needed to canonicalize a use of it.

In both, the `Int` is the number of type parameters, which the use must supply
in full, and the `Canonical` is the home.

`Alias` also carries the parameter names and the aliased type, written in terms
of those names, so that a use can pair each name with its argument.

-}
type Type
    = Alias Int Canonical (List Name.Name) (Can.Type Name)
    | Union Int Canonical



-- ====== CTORS ======


{-| What a constructor name refers to.

`RecordCtor` is the constructor function a type alias of a closed record
defines: `type alias P = { x : Int }` defines `P : Int -> P`. An alias of an
extensible record defines none. It carries the home, the alias's type
parameters, and the function's type, which takes the fields in order and
returns the alias.

`Ctor` is a constructor of a custom type. It carries the home, the name of the
type, the type's full definition, the constructor's position among the type's
constructors, and its argument types.

-}
type Ctor
    = RecordCtor Canonical (List Name.Name) (Can.Type Name)
    | Ctor Canonical Name.Name Can.Union Index.ZeroBased (List (Can.Type Name))



-- ====== BINOPS ======


{-| An infix operator in scope, with how it groups and the function it stands
for.

`op` is the operator's symbol. `name` is the function it stands for, defined in
`home`, and `annotation` is that function's type.

-}
type alias BinopData =
    { op : Name.Name
    , home : Canonical
    , name : Name.Name
    , annotation : Can.Annotation Name
    , associativity : Binop.Associativity
    , precedence : Binop.Precedence
    }


{-| What an operator symbol refers to: the `BinopData` of one operator.
-}
type Binop
    = Binop BinopData



-- ====== ADD LOCALS ======


{-| Returns `env` with each of `names` in scope as a `Local` bound at its region.

A name already bound locally or at the module's top level fails with a
`Shadowing` error. An imported name, ambiguous or not, is replaced without
error. When several names shadow, only one error is reported.

-}
addLocals : Dict Name.Name A.Region -> Env -> EResult i w Env
addLocals names env =
    ReportingResult.map (\newVars -> { env | vars = newVars })
        (Dict.merge
            (\name region -> ReportingResult.map (Dict.insert name (addLocalLeft region)))
            (\name region var acc ->
                addLocalBoth name region var
                    |> ReportingResult.andThen (\var_ -> ReportingResult.map (Dict.insert name var_) acc)
            )
            (\name var -> ReportingResult.map (Dict.insert name var))
            names
            env.vars
            (ReportingResult.ok Dict.empty)
        )


{-| Returns the entry for a new local bound at `region` whose name is not yet in
scope.
-}
addLocalLeft : A.Region -> Var
addLocalLeft region =
    Local region


{-| Returns the entry for a new local bound at `region` whose name is already in
scope as `var`: the local, if `var` is imported, or a `Shadowing` error naming
both regions if `var` is local or top-level.
-}
addLocalBoth : Name.Name -> A.Region -> Var -> EResult i w Var
addLocalBoth name region var =
    case var of
        Foreign _ _ ->
            ReportingResult.ok (Local region)

        Foreigns _ _ ->
            ReportingResult.ok (Local region)

        Local parentRegion ->
            ReportingResult.throw (Error.Shadowing name parentRegion region)

        TopLevel parentRegion ->
            ReportingResult.throw (Error.Shadowing name parentRegion region)



-- ====== FIND TYPE ======


{-| Looks up a type name written bare at `region`.

An ambiguous name fails with `AmbiguousType`, and a name not in scope with
`NotFoundType`, which lists the type names in scope, bare and qualified, as
suggestions.

-}
findType : A.Region -> Env -> Name.Name -> EResult i w Type
findType region { types, q_types } name =
    case Dict.get name types of
        Just (Specific _ tipe) ->
            ReportingResult.ok tipe

        Just (Ambiguous h hs) ->
            ReportingResult.throw (Error.AmbiguousType region Nothing name h hs)

        Nothing ->
            ReportingResult.throw (Error.NotFoundType region Nothing name (toPossibleNames types q_types))


{-| Looks up the type name `name` written after `prefix`, as in `Dict.Dict`, at
`region`.

It fails as `findType` does. An unknown prefix is reported as `NotFoundType`
too, with the prefix included.

-}
findTypeQual : A.Region -> Env -> Name.Name -> Name.Name -> EResult i w Type
findTypeQual region { types, q_types } prefix name =
    case Dict.get prefix q_types of
        Just qualified ->
            case Dict.get name qualified of
                Just (Specific _ tipe) ->
                    ReportingResult.ok tipe

                Just (Ambiguous h hs) ->
                    ReportingResult.throw (Error.AmbiguousType region (Just prefix) name h hs)

                Nothing ->
                    ReportingResult.throw (Error.NotFoundType region (Just prefix) name (toPossibleNames types q_types))

        Nothing ->
            ReportingResult.throw (Error.NotFoundType region (Just prefix) name (toPossibleNames types q_types))



-- ====== FIND CTOR ======


{-| Looks up a constructor name written bare at `region`.

An ambiguous name fails with `AmbiguousVariant`, and a name not in scope with
`NotFoundVariant`, which lists the constructor names in scope, bare and
qualified, as suggestions.

-}
findCtor : A.Region -> Env -> Name.Name -> EResult i w Ctor
findCtor region { ctors, q_ctors } name =
    case Dict.get name ctors of
        Just (Specific _ ctor) ->
            ReportingResult.ok ctor

        Just (Ambiguous h hs) ->
            ReportingResult.throw (Error.AmbiguousVariant region Nothing name h hs)

        Nothing ->
            ReportingResult.throw (Error.NotFoundVariant region Nothing name (toPossibleNames ctors q_ctors))


{-| Looks up the constructor name `name` written after `prefix`, as in
`Maybe.Just`, at `region`.

It fails as `findCtor` does. An unknown prefix is reported as
`NotFoundVariant` too, with the prefix included.

-}
findCtorQual : A.Region -> Env -> Name.Name -> Name.Name -> EResult i w Ctor
findCtorQual region { ctors, q_ctors } prefix name =
    case Dict.get prefix q_ctors of
        Just qualified ->
            case Dict.get name qualified of
                Just (Specific _ pattern) ->
                    ReportingResult.ok pattern

                Just (Ambiguous h hs) ->
                    ReportingResult.throw (Error.AmbiguousVariant region (Just prefix) name h hs)

                Nothing ->
                    ReportingResult.throw (Error.NotFoundVariant region (Just prefix) name (toPossibleNames ctors q_ctors))

        Nothing ->
            ReportingResult.throw (Error.NotFoundVariant region (Just prefix) name (toPossibleNames ctors q_ctors))



-- ====== FIND BINOP ======


{-| Looks up an operator symbol used at `region`.

An ambiguous symbol fails with `AmbiguousBinop`, and one not in scope with
`NotFoundBinop`, which lists the operators in scope as suggestions.

-}
findBinop : A.Region -> Env -> Name.Name -> EResult i w Binop
findBinop region { binops } name =
    case Dict.get name binops of
        Just (Specific _ binop) ->
            ReportingResult.ok binop

        Just (Ambiguous h hs) ->
            ReportingResult.throw (Error.AmbiguousBinop region name h hs)

        Nothing ->
            ReportingResult.throw (Error.NotFoundBinop region name (EverySet.fromList identity (Dict.keys binops)))



-- ====== TO POSSIBLE NAMES ======


{-| Returns the names a not-found error suggests: every name in `exposed`, and
every name in `qualified` under its prefix. Ambiguous names are included.
-}
toPossibleNames : Exposed a -> Qualified a -> Error.PossibleNames
toPossibleNames exposed qualified =
    Error.PossibleNames (EverySet.fromList identity (Dict.keys exposed)) (Dict.map (\_ -> Dict.keys >> EverySet.fromList identity) qualified)
