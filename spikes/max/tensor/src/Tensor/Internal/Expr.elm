module Tensor.Internal.Expr exposing
    ( Body
    , Expr(..)
    , Meta
    , Node
    , Op(..)
    , bodies
    , call
    , const
    , constValues
    , dtype
    , failWith
    , ifThen
    , inherit
    , input
    , keepCheck
    , key
    , mapBodies
    , meta
    , node
    , op
    , operands
    , pending
    , poisoned
    , prim
    , problem
    , proj
    , rank
    , rebuild
    , scalar
    , shallow
    , shape
    , var
    , varMeta
    , while
    )

{-| A tensor in this package is a description of a computation, not its element values, and this
module is the one node type those descriptions are made of.

An _expression_ (`Expr`) is a node that names one operation and the expressions it reads, its
_operands_. Making an expression computes no element values. It computes, once, what can be known
without them: its key, its _meta_ (its shape, which of its axes are pending, and its dtype, as
`Tensor.Internal.Shape` defines them), and any build error.

The _key_ stands for an expression's identity (`Tensor.Internal.Key` says how a key is mixed), and
this module decides what each kind of node mixes into it. Every node mixes a tag for its kind. A
_leaf_, a node that reads no other expression (an input, a placeholder or a constant), also mixes
its meta and what tells it apart from other leaves of its kind. Every other node mixes what
configures it, such as a primitive's tag and every value of its params, and the keys of the
expressions and bodies it reads. `failWith` mixes its message in as well. Two expressions built
alike from operands with the same keys therefore have the same key. A key is a hash, so two
different expressions can also share one; `shallow` describes an expression without its key, so
that such a collision can be noticed.

A _build error_, called a _problem_ here, is a message recorded on an expression saying why it
cannot be made as asked. `prim` records one when the primitive's shape rule
(`Tensor.Internal.Shape.rule`) or the dtype support check refuses the operands, a constant
records one when its values do not fit its shape or its dtype, and `failWith` records one for any
check of the caller's own. An expression is _poisoned_ when it has failed in
any of these ways or reads a poisoned operand. A primitive that reads a poisoned operand records no
message even when its rule refuses, and `failWith` records nothing on an expression that is already
poisoned, so the message stays with the expression that caused it and is neither repeated nor
replaced by what is built on it. A failed primitive still has a meta, a guess (its first operand's
shape and dtype, when it has an operand), so that expressions can go on being built on it.

Most nodes have one result, which their meta describes. A _multi-result node_ (`Call`, `If`,
`While`) holds _bodies_: traced functions, whose outputs are written in terms of _placeholders_
(`Var`) standing for their arguments. Such a node's own meta is a dummy (an `f32` scalar with no
pending axes) that describes none of its results, and each result is read through a _projection_
(`proj`), which has that result's meta. A multi-result node's bodies are not among its operands,
but a poisoned body output poisons the node all the same.

The functions at the end of the file, `operands`, `rebuild`, `keepCheck`, `bodies`, `mapBodies`
and `shallow`, serve code that walks or rewrites expressions. A node that `rebuild` or `mapBodies`
makes keeps the message `failWith` recorded on the node it replaces, and `keepCheck` does the same
for a node made afresh by other means.

-}

import Tensor.Internal.Key as K exposing (Key)
import Tensor.Internal.Prim as P exposing (DT(..), Params, Prim)
import Tensor.Internal.Shape as Shape
import Tensor.Internal.Support as Support
import Tensor.Internal.Values as Values exposing (Values(..))


{-| The shape, pending axes and dtype of an expression's value. It is `Tensor.Internal.Shape`'s
`Meta`, under a name this module exposes.
-}
type alias Meta =
    Shape.Meta


{-| A tensor expression: one node, which holds the expressions it reads.

The constructor wraps the node's record, `Node`. The wrapper is needed because a node's operation
holds other expressions, and a record alias cannot refer to itself.

-}
type Expr
    = Expr Node


