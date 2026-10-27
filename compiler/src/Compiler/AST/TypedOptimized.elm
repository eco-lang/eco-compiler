module Compiler.AST.TypedOptimized exposing
    ( Expr(..), Global(..), Annotations, AnnotationsByGlobal, SchemeRootsByGlobal, Meta
    , Def(..), Destructor(..), Path(..)
    , ContainerHint(..)
    , Decider(..), Choice(..)
    , GlobalGraph(..), LocalGraph(..), LocalGraphData, Node(..), Main(..), EffectsType(..)
    , emptyGlobalGraph
    , compareGlobal, toComparableGlobal, toKernelGlobal
    , typeOf, metaOf, tvarOf
    , computeVarSupers, varSupersOfType
    , globalGraphEncoder, globalGraphDecoder, localGraphEncoder, localGraphDecoder
    , globalHash
    )

{-| The native back end specializes each polymorphic definition at the concrete
types it is used at, and for that it needs the type of every expression after
local optimization. This module is that program representation: the optimized
program of `Compiler.AST.Optimized` with a type on every node, together with
the binary format in which it is kept between builds.

Every expression carries a _meta_ as the last argument of its constructor: its
canonical type and, where one was recorded, the solver variable the type
checker gave it. The parameter `id` of `Expr id` and the other types is how
type variables are named inside `Can.Type id`. The optimizer produces them
named by `Name`; `Compiler.Monomorphize.AssignMVarIds` renumbers them. Only
the `Name` form can be encoded.

The definitions of one module form a `LocalGraph`, and the graphs of many
modules merged together form a `GlobalGraph`. Both map a `Global`, a module and
a name, to a `Node`. Alongside the nodes they keep each definition's type
scheme, its _scheme roots_, which give each quantified type variable of the
scheme the solver root it had and the super constraint recorded there, and
_varSupers_, a map from names to the super constraint their prefix denotes
(`number`, `comparable`, `appendable`, `compappend`; see
`Compiler.Data.Name`).

Most of the file is the binary format. An encoding of either graph is a
format-version byte, a string table, a type table and then the body, in which
every string is an index into the string table and every type an id in the
type table (see `Compiler.AST.StringTable` and `Compiler.AST.TypeTable`). A
version byte other than the current one fails the whole decode. Both tables are
filled before encoding by a pre-pass over the graph: the `internTypesFrom*`
walkers must reach every type the encoders write, and the `collectStringsFrom*`
walkers every string. A missed type makes encoding crash; a missed string is
written as the index of another string, without error.

Decoding does not give back everything that was encoded from. A decoded graph
has no `main`, empty field counts, empty dependency sets on its nodes, no
solver variable in any meta and no lambda id on any `Function` or
`TrackedFunction`. A `Manager` node decodes with effects type `Cmd`, a `Kernel`
node with no chunks, and a `VarDebug` with home `Debug` of `elm/core` and no
unhandled-value name. The solver variable of a `TailDef` is kept.

The string walkers serve one more purpose. `computeVarSupers` runs them with a
collector that keeps only names with a super-constraint prefix, so it sees
every name the encoding would write.


# Core Types

@docs Expr, Global, Annotations, AnnotationsByGlobal, SchemeRootsByGlobal, Meta


# Definitions and Destructuring

@docs Def, Destructor, Path


# Container Hints

@docs ContainerHint


# Pattern Matching

@docs Decider, Choice


# Dependency Graphs

@docs GlobalGraph, LocalGraph, LocalGraphData, Node, Main, EffectsType


# Graph Operations

@docs emptyGlobalGraph


# Global Reference Utilities

@docs compareGlobal, toComparableGlobal, toKernelGlobal


# Type Extraction

@docs typeOf, metaOf, tvarOf


# Super Constraints

@docs computeVarSupers, varSupersOfType


# Serialization

@docs globalGraphEncoder, globalGraphDecoder, localGraphEncoder, localGraphDecoder
@docs globalHash

-}

import Bytes
import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.DecisionTree.TypedPath as DT
import Compiler.AST.StringTable as StringTable exposing (StringTable)
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypeTable as TypeTable exposing (TypeTable)
import Compiler.AST.TypeVars as Vars
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Kernel as K
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Reporting.Annotation as A
import Data.Map
import Data.Set exposing (EverySet)
import Dict exposing (Dict)
import Eco.Hash
import Set exposing (Set)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== TYPE ALIASES ======


{-| The type schemes of one module's top-level definitions, keyed by the
definition's bare name.
-}
type alias Annotations id =
    Dict Name (Can.Annotation id)


{-| The type schemes of the definitions of many modules, keyed by `Global` so
that equal names in different modules stay apart.
-}
type alias AnnotationsByGlobal id =
    Data.Map.Dict String Global (Can.Annotation id)


{-| The scheme roots of the definitions of many modules, keyed by `Global`.

For each definition, the inner map takes a type-variable name of its scheme to
the solver root and super constraint recorded for it. A root is a point of its
home module's solver store and means nothing outside it.

-}
type alias SchemeRootsByGlobal =
    Data.Map.Dict String Global (Dict Name Vars.RootedVar)



-- ====== META ======


{-| The type information on one expression: its canonical type, and the solver
variable the type checker recorded for it.

`tvar` is a point of the home module's solver store and means nothing outside
it. It is `Nothing` where none was recorded, and on every expression of a
decoded graph.

-}
type alias Meta id =
    { tipe : Can.Type id
    , tvar : Maybe Vars.Variable
    }



-- ====== EXPRESSIONS ======


{-| An expression after local optimization, with its `Meta` as the last
argument of every constructor.

Several constructors come in a plain and a tracked form, the tracked one
keeping source regions the plain one drops: `VarLocal` and `TrackedVarLocal`,
`Function` and `TrackedFunction` (whose parameter names are located), and
`Record` and `TrackedRecord` (whose field names are located).

`Chr` holds its character as a `String`; `Chr` and `Str` keep the escaped
source text of the literal. A constructor of a type whose constructors all take
no arguments is `VarEnum`, carrying its index, and the constructor of a type
with one constructor of one argument is `VarBox`.

`VarCycle` refers to a zero-argument definition of the recursive group it is
used in. `VarDebug` is a use of a `Debug` function: its name, the module it is
used in, and an optional name. `VarKernel` names a kernel value by its prefix,
its kernel module and its name.

`Function` carries an optional lambda id, the parameters with their types, and
the body; the lambda id is not encoded, so it is `Nothing` after decoding.

`TailCall` is a call of the enclosing `TailDef` from tail position, pairing each
parameter name with its new argument. `If` is a list of condition and branch
pairs followed by the final `else` branch.

`Case` is a compiled `case`: a label name, the name of the variable inspected,
the decision tree, and the jump list, the branch bodies the tree reaches through
`Jump`, each with the index a `Jump` names. A branch body can also sit in the
tree itself, as `Inline`.

`Update` keys its fields by located name. `Shader` carries the GLSL source and
the names of its attributes and uniforms.

-}
type Expr id
    = Bool A.Region Bool (Meta id)
    | Chr A.Region String (Meta id)
    | Str A.Region String (Meta id)
    | Int A.Region Int (Meta id)
    | Float A.Region Float (Meta id)
    | VarLocal Name (Meta id)
    | TrackedVarLocal A.Region Name (Meta id)
    | VarGlobal A.Region Global (Meta id)
    | VarEnum A.Region Global Index.ZeroBased (Meta id)
    | VarBox A.Region Global (Meta id)
    | VarCycle A.Region ModuleName.Canonical Name (Meta id)
    | VarDebug A.Region Name ModuleName.Canonical (Maybe Name) (Meta id)
    | VarKernel A.Region Name Name Name (Meta id)
    | List A.Region (List (Expr id)) (Meta id)
    | Function (Maybe TypeIds.SrcLambdaId) (List ( Name, Can.Type id )) (Expr id) (Meta id)
    | TrackedFunction (Maybe TypeIds.SrcLambdaId) (List ( A.Located Name, Can.Type id )) (Expr id) (Meta id)
    | Call A.Region (Expr id) (List (Expr id)) (Meta id)
    | TailCall Name (List ( Name, Expr id )) (Meta id)
    | If (List ( Expr id, Expr id )) (Expr id) (Meta id)
    | Let (Def id) (Expr id) (Meta id)
    | Destruct (Destructor id) (Expr id) (Meta id)
    | Case Name Name (Decider (Choice id)) (List ( Int, Expr id )) (Meta id)
    | Accessor A.Region Name (Meta id)
    | Access (Expr id) A.Region Name (Meta id)
    | Update A.Region (Expr id) (Data.Map.Dict String (A.Located Name) (Expr id)) (Meta id)
    | Record (Dict Name (Expr id)) (Meta id)
    | TrackedRecord A.Region (Data.Map.Dict String (A.Located Name) (Expr id)) (Meta id)
    | Unit (Meta id)
    | Tuple A.Region (Expr id) (Expr id) (List (Expr id)) (Meta id)
    | Shader Shader.Source (EverySet String Name) (EverySet String Name) (Meta id)


{-| Returns the canonical type of an expression.
-}
typeOf : Expr id -> Can.Type id
typeOf expr =
    (metaOf expr).tipe


