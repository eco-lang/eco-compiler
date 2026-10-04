module Compiler.Reporting.Result exposing
    ( RResult(..), RStep(..), Step(..)
    , ok, throw, warn, run
    , map, apply, andThen
    , traverse, indexedTraverse, mapTraverseWithKey
    , loop
    )

{-| A compiler pass that checks a whole module should report every problem it
finds, not only the first, and gather warnings as it goes. This module is the
computation type such a pass is written in.

An `RResult info warnings error a` is a computation that is given the current
_info_ and _warnings_ and either succeeds with a value of type `a` or fails
with one or more errors of type `error`. The info is whatever state the
computation's author chooses to carry from step to step; this module only
passes it along. The warnings are passed along in the same way, and `warn`,
the one function here that adds to them, takes them to be a list of
`Compiler.Reporting.Warning.Warning`. No function in this module discards the
info or warnings when a computation fails. Errors are held in a
`Compiler.Data.OneOrMore`, so a failure always carries at least one.

Whether a failure stops the computation depends on how its steps are combined.
`apply` and `traverse` run every step, even after one has failed, and join the
errors of all the failing steps, earlier steps' errors first; this is how a
pass reports many problems at once. `andThen` cannot do this, because its next
step is made from the value of the step before, so a failure ends the
computation there. `loop`, `mapTraverseWithKey` and `indexedTraverse` also
stop at the first failure.


# Types

@docs RResult, RStep, Step


# Basics

`run` starts a computation with `()` as its info and no warnings, and returns
its warnings and an ordinary `Result`.

@docs ok, throw, warn, run


# Combinators

@docs map, apply, andThen


# Traversals

@docs traverse, indexedTraverse, mapTraverseWithKey


# Loops

@docs loop

-}

import Compiler.Data.Index as Index
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Reporting.Warning as Warning
import Data.Map as DataMap



-- ====== RESULT ======


{-| A computation that passes on info and warnings and ends in either a value or
one or more errors.

The constructor is exposed, so a computation can also be written by hand: its
function receives the info and warnings as they stand and returns an `RStep`.
This is how a computation reads or replaces the info, which nothing in this
module does.

-}
type RResult info warnings error a
    = RResult (info -> warnings -> RStep info warnings error a)


{-| The outcome of running a computation once, with the info and warnings as
they stand afterwards.

`ROk` carries the value the computation succeeded with. `RErr` carries its
errors, and the info and warnings it ends with.

-}
type RStep info warnings error a
    = ROk info warnings a
    | RErr info warnings (OneOrMore.OneOrMore error)


{-| Runs a computation with `()` as its info and an empty list of warnings, and
returns the warnings with either the value or the errors.

The warnings are returned whether or not the computation failed. The list is
reversed before it is returned; since `warn` puts each new warning at the head,
warnings added by `warn` come out in the order they were added.

-}
run : RResult () (List w) e a -> ( List w, Result (OneOrMore.OneOrMore e) a )
run (RResult k) =
    case k () [] of
        ROk () w a ->
            ( List.reverse w, Ok a )

        RErr () w e ->
            ( List.reverse w, Err e )



-- ====== LOOP ======


{-| What one iteration of a `loop` asks for next.

`Loop` carries the state the next iteration starts from. `Done` ends the loop,
carrying its result.

-}
type Step state a
    = Loop state
    | Done a


{-| Builds a computation that runs `callback` on `state`, and then on each new
state it returns in a `Loop`, until it returns `Done`, whose value is the
result.

Info and warnings pass from each iteration to the next. The first iteration
that fails ends the loop with its errors. Going round again does not deepen the
stack, so the loop may run any number of times.

-}
loop : (state -> RResult i w e (Step state a)) -> state -> RResult i w e a
loop callback state =
    RResult <|
        \i w ->
            loopHelp callback i w state


{-| Runs iterations of `callback`, starting from `state` with info `i` and
warnings `w`, until one returns `Done` or fails, and returns that outcome. It
calls itself in tail position, which Elm compiles to a loop.
-}
loopHelp : (state -> RResult i w e (Step state a)) -> i -> w -> state -> RStep i w e a
loopHelp callback i w state =
    case callback state of
        RResult k ->
            case k i w of
                RErr i1 w1 e ->
                    RErr i1 w1 e

                ROk i1 w1 (Loop newState) ->
                    loopHelp callback i1 w1 newState

                ROk i1 w1 (Done a) ->
                    ROk i1 w1 a



-- ====== BASICS ======


{-| Creates a computation that succeeds with `a` and leaves the info and warnings
unchanged.
-}
ok : a -> RResult i w e a
ok a =
    RResult <|
        \i w ->
            ROk i w a


{-| Creates a computation that adds `warning` to the warnings and succeeds with
`()`.

The warning is put at the head of the list, so while a computation runs its
warnings are held newest first. `run` reverses them.

-}
warn : Warning.Warning -> RResult i (List Warning.Warning) e ()
warn warning =
    RResult <|
        \i warnings ->
            ROk i (warning :: warnings) ()


{-| Creates a computation that fails with `e` as its only error and leaves the
info and warnings unchanged.
-}
throw : e -> RResult i w e a
throw e =
    RResult <|
        \i w ->
            RErr i w (OneOrMore.one e)



-- ====== COMBINATORS ======


