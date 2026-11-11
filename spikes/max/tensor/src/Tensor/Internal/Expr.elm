module Tensor.Internal.Expr exposing
    ( Expr(..), Node, Op(..), Body, Meta
    , key, op, node, meta, shape, dtype, pending, problem, poisoned, rank
    , input, var, const, scalar, prim, call, ifThen, while, proj, failWith
    , operands, rebuild, shallow
    )

{-| Tensor expressions: an operation and the expressions it reads, with a structural key and the
value-level shape and dtype computed when the expression is made.

An operation whose shape rule fails records the error (`problem`) and a best-guess shape, so a graph
reports every error at once; expressions built on a failed one are `poisoned` and add no error of
their own, so only root causes are reported.

-}

import Tensor.Internal.Key as K exposing (Key)
import Tensor.Internal.Prim as P exposing (DT(..), Params, Prim)
import Tensor.Internal.Shape as Shape
import Tensor.Internal.Support as Support


type alias Meta =
    Shape.Meta


type Expr
    = Expr Node


type alias Node =
    { key : Key
    , op : Op
    , shape : List Int
    , pending : List Int
    , dtype : DT
    , problem : Maybe String
    , poisoned : Bool
    , results : List Meta
    }


{-| A traced function body: its outputs, written over the placeholders (`Var scope i`) of `scope`.
-}
type alias Body =
    { scope : Key, arity : Int, outputs : List Expr }


type Op
    = Input String Int
    | Var Key Int
    | Const (List Float)
    | P Prim (List Expr) Params
      -- a shared subgraph: its name, its body, the arguments
    | Call String Body (List Expr)
      -- the predicate, the two branches, their operands
    | If Expr Body Body (List Expr)
      -- the condition (one mask output), the body, the initial state
    | While Body Body (List Expr)
      -- result i of a Call, If or While
    | Proj Expr Int


node : Expr -> Node
node (Expr n) =
    n


key : Expr -> Key
key (Expr n) =
    n.key


op : Expr -> Op
op (Expr n) =
    n.op


meta : Expr -> Meta
meta (Expr n) =
    { shape = n.shape, pending = n.pending, dtype = n.dtype }


shape : Expr -> List Int
shape (Expr n) =
    n.shape


rank : Expr -> Int
rank (Expr n) =
    List.length n.shape


dtype : Expr -> DT
dtype (Expr n) =
    n.dtype


pending : Expr -> List Int
pending (Expr n) =
    n.pending


problem : Expr -> Maybe String
problem (Expr n) =
    n.problem


poisoned : Expr -> Bool
poisoned (Expr n) =
    n.poisoned


plain : Key -> Op -> Meta -> Expr
plain k o m =
    Expr { key = k, op = o, shape = m.shape, pending = m.pending, dtype = m.dtype, problem = Nothing, poisoned = False, results = [] }


mixMeta : Meta -> Key -> Key
mixMeta m k =
    k |> K.mix (P.dtTag m.dtype) |> K.mixInts m.shape |> K.mixInts m.pending



-- LEAVES


{-| Input `position` of graph `graph`.
-}
input : String -> Int -> DT -> List Int -> Expr
input graph position dt s =
    let
        m =
            { shape = s, pending = [], dtype = dt }
    in
    plain (K.start "input" |> K.mixString graph |> K.mix position |> mixMeta m) (Input graph position) m


{-| Placeholder `position` of the traced body `scope`.
-}
var : Key -> Int -> DT -> List Int -> Expr
var scope position dt s =
    let
        m =
            { shape = s, pending = [], dtype = dt }
    in
    plain (K.start "var" |> K.mixKey scope |> K.mix position |> mixMeta m) (Var scope position) m


{-| A constant: one value per element, row-major, or a single value for a scalar.
-}
const : DT -> List Int -> List Float -> Expr
const dt s values =
    let
        m =
            { shape = s, pending = [], dtype = dt }

        e =
            plain (K.start "const" |> mixMeta m |> K.mixFloats values) (Const values) m
    in
    if List.length values /= List.product s then
        failWith ("a constant of shape " ++ Shape.showShape s ++ " needs " ++ String.fromInt (List.product s) ++ " values, not " ++ String.fromInt (List.length values)) e

    else
        e


