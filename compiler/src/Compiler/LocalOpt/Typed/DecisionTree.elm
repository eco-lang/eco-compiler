module Compiler.LocalOpt.Typed.DecisionTree exposing
    ( DecisionTree(..), Test, Path, ContainerHint
    , compile
    )

{-| A `case` expression has to be run as a sequence of tests on the value it
matches, and this module works out which tests to make and in what order, for
the typed pipeline.

The value a `case` matches on is its _scrutinee_. A _decision tree_ examines
the scrutinee one part at a time: each inner node names a position in the
scrutinee, a `Path`, and branches on a `Test` of the value found there, and
each leaf names the `case` branch that matches. Paths and tests are defined in
`Compiler.IR.DecisionTree.TypedPath` and `Compiler.IR.DecisionTree.Test`.

`Compiler.LocalOpt.Erased.DecisionTree` builds the same trees by the same
algorithm for the pipeline that carries no types. The difference is the path:
here each `Index` step into a list cell, a tuple or a constructor's fields
records that kind of container as a `ContainerHint`, so that a back end that
lays those out differently can choose how to take the field. Paths are compared
with `==`, hint included, so the hint given to a position must be the same
everywhere it is built; this module gives it from the constructor name, the
tuple size, or `HintList` for a list cell.

The algorithm works on rows. A row is one `case` branch, held as the list of
positions it still has to check, each with the pattern expected there. At the
start every row has one position, the scrutinee. Patterns whose shape the type
already fixes are expanded first: a tuple, or a constructor of a type with only
one constructor, is replaced by its parts at sub-positions, an alias is split
into its pattern and a variable, and unit is dropped. Then, if the first row
has nothing left that needs a test, it matches. Otherwise one position is
chosen, the different tests that rows make there become the edges of a node,
each edge keeps the rows that agree with its test (with the matched pattern's
parts added as new positions), and rows that make no test at that position are
carried into every edge, and into the fallback when there is one. The tree is
built again for each edge and for the fallback.

The position is chosen by two heuristics. The first prefers the position
where the fewest rows make no test. Ties are broken by the second, which
prefers the position whose node would have the fewest edges, counting a
fallback as one edge.

@docs DecisionTree, Test, Path, ContainerHint
@docs compile

-}

import Compiler.Core.Annotation as A
import Compiler.Core.Index as Index
import Compiler.Core.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Canonical as Can
import Compiler.IR.DecisionTree.Test as Test
import Compiler.IR.DecisionTree.TypedPath as TypedPath
import Compiler.IR.Source.StringLiteral as ES
import Data.NonEmptyList as NE
import Data.Set as EverySet
import Maybe.Extra as Maybe
import System.Crash exposing (crash)
import Utils.Main as Utils



-- ====== COMPILE CASES ======


{-| Builds the decision tree for the `case` branches given as patterns, each
paired with the number its `Match` leaves are to carry.

Branches are tried in the order given: where several match the same value,
the leaf names the earliest. A branch may be named by several leaves, or by
none. Patterns are assumed to have passed the exhaustiveness check, since a
missing case can lead to a node with no fallback. Crashes on an empty list,
since a `case` has a branch.

-}
compile : List ( Can.Pattern, Int ) -> DecisionTree
compile rawBranches =
    let
        format : ( Can.Pattern, Int ) -> Branch
        format ( pattern, index ) =
            Branch index (flatten ( TypedPath.Empty, pattern ) [])
    in
    case List.map format rawBranches of
        first :: rest ->
            toDecisionTree first rest

        [] ->
            crash "Typed.DecisionTree.compile: a case has at least one branch"



-- ====== DECISION TREES ======


{-| A plan for finding which `case` branch matches a value, made of tests on
parts of that value.

`Match` is a leaf, and carries the number that `compile` was given with the
matching branch's pattern.

`Decision` tests the value at its path. Each edge pairs a test with the tree
to follow when the test succeeds. The optional tree is the fallback, followed
when no edge's test succeeds. It is `Nothing` when the edges' tests cover
every value that can be at the path (every constructor of the type, both
`Bool`s, or both an empty and a non-empty list), and when no branch could
match without one of the edges' tests succeeding. A node always has at least
one edge.

-}
type DecisionTree
    = Match Int
    | Decision Path (NE.Nonempty ( Test, DecisionTree )) (Maybe DecisionTree)


