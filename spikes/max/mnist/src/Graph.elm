module Graph exposing
    ( DType(..), Graph, Ref, Shape
    , empty, input, constF, cast, add, sub, mul, matmul, relu, greater, equal, softmax, logSoftmax
    , reduceAdd, argMax, reshape, transpose, range, softmaxXentLoss
    , shapeOf, grad, print, toModule, byteSize
    )

{-| A tensor compute graph built in Elm, checked as it is built, differentiated in Elm, and printed
as MAX `mo` text.

A graph is a tape: each node is appended with its dtype and shape already inferred, so a mistake
(mismatched shapes, wrong dtypes) is recorded at the node that made it and `print` refuses the
graph. MAX must never see text that fails to verify: its C API crashes on it.

`toModule` gives the same graph as generic MLIR ops (`MlirBc`), for MLIR bytecode or generic text.

Builders take the graph last and return it first, so they chain with `|>`-free let blocks:

    ( g1, h ) = matmul x w g0

-}

import Array exposing (Array)
import Dict exposing (Dict)
import MlirBc
import Set exposing (Set)


type DType
    = F32
    | UI8
    | SI64
    | Bool_


type alias Shape =
    List Int


type alias Ref =
    Int


type Op
    = Input String
    | ConstF Float
    | Cast Ref
    | Bin String Ref Ref
    | Matmul Ref Ref
    | Unary String Ref
    | Axis String Int Ref
    | Reshape Ref
    | Transpose Ref
    | Range Int
      -- The value of `loss`, with the gradient rule of mean softmax cross-entropy over `logits`.
    | XentLoss { loss : Ref, logits : Ref, onehot : Ref }


type alias Node =
    { op : Op, dtype : DType, shape : Shape }


type alias Graph =
    { nodes : Array Node, errors : List String }


empty : Graph
empty =
    { nodes = Array.empty, errors = [] }


node : Graph -> Ref -> Node
node g r =
    Maybe.withDefault { op = ConstF 0, dtype = F32, shape = [] } (Array.get r g.nodes)


shapeOf : Graph -> Ref -> Shape
shapeOf g r =
    (node g r).shape


push : Op -> DType -> Shape -> Graph -> ( Graph, Ref )
push op dt sh g =
    ( { g | nodes = Array.push { op = op, dtype = dt, shape = sh } g.nodes }, Array.length g.nodes )


fail : String -> Op -> DType -> Shape -> Graph -> ( Graph, Ref )
fail msg op dt sh g =
    push op dt sh { g | errors = ("node " ++ String.fromInt (Array.length g.nodes) ++ ": " ++ msg) :: g.errors }



-- BUILDERS


input : String -> DType -> Shape -> Graph -> ( Graph, Ref )
input name dt sh =
    push (Input name) dt sh


constF : Float -> Graph -> ( Graph, Ref )
constF f =
    push (ConstF f) F32 []


cast : DType -> Ref -> Graph -> ( Graph, Ref )
cast dt a g =
    push (Cast a) dt (shapeOf g a) g


{-| Numpy broadcasting: dims align from the right; each pair must be equal or contain a 1.
-}
broadcast : Shape -> Shape -> Maybe Shape
broadcast a b =
    let
        n =
            max (List.length a) (List.length b)

        pad s =
            List.repeat (n - List.length s) 1 ++ s

        dim x y =
            if x == y || y == 1 then
                Just x

            else if x == 1 then
                Just y

            else
                Nothing
    in
    List.map2 dim (pad a) (pad b)
        |> List.foldr (Maybe.map2 (::)) (Just [])


bin : String -> Bool -> Ref -> Ref -> Graph -> ( Graph, Ref )
bin name compare a b g =
    let
        na =
            node g a

        nb =
            node g b

        out =
            if compare then
                Bool_

            else
                na.dtype
    in
    if na.dtype /= nb.dtype then
        fail (name ++ ": dtypes differ") (Bin name a b) out na.shape g

    else
        case broadcast na.shape nb.shape of
            Just sh ->
                push (Bin name a b) out sh g

            Nothing ->
                fail (name ++ ": shapes do not broadcast") (Bin name a b) out na.shape g