{-| Everything known about an expression once it is made: its key, its operation, its meta, and
whether it has failed.

`shape` holds 1 for each pending axis, and `pending` lists those axes' positions. `problem` is the
build error recorded on this expression itself: one that is poisoned only because it reads a
poisoned operand has `Nothing`. `check` is the message, if any, that `failWith` recorded as that
build error, which `rebuild` and `mapBodies` record again on the node they make. `results` holds the metas of a multi-result node's results, in
order, and is empty in every other node this module makes; in a multi-result node, `shape`,
`pending` and `dtype` are the dummy `f32` scalar.

-}
type alias Node =
    { key : Key
    , op : Op
    , shape : List Int
    , pending : List Int
    , dtype : DT
    , problem : Maybe String
    , check : Maybe String
    , poisoned : Bool
    , results : List Meta
    }


{-| The result of tracing a function: its outputs, written in terms of placeholders `Var scope i`,
each standing for argument `i`.

`scope` is the key the placeholders carry, which ties them to this body, and `arity` is the number
of arguments. Nothing here checks that the outputs read only these placeholders, or only
placeholders numbered below `arity`.

-}
type alias Body =
    { scope : Key, arity : Int, outputs : List Expr }


{-| The operation an expression applies, with what it reads.

`Input graph position` is input `position` of the graph named `graph`.

`Var scope position` is a placeholder for argument `position` of the body whose scope key is
`scope`.

`Const values` is a constant whose elements are `values`.

`P prim operands params` applies a primitive to its operands, configured by `params`, whose layout
`Tensor.Internal.Prim` gives for each primitive.

`Call name body args` applies the function named `name`, whose traced body is `body`, to `args`:
the body's placeholder `i` stands for argument `i`.

`If pred thenBody elseBody args` gives the results of `thenBody` when `pred` holds and of
`elseBody` otherwise, each applied to `args`.

`While cond body init` starts from the state `init` and, while `cond` holds for the state, replaces
the state with `body`'s outputs. Both bodies take the state as their arguments, and `cond`'s one
output, a mask, is the condition. Its results are the final state.

`Proj node i` is result `i` of the multi-result node `node`.

-}
type Op
    = Input String Int
    | Var Key Int
    | Const Values
    | P Prim (List Expr) Params
    | Call String Body (List Expr)
    | If Expr Body Body (List Expr)
    | While Body Body (List Expr)
    | Proj Expr Int


{-| Returns the record of everything known about the expression.
-}
node : Expr -> Node
node (Expr n) =
    n


{-| Returns the expression's key.
-}
key : Expr -> Key
key (Expr n) =
    n.key


{-| Returns the operation the expression applies, with what it reads.
-}
op : Expr -> Op
op (Expr n) =
    n.op


{-| Returns the expression's shape, pending axes and dtype. For a multi-result node they are the
dummy `f32` scalar; each result's meta is that of its projection.
-}
meta : Expr -> Meta
meta (Expr n) =
    { shape = n.shape, pending = n.pending, dtype = n.dtype }


{-| Returns the expression's shape, with 1 for each pending axis.
-}
shape : Expr -> List Int
shape (Expr n) =
    n.shape


{-| Returns the expression's number of axes.
-}
rank : Expr -> Int
rank (Expr n) =
    List.length n.shape


{-| Returns the expression's dtype.
-}
dtype : Expr -> DT
dtype (Expr n) =
    n.dtype


{-| Returns the positions of the expression's pending axes.
-}
pending : Expr -> List Int
pending (Expr n) =
    n.pending


{-| Returns the build error recorded on the expression itself, if there is one. An expression
poisoned only because it reads a poisoned operand has none.
-}
problem : Expr -> Maybe String
problem (Expr n) =
    n.problem


{-| Returns whether the expression has failed or reads a poisoned operand. A multi-result node's
bodies do not count as operands.
-}
poisoned : Expr -> Bool
poisoned (Expr n) =
    n.poisoned


{-| Returns a node with key `k`, operation `o` and meta `m` that has not failed and has no results
of its own.
-}
plain : Key -> Op -> Meta -> Expr
plain k o m =
    Expr { key = k, op = o, shape = m.shape, pending = m.pending, dtype = m.dtype, problem = Nothing, check = Nothing, poisoned = False, results = [] }


{-| Returns `k` with a meta mixed in: its dtype's tag, its shape and its pending axes.
-}
mixMeta : Meta -> Key -> Key
mixMeta m k =
    k |> K.mix (P.dtTag m.dtype) |> K.mixInts m.shape |> K.mixInts m.pending



