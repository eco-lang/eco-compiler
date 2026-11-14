module Tensor.Internal.Eval exposing (Ctx, Program, V(..), compile, execute)

{-| The evaluator runs tensor expressions in plain Elm instead of on MAX, and this module is its
engine: it compiles expressions once into a program, which can then be run any number of times.

A _program_ is a list of _instructions_, one for each expression it computes, in an order in which
every expression comes after any of the program's expressions that it reads. Running a program
gives it a _frame_, an array of values, and each instruction appends its result to the frame, so
every expression's value has a fixed position there, its _slot_ (in the evaluator's sense, not a
signature's). An instruction reads each operand by position, from a slot of its own frame or of a
frame enclosing it. An expression's _key_ stands for its identity, as `Tensor.Internal.Expr`
describes. Keys are used only while compiling, to give each expression its slot; nothing is looked
up by key when a program runs.

A multi-result node (`Call`, `If` or `While`, as `Tensor.Internal.Expr` describes them) holds
bodies, traced functions whose outputs are written in terms of placeholders for their arguments. A
body can run with different arguments at each call and at each step of a loop, so the values of
its expressions can change from one run to the next while their keys do not: a placeholder's key
does not depend on the value it stands for. Every body (a `Call`'s, each branch of an `If`, the
test and the step of a `While`) is therefore compiled to a program of its own, and run in a fresh
frame whose first slots hold its arguments.

A body may read expressions from outside it. One that an enclosing program has computed before the
instruction that runs the body is read from that program's frame. Any other is compiled into the
body, and computed again every time the body runs.

Bodies are run only when they are needed. An `If` runs only the branch that element 0 of its
predicate selects. A `While` runs its test and its step in turn until element 0 of the test's
result, rounded to an integer, is zero, and fails once it has taken more than `maxIterations` steps;
the count starts again each time the loop is entered, so it bounds each execution of a loop
separately, not the whole run. Nothing is cached between calls: each `Call` instruction holds its
own compiled copy of its body and runs it every time the instruction runs.

Compiling never fails. Where it finds an error, such as a placeholder read outside its function, it
emits an instruction that fails when it runs, so an error in a branch that is never taken is never
reported. A run stops at the first error.

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


{-| The value of one expression when a program runs.

`One` is the value of every expression except a multi-result node. `Many` holds the results of a
`Call`, `If` or `While`, in order; a projection reads one of them.

-}
type V
    = One T
    | Many (List T)


{-| What a run is given besides the program.

`inputs` holds the values of `Input` expressions, indexed by the position each one carries; the
graph name it also carries is not looked at. `maxIterations` is the guard on loops, applied as this
module's docstring describes.

-}
type alias Ctx =
    { inputs : Array T, maxIterations : Int }


{-| Where an operand's value is when a program runs: how many frames out from the current one
(0 is the current frame), and the slot in that frame.
-}
type Ref
    = Ref Int Int


{-| One instruction of a program, which computes the value of one expression.

`IInput` reads the input at its position in `Ctx`, and fails when there is none.

`IConst` is a constant, already converted to a run-time tensor when it was compiled.

`IArg` reads an argument of the body whose frame its reference names.

`IPrim` applies a primitive to its operands with its params and the meta of its result, by
`Tensor.Internal.Eval.Prim.apply`.

`ICall` runs its program on its operands, and its value is the program's outputs.

`IIf` reads element 0 of its predicate, rounded to an integer, and runs the first program on its
other operands if that element is not zero and the second program otherwise. A predicate with no
elements selects the second.

`IWhile` holds a loop's test and step and reads its initial state, as `loop` describes.

`IProj` is one of the results of the multi-result value its reference names.

`IFail` stands where compiling met an error, and fails with its message when it runs.

-}
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


{-| A compiled computation, ready to be run any number of times.

`compile` makes one from the expressions it is to compute, and `execute` runs it. Nothing in a
program depends on the inputs, so one program serves every run.

-}
type Program
    = Program { arity : Int, code : List Instr, outputs : List Ref }



-- COMPILING


{-| What compiling a body knows about one frame, its own or an enclosing one: a _level_.

`scope` is the scope key of the body whose arguments the frame holds, and is `Nothing` for the
top-level program, which has none. `slots` gives the slot of each expression compiled into the frame
so far, by key; arguments are not in it.

-}
type alias Level =
    { scope : Maybe Key, arity : Int, slots : Dict Key Int }


{-| Compiles a program that computes `roots`, whose outputs are their values in the same order.

Compiling never fails: an error it finds becomes an instruction that fails when it runs.

-}
compile : List Expr -> Program
compile roots =
    compileBody [] { scope = Nothing, arity = 0, slots = Dict.empty } roots


{-| Compiles a program that computes `roots` in the frame `start` describes, inside the frames
`outer`, innermost first.

An expression that one of `outer` already has a slot for is read from there, and so is not compiled
again, and neither is anything reached only through it. Every other expression `roots` reach
through operands is compiled once, after those of its operands that are compiled here, and the
instruction at index i writes slot `start.arity + i` of the frame.

-}
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


{-| Compiles the body `b` to a program of its own, run in a fresh frame whose first `b.arity` slots
are its arguments, inside the frames `frames`.
-}
compileFn : List Level -> E.Body -> Program
compileFn frames b =
    compileBody frames { scope = Just b.scope, arity = b.arity, slots = Dict.empty } b.outputs


{-| Builds an instruction with `k` from the references to `es`, or, when one of them has no slot in
`frames`, an instruction that fails when it runs.
-}
withRefs : List Level -> List Expr -> (List Ref -> Instr) -> Instr
withRefs frames es k =
    case refsOf frames es of
        Just rs ->
            k rs

        Nothing ->
            IFail "internal: an operand was not evaluated"


{-| Returns the references to `es`, in order, or `Nothing` when any of them has no slot in
`frames`.
-}
refsOf : List Level -> List Expr -> Maybe (List Ref)
refsOf frames es =
    List.foldr (\e acc -> Maybe.map2 (::) (refOf frames (E.key e)) acc) (Just []) es


{-| Returns where the expression with key `k` is: in the innermost of `frames` that has a slot for
it.
-}
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


{-| Returns where argument `i` of the body with scope key `scope` is: slot `i` of the innermost of
`frames` that holds that body's arguments and has more than `i` of them, or `Nothing` when none
does.
-}
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


{-| Returns every expression reachable from `roots` through operands, each once and after those of
its operands that are in the list, leaving out each expression whose key `isKnown` accepts and
anything reachable only through one. Expressions are told apart by key, and the bodies of `Call`,
`If` and `While` nodes are not looked into.

The walk keeps its own stack rather than recursing, so a deep expression cannot exhaust the call
stack.

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


{-| Runs a program made by `compile` with the inputs and the loop guard in `ctx`, and returns the
value of each of its outputs, in order, or the first error met.
-}
execute : Ctx -> Program -> Result String (List V)
execute ctx prog =
    runProgram ctx [] prog []


{-| Runs `prog` in a fresh frame that starts with `args`, inside the frames `outer` (innermost
first), and returns the values of its outputs, or the first error met.

Each instruction's value is appended to the frame, so the slots line up with the ones the program
was compiled for only when `args` holds exactly as many values as the program has arguments.
Nothing checks that.

-}
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


{-| Returns the value in the slot `ref` names, or an error when there is none.
-}
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


{-| Returns the single tensor at `r`, or an error when the slot holds a multi-result value or none.
-}
one : List (Array V) -> Ref -> Result String T
one frames r =
    case get frames r of
        Ok (One t) ->
            Ok t

        Ok (Many _) ->
            Err "internal: a multi-result operation used as a tensor"

        Err msg ->
            Err msg


{-| Returns the single tensors at `rs`, in order, or the first error `one` gives.
-}
ones : List (Array V) -> List Ref -> Result String (List T)
ones frames rs =
    List.foldr (\r acc -> Result.map2 (::) (one frames r) acc) (Ok []) rs


{-| Returns the tensors in `vs`, or an error when any of them is a multi-result value.
-}
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


{-| Runs the body `prog` on `args` inside the frames `frames`, and returns its outputs, each of
which must be a single tensor.
-}
body : Ctx -> List (Array V) -> Program -> List T -> Result String (List T)
body ctx frames prog args =
    runProgram ctx frames prog args |> Result.andThen tensors


{-| Runs one instruction and returns its value. `frames` is the frame being filled, followed by the
frames enclosing it.
-}
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


{-| Runs a loop from the state `init` and returns its final state. While element 0 of the test
program's one output, rounded to an integer, is not zero, the step program replaces the state with
its outputs; nothing checks that it gives as many values as the state had.

The loop fails when the test gives other than one output, and as soon as the number of steps taken
exceeds `ctx.maxIterations`: a loop whose test still holds after that many steps runs one step more,
then fails. The count starts at 0 each time an `IWhile` instruction runs.

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