add : Ref -> Ref -> Graph -> ( Graph, Ref )
add =
    bin "add" False


sub : Ref -> Ref -> Graph -> ( Graph, Ref )
sub =
    bin "sub" False


mul : Ref -> Ref -> Graph -> ( Graph, Ref )
mul =
    bin "mul" False


greater : Ref -> Ref -> Graph -> ( Graph, Ref )
greater =
    bin "greater" True


equal : Ref -> Ref -> Graph -> ( Graph, Ref )
equal =
    bin "equal" True


matmul : Ref -> Ref -> Graph -> ( Graph, Ref )
matmul a b g =
    case ( shapeOf g a, shapeOf g b ) of
        ( [ m, k ], [ k2, n ] ) ->
            if k == k2 && (node g a).dtype == (node g b).dtype then
                push (Matmul a b) (node g a).dtype [ m, n ] g

            else
                fail "matmul: inner dims or dtypes differ" (Matmul a b) F32 [ m, n ] g

        _ ->
            fail "matmul: needs two rank-2 operands" (Matmul a b) F32 [] g


relu : Ref -> Graph -> ( Graph, Ref )
relu a g =
    push (Unary "relu" a) (node g a).dtype (shapeOf g a) g


negative : Ref -> Graph -> ( Graph, Ref )
negative a g =
    push (Unary "negative" a) (node g a).dtype (shapeOf g a) g


checkAxis : String -> Int -> Ref -> Graph -> Maybe String
checkAxis name axis a g =
    if axis < 0 || axis >= List.length (shapeOf g a) then
        Just (name ++ ": axis out of range")

    else
        Nothing


axisOp : String -> DType -> Bool -> Int -> Ref -> Graph -> ( Graph, Ref )
axisOp name dt keepsShape axis a g =
    let
        sh =
            if keepsShape then
                shapeOf g a

            else
                List.indexedMap
                    (\i d ->
                        if i == axis then
                            1

                        else
                            d
                    )
                    (shapeOf g a)
    in
    case checkAxis name axis a g of
        Just msg ->
            fail msg (Axis name axis a) dt sh g

        Nothing ->
            push (Axis name axis a) dt sh g


softmax : Int -> Ref -> Graph -> ( Graph, Ref )
softmax axis a g =
    axisOp "softmax" (node g a).dtype True axis a g


logSoftmax : Int -> Ref -> Graph -> ( Graph, Ref )
logSoftmax axis a g =
    axisOp "logsoftmax" (node g a).dtype True axis a g


{-| Sums over `axis`, keeping it as a dimension of size 1, as MAX does.
-}
reduceAdd : Int -> Ref -> Graph -> ( Graph, Ref )
reduceAdd axis a g =
    axisOp "add" (node g a).dtype False axis a g


argMax : Int -> Ref -> Graph -> ( Graph, Ref )
argMax axis a g =
    axisOp "arg_max" SI64 False axis a g


reshape : Shape -> Ref -> Graph -> ( Graph, Ref )
reshape sh a g =
    if List.product sh == List.product (shapeOf g a) then
        push (Reshape a) (node g a).dtype sh g

    else
        fail "reshape: element counts differ" (Reshape a) (node g a).dtype sh g


transpose : Ref -> Graph -> ( Graph, Ref )
transpose a g =
    case shapeOf g a of
        [ m, n ] ->
            push (Transpose a) (node g a).dtype [ n, m ] g

        _ ->
            fail "transpose: needs a rank-2 operand" (Transpose a) (node g a).dtype [] g


{-| 0, 1 .. n-1 as si64.
-}
range : Int -> Graph -> ( Graph, Ref )
range n =
    push (Range n) SI64 [ n ]


{-| Mean softmax cross-entropy of `logits` [batch, classes] against one-hot `onehot`, as a [1, 1]
tensor. Built from primitives, but differentiated by its own rule: (softmax logits - onehot) / batch.
-}
softmaxXentLoss : Ref -> Ref -> Graph -> ( Graph, Ref )
softmaxXentLoss logits onehot g0 =
    let
        batch =
            Maybe.withDefault 1 (List.head (shapeOf g0 logits))

        ( g1, lsm ) =
            logSoftmax 1 logits g0

        ( g2, picked ) =
            mul onehot lsm g1

        ( g3, rows ) =
            reduceAdd 1 picked g2

        ( g4, total ) =
            reduceAdd 0 rows g3

        ( g5, neg ) =
            negative total g4

        ( g6, scale ) =
            constF (1 / toFloat batch) g5

        ( g7, loss ) =
            mul neg scale g6
    in
    push (XentLoss { loss = loss, logits = logits, onehot = onehot }) F32 (shapeOf g7 loss) g7