-- LEAVES


{-| Returns input `position` of the graph named `graph`, with dtype `dt`, shape `s` and no pending
axes. Its key mixes the graph's name, so the same position of two graphs gives two different
expressions.
-}
input : String -> Int -> DT -> List Int -> Expr
input graph position dt s =
    let
        m =
            { shape = s, pending = [], dtype = dt }
    in
    plain (K.start "input" |> K.mixString graph |> K.mix position |> mixMeta m) (Input graph position) m


{-| Returns the placeholder for argument `position` of the body whose scope key is `scope`, with
dtype `dt`, shape `s` and no pending axes: `varMeta` with that meta.
-}
var : Key -> Int -> DT -> List Int -> Expr
var scope position dt s =
    varMeta scope position { shape = s, pending = [], dtype = dt }


{-| Returns the placeholder for argument `position` of the body whose scope key is `scope`, with
the meta `m`: its shape, its pending axes and its dtype. Its key mixes the scope, the position and
the meta, so placeholders that differ only in their pending axes are different expressions.

Giving a placeholder its argument's meta, `varMeta scope i (meta a)`, keeps a pending axis of `a`
pending inside the body. Nothing checks that `m.shape` holds 1 at each of `m.pending`.

-}
varMeta : Key -> Int -> Meta -> Expr
varMeta scope position m =
    plain (K.start "var" |> K.mixKey scope |> K.mix position |> mixMeta m) (Var scope position) m


{-| Returns a constant of dtype `dt` and shape `s` whose elements, one per element in row-major
order, are `values`.

The floats become the dtype's values as `Tensor.Internal.Values.forDtype` makes them: for an
integer dtype or `bool` each is rounded to an `Int`, and nothing checks that the dtype can hold it.
Where `constValues` accepts the rounded values, the two give the same expression. A negative size
in `s` is a build error, and so is a number of values other than the number of elements of `s`.

-}
const : DT -> List Int -> List Float -> Expr
const dt s values =
    constWith False dt s (Values.forDtype dt values)


{-| Returns a constant of dtype `dt` and shape `s` whose elements, one per element in row-major
order, are `values`.

A negative size in `s` is a build error, and so are a number of values other than the number of
elements of `s` and a value that `Tensor.Internal.Values.fitsDtype` finds out of range for `dt`, which it checks only for
`si8`, `ui8`, `si32` and `bool`. Nothing checks that the kind of `values` matches `dt`.

-}
constValues : DT -> List Int -> Values -> Expr
constValues =
    constWith True


{-| Returns the constant of dtype `dt` and shape `s` holding `values`, failed if `s` holds a
negative size, if the number of values is not the number of elements of `s` or, when `checked`, if
`Values.fitsDtype` refuses them. Only the first of these, in that order, is recorded.
-}
constWith : Bool -> DT -> List Int -> Values -> Expr
constWith checked dt s values =
    let
        m =
            { shape = s, pending = [], dtype = dt }

        mixValues =
            case values of
                FloatValues l ->
                    K.mixFloats l

                IntValues l ->
                    K.mixInt64s l

        e =
            plain (K.start "const" |> mixMeta m |> mixValues) (Const values) m

        n =
            Values.length values
    in
    if List.any (\d -> d < 0) s then
        failWith ("a constant of shape " ++ Shape.showShape s ++ " has a negative size") e

    else if n /= List.product s then
        failWith ("a constant of shape " ++ Shape.showShape s ++ " needs " ++ String.fromInt (List.product s) ++ " values, not " ++ String.fromInt n) e

    else
        case ( checked, Values.fitsDtype dt values ) of
            ( True, Just msg ) ->
                failWith msg e

            _ ->
                e


{-| Returns a rank-0 constant of dtype `dt` holding `v`. As with `const`, `v` is rounded for an
integer dtype or `bool`, and nothing checks that the dtype can hold it.
-}
scalar : DT -> Float -> Expr
scalar dt v =
    const dt [] [ v ]


{-| Returns `e` failed with the build error `msg`: poisoned, with `msg` as its problem, and with
`msg` mixed into its key, so that it is a different expression from `e`. Its operation and meta are
kept, so expressions can still be built on it.

An `e` that is already poisoned is returned unchanged, so the build error that poisoned it stays
the one reported for it and `msg` is dropped.

-}
failWith : String -> Expr -> Expr
failWith msg ((Expr n) as e) =
    if n.poisoned then
        e

    else
        Expr { n | problem = Just msg, check = Just msg, poisoned = True, key = K.mixString msg n.key }


