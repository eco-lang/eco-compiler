module Compiler.AST.Optimized exposing
    ( Expr(..), Global(..), compareGlobal, toComparableGlobal
    , Def(..), Destructor(..), Path(..)
    , Decider(..), Choice(..)
    , GlobalGraph(..), LocalGraph(..), Node(..), Main(..), EffectsType(..)
    , empty, typedPathStub, toKernelGlobal, ecoKernelHome
    , globalGraphEncoder, globalGraphDecoder
    , localGraphEncoder, localGraphDecoder
    )

{-| The erased intermediate representation that the JavaScript back end
generates from.

"Erased" means that no expression carries a type. The erased optimizer
(`Compiler.LocalOpt.Erased`) produces it from canonical code, and three changes
separate it from that code: every `case` is compiled to a decision tree, a
saturated self-call in tail position of a function definition becomes a
`TailCall`, and a destructuring pattern in a `let` or a parameter becomes
`Destructor`s whose `Path`s reach into the matched value.

A _global_ is a top-level definition named by its home module and its name.
Each module's definitions become the nodes of a _local graph_, keyed by global,
and a definition's node lists the globals it depends on. The local graphs of a program and
its dependencies are merged into a _global graph_, which code generation walks
from the program's `main` so that only what is reached is emitted. Both graphs
also count how often each record field name is used.

The rest of the module is the binary codec for the two graphs, which is how a
module's graph is stored in its `.eco` file and a package's in
`artifacts.dat`.

On the typed compile path the erased optimizer does not run. What stands in for
the erased graph there is `typedPathStub`.


# Expressions

@docs Expr, Global, compareGlobal, toComparableGlobal


# Definitions

@docs Def, Destructor, Path


# Pattern Matching

The decision tree a compiled `case` is made of:

@docs Decider, Choice


# Dependency Graphs

The compiler builds a graph of definitions for dead code elimination:

@docs GlobalGraph, LocalGraph, Node, Main, EffectsType
@docs empty, typedPathStub, toKernelGlobal, ecoKernelHome


# Binary Serialization

@docs globalGraphEncoder, globalGraphDecoder
@docs localGraphEncoder, localGraphDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.Path as DT
import Compiler.AST.DecisionTree.Test as DT
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
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== EXPRESSIONS ======


{-| An erased expression.

Several constructors come in two forms, a plain one and a `Tracked` one that
also carries source regions, which the JavaScript back end uses for source maps:
`VarLocal` and `TrackedVarLocal`, `Function` and `TrackedFunction` (whose
parameters are located), and `Record` and `TrackedRecord`.

`Bool` is used for `True` and `False` of `Basics`. A constructor of a type with
no constructor arguments anywhere is `VarEnum`, carrying its index, and a
reference to the single constructor of a type with one constructor of one
argument is `VarBox`. `Chr` holds its character as a `String`.

`VarCycle` refers to another definition of the same recursive group from inside
that group. `VarDebug` is a use of a `Debug` function: its name, the module it
is used in, and an optional name. `VarKernel` names a kernel value by its
prefix (`Elm` or `Eco`), its kernel module and its name.

`TailCall` is a call of the enclosing `TailDef` from tail position, pairing each
parameter name with its new argument. `If` is a list of condition and branch
pairs followed by the final `else` branch.

`Case` is a compiled `case`. It carries a label name, the name of the variable
being inspected, the decision tree, and the jump list: the branch bodies that
the tree reaches through `Jump`, each with the index that a `Jump` uses.

`Update` and `TrackedRecord` key their fields by located name, so each field
keeps the region where it was written. `Shader` carries the GLSL source and the
names of its attributes and uniforms.

-}
type Expr
    = Bool A.Region Bool
    | Chr A.Region String
    | Str A.Region String
    | Int A.Region Int
    | Float A.Region Float
    | VarLocal Name
    | TrackedVarLocal A.Region Name
    | VarGlobal A.Region Global
    | VarEnum A.Region Global Index.ZeroBased
    | VarBox A.Region Global
    | VarCycle A.Region ModuleName.Canonical Name
    | VarDebug A.Region Name ModuleName.Canonical (Maybe Name)
    | VarKernel A.Region Name Name Name
    | List A.Region (List Expr)
    | Function (List Name) Expr
    | TrackedFunction (List (A.Located Name)) Expr
    | Call A.Region Expr (List Expr)
    | TailCall Name (List ( Name, Expr ))
    | If (List ( Expr, Expr )) Expr
    | Let Def Expr
    | Destruct Destructor Expr
    | Case Name Name (Decider Choice) (List ( Int, Expr ))
    | Accessor A.Region Name
    | Access Expr A.Region Name
    | Update A.Region Expr (Data.Map.Dict String (A.Located Name) Expr)
    | Record (Dict Name Expr)
    | TrackedRecord A.Region (Data.Map.Dict String (A.Located Name) Expr)
    | Unit
    | Tuple A.Region Expr Expr (List Expr)
    | Shader Shader.Source (EverySet String Name) (EverySet String Name)


{-| A top-level definition, named by its home module and its name.

Globals have two orders, and they differ. `compareGlobal` compares names first
and home modules second. `toComparableGlobal` makes the key that every
dictionary and set of globals in this module is keyed by, and that key orders by
home module first.

-}
type Global
    = Global ModuleName.Canonical Name


{-| Compares two globals by name, and by home module when the names are equal.
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


{-| Returns the key a global is stored under in a dictionary or set: the home
module's comparable name, a dot, and the definition's name.
-}
toComparableGlobal : Global -> String
toComparableGlobal (Global home name) =
    ModuleName.toComparableCanonical home ++ "." ++ name



-- ====== DEFINITIONS ======


{-| A definition inside a `let`, or a function of a recursive group.

`TailDef` is a function that calls itself in tail position through `TailCall`.
It carries its located parameters, where `Def` holds a function as a
`Function` expression.

-}
type Def
    = Def A.Region Name Expr
    | TailDef A.Region Name (List (A.Located Name)) Expr


{-| A variable bound by a pattern, and the path to the part of the matched value
it is bound to.
-}
type Destructor
    = Destructor Name Path


{-| A way to reach a part of a value. Each step wraps the path to the value it
is applied to, so the innermost path is the `Root` variable that holds the
whole value.

`Index` takes a numbered field of a tuple or a constructor. `Field` takes a
record field by name. `ArrayIndex` takes an element of an array-valued field;
the erased optimizer uses it with the field `cs` for the third and later
elements of a tuple. `Unbox` takes the argument of a constructor whose type has
one constructor of one argument. `Root` names the variable the path starts
from.

-}
type Path
    = Index Index.ZeroBased Path
    | ArrayIndex Int Path
    | Field Name Path
    | Unbox Path
    | Root Name



-- ====== BRANCHING ======


{-| A decision tree for a compiled `case`, whose leaves hold `a`.

The paths and tests come from `Compiler.AST.DecisionTree.Path` and
`Compiler.AST.DecisionTree.Test`.

`Chain` runs a list of tests, each on the part of the value its path reaches,
and goes to the first subtree if all of them pass and to the second otherwise.
`FanOut` looks at one part of the value and goes to the subtree whose test
matches it, or to the fallback when none does.

-}
type Decider a
    = Leaf a
    | Chain (List ( DT.Path, DT.Test )) (Decider a) (Decider a)
    | FanOut DT.Path (List ( DT.Test, Decider a )) (Decider a)


{-| What a leaf of a `Case` decision tree does: run a branch body written in
place, or jump to one in the `Case`'s jump list.

The erased optimizer writes a branch in place when exactly one leaf reaches it.
Any other branch goes in the jump list, and `Jump` carries the index it is
listed under there.

-}
type Choice
    = Inline Expr
    | Jump Int



-- ====== OBJECT GRAPH ======


{-| The nodes of many modules merged into one graph, keyed by global, with the
count of uses of each record field name.
-}
type GlobalGraph
    = GlobalGraph (Data.Map.Dict String Global Node) (Dict Name Int)


{-| One module's nodes, keyed by global, with the module's `main` if it has one
and the count of uses of each record field name.
-}
type LocalGraph
    = LocalGraph
        (Maybe Main)
        (Data.Map.Dict String Global Node)
        (Dict Name Int)


{-| What a module's `main` is.

`Static` is a `main` that is a virtual DOM node. `Dynamic` is a `main` that is
a `Platform.Program`: it carries the program's message type and an expression
that decodes the program's flags.

-}
type Main
    = Static
    | Dynamic (Can.Type Name) Expr


{-| One node of a graph: what the global it is stored under stands for.
Where a node carries a set of globals, those are the globals it depends on.

`Define` and `TrackedDefine` are an ordinary definition; the tracked form also
carries the definition's region. `Ctor` is a constructor of a custom type with
its index and its number of arguments. `Enum` is a constructor of a type whose
constructors take no arguments, and `Box` is the constructor of a type with one
constructor of one argument.

`Cycle` is a group of mutually recursive definitions: the names of all of them,
the ones that are values, and the ones that are functions. Each name of the
group is a `Link` to the global the `Cycle` is stored under. `Link` is also how
an effect module's `command` and `subscription` reach its `Manager`, which
records whether the module has commands, subscriptions or both (`Fx`).

`Kernel` is a kernel module's code, as chunks. `PortIncoming` and
`PortOutgoing` are ports, carrying the decoder or encoder of their values.

-}
type Node
    = Define Expr (EverySet String Global)
    | TrackedDefine A.Region Expr (EverySet String Global)
    | Ctor Index.ZeroBased Int
    | Enum Index.ZeroBased
    | Box
    | Link Global
    | Cycle (List Name) (List ( Name, Expr )) (List Def) (EverySet String Global)
    | Manager EffectsType
    | Kernel (List K.Chunk) (EverySet String Global)
    | PortIncoming Expr (EverySet String Global)
    | PortOutgoing Expr (EverySet String Global)


{-| Which kinds of effect an effect module manages: commands, subscriptions, or
both (`Fx`).
-}
type EffectsType
    = Cmd
    | Sub
    | Fx



-- ====== GRAPHS ======


{-| A global graph with no nodes and no field counts.
-}
empty : GlobalGraph
empty =
    GlobalGraph Data.Map.empty Dict.empty


{-| A local graph with no `main`, no nodes and no field counts.
-}
emptyLocalGraph : LocalGraph
emptyLocalGraph =
    LocalGraph Nothing Data.Map.empty Dict.empty


{-| Returns the local graph that the typed compile path stores in place of an
erased graph, given whether the module has a `main`.

The graph has no nodes and no field counts. When `hasMain` is true its `main`
is `Static`, which here only records that a `main` exists and says nothing
about what it is. The marker is needed because this graph's codec keeps `main`,
while `Compiler.AST.TypedOptimized`'s local graph codec does not, so a `main`
can be detected after the graph has been written and read back.

-}
typedPathStub : Bool -> LocalGraph
typedPathStub hasMain =
    if hasMain then
        LocalGraph (Just Static) Data.Map.empty Dict.empty

    else
        emptyLocalGraph


{-| Returns the global under which the graph holds the kernel module with
kernel prefix `kernelPrefix` (`Elm` or `Eco`) and home `home`, as
`Name.getKernel` splits a kernel module name.

An `Elm` kernel is keyed by its home alone, `elm/kernel:File.$` for
`Elm.Kernel.File`. An `Eco` kernel is keyed by its whole module
name, `elm/kernel:Eco.Kernel.File.$`, so that `Elm.Kernel.File` (elm/file) and
`Eco.Kernel.File` (eco/kernel) are two nodes rather than one replacing the other
when package graphs are merged.

-}
toKernelGlobal : Name.Name -> Name.Name -> Global
toKernelGlobal kernelPrefix home =
    if kernelPrefix == "Eco" then
        Global (ModuleName.Canonical Pkg.kernel (ecoKernelModulePrefix ++ home)) Name.dollar

    else
        Global (ModuleName.Canonical Pkg.kernel home) Name.dollar


{-| Returns the home of the `Eco` kernel module that `global` is the graph key
of, as `toKernelGlobal "Eco"` makes it, or `Nothing` for any other global.
-}
ecoKernelHome : Global -> Maybe Name.Name
ecoKernelHome (Global (ModuleName.Canonical pkg moduleName) name) =
    if pkg == Pkg.kernel && name == Name.dollar && String.startsWith ecoKernelModulePrefix moduleName then
        Just (String.dropLeft (String.length ecoKernelModulePrefix) moduleName)

    else
        Nothing


{-| The start of the module name under which `toKernelGlobal` keys an `Eco`
kernel.
-}
ecoKernelModulePrefix : String
ecoKernelModulePrefix =
    "Eco.Kernel."



-- ====== ENCODERS and DECODERS ======


{-| Encodes a global graph: its nodes, then its field counts.
-}
globalGraphEncoder : GlobalGraph -> Bytes.Encode.Encoder
globalGraphEncoder (GlobalGraph nodes fields) =
    Bytes.Encode.sequence
        [ BE.assocListDict globalEncoder nodeEncoder nodes
        , BE.stdDict BE.string BE.int fields
        ]


{-| A decoder for a global graph as `globalGraphEncoder` writes it.
-}
globalGraphDecoder : Bytes.Decode.Decoder GlobalGraph
globalGraphDecoder =
    Bytes.Decode.map2 GlobalGraph
        (BD.assocListDict toComparableGlobal globalDecoder nodeDecoder)
        (BD.stdDict BD.string BD.int)


{-| Encodes a local graph: its `main`, its nodes, then its field counts.
-}
localGraphEncoder : LocalGraph -> Bytes.Encode.Encoder
localGraphEncoder (LocalGraph main nodes fields) =
    Bytes.Encode.sequence
        [ BE.maybe mainEncoder main
        , BE.assocListDict globalEncoder nodeEncoder nodes
        , BE.stdDict BE.string BE.int fields
        ]


{-| A decoder for a local graph as `localGraphEncoder` writes it.
-}
localGraphDecoder : Bytes.Decode.Decoder LocalGraph
localGraphDecoder =
    Bytes.Decode.map3 LocalGraph
        (BD.maybe mainDecoder)
        (BD.assocListDict toComparableGlobal globalDecoder nodeDecoder)
        (BD.stdDict BD.string BD.int)


{-| Encodes a `main` as a tag byte, followed for `Dynamic` by its message type and flags decoder.
-}
mainEncoder : Main -> Bytes.Encode.Encoder
mainEncoder main_ =
    case main_ of
        Static ->
            Bytes.Encode.unsignedInt8 0

        Dynamic msgType decoder ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , Can.typeEncoder msgType
                , exprEncoder decoder
                ]


{-| A decoder for a `main` as `mainEncoder` writes it.
-}
mainDecoder : Bytes.Decode.Decoder Main
mainDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed Static

                    1 ->
                        Bytes.Decode.map2 Dynamic
                            Can.typeDecoder
                            exprDecoder

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a global as its home module followed by its name.
-}
globalEncoder : Global -> Bytes.Encode.Encoder
globalEncoder (Global home name) =
    Bytes.Encode.sequence
        [ ModuleName.canonicalEncoder home
        , BE.string name
        ]