{-| A question a `Decision` node asks about the value at its path. This is
another name for `Compiler.IR.DecisionTree.Test.Test`, which describes it.
-}
type alias Test =
    Test.Test


{-| The kind of container a path step takes a field from. This is another
name for `Compiler.IR.DecisionTree.TypedPath.ContainerHint`, which describes
it.
-}
type alias ContainerHint =
    TypedPath.ContainerHint


{-| A position in the scrutinee, as the steps that reach it. This is another
name for `Compiler.IR.DecisionTree.TypedPath.Path`, which describes it.
-}
type alias Path =
    TypedPath.Path



-- ====== ACTUALLY BUILD DECISION TREES ======


{-| One row: a `case` branch's number, and the positions it still has to
check, each with the flattened pattern expected there.
-}
type Branch
    = Branch Int (List ( Path, FlatPattern ))


{-| A pattern as `flatten` leaves it: one that needs a test of its own, or
`FAnything` for one that needs none.

`FAnything` stands for a variable, a wildcard or a record pattern. `FCtor`
is a constructor of a type with two or more constructors, with the fields of
`Test.IsCtor` and the constructor's argument patterns. `FNil` is the empty
list pattern, and `FCons` a non-empty list or `::` pattern with its head and
tail patterns. The literal and `Bool` patterns keep their values.

-}
type FlatPattern
    = FAnything
    | FCtor ModuleName.Canonical Name.Name Index.ZeroBased Int Can.CtorOpts (List Can.Pattern)
    | FNil
    | FCons Can.Pattern Can.Pattern
    | FInt Int
    | FChr String
    | FStr String
    | FBool Bool


{-| Builds the decision tree for the rows `first :: rest`, earliest row first,
as the module docstring describes.
-}
toDecisionTree : Branch -> List Branch -> DecisionTree
toDecisionTree ((Branch goal firstPatterns) as first) rest =
    case List.filterMap isChoicePath firstPatterns of
        [] ->
            Match goal

        firstPath :: firstPaths ->
            let
                branches : List Branch
                branches =
                    first :: rest

                path : Path
                path =
                    pickPath branches
                        (NE.Nonempty firstPath
                            (firstPaths ++ List.filterMap isChoicePath (List.concatMap (\(Branch _ patterns) -> patterns) rest))
                        )

                ( edges, fallback ) =
                    gatherEdges branches path

                decisionEdges : NE.Nonempty ( Test, DecisionTree )
                decisionEdges =
                    NE.map (Tuple.mapSecond (\(NE.Nonempty b bs) -> toDecisionTree b bs)) edges
            in
            case fallback of
                [] ->
                    Decision path decisionEdges Nothing

                f :: fs ->
                    Decision path decisionEdges (Just (toDecisionTree f fs))


{-| Returns whether the tests, all made at one position and with no duplicates,
cover every value that can be there, so that no fallback is needed.

The kind of test is read from the first one. Tests of `Int`,
`Char` or `String` literals are never complete.

-}
isComplete : NE.Nonempty Test -> Bool
isComplete (NE.Nonempty firstTest otherTests) =
    let
        count : Int
        count =
            1 + List.length otherTests
    in
    case firstTest of
        Test.IsCtor _ _ _ numAlts _ ->
            numAlts == count

        Test.IsCons ->
            count == 2

        Test.IsNil ->
            count == 2

        Test.IsInt _ ->
            False

        Test.IsChr _ ->
            False

        Test.IsStr _ ->
            False

        Test.IsBool _ ->
            count == 2



-- ====== FLATTEN PATTERNS ======


