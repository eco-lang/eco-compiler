module Compiler.Type.Constrain.Common exposing
    ( State(..), Header, emptyState, addToHeaders, getType
    , patternToCategory, patternNeedsConstraint, extractVarFromType
    , Args, makeArgs, TypedArgs(..)
    , RigidTypeVar, Info(..)
    , getName, getAccessName, toShaderRecord
    )

{-| The state records and small classifiers that the expression and pattern
constraint generators share, kept here so that the pattern generator need not
depend on the expression generator.

Constraint generation walks the canonical AST and produces the `Constraint`s
that the solver later solves. Walking a pattern yields a _header_: the names the
pattern binds, each with its type and the region where it is bound. It also
yields the flexible type variables it created and the constraints it emitted,
and `State` carries all three. Walking a function's arguments wraps that state
together with the function's type (`Args` for an unannotated definition,
`TypedArgs` for an annotated one).

An annotation's type variables are _rigid_: inside the annotated definition
they stand for one unknown type and are never unified with anything else.
`RigidTypeVar` maps each such name to its type and is passed down into nested
definitions, so that a nested annotation naming the same variable means the
same type.

The remaining functions classify canonical nodes for constraints and error
messages, and build the record type of a GLSL shader's inputs.


# Pattern State

@docs State, Header, emptyState, addToHeaders, getType


# Pattern Helpers

@docs patternToCategory, patternNeedsConstraint, extractVarFromType


# Args Types

@docs Args, makeArgs, TypedArgs


# Definition Info

@docs RigidTypeVar, Info


# Expression Helpers

@docs getName, getAccessName, toShaderRecord

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeVars as Vars
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E
import Compiler.Type.Type as Type exposing (Constraint, Type(..))
import Data.Map as DataMap
import Dict exposing (Dict)



-- ===== PATTERN STATE =====


{-| What constraint generation has gathered so far from the patterns it has
walked: the header, the flexible type variables it created, and the constraints
it emitted.

The constraints are held newest first, so a consumer reverses them to get
emission order.

-}
type State
    = State Header (List Vars.Variable) (List Constraint)


{-| The names bound by a pattern, each with its type and the region where it
is bound.
-}
type alias Header =
    Dict Name (A.Located Type)


{-| The pattern state before any pattern has been walked: no names, no
variables and no constraints.
-}
emptyState : State
emptyState =
    State Dict.empty [] []


{-| Returns `state` with `name` bound in its header to the type `expectation`
carries, located at `region`. An existing binding of `name` is replaced.
-}
addToHeaders : A.Region -> Name -> E.PExpected Type -> State -> State
addToHeaders region name expectation (State headers vars revCons) =
    let
        tipe : Type
        tipe =
            getType expectation

        newHeaders : Dict Name (A.Located Type)
        newHeaders =
            Dict.insert name (A.At region tipe) headers
    in
    State newHeaders vars revCons


{-| Returns the type a pattern expectation carries, whatever its context.
-}
getType : E.PExpected Type -> Type
getType expectation =
    case expectation of
        E.PNoExpectation tipe ->
            tipe

        E.PFromContext _ _ tipe ->
            tipe



-- ===== PATTERN HELPERS =====


{-| Returns the category a pattern node is reported under when its `CPattern`
constraint fails.

`PAnything`, `PVar` and `PAlias` have no category of their own and get
`PRecord`. A `PCons` is categorised as a list.

-}
patternToCategory : Can.Pattern_ -> E.PCategory
patternToCategory node =
    case node of
        Can.PAnything ->
            E.PRecord

        Can.PVar _ ->
            E.PRecord

        Can.PAlias _ _ ->
            E.PRecord

        Can.PUnit ->
            E.PUnit

        Can.PTuple _ _ _ ->
            E.PTuple

        Can.PCtor { name } ->
            E.PCtor name

        Can.PList _ ->
            E.PList

        Can.PCons _ _ ->
            E.PList

        Can.PRecord _ ->
            E.PRecord

        Can.PInt _ ->
            E.PInt

        Can.PStr _ _ ->
            E.PStr

        Can.PChr _ ->
            E.PChr

        Can.PBool _ _ ->
            E.PBool


{-| Returns whether a pattern node constrains the shape of the value it
matches. It is `False` exactly for `PAnything`, `PVar` and `PAlias`, which accept
any value of the expected type.
-}
patternNeedsConstraint : Can.Pattern_ -> Bool
patternNeedsConstraint node =
    case node of
        Can.PAnything ->
            False

        Can.PVar _ ->
            False

        Can.PAlias _ _ ->
            False

        _ ->
            True