-- AUTODIFF


operands : Op -> List Ref
operands op =
    case op of
        Cast a ->
            [ a ]

        Bin _ a b ->
            [ a, b ]

        Matmul a b ->
            [ a, b ]

        Unary _ a ->
            [ a ]

        Axis _ _ a ->
            [ a ]

        Reshape a ->
            [ a ]

        Transpose a ->
            [ a ]

        XentLoss x ->
            [ x.logits ]

        _ ->
            []


{-| Sums `gr` down to `target`'s shape: the adjoint of numpy broadcasting.
-}
unbroadcast : Shape -> Ref -> Graph -> ( Graph, Ref )
unbroadcast target gr g0 =
    let
        gs =
            shapeOf g0 gr

        lead =
            List.length gs - List.length target

        aligned =
            List.repeat lead 1 ++ target

        step ( i, ( gd, td ) ) ( g, r ) =
            if td == 1 && gd /= 1 then
                reduceAdd i r g

            else
                ( g, r )

        ( g1, summed ) =
            List.foldl step ( g0, gr ) (List.indexedMap Tuple.pair (List.map2 Tuple.pair gs aligned))
    in
    if shapeOf g1 summed == target then
        ( g1, summed )

    else
        reshape target summed g1


{-| Reverse-mode gradients of the scalar `loss` with respect to each of `wrt`, appended to the graph.
Only nodes that depend on `wrt` get adjoints, so inputs and constants cost nothing.
-}
grad : Ref -> List Ref -> Graph -> ( Graph, List Ref )
grad loss wrt g0 =
    let
        count =
            Array.length g0.nodes

        needs =
            List.foldl
                (\r acc ->
                    if Set.member r acc || List.any (\o -> Set.member o acc) (operands (node g0 r).op) then
                        Set.insert r acc

                    else
                        acc
                )
                (Set.fromList wrt)
                (List.range 0 (count - 1))

        accumulate target contribution ( g, adj ) =
            case Dict.get target adj of
                Nothing ->
                    ( g, Dict.insert target contribution adj )

                Just prev ->
                    let
                        ( g2, s ) =
                            add prev contribution g
                    in
                    ( g2, Dict.insert target s adj )

        -- Builds `target`'s share of the adjoint only if `target` leads to a parameter.
        contribute target compute ( g, adj ) =
            if Set.member target needs then
                let
                    ( g2, c ) =
                        compute g
                in
                accumulate target c ( g2, adj )

            else
                ( g, adj )

        rule r ( g, adj ) =
            case Dict.get r adj of
                Nothing ->
                    ( g, adj )

                Just gr ->
                    case (node g0 r).op of
                        Bin "add" a b ->
                            ( g, adj )
                                |> contribute a (unbroadcast (shapeOf g0 a) gr)
                                |> contribute b (unbroadcast (shapeOf g0 b) gr)

                        Bin "sub" a b ->
                            ( g, adj )
                                |> contribute a (unbroadcast (shapeOf g0 a) gr)
                                |> contribute b
                                    (\h ->
                                        let
                                            ( h1, ng ) =
                                                negative gr h
                                        in
                                        unbroadcast (shapeOf g0 b) ng h1
                                    )

                        Bin "mul" a b ->
                            ( g, adj )
                                |> contribute a
                                    (\h ->
                                        let
                                            ( h1, p ) =
                                                mul gr b h
                                        in
                                        unbroadcast (shapeOf g0 a) p h1
                                    )
                                |> contribute b
                                    (\h ->
                                        let
                                            ( h1, p ) =
                                                mul gr a h
                                        in
                                        unbroadcast (shapeOf g0 b) p h1
                                    )

                        Matmul a b ->
                            ( g, adj )
                                |> contribute a
                                    (\h ->
                                        let
                                            ( h1, bt ) =
                                                transpose b h
                                        in
                                        matmul gr bt h1
                                    )
                                |> contribute b
                                    (\h ->
                                        let
                                            ( h1, at ) =
                                                transpose a h
                                        in
                                        matmul at gr h1
                                    )

                        Unary "negative" a ->
                            contribute a (negative gr) ( g, adj )

                        Unary "relu" a ->
                            contribute a
                                (\h ->
                                    let
                                        ( h1, zero ) =
                                            constF 0 h

                                        ( h2, pos ) =
                                            greater a zero h1

                                        ( h3, mask ) =
                                            cast F32 pos h2
                                    in
                                    mul gr mask h3
                                )
                                ( g, adj )

                        Reshape a ->
                            contribute a (reshape (shapeOf g0 a) gr) ( g, adj )

                        XentLoss x ->
                            -- The seed adjoint of a [1, 1] loss is 1, so `gr` is not multiplied in.
                            contribute x.logits
                                (\h ->
                                    let
                                        batch =
                                            Maybe.withDefault 1 (List.head (shapeOf g0 x.logits))

                                        ( h1, sm ) =
                                            softmax 1 x.logits h

                                        ( h2, diff ) =
                                            sub sm x.onehot h1

                                        ( h3, scale ) =
                                            constF (1 / toFloat batch) h2
                                    in
                                    mul diff scale h3
                                )
                                ( g, adj )

                        Input _ ->
                            -- A leaf: its adjoint is the gradient `grad` returns.
                            ( g, adj )

                        _ ->
                            ( { g | errors = ("grad: no rule for node " ++ String.fromInt r) :: g.errors }, adj )

        -- The seed: the loss node's own ref stands for an adjoint of ones (only XentLoss reads it).
        ( gEnd, adjEnd ) =
            List.foldl rule ( g0, Dict.singleton loss loss ) (List.reverse (List.range 0 (count - 1)))

        missing r ( g, acc ) =
            case Dict.get r adjEnd of
                Just gr ->
                    ( g, gr :: acc )

                Nothing ->
                    ( { g | errors = ("grad: parameter " ++ String.fromInt r ++ " does not reach the loss") :: g.errors }, r :: acc )

        ( gFinal, grads ) =
            List.foldr missing ( gEnd, [] ) wrt
    in
    ( gFinal, grads )