{-| Puts a position and its pattern, as `FlatPattern`s, in front of the other
positions, first expanding any pattern whose shape the type already fixes.

A tuple, or a constructor of a type with one constructor, is replaced by its
parts at sub-positions. A one-constructor type is expanded this way whatever
its `Can.CtorOpts`: a single argument is taken with `Unbox`, several with
`Index` steps. An alias pattern becomes its inner pattern and a variable
pattern for the alias name at the same position. Unit is dropped. The parts
are expanded in turn. Every other pattern becomes its `FlatPattern`.

-}
flatten : ( Path, Can.Pattern ) -> List ( Path, FlatPattern ) -> List ( Path, FlatPattern )
flatten ( path, A.At region patternInfo ) otherPathPatterns =
    case patternInfo.node of
        Can.PVar _ ->
            ( path, FAnything ) :: otherPathPatterns

        Can.PAnything ->
            ( path, FAnything ) :: otherPathPatterns

        Can.PCtor { home, union, name, index, args } ->
            let
                (Can.Union unionData) =
                    union
            in
            if unionData.numAlts == 1 then
                case List.map dearg args of
                    [ arg ] ->
                        flatten ( TypedPath.Unbox path, arg ) otherPathPatterns

                    args_ ->
                        List.foldr flatten otherPathPatterns (subPositions (TypedPath.HintCustom name) path args_)

            else
                ( path, FCtor home name index unionData.numAlts unionData.opts (List.map dearg args) ) :: otherPathPatterns

        Can.PTuple a b cs ->
            let
                hint =
                    case cs of
                        Nothing ->
                            TypedPath.HintTuple2

                        Just _ ->
                            TypedPath.HintTuple3
            in
            (a :: b :: Maybe.toList cs)
                |> List.foldl
                    (\x ( index, acc ) ->
                        ( Index.next index
                        , ( TypedPath.Index index hint path, x ) :: acc
                        )
                    )
                    ( Index.first, [] )
                |> Tuple.second
                |> List.foldl flatten otherPathPatterns

        Can.PUnit ->
            otherPathPatterns

        Can.PAlias realPattern _ ->
            flatten ( path, realPattern ) (( path, FAnything ) :: otherPathPatterns)

        Can.PRecord _ ->
            ( path, FAnything ) :: otherPathPatterns

        Can.PList [] ->
            ( path, FNil ) :: otherPathPatterns

        Can.PList (hd :: tl) ->
            let
                -- The tail pattern is synthesized, so it has no real id.
                tl_ : Can.Pattern
                tl_ =
                    A.At region { id = -1, node = Can.PList tl }
            in
            ( path, FCons hd tl_ ) :: otherPathPatterns

        Can.PCons hd tl ->
            ( path, FCons hd tl ) :: otherPathPatterns

        Can.PChr chr ->
            ( path, FChr chr ) :: otherPathPatterns

        Can.PStr str _ ->
            ( path, FStr str ) :: otherPathPatterns

        Can.PInt int ->
            ( path, FInt int ) :: otherPathPatterns

        Can.PBool _ bool ->
            ( path, FBool bool ) :: otherPathPatterns


{-| Pairs each pattern with the position of the field it matches, numbering the
fields from zero within the container at `path`.
-}
subPositions : ContainerHint -> Path -> List Can.Pattern -> List ( Path, Can.Pattern )
subPositions hint path patterns =
    Index.indexedMap (\index pattern -> ( TypedPath.Index index hint path, pattern )) patterns


{-| Returns the pattern of a constructor argument.
-}
dearg : Can.PatternCtorArg -> Can.Pattern
dearg (Can.PatternCtorArg _ _ pattern) =
    pattern



-- ====== GATHER OUTGOING EDGES ======


{-| Returns the edges of a node testing `path`, one per distinct test that rows
make there, each with the rows that can still match when that test succeeds,
together with the fallback rows.

The fallback rows are the rows that make no test at `path`, and there are none
when the tests are complete.

-}
gatherEdges : List Branch -> Path -> ( NE.Nonempty ( Test, NE.Nonempty Branch ), List Branch )
gatherEdges branches path =
    let
        relevantTests : NE.Nonempty Test
        relevantTests =
            testsAtPath path branches

        allEdges : NE.Nonempty ( Test, NE.Nonempty Branch )
        allEdges =
            NE.map (edgesFor path branches) relevantTests

        fallbacks : List Branch
        fallbacks =
            if isComplete relevantTests then
                []

            else
                List.filter (isIrrelevantTo path) branches
    in
    ( allEdges, fallbacks )



-- ====== FIND RELEVANT TESTS ======


