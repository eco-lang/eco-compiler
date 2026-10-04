module System.TypeCheck.IO exposing
    ( unsafePerformIO
    , IO, State, pure, apply, map, andThen, foldrM, foldM, traverseMapWithKey, forM_, mapM_
    , mapM, traverseList, traverseTuple
    , traverseArrayMaybe, foldMArray
    , makeDescriptor
    , NameState, getNames, putNames, withFreshNames
    , NodeIdState, getNodeIds, modifyNodeIds, withNodeIds
    , classifySorted, lsTopContent, lsTopContentK, pointKey, unionSortedAsc
    )

{-| The type checker and the monomorphization solver are imperative algorithms
over a union-find store, written in Elm by passing the store from each step to
the next. This module is the state monad that does the passing.

An _action_, of type `IO a`, is a function that takes the current `State` and
returns the next one together with a result. Despite its name the monad performs
no input or output: the state is all an action can change. `pure` makes an
action from a value, `map`, `apply` and `andThen` build actions from other
actions, and the iterators run an action once for each element of a list, array
or dictionary, handing the state each run leaves on to the next.

The heart of the state is the _point store_, the union-find store itself, which
holds one cell for each type variable; `Compiler.AST.TypeVars` describes points and
their cells. The point store is an `Eco.CellStore`, which the native build
changes in place, so a state is subject to that module's linearity contract:
once a state has been given to an action, only the state the action returns is
used again. A state kept from before an action is therefore not a snapshot that
can be gone back to. Alongside the point store, the state holds a table of
vectors, the state of fresh-name generation, and the record of which variable
stands for each node of the syntax tree.

Because every step may change the state, the order in which an iterator visits
elements is part of what it computes. It decides, for instance, which index each
newly made point is given. `traverseList`, `mapM`, `foldM`, `foldMArray`,
`traverseArrayMaybe` and `traverseMapWithKey` go from the first element to the
last. `foldrM` also goes from the first to the last, despite its name. `mapM_`
and `forM_` go from the last element to the first. Each iterator loops through
a self-tail-recursive helper, which Elm compiles to a loop, so a long list does
not deepen the stack.

The last group of functions serves lambda sets, which `Compiler.AST.TypeVars`
defines, and is used by `Compiler.Type.Unify` and by the monomorphization
solver: comparing and merging ascending lists of member ids, the index of a
point as a key, and shared contents for the top lambda set.

@docs unsafePerformIO


# The IO monad

@docs IO, State, pure, apply, map, andThen, foldrM, foldM, traverseMapWithKey, forM_, mapM_
@docs mapM, traverseList, traverseTuple
@docs traverseArrayMaybe, foldMArray


# Descriptor Utilities

@docs makeDescriptor


# Name State

@docs NameState, getNames, putNames, withFreshNames


# Node ID Tracking

@docs NodeIdState, getNodeIds, modifyNodeIds, withNodeIds


# Lambda Sets

@docs classifySorted, lsTopContent, lsTopContentK, pointKey, unionSortedAsc

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.TypeVars exposing (Content(..), Descriptor, FlatType(..), LambdaSet(..), Mark, Point(..), PointCell, SortedRel(..), Variable)
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Dict as CoreDict
import Eco.CellStore as CellStore


{-| Runs `ioA` on a state made by `freshState` and returns its result, discarding
the final state.

The final state's point store is passed to `Eco.CellStore.disposeThen`
whatever the action did with it, including when the action has already passed
it to `Eco.CellStore.freeze`.

-}
unsafePerformIO : IO a -> a
unsafePerformIO ioA =
    case ioA (freshState ()) of
        ( s1, a ) ->
            CellStore.disposeThen s1.ioRefsPoint a


{-| Creates a state with an empty point store, no vectors, the empty name
state, and the empty node-id state, in which recording is off.

It takes `()` because the native build's point store is mutable. As a constant
it would be evaluated once, and every state made from it would share one
store.

-}
freshState : () -> State
freshState () =
    { ioRefsPoint = CellStore.new 256
    , ioRefsMVector = Array.empty
    , names = emptyNameState
    , nodeIds = emptyNodeIds
    }


{-| A step of the type checker or the solver: a function from the state before
it to the state after it, paired with the step's result.

This is a name for a function type, not a new type, so any function of that
shape is an action. The state comes first in the pair. Some state-passing
functions elsewhere, such as `Compiler.Type.UnionFind.getS`, put it second.

-}
type alias IO a =
    State -> ( State, a )


{-| Everything an action can change.

`ioRefsPoint` is the point store, with one cell for each point. It is used
under the linearity contract of `Eco.CellStore`, so an attempt that may have to
be abandoned must be enclosed in one of the store's undo scopes
(`Eco.CellStore.pushMark` and `Eco.CellStore.rollback`); keeping the earlier
state does not undo it.

`ioRefsMVector` holds every vector made by `Data.IORef.newIORefMVector`, such
as the solver's pools of variables by rank. A reference to a vector is its
position in this array.

-}
type alias State =
    { ioRefsPoint : CellStore.Store PointCell
    , ioRefsMVector : Array (Array (Maybe (List Variable)))
    , names : NameState
    , nodeIds : NodeIdState
    }


{-| The state of fresh-name generation while solved types are converted back
into annotations and error types.

`taken` is the set of names already in use. The five counters, `normals` to
`compAppends`, hold for each kind of variable (plain, `number`, `comparable`,
`appendable` and `compappend`) the index from which the next generated name is
tried. `canMemo` maps the index of a union-find root to the type already built
for it, so that a root reached twice is converted once.

-}
type alias NameState =
    { taken : CoreDict.Dict String ()
    , normals : Int
    , numbers : Int
    , comparables : Int
    , appendables : Int
    , compAppends : Int
    , canMemo : CoreDict.Dict Int (Can.Type String)
    }


{-| The name state a fresh state starts with: no names taken, every counter at
zero and nothing remembered.
-}
emptyNameState : NameState
emptyNameState =
    { taken = CoreDict.empty, normals = 0, numbers = 0, comparables = 0, appendables = 0, compAppends = 0, canMemo = CoreDict.empty }


{-| Returns the current name state, leaving the state unchanged.
-}
getNames : IO NameState
getNames s =
    ( s, s.names )


{-| Replaces the name state with `names`.
-}
putNames : NameState -> IO ()
putNames names s =
    ( { s | names = names }, () )


{-| Runs `action` with `seed` as the name state, then puts back the name state
it found, so names generated inside do not reach the caller's name state. One
such run is a _naming scope_.

Every other part of the state, the point store included, keeps what the action
did to it.

-}
withFreshNames : NameState -> IO a -> IO a
withFreshNames seed action s =
    let
        saved =
            s.names

        ( s1, a ) =
            action { s | names = seed }
    in
    ( { s1 | names = saved }, a )


{-| The record, kept while constraints are generated, of which solver variable
stands for each expression and pattern of a module.

`mapping` is indexed by node id, and holds `Nothing` for an id with no
variable recorded. `syntheticExprIds` holds the ids of expressions whose
variable in `mapping` is a placeholder made in order to be recorded.
`schemeBinderVars` maps an annotated definition's name to the type variables
its annotation introduces, those not already bound by an enclosing annotation,
each by its name. `recording` says whether records are to be made at all; this
module only stores it, and it is off in the state `freshState` makes.

-}
type alias NodeIdState =
    { mapping : Array (Maybe Variable)
    , syntheticExprIds : EverySet Int Int
    , schemeBinderVars : CoreDict.Dict String (CoreDict.Dict String Variable)
    , recording : Bool
    }


{-| The node-id state a fresh state starts with: nothing recorded, and
`recording` off.
-}
emptyNodeIds : NodeIdState
emptyNodeIds =
    { mapping = Array.empty
    , syntheticExprIds = EverySet.empty
    , schemeBinderVars = CoreDict.empty
    , recording = False
    }


{-| Returns the current node-id state, leaving the state unchanged.
-}
getNodeIds : IO NodeIdState
getNodeIds s =
    ( s, s.nodeIds )


{-| Replaces the node-id state with `f` applied to it.
-}
modifyNodeIds : (NodeIdState -> NodeIdState) -> IO ()
modifyNodeIds f s =
    ( { s | nodeIds = f s.nodeIds }, () )


{-| Runs `action` with `seed` as the node-id state, then puts back the node-id
state it found. The result is the action's own, paired with the node-id state
the action finished with.
-}
withNodeIds : NodeIdState -> IO a -> IO ( a, NodeIdState )
withNodeIds seed action s =
    let
        saved =
            s.nodeIds

        ( s1, a ) =
            action { s | nodeIds = seed }
    in
    ( { s1 | nodeIds = saved }, ( a, s1.nodeIds ) )


{-| Returns an action that leaves the state unchanged and returns `x`.
-}
pure : a -> IO a
pure x =
    \s -> ( s, x )


{-| Returns an action that runs `mf`, then `ma`, and applies the function the
first returns to the value the second returns.

The function's action runs first, although it is the second argument.

-}
apply : IO a -> IO (a -> b) -> IO b
apply ma mf =
    andThen (\f -> andThen (f >> pure) ma) mf


{-| Returns an action that runs `ma` and applies `fn` to its result.
-}
map : (a -> b) -> IO a -> IO b
map fn ma s0 =
    let
        ( s1, a ) =
            ma s0
    in
    ( s1, fn a )


{-| Returns an action that runs `ma`, then runs the action `f` makes from its
result on the state `ma` left.
-}
andThen : (a -> IO b) -> IO a -> IO b
andThen f ma s0 =
    let
        ( s1, a ) =
            ma s0
    in
    f a s1


{-| Returns an action that folds `f` over `xs`, starting from `z0`, where `f`
takes an element and the value so far.

Despite the name, the elements are visited from the head of the list to its end,
as in `foldM`. The two differ only in the order of `f`'s arguments.

-}
foldrM : (a -> b -> IO b) -> b -> List a -> IO b
foldrM f z0 xs s0 =
    foldrMGo f xs z0 s0


{-| Folds `f` over `xs` from the head, starting from `acc` on the state `s0`.
-}
foldrMGo : (a -> b -> IO b) -> List a -> b -> State -> ( State, b )
foldrMGo f xs acc s0 =
    case xs of
        [] ->
            ( s0, acc )

        a :: rest ->
            let
                ( s1, b ) =
                    f a acc s0
            in
            foldrMGo f rest b s1


{-| Returns an action that folds `f` over `list` from the first element to the
last, starting from `b0`.
-}
foldM : (b -> a -> IO b) -> b -> List a -> IO b
foldM f b0 list s0 =
    foldMGo f b0 list s0


{-| Folds `f` over `list` from the first element, starting from `acc` on the
state `s0`.
-}
foldMGo : (b -> a -> IO b) -> b -> List a -> State -> ( State, b )
foldMGo f acc list s0 =
    case list of
        [] ->
            ( s0, acc )

        a :: rest ->
            let
                ( s1, b ) =
                    f acc a s0
            in
            foldMGo f b rest s1


{-| Returns an action that runs `f` on every key and value of `dict` and
returns a dictionary of the results under the same keys.

The entries are visited in ascending order of their projected keys.
`keyComparison` has no effect, because `Data.Map.toList` ignores its ordering
function. Each result is filed under `toComparable` of its key, so
`toComparable` should be the projection `dict` was built with.

-}
traverseMapWithKey : (k -> comparable) -> (k -> a -> IO b) -> Dict comparable k a -> IO (Dict comparable k b)
traverseMapWithKey toComparable f dict s0 =
    traverseMapGo toComparable f (Dict.toList dict) Dict.empty s0


{-| Runs `f` on each of `pairs` in list order, inserting each result into
`result` under its key.
-}
traverseMapGo : (k -> comparable) -> (k -> a -> IO b) -> List ( k, a ) -> Dict comparable k b -> State -> ( State, Dict comparable k b )
traverseMapGo toComparable f pairs result s0 =
    case pairs of
        [] ->
            ( s0, result )

        ( k, a ) :: rest ->
            let
                ( s1, b ) =
                    f k a s0
            in
            traverseMapGo toComparable f rest (Dict.insert toComparable k b result) s1


{-| Returns an action that runs `f` on every element of `list` for its effect
on the state, discarding the results.

The elements are visited from the last to the first.

-}
mapM_ : (a -> IO b) -> List a -> IO ()
mapM_ f list s0 =
    mapMGo_ f (List.reverse list) s0


{-| Runs `f` on each element of `list` in list order, discarding the results.
-}
mapMGo_ : (a -> IO b) -> List a -> State -> ( State, () )
mapMGo_ f list s0 =
    case list of
        [] ->
            ( s0, () )

        a :: rest ->
            let
                ( s1, _ ) =
                    f a s0
            in
            mapMGo_ f rest s1


{-| Returns the action `mapM_ f list`, taking its arguments the other way round,
so it also visits the elements from the last to the first.
-}
forM_ : List a -> (a -> IO b) -> IO ()
forM_ list f =
    mapM_ f list


{-| Returns an action that runs `f` on every element of `list`, from the first
to the last, and returns the results in the same order.
-}
traverseList : (a -> IO b) -> List a -> IO (List b)
traverseList f list s0 =
    let
        ( s1, revAcc ) =
            traverseListGo f list [] s0
    in
    ( s1, List.reverse revAcc )


{-| Runs `f` on each element of `list` in list order, pushing each result onto
`acc`, so the results come out with the last first.
-}
traverseListGo : (a -> IO b) -> List a -> List b -> State -> ( State, List b )
traverseListGo f list acc s0 =
    case list of
        [] ->
            ( s0, acc )

        a :: rest ->
            let
                ( s1, b ) =
                    f a s0
            in
            traverseListGo f rest (b :: acc) s1


{-| Returns an action that runs `f` on the second component of a pair and pairs
its result with the unchanged first component.
-}
traverseTuple : (b -> IO c) -> ( a, b ) -> IO ( a, c )
traverseTuple f ( a, b ) =
    map (Tuple.pair a) (f b)


{-| Another name for `traverseList`: the action that runs a function on every
element of a list, from the first to the last, and collects the results in the
same order.
-}
mapM : (a -> IO b) -> List a -> IO (List b)
mapM =
    traverseList


{-| Returns an action that runs `f` on every element of `arr` in index order
and returns the results as an array in the same order.
-}
traverseArray : (a -> IO b) -> Array a -> IO (Array b)
traverseArray f arr =
    Array.toList arr
        |> traverseList f
        |> map Array.fromList


{-| Returns an action that runs `f` on the value in every `Just` element of an
array, in index order, and leaves each `Nothing` where it is.
-}
traverseArrayMaybe : (a -> IO b) -> Array (Maybe a) -> IO (Array (Maybe b))
traverseArrayMaybe f =
    traverseArray
        (\maybeA ->
            case maybeA of
                Nothing ->
                    pure Nothing

                Just a ->
                    map Just (f a)
        )


{-| Returns an action that folds `f` over `arr` in index order, starting from
`b`.
-}
foldMArray : (b -> a -> IO b) -> b -> Array a -> IO b
foldMArray f b arr =
    foldM f b (Array.toList arr)


{-| Builds a descriptor from its content, rank, mark and copy, given in that
order.
-}
makeDescriptor : Content -> Int -> Mark -> Maybe Variable -> Descriptor
makeDescriptor content rank mark copy =
    { content = content, rank = rank, mark = mark, copy = copy }


{-| Returns the index of a point in its store, for use as a key.

An index identifies a point only within the store that made it, and two points
of one class have different indices even after they are joined.

-}
pointKey : Variable -> Int
pointKey (Pt n) =
    n


{-| The content of a set slot holding the top lambda set with provenance code
10, the value of `Compiler.AST.Monomorphized.tkLegacy`.

`lsTopContentK` also returns it for code 10 and for any code above 20. This
module keeps one shared content for each code from 0 to 20, here and in the
private constants below, so that writing a top lambda set into the store builds
no new value.

-}
lsTopContent : Content
lsTopContent =
    Structure (LambdaSet1 (LsTop 10))


{-| The top lambda-set content with provenance code 0,
`Compiler.AST.Monomorphized.tkPoison`.
-}
lsTopPoison : Content
lsTopPoison =
    Structure (LambdaSet1 (LsTop 0))


{-| The top lambda-set content with provenance code 1,
`Compiler.AST.Monomorphized.tkConflict`.
-}
lsTopConflict : Content
lsTopConflict =
    Structure (LambdaSet1 (LsTop 1))


{-| The top lambda-set content with provenance code 2,
`Compiler.AST.Monomorphized.tkWiden`.
-}
lsTopWiden : Content
lsTopWiden =
    Structure (LambdaSet1 (LsTop 2))


{-| The top lambda-set content with provenance code 3,
`Compiler.AST.Monomorphized.tkEdge`.
-}
lsTopEdge : Content
lsTopEdge =
    Structure (LambdaSet1 (LsTop 3))


{-| The top lambda-set content with provenance code 4,
`Compiler.AST.Monomorphized.tkAbi`.
-}
lsTopAbi : Content
lsTopAbi =
    Structure (LambdaSet1 (LsTop 4))


{-| The top lambda-set content with provenance code 5,
`Compiler.AST.Monomorphized.tkDeclZonk`.
-}
lsTopDeclZonk : Content
lsTopDeclZonk =
    Structure (LambdaSet1 (LsTop 5))


{-| The top lambda-set content with provenance code 6, which
`Compiler.AST.Monomorphized` names `tkDeclStoreC`.
-}
lsTopDeclScheme : Content
lsTopDeclScheme =
    Structure (LambdaSet1 (LsTop 6))


{-| The top lambda-set content with provenance code 7, which
`Compiler.AST.Monomorphized` names `tkDeclStoreS`.
-}
lsTopDeclKey : Content
lsTopDeclKey =
    Structure (LambdaSet1 (LsTop 7))


{-| The top lambda-set content with provenance code 8, which
`Compiler.AST.Monomorphized` names `tkDeclOther`.
-}
lsTopDeclSpec : Content
lsTopDeclSpec =
    Structure (LambdaSet1 (LsTop 8))


{-| The top lambda-set content with provenance code 9,
`Compiler.AST.Monomorphized.tkSynth`.
-}
lsTopSynth : Content
lsTopSynth =
    Structure (LambdaSet1 (LsTop 9))


{-| The top lambda-set content with provenance code 11,
`Compiler.AST.Monomorphized.tkClassCase`.
-}
lsTopCls11 : Content
lsTopCls11 =
    Structure (LambdaSet1 (LsTop 11))


{-| The top lambda-set content with provenance code 12,
`Compiler.AST.Monomorphized.tkClassIf`.
-}
lsTopCls12 : Content
lsTopCls12 =
    Structure (LambdaSet1 (LsTop 12))


{-| The top lambda-set content with provenance code 13,
`Compiler.AST.Monomorphized.tkClassLocal`.
-}
lsTopCls13 : Content
lsTopCls13 =
    Structure (LambdaSet1 (LsTop 13))


{-| The top lambda-set content with provenance code 14,
`Compiler.AST.Monomorphized.tkClassLit`.
-}
lsTopCls14 : Content
lsTopCls14 =
    Structure (LambdaSet1 (LsTop 14))


{-| The top lambda-set content with provenance code 15,
`Compiler.AST.Monomorphized.tkClassParam`.
-}
lsTopCls15 : Content
lsTopCls15 =
    Structure (LambdaSet1 (LsTop 15))


{-| The top lambda-set content with provenance code 16,
`Compiler.AST.Monomorphized.tkClassDestr`.
-}
lsTopCls16 : Content
lsTopCls16 =
    Structure (LambdaSet1 (LsTop 16))


{-| The top lambda-set content with provenance code 17,
`Compiler.AST.Monomorphized.tkClassLambda`.
-}
lsTopCls17 : Content
lsTopCls17 =
    Structure (LambdaSet1 (LsTop 17))


{-| The top lambda-set content with provenance code 18,
`Compiler.AST.Monomorphized.tkClassCall`.
-}
lsTopCls18 : Content
lsTopCls18 =
    Structure (LambdaSet1 (LsTop 18))


{-| The top lambda-set content with provenance code 19,
`Compiler.AST.Monomorphized.tkClassLet`.
-}
lsTopCls19 : Content
lsTopCls19 =
    Structure (LambdaSet1 (LsTop 19))


{-| The top lambda-set content with provenance code 20,
`Compiler.AST.Monomorphized.tkClassMisc`.
-}
lsTopCls20 : Content
lsTopCls20 =
    Structure (LambdaSet1 (LsTop 20))


{-| Returns the shared top lambda-set content for code `k` from 11 to 19, and
the one for code 20 for any other `k`.
-}
lsTopClassK : Int -> Content
lsTopClassK k =
    if k == 11 then
        lsTopCls11

    else if k == 12 then
        lsTopCls12

    else if k == 13 then
        lsTopCls13

    else if k == 14 then
        lsTopCls14

    else if k == 15 then
        lsTopCls15

    else if k == 16 then
        lsTopCls16

    else if k == 17 then
        lsTopCls17

    else if k == 18 then
        lsTopCls18

    else if k == 19 then
        lsTopCls19

    else
        lsTopCls20


{-| Returns the shared content of a set slot holding the top lambda set with
provenance code `k`.

Codes 0 to 9 and 11 to 20 each have a content of their own. A negative `k`
gets the content for code 0, and 10 and any code above 20 get `lsTopContent`,
whose code is 10, so the code read back from the result is not always `k`.

-}
lsTopContentK : Int -> Content
lsTopContentK k =
    if k <= 0 then
        lsTopPoison

    else if k == 1 then
        lsTopConflict

    else if k == 2 then
        lsTopWiden

    else if k == 3 then
        lsTopEdge

    else if k == 4 then
        lsTopAbi

    else if k == 5 then
        lsTopDeclZonk

    else if k == 6 then
        lsTopDeclScheme

    else if k == 7 then
        lsTopDeclKey

    else if k == 8 then
        lsTopDeclSpec

    else if k == 9 then
        lsTopSynth

    else if k >= 11 && k <= 20 then
        lsTopClassK k

    else
        lsTopContent


{-| Returns how two lists of member ids relate as sets, as a
`Compiler.AST.TypeVars.SortedRel`, in a single pass over both.

The lists must be ascending and free of duplicates. The types cannot say so,
and for lists that are not, the answer has no meaning.

-}
classifySorted : List Int -> List Int -> SortedRel
classifySorted =
    classifySortedGo False False


{-| Returns how `xs` and `ys` relate as sets, given whether an id found only in
the first list (`leftOnly`) or only in the second (`rightOnly`) has already
been seen. It stops as soon as both have.
-}
classifySortedGo : Bool -> Bool -> List Int -> List Int -> SortedRel
classifySortedGo leftOnly rightOnly xs ys =
    if leftOnly && rightOnly then
        SortedMixed

    else
        case ( xs, ys ) of
            ( [], [] ) ->
                sortedRelOf leftOnly rightOnly

            ( _ :: _, [] ) ->
                sortedRelOf True rightOnly

            ( [], _ :: _ ) ->
                sortedRelOf leftOnly True

            ( x :: xRest, y :: yRest ) ->
                if x == y then
                    classifySortedGo leftOnly rightOnly xRest yRest

                else if x < y then
                    classifySortedGo True rightOnly xRest ys

                else
                    classifySortedGo leftOnly True xs yRest


{-| Returns the relation between two sets, given whether the first holds an id
the second lacks (`leftOnly`) and whether the second holds one the first lacks
(`rightOnly`).
-}
sortedRelOf : Bool -> Bool -> SortedRel
sortedRelOf leftOnly rightOnly =
    if leftOnly then
        if rightOnly then
            SortedMixed

        else
            SortedSuper

    else if rightOnly then
        SortedSub

    else
        SortedEqual


{-| Returns the ascending union of two lists of ids, keeping once an id that is
in both.

The lists must be ascending and free of duplicates. The types cannot say so,
and for lists that are not, the result need not be ascending or free of
duplicates. Once one list runs out, the remainder of the other is used as it
is, without being copied.

-}
unionSortedAsc : List Int -> List Int -> List Int
unionSortedAsc xs ys =
    case ( xs, ys ) of
        ( [], _ ) ->
            ys

        ( _, [] ) ->
            xs

        ( x :: xRest, y :: yRest ) ->
            if x == y then
                x :: unionSortedAsc xRest yRest

            else if x < y then
                x :: unionSortedAsc xRest ys

            else
                y :: unionSortedAsc xs yRest