{-| A decoder for a global as `globalEncoder` writes it.
-}
globalDecoder : Bytes.Decode.Decoder Global
globalDecoder =
    Bytes.Decode.map2 Global
        ModuleName.canonicalDecoder
        BD.string


{-| Encodes a node as a tag byte followed by its contents. No node is written with the tag 2.
-}
nodeEncoder : Node -> Bytes.Encode.Encoder
nodeEncoder node =
    case node of
        Define expr deps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , exprEncoder expr
                , BE.everySet globalEncoder deps
                ]

        TrackedDefine region expr deps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , exprEncoder expr
                , BE.everySet globalEncoder deps
                ]

        Ctor index arity ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , Index.zeroBasedEncoder index
                , BE.int arity
                ]

        Enum index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , Index.zeroBasedEncoder index
                ]

        Box ->
            Bytes.Encode.unsignedInt8 5

        Link linkedGlobal ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , globalEncoder linkedGlobal
                ]

        Cycle names values functions deps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , BE.list BE.string names
                , BE.list (BE.jsonPair BE.string exprEncoder) values
                , BE.list defEncoder functions
                , BE.everySet globalEncoder deps
                ]

        Manager effectsType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , effectsTypeEncoder effectsType
                ]

        Kernel chunks deps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , BE.list K.chunkEncoder chunks
                , BE.everySet globalEncoder deps
                ]

        PortIncoming decoder deps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , exprEncoder decoder
                , BE.everySet globalEncoder deps
                ]

        PortOutgoing encoder deps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , exprEncoder encoder
                , BE.everySet globalEncoder deps
                ]