{-| Returns the distinct tests that rows make at `selectedPath`, telling tests
apart by `Test.testToComparable`.
-}
testsAtPath : Path -> List Branch -> NE.Nonempty Test
testsAtPath selectedPath branches =
    let
        allTests : List Test
        allTests =
            List.filterMap (testAtPath selectedPath) branches

        skipVisited : Test -> ( List Test, EverySet.EverySet String Test ) -> ( List Test, EverySet.EverySet String Test )
        skipVisited test (( uniqueTests, visitedTests ) as curr) =
            if EverySet.member Test.testToComparable test visitedTests then
                curr

            else
                ( test :: uniqueTests
                , EverySet.insert Test.testToComparable test visitedTests
                )
    in
    case Tuple.first (List.foldr skipVisited ( [], EverySet.empty ) allTests) of
        test :: tests ->
            NE.Nonempty test tests

        [] ->
            crash "Typed.DecisionTree.testsAtPath: some branch tests the picked path"


{-| Returns the test a row makes at `selectedPath`, or `Nothing` when it has no
pattern there or its pattern there needs no test.
-}
testAtPath : Path -> Branch -> Maybe Test
testAtPath selectedPath (Branch _ pathPatterns) =
    Utils.listLookup selectedPath pathPatterns
        |> Maybe.andThen
            (\pattern ->
                case pattern of
                    FAnything ->
                        Nothing

                    FCtor home name index numAlts opts _ ->
                        Just (Test.IsCtor home name index numAlts opts)

                    FNil ->
                        Just Test.IsNil

                    FCons _ _ ->
                        Just Test.IsCons

                    FInt int ->
                        Just (Test.IsInt int)

                    FChr chr ->
                        Just (Test.IsChr chr)

                    FStr str ->
                        Just (Test.IsStr str)

                    FBool bool ->
                        Just (Test.IsBool bool)
            )



-- ====== BUILD EDGES ======


{-| Returns the edge for `test`: the test, and the rows that can still match
when it succeeds at `path`.
-}
edgesFor : Path -> List Branch -> Test -> ( Test, NE.Nonempty Branch )
edgesFor path branches test =
    case List.filterMap (toRelevantBranch test path) branches of
        b :: bs ->
            ( test, NE.Nonempty b bs )

        [] ->
            crash "Typed.DecisionTree.edgesFor: the branch that made the test passes it"


{-| Returns the row as it stands once `test` has succeeded at `path`, or
`Nothing` when the row's pattern there cannot match a value that passes.

A row whose pattern agrees with the test has that pattern replaced by its
flattened parts at sub-positions: a constructor's arguments, or a list's head
and tail. A literal, or an empty list under `IsNil`, that agrees is removed. A
row with no pattern at `path`, or one that needs no test there, is kept
unchanged.

-}
toRelevantBranch : Test -> Path -> Branch -> Maybe Branch
toRelevantBranch test path ((Branch goal pathPatterns) as branch) =
    case extract path pathPatterns of
        Found start pattern end ->
            let
                passWith : List ( Path, Can.Pattern ) -> Maybe Branch
                passWith parts =
                    Just (Branch goal (start ++ List.foldr flatten end parts))
            in
            case ( test, pattern ) of
                ( _, FAnything ) ->
                    Just branch

                ( Test.IsCtor _ testName _ _ _, FCtor _ name _ _ _ args ) ->
                    if name == testName then
                        passWith (subPositions (TypedPath.HintCustom name) path args)

                    else
                        Nothing

                ( Test.IsNil, FNil ) ->
                    passWith []

                ( Test.IsCons, FCons hd tl ) ->
                    passWith (subPositions TypedPath.HintList path [ hd, tl ])

                ( Test.IsChr testChr, FChr chr ) ->
                    if ES.valueKey chr == ES.valueKey testChr then
                        passWith []

                    else
                        Nothing

                ( Test.IsStr testStr, FStr str ) ->
                    if ES.valueKey str == ES.valueKey testStr then
                        passWith []

                    else
                        Nothing

                ( Test.IsInt testInt, FInt int ) ->
                    if int == testInt then
                        passWith []

                    else
                        Nothing

                ( Test.IsBool testBool, FBool bool ) ->
                    if bool == testBool then
                        passWith []

                    else
                        Nothing

                _ ->
                    Nothing

        NotFound ->
            Just branch