{-| Returns the `Meta` of an expression.
-}
metaOf : Expr id -> Meta id
metaOf expr =
    case expr of
        Bool _ _ meta ->
            meta

        Chr _ _ meta ->
            meta

        Str _ _ meta ->
            meta

        Int _ _ meta ->
            meta

        Float _ _ meta ->
            meta

        VarLocal _ meta ->
            meta

        TrackedVarLocal _ _ meta ->
            meta

        VarGlobal _ _ meta ->
            meta

        VarEnum _ _ _ meta ->
            meta

        VarBox _ _ meta ->
            meta

        VarCycle _ _ _ meta ->
            meta

        VarDebug _ _ _ _ meta ->
            meta

        VarKernel _ _ _ _ meta ->
            meta

        List _ _ meta ->
            meta

        Function _ _ _ meta ->
            meta

        TrackedFunction _ _ _ meta ->
            meta

        Call _ _ _ meta ->
            meta

        TailCall _ _ meta ->
            meta

        If _ _ meta ->
            meta

        Let _ _ meta ->
            meta

        Destruct _ _ meta ->
            meta

        Case _ _ _ _ meta ->
            meta

        Accessor _ _ meta ->
            meta

        Access _ _ _ meta ->
            meta

        Update _ _ _ meta ->
            meta

        Record _ meta ->
            meta

        TrackedRecord _ _ meta ->
            meta

        Unit meta ->
            meta

        Tuple _ _ _ _ meta ->
            meta

        Shader _ _ _ meta ->
            meta


{-| Returns the solver variable recorded for an expression, if any.
-}
tvarOf : Expr id -> Maybe Vars.Variable
tvarOf expr =
    (metaOf expr).tvar


{-| The name of a top-level definition: its home module and its name.
-}
type Global
    = Global ModuleName.Canonical Name


{-| Returns the order of two globals: by name, and where the names are equal by
home module, as `ModuleName.compareCanonical` orders them.

This is not the order of the strings `toComparableGlobal` makes, which begin
with the home module.

-}
compareGlobal : Global -> Global -> Order
compareGlobal (Global home1 name1) (Global home2 name2) =
    case compare name1 name2 of
        LT ->
            LT

        EQ ->
            ModuleName.compareCanonical home1 home2

        GT ->
            GT


{-| Returns a global as one string, the home module as
`ModuleName.toComparableCanonical` writes it, a dot, and the name. The decoders
key their dictionaries by it.
-}
toComparableGlobal : Global -> String
toComparableGlobal (Global home name) =
    ModuleName.toComparableCanonical home ++ "." ++ name


{-| Returns a hash of a global for use as a `Data.HashMap` key.

Only the lengths of the package author, the package project and the module
name enter it, followed by every character of the name, so two globals with
the same name whose home modules differ only in spelling, not in the lengths
of their parts, collide. `Data.HashMap` confirms
every key with an equality, so a collision costs time, not correctness.

The lengths are mixed as `Compiler.AST.Monomorphized.globalHash` mixes them,
but the name is then hashed with `Eco.Hash.string64`, seeded with the mixed
lengths, so the two functions give different values. The result is not kept
within any range and must not be packed with another hash.

-}
globalHash : Global -> Int
globalHash g =
    case g of
        Global (ModuleName.Canonical ( author, project ) modName) name ->
            Eco.Hash.string64
                (globalMixHash
                    (globalMixHash (globalMixHash 21 (String.length author)) (String.length project))
                    (String.length modName)
                )
                name


{-| Returns the hash `h` with `x` mixed in, reduced modulo 2^26 so that the
arithmetic stays exact in both builds.
-}
globalMixHash : Int -> Int -> Int
globalMixHash h x =
    modBy 67108864 (h * 33 + modBy 67108864 x + 7)


{-| Returns the global standing for the kernel module `shortName`: that module
of the `elm/kernel` package, with the name `$`.
-}
toKernelGlobal : Name.Name -> Global
toKernelGlobal shortName =
    Global (ModuleName.Canonical Pkg.kernel shortName) Name.dollar



-- ====== DEFINITIONS ======


{-| A definition bound by a `let`, or a function of a top-level recursive group.

`Def` carries its region, name, body and the type of the definition.

`TailDef` is a function that calls itself from tail position. It carries its
region, name, its parameters with their types, its body, the type of the whole
definition (not its result type), and the solver variable recorded for it,
which, unlike every other solver variable here, is encoded.

-}
type Def id
    = Def A.Region Name (Expr id) (Can.Type id)
    | TailDef A.Region Name (List ( A.Located Name, Can.Type id )) (Expr id) (Can.Type id) (Maybe Vars.Variable)


{-| One binding made by a destructuring pattern: the name bound, the path to the
part of the value it is bound to, and the meta of that part.
-}
type Destructor id
    = Destructor Name Path (Meta id)


{-| The kind of container an `Index` path step projects from, which tells code
generation how the container is laid out: a list cell, a 2-tuple, a 3-tuple,
or a value built by a constructor, named by `HintCustom`.
-}
type ContainerHint
    = HintList
    | HintTuple2
    | HintTuple3
    | HintCustom Name


{-| Where a destructured part sits inside the value being destructured.

A path is read inside out: `Root` names the variable holding the whole value,
and each other step takes a part of the value its inner path reaches. `Index`
takes the element at an index of a container of the kind its hint names,
`ArrayIndex` an element by position, `Field` a record field, and `Unbox` the
argument of a constructor of a type with one constructor of one argument.

-}
type Path
    = Index Index.ZeroBased ContainerHint Path
    | ArrayIndex Int Path
    | Field Name Path
    | Unbox Path
    | Root Name



-- ====== BRANCHING ======


{-| The decision tree of a compiled `case`, with a value of type `a` at each
leaf.

`Chain` runs a list of tests, each at a path into the inspected value, and
continues with its first tree if all pass and its second otherwise. `FanOut`
picks the edge whose test the value at one path passes, or the fallback tree.
The paths and tests are those of `Compiler.AST.DecisionTree.TypedPath` and
`Compiler.AST.DecisionTree.Test`.

-}
type Decider a
    = Leaf a
    | Chain (List ( DT.Path, DT.Test )) (Decider a) (Decider a)
    | FanOut DT.Path (List ( DT.Test, Decider a )) (Decider a)


{-| What a leaf of a decision tree leads to: a branch body placed in the tree
itself, or a jump to the body of the `Case`'s jump list with the given index.
-}
type Choice id
    = Inline (Expr id)
    | Jump Int



-- ====== OBJECT GRAPH ======


{-| The merged graph of many modules: their nodes, their record field counts,
their type schemes, their scheme roots, and their varSupers.

The field counts are not encoded, so a decoded graph has none.

-}
type GlobalGraph id
    = GlobalGraph (Data.Map.Dict String Global (Node id)) (Dict Name Int) (AnnotationsByGlobal id) SchemeRootsByGlobal (Dict Name Vars.SuperType)


{-| The contents of one module's graph.

`main` is `Nothing` for a module with no `main` and in every decoded graph.
`fields` counts the uses of each record field name and is empty in every
decoded graph. `schemeRoots` is keyed by definition name.

-}
type alias LocalGraphData id =
    { main : Maybe (Main id)
    , nodes : Data.Map.Dict String Global (Node id)
    , fields : Dict Name Int
    , annotations : Annotations id
    , schemeRoots : Dict Name (Dict Name Vars.RootedVar)
    , varSupers : Dict Name Vars.SuperType
    }


{-| The graph of one module's top-level definitions.
-}
type LocalGraph id
    = LocalGraph (LocalGraphData id)


{-| The kind of `main` a module defines. `Static` is a `main` whose type is a
`VirtualDom` node; `Dynamic` is a program, carrying its message type and the
decoder of its flags.
-}
type Main id
    = Static
    | Dynamic (Can.Type id) (Expr id)


{-| What a graph holds under one global.

`Define` and `TrackedDefine` are a top-level definition: its body, the globals
it depends on, and its meta. `TrackedDefine` also keeps the definition's
region.

`Ctor` is a constructor, carrying its index in its type's declaration, its
number of arguments and its type. `Enum` is a constructor of a type whose
constructors all take no arguments, and `Box` the constructor of a type with
one constructor of one argument.

`Cycle` is a recursive group of top-level definitions, held under a name
combined from its members' names. It carries those names, the zero-argument
definitions as name and body, the functions as `Def`s, and the group's
dependencies. Each member's own name holds a `Link` to it. `Link` also points
an effect module's `command` and `subscription` at its `Manager` node.

`Kernel` carries a kernel module's chunks and dependencies. `PortIncoming` and
`PortOutgoing` carry a port's decoder or encoder, its dependencies, and the
port's meta.

Dependency sets, `Manager`'s effects type and `Kernel`'s chunks are not encoded,
so they are empty or `Cmd` in a decoded graph.

-}
type Node id
    = Define (Expr id) (EverySet String Global) (Meta id)
    | TrackedDefine A.Region (Expr id) (EverySet String Global) (Meta id)
    | Ctor Index.ZeroBased Int (Can.Type id)
    | Enum Index.ZeroBased (Can.Type id)
    | Box (Can.Type id)
    | Link Global
    | Cycle (List Name) (List ( Name, Expr id )) (List (Def id)) (EverySet String Global)
    | Manager EffectsType
    | Kernel (List K.Chunk) (EverySet String Global)
    | PortIncoming (Expr id) (EverySet String Global) (Meta id)
    | PortOutgoing (Expr id) (EverySet String Global) (Meta id)


{-| Which effects an effect module manages: commands, subscriptions, or both
(`Fx`).
-}
type EffectsType
    = Cmd
    | Sub
    | Fx



-- ====== GRAPHS ======


{-| A global graph with no modules in it.
-}
emptyGlobalGraph : GlobalGraph id
emptyGlobalGraph =
    GlobalGraph Data.Map.empty Dict.empty Data.Map.empty Data.Map.empty Dict.empty



-- ====== ENCODERS and DECODERS ======


