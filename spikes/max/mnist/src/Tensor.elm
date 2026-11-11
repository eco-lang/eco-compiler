module Tensor exposing
    ( Tensor, F32, U8, I64, Boolean, Any
    , DType, f32, u8, i64
    , input, constant, cast, toFloat, toInt, any
    , plus, minus, times, scale, matmul, relu, negate, greaterThan, equals
    , softmax, logSoftmax, sum, argMax, reshape, column, transpose, range
    , oneHot, crossEntropy, grad
    , Graph, Spec, graph
    )

{-| Tensors as values: a network written the way a textbook writes it.

    network p pixels =
        pixels
            |> toFloat |> scale (1 / 255)
            |> matmul p.w1 |> plus p.b1 |> relu
            |> matmul p.w2 |> plus p.b2

A `Tensor` is an immutable expression: an operation and the tensors it reads. Nothing is
computed and nothing is threaded; `graph` walks back from a graph's outputs and lowers the
expressions onto a `Graph` tape, whose shape inference, checks, autodiff and writers do the rest.

In a pipeline the tensor flowing in is the left operand: `x |> minus y` is x - y, and
`x |> matmul w` is x @ w.

The dtype is a phantom type, so mixing dtypes (an `f32` weight times raw `u8` pixels) is an Elm
compile error. Shapes are values: `Graph` checks them as `graph` lowers, and `graph` refuses the
graph before MAX sees it.

**Sharing.** Every tensor carries a structural key, two 31-bit hashes of its operation and its
operands' keys, computed when it is made. Lowering memoises on it, so a tensor used many times (as
the backward pass uses the forward values) becomes one node, in time linear in the graph; equal
expressions become one node too (all operations are pure).

-}

import Dict exposing (Dict)
import Graph as G



-- DTYPES


type F32
    = F32 Never


type U8
    = U8 Never


type I64
    = I64 Never


type Boolean
    = Boolean Never


{-| Any dtype: for lists that mix them, such as a graph's inputs.
-}
type Any
    = Any Never


type DType t
    = DType G.DType


f32 : DType F32
f32 =
    DType G.F32


u8 : DType U8
u8 =
    DType G.UI8


i64 : DType I64
i64 =
    DType G.SI64



-- EXPRESSIONS


type Tensor t
    = Tensor Expr


type Expr
    = Expr Key Op


type alias Key =
    ( Int, Int )


type Op
    = Input String G.DType (List Int)
    | Const Float
    | Cast G.DType Expr
    | Bin BinOp Expr Expr
    | Matmul Expr Expr
    | Unary UnaryOp Expr
    | Axis AxisOp Int Expr
    | Reshape (List Int) Expr
    | Column Expr
    | Transpose Expr
    | Range Int
      -- logits, one-hot target
    | Xent Expr Expr
      -- the gradient group's key, the loss, the parameters, which parameter
    | GradOf Key Expr (List Expr) Int


type BinOp
    = Add
    | Sub
    | Mul
    | Greater
    | Equal


type UnaryOp
    = Relu
    | Negate


type AxisOp
    = Softmax
    | LogSoftmax
    | Sum
    | ArgMax


expr : Op -> Expr
expr op =
    Expr (hash op) op


unwrap : Tensor t -> Expr
unwrap (Tensor e) =
    e



-- STRUCTURAL KEYS


{-| One step of two multiplicative hashes. The products stay below 2^53, so they are exact on
every Elm back end.
-}
mix : Int -> Key -> Key
mix x ( a, b ) =
    ( modBy 2147483647 (a * 1000003 + x), modBy 1000000007 (b * 131071 + x) )


mixString : String -> Key -> Key
mixString s k =
    String.foldl (\c acc -> mix (Char.toCode c) acc) (mix (String.length s) k) s


mixInts : List Int -> Key -> Key
mixInts l k =
    List.foldl mix (mix (List.length l) k) l


mixKey : Key -> Key -> Key
mixKey ( a, b ) k =
    mix b (mix a k)


mixExpr : Expr -> Key -> Key
mixExpr (Expr k _) =
    mixKey k


dtypeTag : G.DType -> Int
dtypeTag dt =
    case dt of
        G.F32 ->
            1

        G.UI8 ->
            2

        G.SI64 ->
            3

        G.Bool_ ->
            4