{-| A decoder for a node as `nodeEncoder` writes it. It fails on the tag 2.
-}
nodeDecoder : Bytes.Decode.Decoder Node
nodeDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 Define
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)

                    1 ->
                        Bytes.Decode.map3 TrackedDefine
                            A.regionDecoder
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)

                    3 ->
                        Bytes.Decode.map2 Ctor
                            Index.zeroBasedDecoder
                            BD.int

                    4 ->
                        Bytes.Decode.map Enum
                            Index.zeroBasedDecoder

                    5 ->
                        Bytes.Decode.succeed Box

                    6 ->
                        Bytes.Decode.map Link globalDecoder

                    7 ->
                        Bytes.Decode.map4 Cycle
                            (BD.list BD.string)
                            (BD.list (BD.jsonPair BD.string exprDecoder))
                            (BD.list defDecoder)
                            (BD.everySet toComparableGlobal globalDecoder)

                    8 ->
                        Bytes.Decode.map Manager effectsTypeDecoder

                    9 ->
                        Bytes.Decode.map2 Kernel
                            (BD.list K.chunkDecoder)
                            (BD.everySet toComparableGlobal globalDecoder)

                    10 ->
                        Bytes.Decode.map2 PortIncoming
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)

                    11 ->
                        Bytes.Decode.map2 PortOutgoing
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes an expression as a tag byte followed by its contents.
-}
exprEncoder : Expr -> Bytes.Encode.Encoder
exprEncoder expr =
    case expr of
        Bool region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                , BE.bool value
                ]

        Chr region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , BE.string value
                ]

        Str region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoder region
                , BE.string value
                ]

        Int region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , A.regionEncoder region
                , BE.int value
                ]

        Float region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , A.regionEncoder region
                , BE.float value
                ]

        VarLocal value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , BE.string value
                ]

        TrackedVarLocal region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , A.regionEncoder region
                , BE.string value
                ]

        VarGlobal region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , A.regionEncoder region
                , globalEncoder value
                ]

        VarEnum region global index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , A.regionEncoder region
                , globalEncoder global
                , Index.zeroBasedEncoder index
                ]

        VarBox region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , A.regionEncoder region
                , globalEncoder value
                ]

        VarCycle region home name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , A.regionEncoder region
                , ModuleName.canonicalEncoder home
                , BE.string name
                ]

        VarDebug region name home unhandledValueName ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , A.regionEncoder region
                , BE.string name
                , ModuleName.canonicalEncoder home
                , BE.maybe BE.string unhandledValueName
                ]

        VarKernel region kernelPrefix home name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 12
                , A.regionEncoder region
                , BE.string kernelPrefix
                , BE.string home
                , BE.string name
                ]

        List region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 13
                , A.regionEncoder region
                , BE.list exprEncoder value
                ]

        Function args body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 14
                , BE.list BE.string args
                , exprEncoder body
                ]

        TrackedFunction args body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 15
                , BE.list (A.locatedEncoder BE.string) args
                , exprEncoder body
                ]

        Call region func args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 16
                , A.regionEncoder region
                , exprEncoder func
                , BE.list exprEncoder args
                ]

        TailCall name args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 17
                , BE.string name
                , BE.list (BE.jsonPair BE.string exprEncoder) args
                ]

        If branches final ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 18
                , BE.list (BE.jsonPair exprEncoder exprEncoder) branches
                , exprEncoder final
                ]

        Let def body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 19
                , defEncoder def
                , exprEncoder body
                ]

        Destruct destructor body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 20
                , destructorEncoder destructor
                , exprEncoder body
                ]

        Case label root decider jumps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 21
                , BE.string label
                , BE.string root
                , deciderEncoder choiceEncoder decider
                , BE.list (BE.jsonPair BE.int exprEncoder) jumps
                ]

        Accessor region field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 22
                , A.regionEncoder region
                , BE.string field
                ]

        Access record region field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 23
                , exprEncoder record
                , A.regionEncoder region
                , BE.string field
                ]

        Update region record fields ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 24
                , A.regionEncoder region
                , exprEncoder record
                , BE.assocListDict (A.locatedEncoder BE.string) exprEncoder fields
                ]

        Record value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 25
                , BE.stdDict BE.string exprEncoder value
                ]

        TrackedRecord region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 26
                , A.regionEncoder region
                , BE.assocListDict (A.locatedEncoder BE.string) exprEncoder value
                ]

        Unit ->
            Bytes.Encode.unsignedInt8 27

        Tuple region a b cs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 28
                , A.regionEncoder region
                , exprEncoder a
                , exprEncoder b
                , BE.list exprEncoder cs
                ]

        Shader src attributes uniforms ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 29
                , Shader.sourceEncoder src
                , BE.everySet BE.string attributes
                , BE.everySet BE.string uniforms
                ]