{-| Produces an encoder for a global graph: the format-version byte, the string
table, the type table, then the nodes, type schemes, scheme roots and
varSupers. The field counts are not written.
-}
globalGraphEncoder : GlobalGraph Name -> Bytes.Encode.Encoder
globalGraphEncoder ((GlobalGraph nodes _ annotations allSchemeRoots varSupers) as graph) =
    let
        ( strs, tb ) =
            prePassGlobal graph

        st : StringTable
        st =
            StringTable.build strs

        tt : TypeTable
        tt =
            TypeTable.freeze tb
    in
    Bytes.Encode.sequence
        [ Bytes.Encode.unsignedInt8 typedGraphFormatVersion
        , StringTable.tableEncoder st
        , TypeTable.encoder st tt
        , BE.assocListDict (globalEncoderS st) (nodeEncoderS st tt) nodes
        , BE.assocListDict (globalEncoderS st) (annotationEncoderT st tt) annotations
        , globalSchemeRootsEncoderS st allSchemeRoots
        , varSupersEncoderS st varSupers
        ]


{-| A decoder for a global graph as `globalGraphEncoder` writes it. It fails on
any format-version byte but the current one, and gives a graph with no field
counts and with the other parts the module docstring lists as not encoded.
-}
globalGraphDecoder : Bytes.Decode.Decoder (GlobalGraph Name)
globalGraphDecoder =
    formatVersionDecoder
        |> Bytes.Decode.andThen
            (\() ->
                StringTable.tableDecoder
                    |> Bytes.Decode.andThen
                        (\st ->
                            TypeTable.decoder st
                                |> Bytes.Decode.andThen
                                    (\tdt ->
                                        Bytes.Decode.map4
                                            (\nodes annotations allSchemeRoots varSupers ->
                                                GlobalGraph nodes Dict.empty annotations allSchemeRoots varSupers
                                            )
                                            (BD.assocListDict toComparableGlobal (globalDecoderS st) (nodeDecoderS st tdt))
                                            (BD.assocListDict toComparableGlobal (globalDecoderS st) (annotationDecoderT st tdt))
                                            (globalSchemeRootsDecoderS st)
                                            (varSupersDecoderS st)
                                    )
                        )
            )


{-| Produces an encoder for a local graph: the format-version byte, the string
table, the type table, then the nodes, type schemes, scheme roots and
varSupers. `main` and the field counts are not written.
-}
localGraphEncoder : LocalGraph Name -> Bytes.Encode.Encoder
localGraphEncoder ((LocalGraph data) as graph) =
    let
        ( strs, tb ) =
            prePassLocal graph

        st : StringTable
        st =
            StringTable.build strs

        tt : TypeTable
        tt =
            TypeTable.freeze tb
    in
    Bytes.Encode.sequence
        [ Bytes.Encode.unsignedInt8 typedGraphFormatVersion
        , StringTable.tableEncoder st
        , TypeTable.encoder st tt
        , BE.assocListDict (globalEncoderS st) (nodeEncoderS st tt) data.nodes
        , BE.stdDict (StringTable.string st) (annotationEncoderT st tt) data.annotations
        , schemeRootsEncoderS st data.schemeRoots
        , varSupersEncoderS st data.varSupers
        ]


{-| A decoder for a local graph as `localGraphEncoder` writes it. It fails on
any format-version byte but the current one, and gives a graph with no `main`,
no field counts, and with the other parts the module docstring lists as not
encoded.
-}
localGraphDecoder : Bytes.Decode.Decoder (LocalGraph Name)
localGraphDecoder =
    formatVersionDecoder
        |> Bytes.Decode.andThen
            (\() ->
                StringTable.tableDecoder
                    |> Bytes.Decode.andThen
                        (\st ->
                            TypeTable.decoder st
                                |> Bytes.Decode.andThen
                                    (\tdt ->
                                        Bytes.Decode.map4
                                            (\nodes annotations schemeRoots varSupers ->
                                                LocalGraph
                                                    { main = Nothing
                                                    , nodes = nodes
                                                    , fields = Dict.empty
                                                    , annotations = annotations
                                                    , schemeRoots = schemeRoots
                                                    , varSupers = varSupers
                                                    }
                                            )
                                            (BD.assocListDict toComparableGlobal (globalDecoderS st) (nodeDecoderS st tdt))
                                            (BD.stdDict (StringTable.stringDec st) (annotationDecoderT st tdt))
                                            (schemeRootsDecoderS st)
                                            (varSupersDecoderS st)
                                    )
                        )
            )


{-| Produces an encoder for a global: its home module, then its name.
-}
globalEncoderS : StringTable -> Global -> Bytes.Encode.Encoder
globalEncoderS st (Global home name) =
    Bytes.Encode.sequence
        [ ModuleName.canonicalEncoderS st home
        , StringTable.string st name
        ]


{-| Produces a decoder for a global as `globalEncoderS` writes it.
-}
globalDecoderS : StringTable -> Bytes.Decode.Decoder Global
globalDecoderS st =
    Bytes.Decode.map2 Global
        (ModuleName.canonicalDecoderS st)
        (StringTable.stringDec st)


{-| Produces an encoder for a meta, which writes only its type; the solver
variable is dropped.
-}
metaEncoderS : TypeTable -> Meta Name -> Bytes.Encode.Encoder
metaEncoderS tt meta =
    TypeTable.ref tt meta.tipe


{-| Produces an encoder for a type scheme: its free variables, then its type as a
type-table reference.
-}
annotationEncoderT : StringTable -> TypeTable -> Can.Annotation Name -> Bytes.Encode.Encoder
annotationEncoderT st tt (Can.Forall freeVars tipe) =
    Bytes.Encode.sequence
        [ Can.freeVarsEncoderS st freeVars
        , TypeTable.ref tt tipe
        ]


{-| Produces a decoder for a type scheme as `annotationEncoderT` writes it.
-}
annotationDecoderT : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder (Can.Annotation Name)
annotationDecoderT st tdt =
    Bytes.Decode.map2 Can.Forall
        (Can.freeVarsDecoderS st)
        (TypeTable.refDecoder tdt)


{-| Produces a decoder for a meta, which reads its type and sets no solver
variable.
-}
metaDecoderS : TypeTable.Decoded -> Bytes.Decode.Decoder (Meta Name)
metaDecoderS tdt =
    Bytes.Decode.map (\t -> { tipe = t, tvar = Nothing }) (TypeTable.refDecoder tdt)


{-| Produces an encoder for a node: a tag byte, then its fields. Dependency
sets, `Manager`'s effects type and `Kernel`'s chunks are not written, so a
`Manager` or `Kernel` node is its tag alone. Tag 2 is not used.
-}
nodeEncoderS : StringTable -> TypeTable -> Node Name -> Bytes.Encode.Encoder
nodeEncoderS st tt node =
    case node of
        Define expr _ meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , exprEncoderS st tt expr
                , TypeTable.ref tt meta.tipe
                ]

        TrackedDefine region expr _ meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoderV region
                , exprEncoderS st tt expr
                , TypeTable.ref tt meta.tipe
                ]

        Ctor index arity tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , Index.zeroBasedEncoderV index
                , BE.uintV arity
                , TypeTable.ref tt tipe
                ]

        Enum index tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , Index.zeroBasedEncoderV index
                , TypeTable.ref tt tipe
                ]

        Box tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , TypeTable.ref tt tipe
                ]

        Link linkedGlobal ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , globalEncoderS st linkedGlobal
                ]

        Cycle names values functions _ ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , BE.list (StringTable.string st) names
                , BE.list (BE.jsonPair (StringTable.string st) (exprEncoderS st tt)) values
                , BE.list (defEncoderS st tt) functions
                ]

        Manager _ ->
            Bytes.Encode.unsignedInt8 8

        Kernel _ _ ->
            Bytes.Encode.unsignedInt8 9

        PortIncoming decoder _ meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , exprEncoderS st tt decoder
                , TypeTable.ref tt meta.tipe
                ]

        PortOutgoing encoder _ meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , exprEncoderS st tt encoder
                , TypeTable.ref tt meta.tipe
                ]


{-| Produces a decoder for a node as `nodeEncoderS` writes it, filling what was
not written with empty dependency sets, effects type `Cmd` and no kernel
chunks. An unknown tag fails.
-}
nodeDecoderS : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder (Node Name)
nodeDecoderS st tdt =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 (\expr meta -> Define expr Data.Set.empty meta)
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    1 ->
                        Bytes.Decode.map3 (\region expr meta -> TrackedDefine region expr Data.Set.empty meta)
                            A.regionDecoderV
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    3 ->
                        Bytes.Decode.map3 Ctor
                            Index.zeroBasedDecoderV
                            BD.uintV
                            (TypeTable.refDecoder tdt)

                    4 ->
                        Bytes.Decode.map2 Enum
                            Index.zeroBasedDecoderV
                            (TypeTable.refDecoder tdt)

                    5 ->
                        Bytes.Decode.map Box (TypeTable.refDecoder tdt)

                    6 ->
                        Bytes.Decode.map Link (globalDecoderS st)

                    7 ->
                        Bytes.Decode.map3 (\names values funcs -> Cycle names values funcs Data.Set.empty)
                            (BD.list (StringTable.stringDec st))
                            (BD.list (BD.jsonPair (StringTable.stringDec st) (exprDecoderS st tdt)))
                            (BD.list (defDecoderS st tdt))

                    8 ->
                        Bytes.Decode.succeed (Manager Cmd)

                    9 ->
                        Bytes.Decode.succeed (Kernel [] Data.Set.empty)

                    10 ->
                        Bytes.Decode.map2 (\expr meta -> PortIncoming expr Data.Set.empty meta)
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    11 ->
                        Bytes.Decode.map2 (\expr meta -> PortOutgoing expr Data.Set.empty meta)
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Produces an encoder for a located name with its type. The region is written
in the fixed-width form of `A.locatedEncoder`, not the varint form used for the
other regions of the body.
-}
typedLocatedNameEncoderS : StringTable -> TypeTable -> ( A.Located Name, Can.Type Name ) -> Bytes.Encode.Encoder
typedLocatedNameEncoderS st tt ( locName, tipe ) =
    Bytes.Encode.sequence
        [ A.locatedEncoder (StringTable.string st) locName
        , TypeTable.ref tt tipe
        ]