-- PRINTING


dtypeName : DType -> String
dtypeName dt =
    case dt of
        F32 ->
            "f32"

        UI8 ->
            "ui8"

        SI64 ->
            "si64"

        Bool_ ->
            "bool"


byteSize : DType -> Int
byteSize dt =
    case dt of
        F32 ->
            4

        UI8 ->
            1

        SI64 ->
            8

        Bool_ ->
            1


ints : List Int -> String
ints l =
    String.join ", " (List.map String.fromInt l)


tensorType : Node -> String
tensorType n =
    "!mo.tensor<[" ++ ints n.shape ++ "], " ++ dtypeName n.dtype ++ ">"


{-| An MLIR float literal: it needs a `.` before any exponent.
-}
floatLit : Float -> String
floatLit f =
    let
        s =
            String.fromFloat f
    in
    if String.contains "." s then
        s

    else if String.contains "e" s then
        String.replace "e" ".0e" s

    else
        s ++ ".0"


{-| `nodes` print in tape order; XentLoss prints nothing and names its loss node instead.
-}
print : String -> List ( String, Ref ) -> List ( String, Ref ) -> Graph -> Result (List String) String
print graphName inputs outputs g =
    if not (List.isEmpty g.errors) then
        Err (List.reverse g.errors)

    else
        let
            name r =
                case (node g r).op of
                    Input n ->
                        "%" ++ n

                    XentLoss x ->
                        name x.loss

                    _ ->
                        "%v" ++ String.fromInt r

            ty r =
                tensorType (node g r)

            sig rs =
                "(" ++ String.join ", " (List.map ty rs) ++ ")"

            line r n =
                let
                    v =
                        "  %v" ++ String.fromInt r ++ " = "

                    out =
                        tensorType n

                    simple opName rs =
                        v ++ opName ++ "(" ++ String.join ", " (List.map name rs) ++ ") : " ++ sig rs ++ " -> " ++ out
                in
                case n.op of
                    Input _ ->
                        []

                    XentLoss _ ->
                        []

                    ConstF f ->
                        [ v ++ "mo.constant <#M.dense_array<" ++ floatLit f ++ "> : tensor<f32>> : " ++ out ]

                    Cast a ->
                        [ simple "mo.cast" [ a ] ]

                    Bin opName a b ->
                        [ simple ("rmo." ++ opName) [ a, b ] ]

                    Matmul a b ->
                        [ simple "rmo.matmul" [ a, b ] ]

                    Unary opName a ->
                        [ simple ("rmo.mo." ++ opName) [ a ] ]

                    Axis opName axis a ->
                        [ v ++ "rmo.mo.reduce." ++ opName ++ "(" ++ name a ++ ") [axis = " ++ String.fromInt axis ++ "] : " ++ sig [ a ] ++ " -> " ++ out ]

                    Reshape a ->
                        [ v ++ "rmo.reshape(" ++ name a ++ ") [newShape = #mosh<ape[" ++ ints n.shape ++ "]> : !mosh.ape] : " ++ sig [ a ] ++ " -> " ++ out ]

                    Transpose a ->
                        let
                            p =
                                "%p" ++ String.fromInt r
                        in
                        [ "  " ++ p ++ " = mo.constant <#M.dense_array<1, 0> : tensor<2xsi64>> : !mo.tensor<[2], si64>"
                        , v ++ "rmo.mo.transpose(" ++ name a ++ ", " ++ p ++ ") : (" ++ ty a ++ ", !mo.tensor<[2], si64>) -> " ++ out
                        ]

                    Range count ->
                        let
                            c k x =
                                "  %r" ++ String.fromInt r ++ k ++ " = mo.constant <#M.dense_array<" ++ String.fromInt x ++ "> : tensor<si64>> : !mo.tensor<[], si64>"

                            s =
                                "%r" ++ String.fromInt r
                        in
                        [ c "a" 0
                        , c "b" count
                        , c "c" 1
                        , v ++ "rmo.mo.range(" ++ s ++ "a, " ++ s ++ "b, " ++ s ++ "c) : (!mo.tensor<[], si64>, !mo.tensor<[], si64>, !mo.tensor<[], si64>) -> " ++ out
                        ]

            body =
                List.concat (List.indexedMap line (Array.toList g.nodes))

            quoted l =
                "[" ++ String.join ", " (List.map (\( n, _ ) -> "\"" ++ n ++ "\"") l) ++ "]"

            outRefs =
                List.map Tuple.second outputs
        in
        Ok
            (String.join "\n"
                ([ "mo.graph @"
                    ++ graphName
                    ++ "("
                    ++ String.join ", " (List.map (\( n, r ) -> "%" ++ n ++ ": " ++ ty r) inputs)
                    ++ ") -> "
                    ++ sig outRefs
                    ++ " attributes {argument_names = "
                    ++ quoted inputs
                    ++ ", result_names = "
                    ++ quoted outputs
                    ++ "} {"
                 ]
                    ++ body
                    ++ [ "  mo.output " ++ String.join ", " (List.map name outRefs) ++ " : " ++ String.join ", " (List.map ty outRefs)
                       , "}"
                       , ""
                       ]
                )
            )