{-| The result of looking for a position in a row: the positions before it,
its pattern, and the positions after it, or `NotFound`.
-}
type Extract
    = NotFound
    | Found (List ( Path, FlatPattern )) FlatPattern (List ( Path, FlatPattern ))


{-| Finds the first entry for `selectedPath` in a row's positions.
-}
extract : Path -> List ( Path, FlatPattern ) -> Extract
extract selectedPath pathPatterns =
    case pathPatterns of
        [] ->
            NotFound

        (( path, pattern ) as first) :: rest ->
            if path == selectedPath then
                Found [] pattern rest

            else
                case extract selectedPath rest of
                    NotFound ->
                        NotFound

                    Found start foundPattern end ->
                        Found (first :: start) foundPattern end



-- ====== FIND IRRELEVANT BRANCHES ======


{-| Returns whether a row makes no test at `selectedPath`: it has no pattern
there, or one that needs no test.
-}
isIrrelevantTo : Path -> Branch -> Bool
isIrrelevantTo selectedPath (Branch _ pathPatterns) =
    case Utils.listLookup selectedPath pathPatterns of
        Nothing ->
            True

        Just pattern ->
            not (needsTests pattern)


{-| Returns whether matching the pattern needs a test: every `FlatPattern` but
`FAnything` does.
-}
needsTests : FlatPattern -> Bool
needsTests pattern =
    case pattern of
        FAnything ->
            False

        _ ->
            True



-- ====== PICK A PATH ======


{-| Chooses the position to test next among those where some row needs a test,
by the two heuristics the module docstring describes. Of positions still tied
after both, the one whose first occurrence in the rows comes first wins.
-}
pickPath : List Branch -> NE.Nonempty Path -> Path
pickPath branches allPaths =
    case bests (addWeights (smallDefaults branches) allPaths) of
        NE.Nonempty path [] ->
            path

        tiedPaths ->
            let
                (NE.Nonempty path _) =
                    bests (addWeights (smallBranchingFactor branches) tiedPaths)
            in
            path


{-| Returns the position when its pattern needs a test.
-}
isChoicePath : ( Path, FlatPattern ) -> Maybe Path
isChoicePath ( path, pattern ) =
    if needsTests pattern then
        Just path

    else
        Nothing


{-| Pairs each path with its weight.
-}
addWeights : (Path -> Int) -> NE.Nonempty Path -> NE.Nonempty ( Path, Int )
addWeights toWeight paths =
    NE.map (\path -> ( path, toWeight path )) paths


{-| Returns the paths of least weight, in reverse order of the list given.
-}
bests : NE.Nonempty ( Path, Int ) -> NE.Nonempty Path
bests (NE.Nonempty ( headPath, headWeight ) weightedPaths) =
    let
        gatherMinimum : ( a, comparable ) -> ( comparable, NE.Nonempty a ) -> ( comparable, NE.Nonempty a )
        gatherMinimum ( path, weight ) (( minWeight, NE.Nonempty p ps ) as acc) =
            if weight == minWeight then
                ( minWeight, NE.Nonempty path (p :: ps) )

            else if weight < minWeight then
                ( weight, NE.singleton path )

            else
                acc
    in
    Tuple.second (List.foldl gatherMinimum ( headWeight, NE.singleton headPath ) weightedPaths)



-- ====== PATH PICKING HEURISTICS ======


{-| Returns how many rows make no test at `path`, the weight for the first
heuristic.
-}
smallDefaults : List Branch -> Path -> Int
smallDefaults branches path =
    List.length (List.filter (isIrrelevantTo path) branches)


{-| Returns how many edges a node testing `path` would have, counting a fallback
as one, the weight for the second heuristic.
-}
smallBranchingFactor : List Branch -> Path -> Int
smallBranchingFactor branches path =
    let
        ( edges, fallback ) =
            gatherEdges branches path
    in
    List.length (NE.toList edges)
        + (if List.isEmpty fallback then
            0

           else
            1
          )