{-| Produces a decoder for a located name with its type, as
`typedLocatedNameEncoderS` writes it.
-}
typedLocatedNameDecoderS : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder ( A.Located Name, Can.Type Name )
typedLocatedNameDecoderS st tdt =
    Bytes.Decode.map2 Tuple.pair
        (A.locatedDecoder (StringTable.stringDec st))
        (TypeTable.refDecoder tdt)


{-| Produces an encoder for a name with its type.
-}
typedNameEncoderS : StringTable -> TypeTable -> ( Name, Can.Type Name ) -> Bytes.Encode.Encoder
typedNameEncoderS st tt ( name, tipe ) =
    Bytes.Encode.sequence
        [ StringTable.string st name
        , TypeTable.ref tt tipe
        ]


{-| Produces a decoder for a name with its type, as `typedNameEncoderS` writes it.
-}
typedNameDecoderS : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder ( Name, Can.Type Name )
typedNameDecoderS st tdt =
    Bytes.Decode.map2 Tuple.pair
        (StringTable.stringDec st)
        (TypeTable.refDecoder tdt)


{-| Produces an encoder for an expression: a tag byte, its fields, and its type
last. A solver variable and a lambda id are not written. An `Int` is written as
an exact 64-bit integer, not as a float. A `VarDebug`'s home and
unhandled-value name are not written.
-}
exprEncoderS : StringTable -> TypeTable -> Expr Name -> Bytes.Encode.Encoder
exprEncoderS st tt expr =
    case expr of
        Bool region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoderV region
                , BE.bool value
                , TypeTable.ref tt meta.tipe
                ]

        Chr region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoderV region
                , StringTable.string st value
                , TypeTable.ref tt meta.tipe
                ]

        Str region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoderV region
                , StringTable.string st value
                , TypeTable.ref tt meta.tipe
                ]

        Int region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , A.regionEncoderV region
                , BE.int64 value
                , TypeTable.ref tt meta.tipe
                ]

        Float region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , A.regionEncoderV region
                , BE.float value
                , TypeTable.ref tt meta.tipe
                ]

        VarLocal value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , StringTable.string st value
                , TypeTable.ref tt meta.tipe
                ]

        TrackedVarLocal region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , A.regionEncoderV region
                , StringTable.string st value
                , TypeTable.ref tt meta.tipe
                ]

        VarGlobal region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , A.regionEncoderV region
                , globalEncoderS st value
                , TypeTable.ref tt meta.tipe
                ]

        VarEnum region global index meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , A.regionEncoderV region
                , globalEncoderS st global
                , Index.zeroBasedEncoderV index
                , TypeTable.ref tt meta.tipe
                ]

        VarBox region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , A.regionEncoderV region
                , globalEncoderS st value
                , TypeTable.ref tt meta.tipe
                ]

        VarCycle region home name meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , A.regionEncoderV region
                , ModuleName.canonicalEncoderS st home
                , StringTable.string st name
                , TypeTable.ref tt meta.tipe
                ]

        VarDebug region name _ _ meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , A.regionEncoderV region
                , StringTable.string st name
                , TypeTable.ref tt meta.tipe
                ]

        VarKernel region kernelPrefix home name meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 12
                , A.regionEncoderV region
                , StringTable.string st kernelPrefix
                , StringTable.string st home
                , StringTable.string st name
                , TypeTable.ref tt meta.tipe
                ]

        List region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 13
                , A.regionEncoderV region
                , BE.list (exprEncoderS st tt) value
                , TypeTable.ref tt meta.tipe
                ]

        Function _ args body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 14
                , BE.list (typedNameEncoderS st tt) args
                , exprEncoderS st tt body
                , TypeTable.ref tt meta.tipe
                ]

        TrackedFunction _ args body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 15
                , BE.list (typedLocatedNameEncoderS st tt) args
                , exprEncoderS st tt body
                , TypeTable.ref tt meta.tipe
                ]

        Call region func args meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 16
                , A.regionEncoderV region
                , exprEncoderS st tt func
                , BE.list (exprEncoderS st tt) args
                , TypeTable.ref tt meta.tipe
                ]

        TailCall name args meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 17
                , StringTable.string st name
                , BE.list (BE.jsonPair (StringTable.string st) (exprEncoderS st tt)) args
                , TypeTable.ref tt meta.tipe
                ]

        If branches final meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 18
                , BE.list (BE.jsonPair (exprEncoderS st tt) (exprEncoderS st tt)) branches
                , exprEncoderS st tt final
                , TypeTable.ref tt meta.tipe
                ]

        Let def body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 19
                , defEncoderS st tt def
                , exprEncoderS st tt body
                , TypeTable.ref tt meta.tipe
                ]

        Destruct destructor body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 20
                , destructorEncoderS st tt destructor
                , exprEncoderS st tt body
                , TypeTable.ref tt meta.tipe
                ]

        Case label root decider jumps meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 21
                , StringTable.string st label
                , StringTable.string st root
                , deciderEncoderS st (choiceEncoderS st tt) decider
                , BE.list (BE.jsonPair BE.uintV (exprEncoderS st tt)) jumps
                , TypeTable.ref tt meta.tipe
                ]

        Accessor region field meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 22
                , A.regionEncoderV region
                , StringTable.string st field
                , TypeTable.ref tt meta.tipe
                ]

        Access record region field meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 23
                , exprEncoderS st tt record
                , A.regionEncoderV region
                , StringTable.string st field
                , TypeTable.ref tt meta.tipe
                ]

        Update region record fields meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 24
                , A.regionEncoderV region
                , exprEncoderS st tt record
                , BE.assocListDict (A.locatedEncoder (StringTable.string st)) (exprEncoderS st tt) fields
                , TypeTable.ref tt meta.tipe
                ]

        Record value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 25
                , BE.stdDict (StringTable.string st) (exprEncoderS st tt) value
                , TypeTable.ref tt meta.tipe
                ]

        TrackedRecord region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 26
                , A.regionEncoderV region
                , BE.assocListDict (A.locatedEncoder (StringTable.string st)) (exprEncoderS st tt) value
                , TypeTable.ref tt meta.tipe
                ]

        Unit meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 27
                , TypeTable.ref tt meta.tipe
                ]

        Tuple region a b cs meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 28
                , A.regionEncoderV region
                , exprEncoderS st tt a
                , exprEncoderS st tt b
                , BE.list (exprEncoderS st tt) cs
                , TypeTable.ref tt meta.tipe
                ]

        Shader src attributes uniforms meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 29
                , Shader.sourceEncoderS st src
                , BE.everySet (StringTable.string st) attributes
                , BE.everySet (StringTable.string st) uniforms
                , TypeTable.ref tt meta.tipe
                ]