hash : Op -> Key
hash op =
    let
        start tag =
            mixString tag ( 17, 19 )
    in
    case op of
        Input name dt shape ->
            start "input" |> mixString name |> mix (dtypeTag dt) |> mixInts shape

        Const f ->
            start "const" |> mixString (String.fromFloat f)

        Cast dt a ->
            start "cast" |> mix (dtypeTag dt) |> mixExpr a

        Bin o a b ->
            start "bin" |> mix (binTag o) |> mixExpr a |> mixExpr b

        Matmul a b ->
            start "matmul" |> mixExpr a |> mixExpr b

        Unary o a ->
            start "unary" |> mix (unaryTag o) |> mixExpr a

        Axis o axis a ->
            start "axis" |> mix (axisTag o) |> mix axis |> mixExpr a

        Reshape shape a ->
            start "reshape" |> mixInts shape |> mixExpr a

        Column a ->
            start "column" |> mixExpr a

        Transpose a ->
            start "transpose" |> mixExpr a

        Range n ->
            start "range" |> mix n

        Xent logits target ->
            start "xent" |> mixExpr logits |> mixExpr target

        GradOf group _ _ i ->
            start "grad" |> mixKey group |> mix i


binTag : BinOp -> Int
binTag o =
    case o of
        Add ->
            1

        Sub ->
            2

        Mul ->
            3

        Greater ->
            4

        Equal ->
            5


unaryTag : UnaryOp -> Int
unaryTag o =
    case o of
        Relu ->
            1

        Negate ->
            2


axisTag : AxisOp -> Int
axisTag o =
    case o of
        Softmax ->
            1

        LogSoftmax ->
            2

        Sum ->
            3

        ArgMax ->
            4



-- BUILDING


{-| A named graph input. Pass it to `graph`'s input list.
-}
input : String -> DType t -> List Int -> Tensor t
input name (DType dt) shape =
    Tensor (expr (Input name dt shape))


{-| A scalar f32 constant; it broadcasts against any shape.
-}
constant : Float -> Tensor F32
constant f =
    Tensor (expr (Const f))


cast : DType b -> Tensor a -> Tensor b
cast (DType dt) (Tensor a) =
    Tensor (expr (Cast dt a))


toFloat : Tensor a -> Tensor F32
toFloat =
    cast f32


toInt : Tensor a -> Tensor I64
toInt =
    cast i64


{-| Forget the dtype, to put tensors of different dtypes in one list.
-}
any : Tensor a -> Tensor Any
any (Tensor e) =
    Tensor e


bin : BinOp -> Tensor a -> Tensor a -> Tensor b
bin o (Tensor a) (Tensor b) =
    Tensor (expr (Bin o a b))


{-| `x |> plus y` is x + y, with numpy broadcasting (so a bias adds to every row).
-}
plus : Tensor t -> Tensor t -> Tensor t
plus y x =
    bin Add x y


{-| `x |> minus y` is x - y.
-}
minus : Tensor t -> Tensor t -> Tensor t
minus y x =
    bin Sub x y


{-| `x |> times y` is the elementwise x * y.
-}
times : Tensor t -> Tensor t -> Tensor t
times y x =
    bin Mul x y


{-| `x |> scale k` is x * k.
-}
scale : Float -> Tensor F32 -> Tensor F32
scale k x =
    bin Mul x (constant k)


{-| `x |> matmul w` is x @ w.
-}
matmul : Tensor t -> Tensor t -> Tensor t
matmul w (Tensor x) =
    Tensor (expr (Matmul x (unwrap w)))


relu : Tensor t -> Tensor t
relu (Tensor x) =
    Tensor (expr (Unary Relu x))


negate : Tensor t -> Tensor t
negate (Tensor x) =
    Tensor (expr (Unary Negate x))


{-| `x |> greaterThan y` is x > y, elementwise.
-}
greaterThan : Tensor t -> Tensor t -> Tensor Boolean
greaterThan y x =
    bin Greater x y


{-| `x |> equals y` is x == y, elementwise.
-}
equals : Tensor t -> Tensor t -> Tensor Boolean
equals y x =
    bin Equal x y


axisOp : AxisOp -> Int -> Tensor a -> Tensor b
axisOp o axis (Tensor x) =
    Tensor (expr (Axis o axis x))


softmax : Int -> Tensor F32 -> Tensor F32
softmax =
    axisOp Softmax


logSoftmax : Int -> Tensor F32 -> Tensor F32
logSoftmax =
    axisOp LogSoftmax


{-| Sums along `axis`, keeping it as a dimension of size 1, as MAX does.
-}
sum : Int -> Tensor t -> Tensor t
sum =
    axisOp Sum