-- GENERIC OPS


{-| The graph as one generic `mo.graph` op, with the inherent attributes MAX's parser would derive
from the custom syntax `print` writes: `functionType`, `signature` (the same function type as a
`kgen` generator; no parameters, since every shape is static), the parameter lists, and the names.
Value numbers: the graph's arguments, then each op's one result, in tape order.
-}
toModule : String -> List ( String, Ref ) -> List ( String, Ref ) -> Graph -> Result (List String) MlirBc.Op
toModule graphName inputs outputs g =
    if not (List.isEmpty g.errors) then
        Err (List.reverse g.errors)

    else
        let
            ty r =
                MlirBc.OpaqueType (tensorType (node g r))

            scalarSi64 =
                MlirBc.OpaqueType "!mo.tensor<[], si64>"

            constant text t =
                { name = "mo.constant", attrs = [ ( "value", MlirBc.OpaqueAttr text ) ], results = [ t ], operands = [], regions = [] }

            simple opName attrs args t =
                { name = opName, attrs = attrs, results = [ t ], operands = args, regions = [] }

            -- Fold state: ops so far (reversed), the next value number, and each node's value.
            step r n st =
                let
                    v a =
                        Maybe.withDefault -1 (Dict.get a st.values)

                    out =
                        MlirBc.OpaqueType (tensorType n)

                    emit ops =
                        { ops = List.reverse ops ++ st.ops
                        , next = st.next + List.length ops
                        , values = Dict.insert r (st.next + List.length ops - 1) st.values
                        }

                    k =
                        st.next
                in
                case n.op of
                    Input _ ->
                        st

                    XentLoss x ->
                        { st | values = Dict.insert r (v x.loss) st.values }

                    ConstF f ->
                        emit [ constant ("#M.dense_array<" ++ floatLit f ++ "> : tensor<f32>") out ]

                    Cast a ->
                        emit [ simple "mo.cast" [] [ v a ] out ]

                    Bin opName a b ->
                        emit [ simple ("rmo." ++ opName) [] [ v a, v b ] out ]

                    Matmul a b ->
                        emit [ simple "rmo.matmul" [] [ v a, v b ] out ]

                    Unary opName a ->
                        emit [ simple ("rmo.mo." ++ opName) [] [ v a ] out ]

                    Axis opName axis a ->
                        emit [ simple ("rmo.mo.reduce." ++ opName) [ ( "axis", MlirBc.IntAttr axis MlirBc.IndexType ) ] [ v a ] out ]

                    Reshape a ->
                        emit [ simple "rmo.reshape" [ ( "newShape", MlirBc.OpaqueAttr ("#mosh<ape[" ++ ints n.shape ++ "]> : !mosh.ape") ) ] [ v a ] out ]

                    Transpose a ->
                        emit
                            [ constant "#M.dense_array<1, 0> : tensor<2xsi64>" (MlirBc.OpaqueType "!mo.tensor<[2], si64>")
                            , simple "rmo.mo.transpose" [] [ v a, k ] out
                            ]

                    Range count ->
                        let
                            c x =
                                constant ("#M.dense_array<" ++ String.fromInt x ++ "> : tensor<si64>") scalarSi64
                        in
                        emit [ c 0, c count, c 1, simple "rmo.mo.range" [] [ k, k + 1, k + 2 ] out ]

            start =
                { ops = []
                , next = List.length inputs
                , values = Dict.fromList (List.indexedMap (\i ( _, r ) -> ( r, i )) inputs)
                }

            final =
                List.foldl (\( r, n ) st -> step r n st) start (List.indexedMap Tuple.pair (Array.toList g.nodes))

            outRefs =
                List.map Tuple.second outputs

            fnType =
                MlirBc.FunctionType (List.map (Tuple.second >> ty) inputs) (List.map ty outRefs)

            names l =
                MlirBc.ArrayAttr (List.map (Tuple.first >> MlirBc.StrAttr) l)

            output =
                { name = "mo.output"
                , attrs = []
                , results = []
                , operands = List.map (\r -> Maybe.withDefault -1 (Dict.get r final.values)) outRefs
                , regions = []
                }
        in
        Ok
            { name = "mo.graph"
            , attrs =
                [ ( "sym_name", MlirBc.StrAttr graphName )
                , ( "functionType", MlirBc.TypeAttr fnType )
                , ( "signature", MlirBc.TypeAttr (MlirBc.OpaqueType ("!kgen.generator<" ++ MlirBc.typeText fnType ++ ">")) )
                , ( "inputParameters", MlirBc.OpaqueAttr "#kgen<param.decls[]>" )
                , ( "resultParameters", MlirBc.OpaqueAttr "#kgen<param.decls[]>" )
                , ( "argument_names", names inputs )
                , ( "result_names", names outputs )
                ]
            , results = []
            , operands = []
            , regions = [ MlirBc.Region (List.map (Tuple.second >> ty) inputs) (List.reverse (output :: final.ops)) ]
            }