{-| Produces a decoder for an expression as `exprEncoderS` writes it. A
`VarDebug` gets home `Debug` of `elm/core` and no unhandled-value name, and a
`Function` or `TrackedFunction` no lambda id. An unknown tag fails.
-}
exprDecoderS : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder (Expr Name)
exprDecoderS st tdt =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Bool
                            A.regionDecoderV
                            BD.bool
                            (metaDecoderS tdt)

                    1 ->
                        Bytes.Decode.map3 Chr
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    2 ->
                        Bytes.Decode.map3 Str
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    3 ->
                        Bytes.Decode.map3 Int
                            A.regionDecoderV
                            BD.int64
                            (metaDecoderS tdt)

                    4 ->
                        Bytes.Decode.map3 Float
                            A.regionDecoderV
                            BD.float
                            (metaDecoderS tdt)

                    5 ->
                        Bytes.Decode.map2 VarLocal
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    6 ->
                        Bytes.Decode.map3 TrackedVarLocal
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    7 ->
                        Bytes.Decode.map3 VarGlobal
                            A.regionDecoderV
                            (globalDecoderS st)
                            (metaDecoderS tdt)

                    8 ->
                        Bytes.Decode.map4 VarEnum
                            A.regionDecoderV
                            (globalDecoderS st)
                            Index.zeroBasedDecoderV
                            (metaDecoderS tdt)

                    9 ->
                        Bytes.Decode.map3 VarBox
                            A.regionDecoderV
                            (globalDecoderS st)
                            (metaDecoderS tdt)

                    10 ->
                        Bytes.Decode.map4 VarCycle
                            A.regionDecoderV
                            (ModuleName.canonicalDecoderS st)
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    11 ->
                        Bytes.Decode.map3
                            (\region name meta ->
                                VarDebug region name (ModuleName.Canonical Pkg.core Name.debug) Nothing meta
                            )
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    12 ->
                        Bytes.Decode.map5 VarKernel
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (StringTable.stringDec st)
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    13 ->
                        Bytes.Decode.map3 List
                            A.regionDecoderV
                            (BD.list (exprDecoderS st tdt))
                            (metaDecoderS tdt)

                    14 ->
                        Bytes.Decode.map3 (Function Nothing)
                            (BD.list (typedNameDecoderS st tdt))
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    15 ->
                        Bytes.Decode.map3 (TrackedFunction Nothing)
                            (BD.list (typedLocatedNameDecoderS st tdt))
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    16 ->
                        Bytes.Decode.map4 Call
                            A.regionDecoderV
                            (exprDecoderS st tdt)
                            (BD.list (exprDecoderS st tdt))
                            (metaDecoderS tdt)

                    17 ->
                        Bytes.Decode.map3 TailCall
                            (StringTable.stringDec st)
                            (BD.list (BD.jsonPair (StringTable.stringDec st) (exprDecoderS st tdt)))
                            (metaDecoderS tdt)

                    18 ->
                        Bytes.Decode.map3 If
                            (BD.list (BD.jsonPair (exprDecoderS st tdt) (exprDecoderS st tdt)))
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    19 ->
                        Bytes.Decode.map3 Let
                            (defDecoderS st tdt)
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    20 ->
                        Bytes.Decode.map3 Destruct
                            (destructorDecoderS st tdt)
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    21 ->
                        Bytes.Decode.map5 Case
                            (StringTable.stringDec st)
                            (StringTable.stringDec st)
                            (deciderDecoderS st (choiceDecoderS st tdt))
                            (BD.list (BD.jsonPair BD.uintV (exprDecoderS st tdt)))
                            (metaDecoderS tdt)

                    22 ->
                        Bytes.Decode.map3 Accessor
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    23 ->
                        Bytes.Decode.map4 Access
                            (exprDecoderS st tdt)
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    24 ->
                        Bytes.Decode.map4 Update
                            A.regionDecoderV
                            (exprDecoderS st tdt)
                            (BD.assocListDict A.toValue (A.locatedDecoder (StringTable.stringDec st)) (exprDecoderS st tdt))
                            (metaDecoderS tdt)

                    25 ->
                        Bytes.Decode.map2 Record
                            (BD.stdDict (StringTable.stringDec st) (exprDecoderS st tdt))
                            (metaDecoderS tdt)

                    26 ->
                        Bytes.Decode.map3 TrackedRecord
                            A.regionDecoderV
                            (BD.assocListDict A.toValue (A.locatedDecoder (StringTable.stringDec st)) (exprDecoderS st tdt))
                            (metaDecoderS tdt)

                    27 ->
                        Bytes.Decode.map Unit (metaDecoderS tdt)

                    28 ->
                        Bytes.Decode.map5 Tuple
                            A.regionDecoderV
                            (exprDecoderS st tdt)
                            (exprDecoderS st tdt)
                            (BD.list (exprDecoderS st tdt))
                            (metaDecoderS tdt)

                    29 ->
                        Bytes.Decode.map4 Shader
                            (Shader.sourceDecoderS st)
                            (BD.everySet identity (StringTable.stringDec st))
                            (BD.everySet identity (StringTable.stringDec st))
                            (metaDecoderS tdt)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Produces an encoder for a definition. A `TailDef`'s solver variable is
written as a byte, 0 for none and 1 for one, followed by the point's index.
-}
defEncoderS : StringTable -> TypeTable -> Def Name -> Bytes.Encode.Encoder
defEncoderS st tt def =
    case def of
        Def region name expr tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoderV region
                , StringTable.string st name
                , exprEncoderS st tt expr
                , TypeTable.ref tt tipe
                ]

        TailDef region name args expr tipe maybeTvar ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoderV region
                , StringTable.string st name
                , BE.list (typedLocatedNameEncoderS st tt) args
                , exprEncoderS st tt expr
                , TypeTable.ref tt tipe
                , case maybeTvar of
                    Nothing ->
                        Bytes.Encode.unsignedInt8 0

                    Just (Vars.Pt n) ->
                        Bytes.Encode.sequence
                            [ Bytes.Encode.unsignedInt8 1
                            , Bytes.Encode.signedInt32 Bytes.BE n
                            ]
                ]


{-| Produces a decoder for a definition as `defEncoderS` writes it. Any non-zero
byte before a `TailDef`'s solver variable is read as present.
-}
defDecoderS : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder (Def Name)
defDecoderS st tdt =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map4 Def
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (exprDecoderS st tdt)
                            (TypeTable.refDecoder tdt)

                    1 ->
                        Bytes.Decode.map5 TailDef
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (BD.list (typedLocatedNameDecoderS st tdt))
                            (exprDecoderS st tdt)
                            (TypeTable.refDecoder tdt)
                            |> Bytes.Decode.andThen
                                (\tailDefFn ->
                                    Bytes.Decode.unsignedInt8
                                        |> Bytes.Decode.andThen
                                            (\tag ->
                                                case tag of
                                                    0 ->
                                                        Bytes.Decode.succeed (tailDefFn Nothing)

                                                    _ ->
                                                        Bytes.Decode.map (\n -> tailDefFn (Just (Vars.Pt n)))
                                                            (Bytes.Decode.signedInt32 Bytes.BE)
                                            )
                                )

                    _ ->
                        Bytes.Decode.fail
            )


{-| Produces an encoder for a destructor: its name, its path and its type.
-}
destructorEncoderS : StringTable -> TypeTable -> Destructor Name -> Bytes.Encode.Encoder
destructorEncoderS st tt (Destructor name path meta) =
    Bytes.Encode.sequence
        [ StringTable.string st name
        , pathEncoderS st path
        , metaEncoderS tt meta
        ]


{-| Produces a decoder for a destructor as `destructorEncoderS` writes it.
-}
destructorDecoderS : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder (Destructor Name)
destructorDecoderS st tdt =
    Bytes.Decode.map3 Destructor
        (StringTable.stringDec st)
        (pathDecoderS st)
        (metaDecoderS tdt)


{-| Produces an encoder for a decision tree, writing each leaf with `encoder`.
-}
deciderEncoderS : StringTable -> (a -> Bytes.Encode.Encoder) -> Decider a -> Bytes.Encode.Encoder
deciderEncoderS st encoder decider =
    case decider of
        Leaf value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , encoder value
                ]

        Chain testChain success failure ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.list (BE.jsonPair (DT.pathEncoderS st) (DT.testEncoderS st)) testChain
                , deciderEncoderS st encoder success
                , deciderEncoderS st encoder failure
                ]

        FanOut path edges fallback ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , DT.pathEncoderS st path
                , BE.list (BE.jsonPair (DT.testEncoderS st) (deciderEncoderS st encoder)) edges
                , deciderEncoderS st encoder fallback
                ]


{-| Produces a decoder for a decision tree as `deciderEncoderS` writes it,
reading each leaf with `decoder`.
-}
deciderDecoderS : StringTable -> Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (Decider a)
deciderDecoderS st decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Leaf decoder

                    1 ->
                        Bytes.Decode.map3 Chain
                            (BD.list (BD.jsonPair (DT.pathDecoderS st) (DT.testDecoderS st)))
                            (deciderDecoderS st decoder)
                            (deciderDecoderS st decoder)

                    2 ->
                        Bytes.Decode.map3 FanOut
                            (DT.pathDecoderS st)
                            (BD.list (BD.jsonPair (DT.testDecoderS st) (deciderDecoderS st decoder)))
                            (deciderDecoderS st decoder)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Produces an encoder for the choice at a decision-tree leaf.
-}
choiceEncoderS : StringTable -> TypeTable -> Choice Name -> Bytes.Encode.Encoder
choiceEncoderS st tt choice =
    case choice of
        Inline value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , exprEncoderS st tt value
                ]

        Jump value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.uintV value
                ]


{-| Produces a decoder for a choice as `choiceEncoderS` writes it.
-}
choiceDecoderS : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder (Choice Name)
choiceDecoderS st tdt =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Inline (exprDecoderS st tdt)

                    1 ->
                        Bytes.Decode.map Jump BD.uintV

                    _ ->
                        Bytes.Decode.fail
            )


{-| Produces an encoder for a container hint: tags 0 to 2 for list, 2-tuple and
3-tuple, and tag 3 followed by the constructor name for `HintCustom`.
-}
containerHintEncoderS : StringTable -> ContainerHint -> Bytes.Encode.Encoder
containerHintEncoderS st hint =
    case hint of
        HintList ->
            Bytes.Encode.unsignedInt8 0

        HintTuple2 ->
            Bytes.Encode.unsignedInt8 1

        HintTuple3 ->
            Bytes.Encode.unsignedInt8 2

        HintCustom ctorName ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , StringTable.string st ctorName
                ]


{-| Produces a decoder for a container hint as `containerHintEncoderS` writes
it. Any tag above 2, not only 3, is read as `HintCustom` followed by a name.
-}
containerHintDecoderS : StringTable -> Bytes.Decode.Decoder ContainerHint
containerHintDecoderS st =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\n ->
                case n of
                    0 ->
                        Bytes.Decode.succeed HintList

                    1 ->
                        Bytes.Decode.succeed HintTuple2

                    2 ->
                        Bytes.Decode.succeed HintTuple3

                    _ ->
                        Bytes.Decode.map HintCustom (StringTable.stringDec st)
            )


{-| Produces an encoder for a destructuring path, outermost step first.
-}
pathEncoderS : StringTable -> Path -> Bytes.Encode.Encoder
pathEncoderS st path =
    case path of
        Index index hint subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Index.zeroBasedEncoderV index
                , containerHintEncoderS st hint
                , pathEncoderS st subPath
                ]

        ArrayIndex index subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.uintV index
                , pathEncoderS st subPath
                ]

        Field field subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , StringTable.string st field
                , pathEncoderS st subPath
                ]

        Unbox subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , pathEncoderS st subPath
                ]

        Root name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , StringTable.string st name
                ]