{-| The index of the largest element along `axis` (kept, with size 1).
-}
argMax : Int -> Tensor t -> Tensor I64
argMax =
    axisOp ArgMax


reshape : List Int -> Tensor t -> Tensor t
reshape shape (Tensor x) =
    Tensor (expr (Reshape shape x))


{-| A vector of n elements as an n × 1 matrix.
-}
column : Tensor t -> Tensor t
column (Tensor x) =
    Tensor (expr (Column x))


{-| The transpose of a matrix.
-}
transpose : Tensor t -> Tensor t
transpose (Tensor x) =
    Tensor (expr (Transpose x))


{-| 0, 1 .. n-1.
-}
range : Int -> Tensor I64
range n =
    Tensor (expr (Range n))


{-| Class labels (0 .. classes-1, any integer dtype) as one-hot f32 rows.
-}
oneHot : Int -> Tensor a -> Tensor F32
oneHot classes labels =
    labels |> toInt |> column |> equals (range classes) |> toFloat


{-| `logits |> crossEntropy target`: the mean softmax cross-entropy of `logits` [batch, classes]
against one-hot rows `target`, as a [1, 1] tensor.
-}
crossEntropy : Tensor F32 -> Tensor F32 -> Tensor F32
crossEntropy (Tensor target) (Tensor logits) =
    Tensor (expr (Xent logits target))


{-| The gradients of the [1, 1] `loss` with respect to each of `wrt`, by reverse-mode autodiff
(`Graph.grad`, run once for the whole list when the graph is lowered).
-}
grad : Tensor F32 -> List (Tensor F32) -> List (Tensor F32)
grad (Tensor loss) wrt =
    let
        params =
            List.map unwrap wrt

        group =
            List.foldl mixExpr (mixExpr loss (mixString "grads" ( 23, 29 ))) params
    in
    List.indexedMap (\i _ -> Tensor (expr (GradOf group loss params i))) params



-- GRAPHS


{-| What the host needs to know about one input or output.
-}
type alias Spec =
    { name : String, dtype : G.DType, shape : List Int }


{-| A graph lowered onto a `Graph` tape and checked, with its named inputs and outputs.
-}
type alias Graph =
    { name : String
    , inputs : List ( String, G.Ref )
    , outputs : List ( String, G.Ref )
    , graph : G.Graph
    , inputSpecs : List Spec
    , outputSpecs : List Spec
    }


type alias State =
    { tape : G.Graph
    , refs : Dict Key G.Ref
    , grads : Dict Key (List G.Ref)
    , inputs : Dict String Key
    }


{-| The graph `name` computing `outputs` from `inputs`, in the order given (the host passes
buffers by position). Refused, with every error, if a shape is wrong, an input the outputs use is
not listed, a listed tensor is not an input, or two inputs share a name.

Tensors lower in post-order (operands left to right), the inputs first, then the outputs in order.
-}
graph : String -> List (Tensor Any) -> List ( String, Tensor a ) -> Result (List String) Graph
graph name inputs outputs =
    let
        st0 =
            { tape = G.empty, refs = Dict.empty, grads = Dict.empty, inputs = Dict.empty }

        inputName (Tensor (Expr _ op)) =
            case op of
                Input n _ _ ->
                    Just n

                _ ->
                    Nothing

        notInputs =
            List.indexedMap
                (\i t ->
                    if inputName t == Nothing then
                        [ name ++ ": input " ++ String.fromInt (i + 1) ++ " is not made by Tensor.input" ]

                    else
                        []
                )
                inputs
                |> List.concat

        listedNames =
            List.filterMap inputName inputs

        repeated =
            listedNames
                |> List.filter (\n -> List.length (List.filter ((==) n) listedNames) > 1)
                |> List.foldr
                    (\n acc ->
                        if List.member n acc then
                            acc

                        else
                            n :: acc
                    )
                    []
                |> List.map (\n -> name ++ ": input " ++ n ++ " is listed twice")

        ( st1, inRefs ) =
            lowerAll (List.map unwrap inputs) st0

        ( st2, outRefs ) =
            lowerAll (List.map (Tuple.second >> unwrap) outputs) st1

        unlisted =
            Dict.keys st2.inputs
                |> List.filter (\n -> not (List.member n listedNames))
                |> List.map (\n -> name ++ ": the outputs use input " ++ n ++ ", which is not in the input list")

        problems =
            notInputs ++ repeated ++ unlisted ++ List.map (\e -> name ++ ": " ++ e) (List.reverse st2.tape.errors)

        spec n r =
            { name = n, dtype = G.dtypeOf st2.tape r, shape = G.shapeOf st2.tape r }

        namedInputs =
            List.map2 Tuple.pair listedNames inRefs

        namedOutputs =
            List.map2 Tuple.pair (List.map Tuple.first outputs) outRefs
    in
    if List.isEmpty problems then
        Ok
            { name = name
            , inputs = namedInputs
            , outputs = namedOutputs
            , graph = st2.tape
            , inputSpecs = List.map (\( n, r ) -> spec n r) namedInputs
            , outputSpecs = List.map (\( n, r ) -> spec n r) namedOutputs
            }

    else
        Err problems