{-| Returns `result`, failed as `template` failed when `template` is poisoned and `result` is not:
`failWith` of the first build error found on `template` or on what it reads (through operands and
bodies, depth first, operands in order), or of a generic message if none is found. Otherwise
returns `result` unchanged.

This is for an expression made from what is known about `template`, such as its shape, without
reading it: without `inherit`, a failed template's error would not be reachable from the result.

-}
inherit : Expr -> Expr -> Expr
inherit template result =
    if poisoned template && not (poisoned result) then
        failWith (rootProblem template |> Maybe.withDefault "made from a tensor that failed to build") result

    else
        result


{-| Returns the first build error recorded on `e` or on a poisoned expression it reads, searching
depth first through operands, in order, and then bodies' outputs; only poisoned expressions are
looked into, and each key only once.
-}
rootProblem : Expr -> Maybe String
rootProblem e =
    let
        go : List Expr -> List Key -> Maybe String
        go stack seen =
            case stack of
                [] ->
                    Nothing

                ((Expr n) as x) :: rest ->
                    if not n.poisoned || List.member n.key seen then
                        go rest seen

                    else
                        case n.problem of
                            Just msg ->
                                Just msg

                            Nothing ->
                                go (operands x ++ List.concatMap .outputs (bodies x) ++ rest) (n.key :: seen)
    in
    go [ e ] []



-- PRIMITIVES


{-| Returns the node that applies `p` to `args` with `params`, with the meta that `p`'s shape rule
(`Tensor.Internal.Shape.rule`) gives. Its key mixes `p`'s tag, every value of `params`, and the
number and keys of `args`.

When the rule accepts the operands, the dtype support check is made: a primitive that the generated
`Tensor.Internal.Support` table lists, by its name, as not compiling on MAX for the first operand's
dtype is refused. Only the first operand's dtype is looked up.

If either refuses, the node is poisoned and its meta is a guess: the first operand's shape and
dtype with no pending axes, or an `f32` scalar when there are no operands. Its problem is the
refusal, after `p`'s name (`"plus: …"`), unless an operand is already poisoned, in which case it
has none. If both accept, the node is poisoned only when an operand is.

-}
prim : Prim -> List Expr -> Params -> Expr
prim p args params =
    let
        k =
            K.start "prim"
                |> K.mix (P.tag p)
                |> K.mixInts params.a
                |> K.mixInts params.b
                |> K.mixFloats params.f
                |> argsKey args

        anyPoisoned =
            List.any poisoned args

        guess =
            case args of
                a :: _ ->
                    meta a

                [] ->
                    { shape = [], pending = [], dtype = F32 }
    in
    case Shape.rule p (List.map meta args) params |> Result.andThen (supported p args) of
        Ok m ->
            Expr { key = k, op = P p args params, shape = m.shape, pending = m.pending, dtype = m.dtype, problem = Nothing, check = Nothing, poisoned = anyPoisoned, results = [] }

        Err msg ->
            if anyPoisoned then
                Expr { key = k, op = P p args params, shape = guess.shape, pending = [], dtype = guess.dtype, problem = Nothing, check = Nothing, poisoned = True, results = [] }

            else
                Expr { key = k, op = P p args params, shape = guess.shape, pending = [], dtype = guess.dtype, problem = Just (P.name p ++ ": " ++ msg), check = Nothing, poisoned = True, results = [] }


{-| Returns `m`, or a refusal naming the dtype when the generated `Tensor.Internal.Support` table
lists `p`, by its name, as not compiling for the dtype of the first of `args`. That table records
what a probe of MAX on CPU found not to compile. Only the first operand's dtype is looked up, and a
primitive with no operands is never refused.
-}
supported : Prim -> List Expr -> Meta -> Result String Meta
supported p args m =
    case args of
        a :: _ ->
            if Support.refused (P.name p) (dtype a) then
                Err ("MAX does not compile this for " ++ P.dtName (dtype a) ++ " tensors (on CPU)")

            else
                Ok m

        [] ->
            Ok m