{-| Produces a decoder for a destructuring path as `pathEncoderS` writes it.
-}
pathDecoderS : StringTable -> Bytes.Decode.Decoder Path
pathDecoderS st =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Index
                            Index.zeroBasedDecoderV
                            (containerHintDecoderS st)
                            (pathDecoderS st)

                    1 ->
                        Bytes.Decode.map2 ArrayIndex
                            BD.uintV
                            (pathDecoderS st)

                    2 ->
                        Bytes.Decode.map2 Field
                            (StringTable.stringDec st)
                            (pathDecoderS st)

                    3 ->
                        Bytes.Decode.map Unbox (pathDecoderS st)

                    4 ->
                        Bytes.Decode.map Root (StringTable.stringDec st)

                    _ ->
                        Bytes.Decode.fail
            )



-- ====== FORMAT VERSION ======


{-| The version of the binary format of both graphs, written as their first
byte. It must change with any change to the layout, so that an artifact in an
older layout fails to decode rather than decoding into the wrong values.
-}
typedGraphFormatVersion : Int
typedGraphFormatVersion =
    3


{-| A decoder that reads the format-version byte and fails unless it is
`typedGraphFormatVersion`.
-}
formatVersionDecoder : Bytes.Decode.Decoder ()
formatVersionDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\v ->
                if v == typedGraphFormatVersion then
                    Bytes.Decode.succeed ()

                else
                    Bytes.Decode.fail
            )



-- ====== SCHEME ROOTS ENCODERS/DECODERS ======


{-| Produces an encoder for a solver variable: its point index as a signed 32-bit
integer.
-}
variableEncoder : Vars.Variable -> Bytes.Encode.Encoder
variableEncoder (Vars.Pt idx) =
    Bytes.Encode.signedInt32 Bytes.BE idx


{-| A decoder for a solver variable as `variableEncoder` writes it.
-}
variableDecoder : Bytes.Decode.Decoder Vars.Variable
variableDecoder =
    Bytes.Decode.map Vars.Pt (Bytes.Decode.signedInt32 Bytes.BE)


{-| Returns the byte that stands for an optional super constraint: 0 for none,
then 1 to 4 for `Number`, `Comparable`, `Appendable` and `CompAppend`.
-}
maybeSuperToByte : Maybe Vars.SuperType -> Int
maybeSuperToByte ms =
    case ms of
        Nothing ->
            0

        Just Vars.Number ->
            1

        Just Vars.Comparable ->
            2

        Just Vars.Appendable ->
            3

        Just Vars.CompAppend ->
            4


{-| Returns the optional super constraint a byte stands for, as
`maybeSuperToByte` assigns them. Any byte outside 1 to 4 means none.
-}
byteToMaybeSuper : Int -> Maybe Vars.SuperType
byteToMaybeSuper b =
    case b of
        1 ->
            Just Vars.Number

        2 ->
            Just Vars.Comparable

        3 ->
            Just Vars.Appendable

        4 ->
            Just Vars.CompAppend

        _ ->
            Nothing


{-| Produces an encoder for a solver root and its optional super constraint.
-}
rootedVarEncoder : Vars.RootedVar -> Bytes.Encode.Encoder
rootedVarEncoder rv =
    Bytes.Encode.sequence
        [ variableEncoder rv.var
        , Bytes.Encode.unsignedInt8 (maybeSuperToByte rv.super)
        ]


{-| A decoder for a solver root as `rootedVarEncoder` writes it.
-}
rootedVarDecoder : Bytes.Decode.Decoder Vars.RootedVar
rootedVarDecoder =
    Bytes.Decode.map2 (\v b -> { var = v, super = byteToMaybeSuper b })
        variableDecoder
        Bytes.Decode.unsignedInt8


{-| Produces an encoder for the scheme roots of one definition.
-}
schemeRootsForDefEncoderS : StringTable -> Dict Name Vars.RootedVar -> Bytes.Encode.Encoder
schemeRootsForDefEncoderS st roots =
    BE.stdDict (StringTable.string st) rootedVarEncoder roots


{-| Produces a decoder for the scheme roots of one definition.
-}
schemeRootsForDefDecoderS : StringTable -> Bytes.Decode.Decoder (Dict Name Vars.RootedVar)
schemeRootsForDefDecoderS st =
    BD.stdDict (StringTable.stringDec st) rootedVarDecoder


{-| Produces an encoder for a local graph's scheme roots, keyed by definition
name.
-}
schemeRootsEncoderS : StringTable -> Dict Name (Dict Name Vars.RootedVar) -> Bytes.Encode.Encoder
schemeRootsEncoderS st allRoots =
    BE.stdDict (StringTable.string st) (schemeRootsForDefEncoderS st) allRoots


{-| Produces a decoder for a local graph's scheme roots.
-}
schemeRootsDecoderS : StringTable -> Bytes.Decode.Decoder (Dict Name (Dict Name Vars.RootedVar))
schemeRootsDecoderS st =
    BD.stdDict (StringTable.stringDec st) (schemeRootsForDefDecoderS st)



-- ====== VAR SUPERS ENCODERS/DECODERS ======


{-| Produces an encoder for a super constraint, as the byte `maybeSuperToByte`
gives it.
-}
superValueEncoder : Vars.SuperType -> Bytes.Encode.Encoder
superValueEncoder s =
    Bytes.Encode.unsignedInt8 (maybeSuperToByte (Just s))


{-| A decoder for a super constraint. A byte that names none, including 0, is
read as `Number`.
-}
superValueDecoder : Bytes.Decode.Decoder Vars.SuperType
superValueDecoder =
    Bytes.Decode.map (\b -> Maybe.withDefault Vars.Number (byteToMaybeSuper b)) Bytes.Decode.unsignedInt8


{-| Produces an encoder for a varSupers map.
-}
varSupersEncoderS : StringTable -> Dict Name Vars.SuperType -> Bytes.Encode.Encoder
varSupersEncoderS st vs =
    BE.stdDict (StringTable.string st) superValueEncoder vs


{-| Produces a decoder for a varSupers map.
-}
varSupersDecoderS : StringTable -> Bytes.Decode.Decoder (Dict Name Vars.SuperType)
varSupersDecoderS st =
    BD.stdDict (StringTable.stringDec st) superValueDecoder


{-| Produces an encoder for a global graph's scheme roots, keyed by global.
-}
globalSchemeRootsEncoderS : StringTable -> SchemeRootsByGlobal -> Bytes.Encode.Encoder
globalSchemeRootsEncoderS st allRoots =
    BE.assocListDict (globalEncoderS st) (schemeRootsForDefEncoderS st) allRoots


{-| Produces a decoder for a global graph's scheme roots.
-}
globalSchemeRootsDecoderS : StringTable -> Bytes.Decode.Decoder SchemeRootsByGlobal
globalSchemeRootsDecoderS st =
    BD.assocListDict toComparableGlobal (globalDecoderS st) (schemeRootsForDefDecoderS st)



-- ====== STRING COLLECTORS ======


{-| Returns the collector after giving it every string the body of
`localGraphEncoder` writes, apart from those inside types, which the type
table's rows write.
-}
collectStringsFromLocalGraph : LocalGraph Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromLocalGraph (LocalGraph data) acc =
    acc
        |> (\a -> Data.Map.foldl collectStringsFromGlobalNodePair a data.nodes)
        |> (\a -> Dict.foldl collectStringsFromAnnotationPair a data.annotations)
        |> collectStringsFromSchemeRoots data.schemeRoots
        |> (\a -> Dict.foldl (\k _ a2 -> StringTable.add k a2) a data.varSupers)


{-| Returns the collector after giving it every string the body of
`globalGraphEncoder` writes, apart from those inside types.
-}
collectStringsFromGlobalGraph : GlobalGraph Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromGlobalGraph (GlobalGraph nodes _ annotations allSchemeRoots varSupers) acc =
    acc
        |> (\a -> Data.Map.foldl collectStringsFromGlobalNodePair a nodes)
        |> (\a -> Data.Map.foldl collectStringsFromGlobalAnnotationPair a annotations)
        |> collectStringsFromGlobalSchemeRoots allSchemeRoots
        |> (\a -> Dict.foldl (\k _ a2 -> StringTable.add k a2) a varSupers)


{-| Returns the collector after giving it the strings of a node's key and of
the node.
-}
collectStringsFromGlobalNodePair : Global -> Node Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromGlobalNodePair g node acc =
    acc
        |> collectStringsFromGlobal g
        |> collectStringsFromNode node


{-| Returns the collector after giving it a definition's name and the free
variables of its type scheme.
-}
collectStringsFromAnnotationPair : Name -> Can.Annotation Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromAnnotationPair name (Can.Forall freeVars _) acc =
    acc
        |> StringTable.add name
        |> collectStringsFromFreeVars freeVars


{-| Returns the collector after giving it a global and the free variables of its
type scheme.
-}
collectStringsFromGlobalAnnotationPair : Global -> Can.Annotation Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromGlobalAnnotationPair g (Can.Forall freeVars _) acc =
    acc
        |> collectStringsFromGlobal g
        |> collectStringsFromFreeVars freeVars


{-| Returns the collector after giving it the names of a scheme's free
variables. The scheme's type is written through the type table, so its strings
are not collected here.
-}
collectStringsFromFreeVars : Can.FreeVars -> StringTable.Collector -> StringTable.Collector
collectStringsFromFreeVars freeVars acc =
    Dict.foldl (\k _ a -> StringTable.add k a) acc freeVars