lowerAll : List Expr -> State -> ( State, List G.Ref )
lowerAll es st0 =
    List.foldl
        (\e ( st, acc ) ->
            let
                ( st1, r ) =
                    lower e st
            in
            ( st1, r :: acc )
        )
        ( st0, [] )
        es
        |> Tuple.mapSecond List.reverse


lower : Expr -> State -> ( State, G.Ref )
lower (Expr key op) st =
    case Dict.get key st.refs of
        Just r ->
            ( st, r )

        Nothing ->
            let
                ( st1, r ) =
                    lowerOp key op st
            in
            ( { st1 | refs = Dict.insert key r st1.refs }, r )


onTape : (G.Graph -> ( G.Graph, G.Ref )) -> State -> ( State, G.Ref )
onTape f st =
    let
        ( tape, r ) =
            f st.tape
    in
    ( { st | tape = tape }, r )


unary : Expr -> (G.Ref -> G.Graph -> ( G.Graph, G.Ref )) -> State -> ( State, G.Ref )
unary a f st =
    let
        ( st1, ra ) =
            lower a st
    in
    onTape (f ra) st1


binary : Expr -> Expr -> (G.Ref -> G.Ref -> G.Graph -> ( G.Graph, G.Ref )) -> State -> ( State, G.Ref )
binary a b f st =
    let
        ( st1, ra ) =
            lower a st

        ( st2, rb ) =
            lower b st1
    in
    onTape (f ra rb) st2


lowerOp : Key -> Op -> State -> ( State, G.Ref )
lowerOp key op st =
    case op of
        Input name dt shape ->
            let
                st1 =
                    if Dict.member name st.inputs then
                        { st | tape = addError ("two different inputs are named " ++ name) st.tape }

                    else
                        { st | inputs = Dict.insert name key st.inputs }
            in
            onTape (G.input name dt shape) st1

        Const f ->
            onTape (G.constF f) st

        Cast dt a ->
            unary a (G.cast dt) st

        Bin o a b ->
            binary a b
                (case o of
                    Add ->
                        G.add

                    Sub ->
                        G.sub

                    Mul ->
                        G.mul

                    Greater ->
                        G.greater

                    Equal ->
                        G.equal
                )
                st

        Matmul a b ->
            binary a b G.matmul st

        Unary o a ->
            unary a
                (case o of
                    Relu ->
                        G.relu

                    Negate ->
                        G.negative
                )
                st

        Axis o axis a ->
            unary a
                ((case o of
                    Softmax ->
                        G.softmax

                    LogSoftmax ->
                        G.logSoftmax

                    Sum ->
                        G.reduceAdd

                    ArgMax ->
                        G.argMax
                 )
                    axis
                )
                st

        Reshape shape a ->
            unary a (G.reshape shape) st

        Column a ->
            unary a (\r g -> G.reshape [ List.product (G.shapeOf g r), 1 ] r g) st

        Transpose a ->
            unary a G.transpose st

        Range n ->
            onTape (G.range n) st

        Xent logits target ->
            binary logits target G.softmaxXentLoss st

        GradOf group loss params i ->
            let
                pick rs =
                    Maybe.withDefault -1 (List.head (List.drop i rs))
            in
            case Dict.get group st.grads of
                Just rs ->
                    ( st, pick rs )

                Nothing ->
                    let
                        ( st1, lossRef ) =
                            lower loss st

                        ( st2, paramRefs ) =
                            lowerAll params st1

                        ( tape, rs ) =
                            G.grad lossRef paramRefs st2.tape
                    in
                    ( { st2 | tape = tape, grads = Dict.insert group rs st2.grads }, pick rs )


addError : String -> G.Graph -> G.Graph
addError msg g =
    { g | errors = msg :: g.errors }