-- MULTI-RESULT OPERATIONS


{-| Returns a multi-result node with key `k`, operation `o`, bodies `bs` and result metas
`results`. It is poisoned when one of `args` or one of `bs`' outputs is, and it records no problem
of its own.
-}
multi : Key -> Op -> List Expr -> List Body -> List Meta -> Expr
multi k o args bs results =
    Expr
        { key = k
        , op = o
        , shape = []
        , pending = []
        , dtype = F32
        , problem = Nothing
        , check = Nothing
        , poisoned = List.any poisoned args || List.any (\b -> List.any poisoned b.outputs) bs
        , results = results
        }


{-| Returns `k` with a body mixed in: its scope, its arity and the keys of its outputs.
-}
bodyKey : Body -> Key -> Key
bodyKey b k =
    List.foldl (\o acc -> K.mixKey (key o) acc) (k |> K.mixKey b.scope |> K.mix b.arity) b.outputs


{-| Returns `k` with the number and keys of `args` mixed in.
-}
argsKey : List Expr -> Key -> Key
argsKey args k =
    List.foldl (\a acc -> K.mixKey (key a) acc) (K.mix (List.length args) k) args


{-| Returns a node that applies the function named `name`, traced as `b`, to `args`. Its key mixes
the name, the body and the arguments.

Its results have the metas of `b`'s outputs. It is poisoned when an argument or an output of `b`
is. Nothing here compares `args` with the arguments `b` was traced on.

-}
call : String -> Body -> List Expr -> Expr
call name b args =
    multi (K.start "call" |> K.mixString name |> bodyKey b |> argsKey args) (Call name b args) args [ b ] (List.map meta b.outputs)


{-| Returns a node that gives the results of `t` when `pred` holds and of `f` otherwise, each body
applied to `args`.

Its results have the metas of `t`'s outputs. It is poisoned when `pred`, an argument or an output
of either body is. Nothing here checks that `f`'s outputs have the same metas, or that `pred` is a
scalar mask.

-}
ifThen : Expr -> Body -> Body -> List Expr -> Expr
ifThen pred t f args =
    multi (K.start "if" |> K.mixKey (key pred) |> bodyKey t |> bodyKey f |> argsKey args) (If pred t f args) (pred :: args) [ t, f ] (List.map meta t.outputs)


{-| Returns a node that starts from the state `init` and, while `c` holds for the state, replaces
the state with `b`'s outputs; its results are the final state.

Its results have the metas of `init`. It is poisoned when a tensor of `init` or an output of
either body is. Nothing here checks that `b` keeps them, or that `c` gives a single scalar mask.

-}
while : Body -> Body -> List Expr -> Expr
while c b init =
    multi (K.start "while" |> bodyKey c |> bodyKey b |> argsKey init) (While c b init) init [ c, b ] (List.map meta init)


{-| Returns result `i` of the multi-result node `e`, with that result's meta. It is poisoned when
`e` is.

An `i` at or beyond the number of results, or an `e` that is not a multi-result node, gives the
meta of an `f32` scalar and no build error.

-}
proj : Expr -> Int -> Expr
proj (Expr n) i =
    let
        m =
            List.drop i n.results |> List.head |> Maybe.withDefault { shape = [], pending = [], dtype = F32 }
    in
    Expr { key = K.start "proj" |> K.mixKey n.key |> K.mix i, op = Proj (Expr n) i, shape = m.shape, pending = m.pending, dtype = m.dtype, problem = Nothing, check = Nothing, poisoned = n.poisoned, results = [] }



-- STRUCTURE


{-| Returns the expressions `e` reads directly, in the order `rebuild` takes them: a primitive's
operands, a call's arguments, an `If`'s predicate and then its arguments, a loop's initial state,
or a projection's node. A leaf reads none, and the bodies of a `Call`, `If` or `While` are not
included.
-}
operands : Expr -> List Expr
operands (Expr n) =
    case n.op of
        P _ args _ ->
            args

        Call _ _ args ->
            args

        If pred _ _ args ->
            pred :: args

        While _ _ init ->
            init

        Proj e _ ->
            [ e ]

        _ ->
            []