{-| A decoder for an expression as `exprEncoder` writes it.
-}
exprDecoder : Bytes.Decode.Decoder Expr
exprDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 Bool
                            A.regionDecoder
                            BD.bool

                    1 ->
                        Bytes.Decode.map2 Chr
                            A.regionDecoder
                            BD.string

                    2 ->
                        Bytes.Decode.map2 Str
                            A.regionDecoder
                            BD.string

                    3 ->
                        Bytes.Decode.map2 Int
                            A.regionDecoder
                            BD.int

                    4 ->
                        Bytes.Decode.map2 Float
                            A.regionDecoder
                            BD.float

                    5 ->
                        Bytes.Decode.map VarLocal BD.string

                    6 ->
                        Bytes.Decode.map2 TrackedVarLocal
                            A.regionDecoder
                            BD.string

                    7 ->
                        Bytes.Decode.map2 VarGlobal
                            A.regionDecoder
                            globalDecoder

                    8 ->
                        Bytes.Decode.map3 VarEnum
                            A.regionDecoder
                            globalDecoder
                            Index.zeroBasedDecoder

                    9 ->
                        Bytes.Decode.map2 VarBox
                            A.regionDecoder
                            globalDecoder

                    10 ->
                        Bytes.Decode.map3 VarCycle
                            A.regionDecoder
                            ModuleName.canonicalDecoder
                            BD.string

                    11 ->
                        Bytes.Decode.map4 VarDebug
                            A.regionDecoder
                            BD.string
                            ModuleName.canonicalDecoder
                            (BD.maybe BD.string)

                    12 ->
                        Bytes.Decode.map4 VarKernel
                            A.regionDecoder
                            BD.string
                            BD.string
                            BD.string

                    13 ->
                        Bytes.Decode.map2 List
                            A.regionDecoder
                            (BD.list exprDecoder)

                    14 ->
                        Bytes.Decode.map2 Function
                            (BD.list BD.string)
                            exprDecoder

                    15 ->
                        Bytes.Decode.map2 TrackedFunction
                            (BD.list (A.locatedDecoder BD.string))
                            exprDecoder

                    16 ->
                        Bytes.Decode.map3 Call
                            A.regionDecoder
                            exprDecoder
                            (BD.list exprDecoder)

                    17 ->
                        Bytes.Decode.map2 TailCall
                            BD.string
                            (BD.list (BD.jsonPair BD.string exprDecoder))

                    18 ->
                        Bytes.Decode.map2 If
                            (BD.list (BD.jsonPair exprDecoder exprDecoder))
                            exprDecoder

                    19 ->
                        Bytes.Decode.map2 Let
                            defDecoder
                            exprDecoder

                    20 ->
                        Bytes.Decode.map2 Destruct
                            destructorDecoder
                            exprDecoder

                    21 ->
                        Bytes.Decode.map4 Case
                            BD.string
                            BD.string
                            (deciderDecoder choiceDecoder)
                            (BD.list (BD.jsonPair BD.int exprDecoder))

                    22 ->
                        Bytes.Decode.map2 Accessor
                            A.regionDecoder
                            BD.string

                    23 ->
                        Bytes.Decode.map3 Access
                            exprDecoder
                            A.regionDecoder
                            BD.string

                    24 ->
                        Bytes.Decode.map3 Update
                            A.regionDecoder
                            exprDecoder
                            (BD.assocListDict A.toValue (A.locatedDecoder BD.string) exprDecoder)

                    25 ->
                        Bytes.Decode.map Record
                            (BD.stdDict BD.string exprDecoder)

                    26 ->
                        Bytes.Decode.map2 TrackedRecord
                            A.regionDecoder
                            (BD.assocListDict A.toValue (A.locatedDecoder BD.string) exprDecoder)

                    27 ->
                        Bytes.Decode.succeed Unit

                    28 ->
                        Bytes.Decode.map4 Tuple
                            A.regionDecoder
                            exprDecoder
                            exprDecoder
                            (BD.list exprDecoder)

                    29 ->
                        Bytes.Decode.map3 Shader
                            Shader.sourceDecoder
                            (BD.everySet identity BD.string)
                            (BD.everySet identity BD.string)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a definition as a tag byte followed by its contents.