{-| Returns a computation that runs the given one and applies `func` to its
value. A failure is passed on unchanged.
-}
map : (a -> b) -> RResult i w e a -> RResult i w e b
map func (RResult k) =
    RResult <|
        \i w ->
            case k i w of
                ROk i1 w1 value ->
                    ROk i1 w1 (func value)

                RErr i1 w1 e ->
                    RErr i1 w1 e


{-| Returns a computation that runs the function computation, then the value
computation, and succeeds with the function applied to the value.

The value comes first among the arguments, so that further arguments can be
supplied in a pipeline: `ok f |> apply a |> apply b`.

The value computation runs even when the function computation has failed,
starting from the info and warnings that failure left. When both fail, the
result carries the function computation's errors followed by the value
computation's. When one fails, the result carries its errors and the info and
warnings left by the value computation.

-}
apply : RResult i w x a -> RResult i w x (a -> b) -> RResult i w x b
apply (RResult kv) (RResult kf) =
    RResult <|
        \i w ->
            case kf i w of
                ROk i1 w1 func ->
                    case kv i1 w1 of
                        ROk i2 w2 value ->
                            ROk i2 w2 (func value)

                        RErr i2 w2 e2 ->
                            RErr i2 w2 e2

                RErr i1 w1 e1 ->
                    case kv i1 w1 of
                        ROk i2 w2 _ ->
                            RErr i2 w2 e1

                        RErr i2 w2 e2 ->
                            RErr i2 w2 (OneOrMore.more e1 e2)


{-| Returns a computation that runs the given one, then the computation `callback`
makes from its value.

If the first computation fails, `callback` is never called and the result is
that failure, so no errors from later steps are collected.

-}
andThen : (a -> RResult i w x b) -> RResult i w x a -> RResult i w x b
andThen callback (RResult ka) =
    RResult <|
        \i w ->
            case ka i w of
                ROk i1 w1 a ->
                    case callback a of
                        RResult kb ->
                            kb i1 w1

                RErr i1 w1 e ->
                    RErr i1 w1 e


{-| Returns a computation that runs `func` on each element of the list, first to
last, and succeeds with the list of results in the same order.

Every element is run, even after one has failed, each starting from the info
and warnings the element before it left. If any fail, the result carries the
errors of every failing element, in list order.

-}
traverse : (a -> RResult i w x b) -> List a -> RResult i w x (List b)
traverse func =
    List.foldl
        (\a (RResult acc) ->
            RResult <|
                \i w ->
                    let
                        (RResult kv) =
                            func a
                    in
                    case acc i w of
                        ROk i1 w1 accList ->
                            case kv i1 w1 of
                                ROk i2 w2 value ->
                                    ROk i2 w2 (value :: accList)

                                RErr i2 w2 e2 ->
                                    RErr i2 w2 e2

                        RErr i1 w1 e1 ->
                            case kv i1 w1 of
                                ROk i2 w2 _ ->
                                    RErr i2 w2 e1

                                RErr i2 w2 e2 ->
                                    RErr i2 w2 (OneOrMore.more e1 e2)
        )
        (ok [])
        >> map List.reverse


{-| Returns a computation that runs `f` on each key and value of `dict`, and
succeeds with a dictionary in which each key is filed, under `toComparable` of
it, with the result of `f`.

Entries are run in ascending order of their projected keys; `keyComparison` is
passed to `Data.Map.toList`, which ignores it. Info and warnings pass from each
entry to the next. The first entry whose computation fails ends the traversal,
and the result carries only that entry's errors.

-}
mapTraverseWithKey : (k -> comparable) -> (k -> k -> Order) -> (k -> a -> RResult i w x b) -> DataMap.Dict comparable k a -> RResult i w x (DataMap.Dict comparable k b)
mapTraverseWithKey toComparable keyComparison f dict =
    loop (mapTraverseWithKeyHelp toComparable f) ( DataMap.toList keyComparison dict, DataMap.empty )


{-| Performs one iteration of the loop behind `mapTraverseWithKey`. Given the
entries still to run and the dictionary built so far, it returns `Done` with
that dictionary when no entries remain, and otherwise runs `f` on the first
entry and returns `Loop` with the rest and the dictionary extended by its
result.
-}
mapTraverseWithKeyHelp :
    (k -> comparable)
    -> (k -> a -> RResult i w x b)
    -> ( List ( k, a ), DataMap.Dict comparable k b )
    -> RResult i w x (Step ( List ( k, a ), DataMap.Dict comparable k b ) (DataMap.Dict comparable k b))
mapTraverseWithKeyHelp toComparable f ( pairs, result ) =
    case pairs of
        [] ->
            ok (Done result)

        ( k, a ) :: rest ->
            map (\b -> Loop ( rest, DataMap.insert toComparable k b result )) (f k a)


{-| Returns a computation that runs `func` on each element of `xs` together with
its position, counted from `Index.first`, and succeeds with the results in the
order of the list.

Unlike `traverse`, the elements run from last to first: info and warnings pass
from each element to the one before it in the list. The first failure in that
order, which is the failing element nearest the end of the list, ends the
traversal, and the result carries only that element's errors.

-}
indexedTraverse : (Index.ZeroBased -> a -> RResult i w error b) -> List a -> RResult i w error (List b)
indexedTraverse func xs =
    List.foldr (\a -> andThen (\acc -> map (\b -> b :: acc) a)) (ok []) (Index.indexedMap func xs)