scalar : DT -> Float -> Expr
scalar dt v =
    const dt [] [ v ]


{-| Marks an expression with a build error (keeping its shape, so later operations still check).
-}
failWith : String -> Expr -> Expr
failWith msg (Expr n) =
    Expr { n | problem = Just msg, poisoned = True, key = K.mixString msg n.key }



-- PRIMITIVES


prim : Prim -> List Expr -> Params -> Expr
prim p args params =
    let
        k =
            K.start "prim"
                |> K.mix (P.tag p)
                |> K.mixInts params.a
                |> K.mixInts params.b
                |> K.mixFloats params.f
                |> (\k0 -> List.foldl (\a acc -> K.mixKey (key a) acc) (K.mix (List.length args) k0) args)

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
            Expr { key = k, op = P p args params, shape = m.shape, pending = m.pending, dtype = m.dtype, problem = Nothing, poisoned = anyPoisoned, results = [] }

        Err msg ->
            if anyPoisoned then
                Expr { key = k, op = P p args params, shape = guess.shape, pending = [], dtype = guess.dtype, problem = Nothing, poisoned = True, results = [] }

            else
                Expr { key = k, op = P p args params, shape = guess.shape, pending = [], dtype = guess.dtype, problem = Just (P.name p ++ ": " ++ msg), poisoned = True, results = [] }



{-| The dtype support table, probed on MAX: an operation MAX refuses to compile for its operand's
dtype is refused here, with a clear message, rather than by MAX's opaque compile failure.
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


multi : Key -> Op -> List Expr -> List Meta -> Expr
multi k o args results =
    Expr { key = k, op = o, shape = [], pending = [], dtype = F32, problem = Nothing, poisoned = List.any poisoned args, results = results }


bodyKey : Body -> Key -> Key
bodyKey b k =
    List.foldl (\o acc -> K.mixKey (key o) acc) (k |> K.mixKey b.scope |> K.mix b.arity) b.outputs


argsKey : List Expr -> Key -> Key
argsKey args k =
    List.foldl (\a acc -> K.mixKey (key a) acc) (K.mix (List.length args) k) args


call : String -> Body -> List Expr -> Expr
call name b args =
    multi (K.start "call" |> K.mixString name |> bodyKey b |> argsKey args) (Call name b args) args (List.map meta b.outputs)


ifThen : Expr -> Body -> Body -> List Expr -> Expr
ifThen pred t f args =
    multi (K.start "if" |> K.mixKey (key pred) |> bodyKey t |> bodyKey f |> argsKey args) (If pred t f args) (pred :: args) (List.map meta t.outputs)


while : Body -> Body -> List Expr -> Expr
while c b init =
    multi (K.start "while" |> bodyKey c |> bodyKey b |> argsKey init) (While c b init) init (List.map meta init)


proj : Expr -> Int -> Expr
proj (Expr n) i =
    let
        m =
            List.drop i n.results |> List.head |> Maybe.withDefault { shape = [], pending = [], dtype = F32 }
    in
    Expr { key = K.start "proj" |> K.mixKey n.key |> K.mix i, op = Proj (Expr n) i, shape = m.shape, pending = m.pending, dtype = m.dtype, problem = Nothing, poisoned = n.poisoned, results = [] }



-- STRUCTURE


{-| The expressions an expression reads directly (not the bodies of calls and branches).
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


{-| The same operation over new operands (in `operands` order), re-keyed and re-checked.
-}
rebuild : Expr -> List Expr -> Expr
rebuild ((Expr n) as e) args =
    case ( n.op, args ) of
        ( P p _ params, _ ) ->
            prim p args params

        ( Call name b _, _ ) ->
            call name b args

        ( If _ t f _, pred :: rest ) ->
            ifThen pred t f rest

        ( While c b _, _ ) ->
            while c b args

        ( Proj _ i, [ m ] ) ->
            proj m i

        _ ->
            e


{-| What identifies an expression besides its key: its operation and its operands' keys. Lowering
compares these on every key hit.
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
                    "const " ++ String.fromInt (List.length vs)

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