-}
defEncoder : Def -> Bytes.Encode.Encoder
defEncoder def =
    case def of
        Def region name expr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                , BE.string name
                , exprEncoder expr
                ]

        TailDef region name args expr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , BE.string name
                , BE.list (A.locatedEncoder BE.string) args
                , exprEncoder expr
                ]


{-| A decoder for a definition as `defEncoder` writes it.
-}
defDecoder : Bytes.Decode.Decoder Def
defDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Def
                            A.regionDecoder
                            BD.string
                            exprDecoder

                    1 ->
                        Bytes.Decode.map4 TailDef
                            A.regionDecoder
                            BD.string
                            (BD.list (A.locatedDecoder BD.string))
                            exprDecoder

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a destructor as its variable name followed by its path.
-}
destructorEncoder : Destructor -> Bytes.Encode.Encoder
destructorEncoder (Destructor name path) =
    Bytes.Encode.sequence
        [ BE.string name
        , pathEncoder path
        ]


{-| A decoder for a destructor as `destructorEncoder` writes it.
-}
destructorDecoder : Bytes.Decode.Decoder Destructor
destructorDecoder =
    Bytes.Decode.map2 Destructor
        BD.string
        pathDecoder


{-| Encodes a decision tree, using `encoder` for its leaves.
-}
deciderEncoder : (a -> Bytes.Encode.Encoder) -> Decider a -> Bytes.Encode.Encoder
deciderEncoder encoder decider =
    case decider of
        Leaf value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , encoder value
                ]

        Chain testChain success failure ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.list (BE.jsonPair DT.pathEncoder DT.testEncoder) testChain
                , deciderEncoder encoder success
                , deciderEncoder encoder failure
                ]

        FanOut path edges fallback ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , DT.pathEncoder path
                , BE.list (BE.jsonPair DT.testEncoder (deciderEncoder encoder)) edges
                , deciderEncoder encoder fallback
                ]