{-| Returns the collector after giving it the definition names and variable
names of a local graph's scheme roots.
-}
collectStringsFromSchemeRoots : Dict Name (Dict Name Vars.RootedVar) -> StringTable.Collector -> StringTable.Collector
collectStringsFromSchemeRoots roots acc =
    Dict.foldl
        (\k inner a ->
            Dict.foldl (\k2 _ a2 -> StringTable.add k2 a2) (StringTable.add k a) inner
        )
        acc
        roots


{-| Returns the collector after giving it the globals and variable names of a
global graph's scheme roots.
-}
collectStringsFromGlobalSchemeRoots : SchemeRootsByGlobal -> StringTable.Collector -> StringTable.Collector
collectStringsFromGlobalSchemeRoots roots acc =
    Data.Map.foldl
        (\g inner a ->
            Dict.foldl (\k _ a2 -> StringTable.add k a2) (collectStringsFromGlobal g a) inner
        )
        acc
        roots



-- ====== TYPE-TABLE PRE-PASS ======


{-| Returns what encoding a local graph needs before it starts: the type table
builder holding every type the encoding refers to, and every string the
encoding writes, from the body and from the rows of the type table.

The `internTypesFrom*` walkers must reach every type the encoders write; a
type they miss makes `TypeTable.ref` crash during encoding.

-}
prePassLocal : LocalGraph Name -> ( Set String, TypeTable.Builder )
prePassLocal graph =
    let
        tb : TypeTable.Builder
        tb =
            internTypesFromLocalGraph graph TypeTable.empty
    in
    ( StringTable.collected (TypeTable.collectStrings tb (collectStringsFromLocalGraph graph StringTable.collectAll))
    , tb
    )


{-| Returns the type table builder and the strings that encoding a global graph
needs, as `prePassLocal` does for a local graph.
-}
prePassGlobal : GlobalGraph Name -> ( Set String, TypeTable.Builder )
prePassGlobal graph =
    let
        tb : TypeTable.Builder
        tb =
            internTypesFromGlobalGraph graph TypeTable.empty
    in
    ( StringTable.collected (TypeTable.collectStrings tb (collectStringsFromGlobalGraph graph StringTable.collectAll))
    , tb
    )


{-| Returns the builder with every type of a local graph's nodes and type
schemes interned.
-}
internTypesFromLocalGraph : LocalGraph Name -> TypeTable.Builder -> TypeTable.Builder
internTypesFromLocalGraph (LocalGraph data) tb =
    tb
        |> (\b -> Data.Map.foldl (\_ node b2 -> internTypesFromNode node b2) b data.nodes)
        |> (\b -> Dict.foldl (\_ (Can.Forall _ t) b2 -> TypeTable.add t b2) b data.annotations)


{-| Returns the builder with every type of a global graph's nodes and type
schemes interned.
-}
internTypesFromGlobalGraph : GlobalGraph Name -> TypeTable.Builder -> TypeTable.Builder
internTypesFromGlobalGraph (GlobalGraph nodes _ annotations _ _) tb =
    tb
        |> (\b -> Data.Map.foldl (\_ node b2 -> internTypesFromNode node b2) b nodes)
        |> (\b -> Data.Map.foldl (\_ (Can.Forall _ t) b2 -> TypeTable.add t b2) b annotations)


{-| Returns the builder with every type a node's encoding writes interned.
-}
internTypesFromNode : Node Name -> TypeTable.Builder -> TypeTable.Builder
internTypesFromNode node tb =
    case node of
        Define expr _ meta ->
            tb |> internTypesFromExpr expr |> TypeTable.add meta.tipe

        TrackedDefine _ expr _ meta ->
            tb |> internTypesFromExpr expr |> TypeTable.add meta.tipe

        Ctor _ _ tipe ->
            TypeTable.add tipe tb

        Enum _ tipe ->
            TypeTable.add tipe tb

        Box tipe ->
            TypeTable.add tipe tb

        Link _ ->
            tb

        Cycle _ values funcs _ ->
            List.foldl internTypesFromDef
                (List.foldl (\( _, e ) b -> internTypesFromExpr e b) tb values)
                funcs

        Manager _ ->
            tb

        Kernel _ _ ->
            tb

        PortIncoming expr _ meta ->
            tb |> internTypesFromExpr expr |> TypeTable.add meta.tipe

        PortOutgoing expr _ meta ->
            tb |> internTypesFromExpr expr |> TypeTable.add meta.tipe


{-| Returns the builder with every type a definition's encoding writes interned.
-}
internTypesFromDef : Def Name -> TypeTable.Builder -> TypeTable.Builder
internTypesFromDef def tb =
    case def of
        Def _ _ expr tipe ->
            tb |> internTypesFromExpr expr |> TypeTable.add tipe

        TailDef _ _ args expr tipe _ ->
            List.foldl (\( _, t ) b -> TypeTable.add t b) tb args
                |> internTypesFromExpr expr
                |> TypeTable.add tipe


{-| Returns the builder with every type an expression's encoding writes interned:
its own, those of its subexpressions, of its parameters and of its
destructors.
-}
internTypesFromExpr : Expr Name -> TypeTable.Builder -> TypeTable.Builder
internTypesFromExpr expr tb =
    case expr of
        List _ values meta ->
            List.foldl internTypesFromExpr (TypeTable.add meta.tipe tb) values

        Function _ args body meta ->
            List.foldl (\( _, t ) b -> TypeTable.add t b) tb args
                |> internTypesFromExpr body
                |> TypeTable.add meta.tipe

        TrackedFunction _ args body meta ->
            List.foldl (\( _, t ) b -> TypeTable.add t b) tb args
                |> internTypesFromExpr body
                |> TypeTable.add meta.tipe

        Call _ func args meta ->
            List.foldl internTypesFromExpr
                (tb |> internTypesFromExpr func |> TypeTable.add meta.tipe)
                args

        TailCall _ args meta ->
            List.foldl (\( _, e ) b -> internTypesFromExpr e b) (TypeTable.add meta.tipe tb) args

        If branches final meta ->
            List.foldl
                (\( c, e ) b -> b |> internTypesFromExpr c |> internTypesFromExpr e)
                (tb |> internTypesFromExpr final |> TypeTable.add meta.tipe)
                branches

        Let def body meta ->
            tb |> internTypesFromDef def |> internTypesFromExpr body |> TypeTable.add meta.tipe

        Destruct (Destructor _ _ dmeta) body meta ->
            tb |> TypeTable.add dmeta.tipe |> internTypesFromExpr body |> TypeTable.add meta.tipe

        Case _ _ decider jumps meta ->
            List.foldl (\( _, e ) b -> internTypesFromExpr e b)
                (internTypesFromDecider decider tb)
                jumps
                |> TypeTable.add meta.tipe

        Access record _ _ meta ->
            tb |> internTypesFromExpr record |> TypeTable.add meta.tipe

        Update _ record fields meta ->
            Data.Map.foldl
                (\_ e b -> internTypesFromExpr e b)
                (internTypesFromExpr record tb)
                fields
                |> TypeTable.add meta.tipe

        Record value meta ->
            Dict.foldl (\_ e b -> internTypesFromExpr e b) tb value
                |> TypeTable.add meta.tipe

        TrackedRecord _ value meta ->
            Data.Map.foldl (\_ e b -> internTypesFromExpr e b) tb value
                |> TypeTable.add meta.tipe

        Tuple _ a b cs meta ->
            List.foldl internTypesFromExpr
                (tb |> internTypesFromExpr a |> internTypesFromExpr b |> TypeTable.add meta.tipe)
                cs

        _ ->
            TypeTable.add (typeOf expr) tb


{-| Returns the builder with the types of every branch body placed in a decision
tree interned. Paths and tests carry no types.
-}
internTypesFromDecider : Decider (Choice Name) -> TypeTable.Builder -> TypeTable.Builder
internTypesFromDecider decider tb =
    case decider of
        Leaf (Inline value) ->
            internTypesFromExpr value tb

        Leaf (Jump _) ->
            tb

        Chain _ success failure ->
            tb |> internTypesFromDecider success |> internTypesFromDecider failure

        FanOut _ edges fallback ->
            List.foldl (\( _, d ) b -> internTypesFromDecider d b) tb edges
                |> internTypesFromDecider fallback



-- ====== VAR SUPERS COMPUTATION ======


{-| Returns the super constraint a name's prefix denotes, by the rule
`Compiler.Data.Name` states, or `Nothing`.

This decides the varSupers map. `StringTable.isSuperName`, which the
`collectSupers` collector uses to pick the names this sees, must be true
exactly where this returns `Just`.

-}
superOfName : Name -> Maybe Vars.SuperType
superOfName name =
    if Name.isNumberType name then
        Just Vars.Number

    else if Name.isComparableType name then
        Just Vars.Comparable

    else if Name.isAppendableType name then
        Just Vars.Appendable

    else if Name.isCompappendType name then
        Just Vars.CompAppend

    else
        Nothing


{-| Returns `acc` with `name` mapped to its super constraint, if it has one.
-}
insertSuperOfName : Name -> Dict Name Vars.SuperType -> Dict Name Vars.SuperType
insertSuperOfName name acc =
    case superOfName name of
        Just s ->
            Dict.insert name s acc

        Nothing ->
            acc


{-| Returns the varSupers map of a local graph: every string its encoding would
write, from the body or from a type, that has a super-constraint prefix,
mapped to that constraint.

Because it walks what the encoders write, it sees every type variable in the
graph. It also takes any other string with such a prefix, such as a local
variable named `numbers` or a record field named `comparableKey`.

-}
computeVarSupers : LocalGraph Name -> Dict Name Vars.SuperType
computeVarSupers graph =
    let
        tb : TypeTable.Builder
        tb =
            internTypesFromLocalGraph graph TypeTable.empty
    in
    Set.foldl insertSuperOfName
        Dict.empty
        (StringTable.collected
            (TypeTable.collectStrings tb (collectStringsFromLocalGraph graph StringTable.collectSupers))
        )


