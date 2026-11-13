module Tensor.Internal.Eval exposing (Ctx, Program, V(..), compile, execute)

{-| The evaluator's engine: expressions compiled once into programs, then run any number of times.

A program is its instructions in evaluation order (a post-order of its roots). Each instruction's
result goes in the next slot of its frame, and each operand is read by position: a slot of this
frame or of an enclosing one. Nothing is looked up by key when a program runs.

A traced body's nodes have the same keys every time it is evaluated (a `Var`'s key is made from its
scope and position only), so a body cannot share its parent's slots. As lowering does, every body (a
`Call`, each branch of an `If`, the test and step of a `While`) is compiled to its own program, run
in a fresh frame whose first slots are its arguments. A body may read outer expressions: from the
enclosing frame when the enclosing program has computed them before the instruction that runs the
body, and otherwise by computing them itself.

Errors found while compiling (a function argument read outside its function) become instructions
that fail when they run, so a branch never taken is not an error.

-}

import Array exposing (Array)
import Dict exposing (Dict)
import Set exposing (Set)
import Tensor.Internal.Eval.Core as C exposing (T)
import Tensor.Internal.Eval.Prim as EvalPrim
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Key exposing (Key)
import Tensor.Internal.Prim exposing (Params, Prim)
import Tensor.Internal.Shape exposing (Meta)


{-| One result, or the results of a `Call`, `If` or `While`.
-}
type V
    = One T
    | Many (List T)


{-| The graph's inputs by position, and the `While` guard.
-}
type alias Ctx =
    { inputs : Array T, maxIterations : Int }


{-| An operand: how many frames out, and the slot there.
-}
type Ref
    = Ref Int Int


type Instr
    = IInput Int
    | IConst T
    | IArg Ref
    | IPrim Prim (List Ref) Params Meta
    | ICall Program (List Ref)
    | IIf Ref Program Program (List Ref)
    | IWhile Program Program (List Ref)
    | IProj Ref Int
    | IFail String


{-| A compiled body or graph: its instructions, and where its outputs are. Its arguments are the
first slots of its frame; instruction i writes slot `arity + i`.
-}
type Program
    = Program { arity : Int, code : List Instr, outputs : List Ref }



-- COMPILING


{-| What a body being compiled can see of one enclosing (or its own) frame: the function whose
arguments the frame holds, and the slot of every expression computed so far.
-}
type alias Level =
    { scope : Maybe Key, arity : Int, slots : Dict Key Int }


{-| The program computing `roots` with no arguments, at top level.
-}
compile : List Expr -> Program
compile roots =
    compileBody [] { scope = Nothing, arity = 0, slots = Dict.empty } roots


compileBody : List Level -> Level -> List Expr -> Program
compileBody outer start roots =
    let
        order =
            postorderPruned (\k -> List.any (\l -> Dict.member k l.slots) outer) roots

        instr level e =
            let
                frames =
                    level :: outer
            in
            case E.op e of
                E.Input _ i ->
                    IInput i

                E.Var scope i ->
                    case varRef frames scope i of
                        Just r ->
                            IArg r

                        Nothing ->
                            IFail "internal: a function argument read outside its function"

                E.Const vs ->
                    IConst (C.fromValues (E.dtype e) (E.shape e) vs)

                E.P p args params ->
                    withRefs frames args (\rs -> IPrim p rs params (E.meta e))

                E.Proj src i ->
                    withRefs frames [ src ] (\rs -> List.head rs |> Maybe.map (\r -> IProj r i) |> Maybe.withDefault (IFail "internal"))

                E.Call _ b args ->
                    withRefs frames args (\rs -> ICall (compileFn frames b) rs)

                E.If pred t f args ->
                    withRefs frames
                        (pred :: args)
                        (\rs ->
                            case rs of
                                p :: rest ->
                                    IIf p (compileFn frames t) (compileFn frames f) rest

                                [] ->
                                    IFail "internal"
                        )

                E.While c b init ->
                    withRefs frames init (\rs -> IWhile (compileFn frames c) (compileFn frames b) rs)

        ( final, code ) =
            List.foldl
                (\e ( level, acc ) ->
                    ( { level | slots = Dict.insert (E.key e) (level.arity + List.length acc) level.slots }
                    , instr level e :: acc
                    )
                )
                ( start, [] )
                order
    in
    Program
        { arity = start.arity
        , code = List.reverse code
        , outputs = List.map (\r -> refOf (final :: outer) (E.key r) |> Maybe.withDefault (Ref -1 -1)) roots
        }


compileFn : List Level -> E.Body -> Program
compileFn frames b =
    compileBody frames { scope = Just b.scope, arity = b.arity, slots = Dict.empty } b.outputs


withRefs : List Level -> List Expr -> (List Ref -> Instr) -> Instr
withRefs frames es k =
    case refsOf frames es of
        Just rs ->
            k rs

        Nothing ->
            IFail "internal: an operand was not evaluated"


refsOf : List Level -> List Expr -> Maybe (List Ref)
refsOf frames es =
    List.foldr (\e acc -> Maybe.map2 (::) (refOf frames (E.key e)) acc) (Just []) es


refOf : List Level -> Key -> Maybe Ref
refOf frames k =
    let
        go depth ls =
            case ls of
                [] ->
                    Nothing

                l :: rest ->
                    case Dict.get k l.slots of
                        Just s ->
                            Just (Ref depth s)

                        Nothing ->
                            go (depth + 1) rest
    in
    go 0 frames