{-| Returns the variable a type consists of when the type is a bare `VarN`,
and `Nothing` for any other type.
-}
extractVarFromType : Type -> Maybe Vars.Variable
extractVarFromType tipe =
    case tipe of
        Type.VarN v ->
            Just v

        _ ->
            Nothing



-- ===== ARGS TYPES =====


{-| What walking the arguments of an unannotated function produces.

`vars` holds the fresh variables made for each argument's type and for the
result. `tipe` is the whole function type and `result` the type after every
argument has been applied. `state` is what the argument patterns gathered.

-}
type alias Args =
    { vars : List Vars.Variable
    , tipe : Type
    , result : Type
    , state : State
    }


{-| Builds an `Args` from its variables, function type, result type and
pattern state, in that order.
-}
makeArgs : List Vars.Variable -> Type -> Type -> State -> Args
makeArgs vars tipe result state =
    { vars = vars, tipe = tipe, result = result, state = state }


{-| What walking the arguments of an annotated function produces: the whole
function type, the result type, and what the argument patterns gathered, in that
order. No variables are carried, because the types come from the annotation.
-}
type TypedArgs
    = TypedArgs Type Type State



-- ===== DEF INFO =====


{-| The rigid type variables in scope, by name, each with its type.

Inside a definition annotated `func : a -> b`, it holds `a` and `b`. A nested
annotation that names `a` gets the same type, rather than a new variable.

-}
type alias RigidTypeVar =
    Dict Name Type


{-| What constraint generation gathers from one kind of definition in a
recursive group: its type variables, its constraints, and the header naming
each definition with its type, in that order.

The group is walked with two of these, one for the annotated definitions and
one for the unannotated ones.

-}
type Info
    = Info (List Vars.Variable) (List Constraint) (Dict Name (A.Located Type))



-- ===== EXPRESSION HELPERS =====


{-| Returns how an expression in function position is named in a type error.

A variable of any kind, kernel references included, is a `FuncName`, a
constructor a `CtorName` and an operator an `OpName`. Any other expression is
`NoName`.

-}
getName : Can.Expr -> E.MaybeName
getName (A.At _ exprInfo) =
    case exprInfo.node of
        Can.VarLocal name ->
            E.FuncName name

        Can.VarTopLevel _ name ->
            E.FuncName name

        Can.VarForeign _ name _ ->
            E.FuncName name

        Can.VarCtor _ _ name _ _ ->
            E.CtorName name

        Can.VarOperator op _ _ _ ->
            E.OpName op

        Can.VarKernel _ _ name ->
            E.FuncName name

        _ ->
            E.NoName


{-| Returns the name of a local, top-level or imported variable, and
`Nothing` for any other expression. Kernel references and constructors are
`Nothing`.
-}
getAccessName : Can.Expr -> Maybe Name
getAccessName (A.At _ exprInfo) =
    case exprInfo.node of
        Can.VarLocal name ->
            Just name

        Can.VarTopLevel _ name ->
            Just name

        Can.VarForeign _ name _ ->
            Just name

        _ ->
            Nothing


{-| Returns the record type whose fields are the names in `types`, each with
the Elm type of its GLSL type, extending `baseRecType`. When `types` is empty
the result is `baseRecType` itself.
-}
toShaderRecord : DataMap.Dict String Name Shader.Type -> Type -> Type
toShaderRecord types baseRecType =
    if DataMap.isEmpty types then
        baseRecType

    else
        RecordN (Dict.fromList (DataMap.toList (DataMap.map (\_ -> glToType) types))) baseRecType


{-| Returns the Elm type a GLSL type is seen as: a vector or matrix becomes
the corresponding type of `Compiler.Type.Type` (`vec2` and so on), a sampler
becomes `texture`, and `Int`, `Float` and `Bool` become themselves.
-}
glToType : Shader.Type -> Type
glToType glType =
    case glType of
        Shader.V2 ->
            Type.vec2

        Shader.V3 ->
            Type.vec3

        Shader.V4 ->
            Type.vec4

        Shader.M4 ->
            Type.mat4

        Shader.Int ->
            Type.int

        Shader.Float ->
            Type.float

        Shader.Texture ->
            Type.texture

        Shader.Bool ->
            Type.bool