{-| Returns a varSupers map for one canonical type: each string the type writes
that has a super-constraint prefix, mapped to that constraint. Like
`computeVarSupers`, it takes alias argument and record field names as well as
type variables.
-}
varSupersOfType : Can.Type Name -> Dict Name Vars.SuperType
varSupersOfType tipe =
    Set.foldl insertSuperOfName
        Dict.empty
        (StringTable.collected (Can.collectStringsFromType tipe StringTable.collectSupers))


{-| Returns the collector after giving it a global's home module and name.
-}
collectStringsFromGlobal : Global -> StringTable.Collector -> StringTable.Collector
collectStringsFromGlobal (Global home name) acc =
    acc
        |> ModuleName.collectStringsFromCanonical home
        |> StringTable.add name


{-| Returns the collector after giving it every string a node's encoding writes,
apart from those inside types.
-}
collectStringsFromNode : Node Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromNode node acc =
    case node of
        Define expr _ _ ->
            acc |> collectStringsFromExpr expr

        TrackedDefine _ expr _ _ ->
            acc |> collectStringsFromExpr expr

        Ctor _ _ _ ->
            acc

        Enum _ _ ->
            acc

        Box _ ->
            acc

        Link g ->
            collectStringsFromGlobal g acc

        Cycle names values funcs _ ->
            let
                withNames : StringTable.Collector
                withNames =
                    List.foldl StringTable.add acc names

                withValues : StringTable.Collector
                withValues =
                    List.foldl
                        (\( n, e ) a -> a |> StringTable.add n |> collectStringsFromExpr e)
                        withNames
                        values
            in
            List.foldl collectStringsFromDef withValues funcs

        Manager _ ->
            acc

        Kernel _ _ ->
            acc

        PortIncoming expr _ _ ->
            acc |> collectStringsFromExpr expr

        PortOutgoing expr _ _ ->
            acc |> collectStringsFromExpr expr


{-| Returns the collector after giving it every string a definition's encoding
writes, apart from those inside types.
-}
collectStringsFromDef : Def Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromDef def acc =
    case def of
        Def _ name expr _ ->
            acc
                |> StringTable.add name
                |> collectStringsFromExpr expr

        TailDef _ name args expr _ _ ->
            let
                withArgs : StringTable.Collector
                withArgs =
                    List.foldl
                        (\( locName, _ ) a ->
                            a |> StringTable.add (A.toValue locName)
                        )
                        (StringTable.add name acc)
                        args
            in
            withArgs |> collectStringsFromExpr expr


{-| Returns the collector after giving it every string an expression's encoding
writes, apart from those inside types.
-}
collectStringsFromExpr : Expr Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromExpr expr acc =
    case expr of
        Bool _ _ _ ->
            acc

        Chr _ value _ ->
            acc |> StringTable.add value

        Str _ value _ ->
            acc |> StringTable.add value

        Int _ _ _ ->
            acc

        Float _ _ _ ->
            acc

        VarLocal value _ ->
            acc |> StringTable.add value

        TrackedVarLocal _ value _ ->
            acc |> StringTable.add value

        VarGlobal _ g _ ->
            acc |> collectStringsFromGlobal g

        VarEnum _ g _ _ ->
            acc |> collectStringsFromGlobal g

        VarBox _ g _ ->
            acc |> collectStringsFromGlobal g

        VarCycle _ home name _ ->
            acc
                |> ModuleName.collectStringsFromCanonical home
                |> StringTable.add name

        VarDebug _ name _ _ _ ->
            acc |> StringTable.add name

        VarKernel _ kp home name _ ->
            acc
                |> StringTable.add kp
                |> StringTable.add home
                |> StringTable.add name

        List _ values _ ->
            List.foldl collectStringsFromExpr acc values

        Function _ args body _ ->
            let
                withArgs : StringTable.Collector
                withArgs =
                    List.foldl
                        (\( n, _ ) a -> StringTable.add n a)
                        acc
                        args
            in
            withArgs |> collectStringsFromExpr body

        TrackedFunction _ args body _ ->
            let
                withArgs : StringTable.Collector
                withArgs =
                    List.foldl
                        (\( locN, _ ) a ->
                            a |> StringTable.add (A.toValue locN)
                        )
                        acc
                        args
            in
            withArgs |> collectStringsFromExpr body

        Call _ func args _ ->
            List.foldl collectStringsFromExpr
                (acc |> collectStringsFromExpr func)
                args

        TailCall name args _ ->
            List.foldl
                (\( n, e ) a -> a |> StringTable.add n |> collectStringsFromExpr e)
                (acc |> StringTable.add name)
                args

        If branches final _ ->
            List.foldl
                (\( c, b ) a -> a |> collectStringsFromExpr c |> collectStringsFromExpr b)
                (acc |> collectStringsFromExpr final)
                branches

        Let def body _ ->
            acc
                |> collectStringsFromDef def
                |> collectStringsFromExpr body

        Destruct destructor body _ ->
            acc
                |> collectStringsFromDestructor destructor
                |> collectStringsFromExpr body

        Case label root decider jumps _ ->
            let
                withLabels : StringTable.Collector
                withLabels =
                    acc |> StringTable.add label |> StringTable.add root

                withDecider : StringTable.Collector
                withDecider =
                    collectStringsFromDecider collectStringsFromChoice decider withLabels
            in
            List.foldl (\( _, e ) a -> collectStringsFromExpr e a) withDecider jumps

        Accessor _ field _ ->
            acc |> StringTable.add field

        Access record _ field _ ->
            acc
                |> collectStringsFromExpr record
                |> StringTable.add field

        Update _ record fields _ ->
            let
                withRecord : StringTable.Collector
                withRecord =
                    collectStringsFromExpr record acc
            in
            Data.Map.foldl
                (\locN e a ->
                    a |> StringTable.add (A.toValue locN) |> collectStringsFromExpr e
                )
                withRecord
                fields

        Record value _ ->
            Dict.foldl
                (\k e a -> a |> StringTable.add k |> collectStringsFromExpr e)
                acc
                value

        TrackedRecord _ value _ ->
            Data.Map.foldl
                (\locN e a ->
                    a |> StringTable.add (A.toValue locN) |> collectStringsFromExpr e
                )
                acc
                value

        Unit _ ->
            acc

        Tuple _ a b cs _ ->
            List.foldl collectStringsFromExpr
                (acc
                    |> collectStringsFromExpr a
                    |> collectStringsFromExpr b
                )
                cs

        Shader src attributes uniforms _ ->
            let
                withSrc : StringTable.Collector
                withSrc =
                    Shader.collectStringsFromSource src acc

                withAttrs : StringTable.Collector
                withAttrs =
                    Data.Set.foldr StringTable.add withSrc attributes
            in
            Data.Set.foldr StringTable.add withAttrs uniforms


{-| Returns the collector after giving it a destructor's name and the strings of
its path.
-}
collectStringsFromDestructor : Destructor Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromDestructor (Destructor name path _) acc =
    acc
        |> StringTable.add name
        |> collectStringsFromPath path


{-| Returns the collector after giving it the field, constructor and root names
of a destructuring path.
-}
collectStringsFromPath : Path -> StringTable.Collector -> StringTable.Collector
collectStringsFromPath path acc =
    case path of
        Index _ hint subPath ->
            acc |> collectStringsFromContainerHint hint |> collectStringsFromPath subPath

        ArrayIndex _ subPath ->
            collectStringsFromPath subPath acc

        Field field subPath ->
            acc |> StringTable.add field |> collectStringsFromPath subPath

        Unbox subPath ->
            collectStringsFromPath subPath acc

        Root name ->
            StringTable.add name acc


{-| Returns the collector after giving it the constructor name of a
`HintCustom` hint; the other hints write no string.
-}
collectStringsFromContainerHint : ContainerHint -> StringTable.Collector -> StringTable.Collector
collectStringsFromContainerHint hint acc =
    case hint of
        HintCustom ctorName ->
            StringTable.add ctorName acc

        _ ->
            acc


{-| Returns the collector after giving it the strings of a decision tree's paths
and tests, and those `collectInner` gives it for each leaf.
-}
collectStringsFromDecider : (a -> StringTable.Collector -> StringTable.Collector) -> Decider a -> StringTable.Collector -> StringTable.Collector
collectStringsFromDecider collectInner decider acc =
    case decider of
        Leaf value ->
            collectInner value acc

        Chain testChain success failure ->
            let
                withTests : StringTable.Collector
                withTests =
                    List.foldl
                        (\( p, t ) a -> a |> DT.collectStringsFromPath p |> DT.collectStringsFromTest t)
                        acc
                        testChain
            in
            withTests
                |> collectStringsFromDecider collectInner success
                |> collectStringsFromDecider collectInner failure

        FanOut path edges fallback ->
            let
                withPath : StringTable.Collector
                withPath =
                    DT.collectStringsFromPath path acc

                withEdges : StringTable.Collector
                withEdges =
                    List.foldl
                        (\( t, d ) a ->
                            a
                                |> DT.collectStringsFromTest t
                                |> collectStringsFromDecider collectInner d
                        )
                        withPath
                        edges
            in
            collectStringsFromDecider collectInner fallback withEdges


{-| Returns the collector after giving it the strings of a branch body placed in
a decision tree; a jump writes none.
-}
collectStringsFromChoice : Choice Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromChoice choice acc =
    case choice of
        Inline value ->
            collectStringsFromExpr value acc

        Jump _ ->
            acc