varRef : List Level -> Key -> Int -> Maybe Ref
varRef frames scope i =
    let
        go depth ls =
            case ls of
                [] ->
                    Nothing

                l :: rest ->
                    if l.scope == Just scope && i < l.arity then
                        Just (Ref depth i)

                    else
                        go (depth + 1) rest
    in
    go 0 frames


{-| `Grad.postorder`, not descending into what `isKnown` finds already computed.
-}
postorderPruned : (Key -> Bool) -> List Expr -> List Expr
postorderPruned isKnown roots =
    let
        go stack visited acc =
            case stack of
                [] ->
                    List.reverse acc

                ( e, expanded ) :: rest ->
                    let
                        k =
                            E.key e
                    in
                    if expanded then
                        go rest visited (e :: acc)

                    else if Set.member k visited || isKnown k then
                        go rest visited acc

                    else
                        let
                            kids =
                                E.operands e
                                    |> List.filter (\o -> not (Set.member (E.key o) visited) && not (isKnown (E.key o)))
                                    |> List.map (\o -> ( o, False ))
                        in
                        go (kids ++ (( e, True ) :: rest)) (Set.insert k visited) acc
    in
    go (List.map (\r -> ( r, False )) roots) Set.empty []



-- RUNNING


{-| Run a top-level program: its outputs, in order.
-}
execute : Ctx -> Program -> Result String (List V)
execute ctx prog =
    runProgram ctx [] prog []


runProgram : Ctx -> List (Array V) -> Program -> List T -> Result String (List V)
runProgram ctx outer (Program p) args =
    let
        step code frame =
            case code of
                [] ->
                    Ok frame

                i :: rest ->
                    case exec ctx (frame :: outer) i of
                        Ok v ->
                            step rest (Array.push v frame)

                        Err msg ->
                            Err msg
    in
    case step p.code (Array.fromList (List.map One args)) of
        Ok frame ->
            List.foldr (\r acc -> Result.map2 (::) (get (frame :: outer) r) acc) (Ok []) p.outputs

        Err msg ->
            Err msg


get : List (Array V) -> Ref -> Result String V
get frames (Ref depth slot) =
    case List.drop depth frames of
        f :: _ ->
            case Array.get slot f of
                Just v ->
                    Ok v

                Nothing ->
                    Err "internal: an operand was not evaluated"

        [] ->
            Err "internal: an operand was not evaluated"


one : List (Array V) -> Ref -> Result String T
one frames r =
    case get frames r of
        Ok (One t) ->
            Ok t

        Ok (Many _) ->
            Err "internal: a multi-result operation used as a tensor"

        Err msg ->
            Err msg


ones : List (Array V) -> List Ref -> Result String (List T)
ones frames rs =
    List.foldr (\r acc -> Result.map2 (::) (one frames r) acc) (Ok []) rs


tensors : List V -> Result String (List T)
tensors vs =
    List.foldr
        (\v acc ->
            case v of
                One t ->
                    Result.map ((::) t) acc

                Many _ ->
                    Err "internal: a body output is not a tensor"
        )
        (Ok [])
        vs


body : Ctx -> List (Array V) -> Program -> List T -> Result String (List T)
body ctx frames prog args =
    runProgram ctx frames prog args |> Result.andThen tensors


exec : Ctx -> List (Array V) -> Instr -> Result String V
exec ctx frames instr =
    case instr of
        IInput i ->
            case Array.get i ctx.inputs of
                Just t ->
                    Ok (One t)

                Nothing ->
                    Err ("input " ++ String.fromInt i ++ " was not given")

        IConst t ->
            Ok (One t)

        IArg r ->
            Result.map One (one frames r)

        IPrim p rs params meta ->
            ones frames rs
                |> Result.andThen (\ts -> EvalPrim.apply p ts params meta)
                |> Result.map One

        IProj r i ->
            case get frames r of
                Ok (Many ts) ->
                    case List.drop i ts of
                        t :: _ ->
                            Ok (One t)

                        [] ->
                            Err "internal: result index out of range"

                _ ->
                    Err "internal: a projection of a single result"

        ICall b rs ->
            ones frames rs |> Result.andThen (body ctx frames b) |> Result.map Many

        IIf pr t f rs ->
            Result.map2 Tuple.pair (one frames pr) (ones frames rs)
                |> Result.andThen
                    (\( p, vs ) ->
                        body ctx
                            frames
                            (if C.getI (C.intsOf p) 0 /= 0 then
                                t

                             else
                                f
                            )
                            vs
                            |> Result.map Many
                    )

        IWhile c b rs ->
            ones frames rs |> Result.andThen (loop ctx frames c b) |> Result.map Many

        IFail msg ->
            Err msg


{-| Test, then step, until the test is false or the guard is passed.
-}
loop : Ctx -> List (Array V) -> Program -> Program -> List T -> Result String (List T)
loop ctx frames c b init =
    let
        go n state =
            if n > ctx.maxIterations then
                Err ("While: more than " ++ String.fromInt ctx.maxIterations ++ " iterations")

            else
                case body ctx frames c state of
                    Ok [ t ] ->
                        if C.getI (C.intsOf t) 0 /= 0 then
                            case body ctx frames b state of
                                Ok next ->
                                    go (n + 1) next

                                Err msg ->
                                    Err msg

                        else
                            Ok state

                    Ok _ ->
                        Err "While: the test must return one mask"

                    Err msg ->
                        Err msg
    in
    go 0 init