{-| Produces a decoder for a decision tree as `deciderEncoder` writes it, using `decoder` for its leaves.
-}
deciderDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (Decider a)
deciderDecoder decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Leaf decoder

                    1 ->
                        Bytes.Decode.map3 Chain
                            (BD.list (BD.jsonPair DT.pathDecoder DT.testDecoder))
                            (deciderDecoder decoder)
                            (deciderDecoder decoder)

                    2 ->
                        Bytes.Decode.map3 FanOut
                            DT.pathDecoder
                            (BD.list (BD.jsonPair DT.testDecoder (deciderDecoder decoder)))
                            (deciderDecoder decoder)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a choice as a tag byte followed by its expression or jump index.
-}
choiceEncoder : Choice -> Bytes.Encode.Encoder
choiceEncoder choice =
    case choice of
        Inline value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , exprEncoder value
                ]

        Jump value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.int value
                ]


{-| A decoder for a choice as `choiceEncoder` writes it.
-}
choiceDecoder : Bytes.Decode.Decoder Choice
choiceDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Inline exprDecoder

                    1 ->
                        Bytes.Decode.map Jump BD.int

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a path as a tag byte followed by its contents, from its last step
down to its `Root`.
-}
pathEncoder : Path -> Bytes.Encode.Encoder
pathEncoder path =
    case path of
        Index index subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Index.zeroBasedEncoder index
                , pathEncoder subPath
                ]

        ArrayIndex index subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.int index
                , pathEncoder subPath
                ]

        Field field subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string field
                , pathEncoder subPath
                ]

        Unbox subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , pathEncoder subPath
                ]

        Root name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , BE.string name
                ]


{-| A decoder for a path as `pathEncoder` writes it.
-}
pathDecoder : Bytes.Decode.Decoder Path
pathDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 Index
                            Index.zeroBasedDecoder
                            pathDecoder

                    1 ->
                        Bytes.Decode.map2 ArrayIndex
                            BD.int
                            pathDecoder

                    2 ->
                        Bytes.Decode.map2 Field
                            BD.string
                            pathDecoder

                    3 ->
                        Bytes.Decode.map Unbox pathDecoder

                    4 ->
                        Bytes.Decode.map Root BD.string

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes an effects type as one byte.
-}
effectsTypeEncoder : EffectsType -> Bytes.Encode.Encoder
effectsTypeEncoder effectsType =
    Bytes.Encode.unsignedInt8
        (case effectsType of
            Cmd ->
                0

            Sub ->
                1

            Fx ->
                2
        )


{-| A decoder for an effects type as `effectsTypeEncoder` writes it.
-}
effectsTypeDecoder : Bytes.Decode.Decoder EffectsType
effectsTypeDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed Cmd

                    1 ->
                        Bytes.Decode.succeed Sub

                    2 ->
                        Bytes.Decode.succeed Fx

                    _ ->
                        Bytes.Decode.fail
            )