{-| Returns `e`'s operation applied to `args`, in `operands` order, in place of its operands. The
node is made afresh by the function that builds its kind: its key is mixed again, and a
primitive is checked again as `prim` checks it. Its bodies, name, params and index, whichever it
has, are kept, and a message that `failWith` recorded on `e` is recorded again by `failWith` on the
new node (which keeps only the new node's own build error when it is already poisoned).

A leaf is returned unchanged, and so is an `If` given no arguments or a projection given other than
one.

-}
rebuild : Expr -> List Expr -> Expr
rebuild ((Expr n) as e) args =
    case ( n.op, args ) of
        ( P p _ params, _ ) ->
            prim p args params |> keepCheck e

        ( Call name b _, _ ) ->
            call name b args |> keepCheck e

        ( If _ t f _, pred :: rest ) ->
            ifThen pred t f rest |> keepCheck e

        ( While c b _, _ ) ->
            while c b args |> keepCheck e

        ( Proj _ i, [ m ] ) ->
            proj m i |> keepCheck e

        _ ->
            e


{-| Returns `fresh` with the message `failWith` recorded on `old`, if any, recorded on it by
`failWith`, so that a node made afresh in place of `old` keeps the caller's check that failed it.
A `fresh` that is already poisoned is returned unchanged, as `failWith` returns it.
-}
keepCheck : Expr -> Expr -> Expr
keepCheck (Expr old) fresh =
    case old.check of
        Just msg ->
            failWith msg fresh

        Nothing ->
            fresh


{-| Returns the bodies of a multi-result node, in the order `mapBodies` takes them: a call's body,
an `If`'s then-body and else-body, or a loop's condition and step. Any other node has none.
-}
bodies : Expr -> List Body
bodies (Expr n) =
    case n.op of
        Call _ b _ ->
            [ b ]

        If _ t f _ ->
            [ t, f ]

        While c b _ ->
            [ c, b ]

        _ ->
            []


{-| Returns `e` with each of its bodies, in `bodies` order, replaced by `f` of it, and its operands,
name and index kept. The node is made afresh by `call`, `ifThen` or `while`, so its key is mixed
again from the new bodies, and a message that `failWith` recorded on `e` is recorded again on it,
as `rebuild` does.

Any other node is returned unchanged. When no body's key-relevant parts change (scope, arity and the
keys of the outputs), the result has `e`'s key.

-}
mapBodies : (Body -> Body) -> Expr -> Expr
mapBodies f ((Expr n) as e) =
    case n.op of
        Call name b args ->
            call name (f b) args |> keepCheck e

        If pred t fb args ->
            ifThen pred (f t) (f fb) args |> keepCheck e

        While c b init ->
            while (f c) (f b) init |> keepCheck e

        _ ->
            e


{-| Returns a description of `e` made without its key: a string naming its kind, its dtype and its
shape, paired with the keys of its operands.

Two expressions that share a key but have different descriptions are a key collision. Two with the
same description may still differ, because it leaves out a primitive's params (a primitive is
described by its tag and its number of operands), the bodies of a `Call`, `If` or `While`, a
placeholder's scope, pending axes, and problems. A constant is described by its kind, its number of
values and `Tensor.Internal.Values.altHash` of them, a second hash that can itself collide.

-}
shallow : Expr -> ( String, List Key )
shallow (Expr n) =
    let
        tagOf =
            case n.op of
                Input g i ->
                    "input " ++ g ++ " " ++ String.fromInt i

                Var _ i ->
                    "var " ++ String.fromInt i

                Const vs ->
                    "const "
                        ++ (case vs of
                                FloatValues _ ->
                                    "f"

                                IntValues _ ->
                                    "i"
                           )
                        ++ " "
                        ++ String.fromInt (Values.length vs)
                        ++ " "
                        ++ String.fromInt (Values.altHash vs)

                P p params _ ->
                    "prim " ++ String.fromInt (P.tag p) ++ " " ++ String.fromInt (List.length params)

                Call name _ _ ->
                    "call " ++ name

                If _ _ _ _ ->
                    "if"

                While _ _ _ ->
                    "while"

                Proj _ i ->
                    "proj " ++ String.fromInt i
    in
    ( tagOf ++ " " ++ P.dtName n.dtype ++ " " ++ Shape.showShape n.shape, List.map key (operands (Expr n)) )
