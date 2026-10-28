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
`Compiler.AST.DecisionTree.TypedPath` and `Compiler.AST.DecisionTree.Test`.

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

import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.Test as Test
import Compiler.AST.DecisionTree.TypedPath as TypedPath
import Compiler.Data.Index as Index
import Compiler.Elm.String as ES
import Compiler.Reporting.Annotation as A
import Data.Set as EverySet
import Prelude
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- ====== COMPILE CASES ======


{-| Builds the decision tree for the `case` branches given as patterns, each
paired with the number its `Match` leaves are to carry.

Branches are tried in the order given: where several match the same value,
the leaf names the earliest. A branch may be named by several leaves, or by
none. Patterns are assumed to have passed the exhaustiveness check, since a
missing case can lead to a node with no fallback.

-}
compile : List ( Can.Pattern, Int ) -> DecisionTree
compile rawBranches =
    let
        format : ( Can.Pattern, Int ) -> Branch
        format ( pattern, index ) =
            Branch index [ ( TypedPath.Empty, pattern ) ]
    in
    toDecisionTree (List.map format rawBranches)



-- ====== DECISION TREES ======


{-| A plan for finding which `case` branch matches a value, made of tests on
parts of that value.

`Match` is a leaf, and carries the number that `compile` was given with the
matching branch's pattern.

`Decision` tests the value at its path. Each edge pairs a test with the tree
to follow when the test succeeds. The optional tree is the fallback, followed
when no edge's test succeeds. It is `Nothing` when the edges' tests cover
every value that can be at the path (every constructor of the type, both
`Bool`s, both an empty and a non-empty list, or a tuple test), and when no
branch could match without one of the edges' tests succeeding. A node whose
one edge would have no fallback is not built: the edge's tree stands in its
place, so its test is never made.

-}
type DecisionTree
    = Match Int
    | Decision Path (List ( Test, DecisionTree )) (Maybe DecisionTree)


{-| A question a `Decision` node asks about the value at its path. This is
another name for `Compiler.AST.DecisionTree.Test.Test`, which describes it.
-}
type alias Test =
    Test.Test


{-| The kind of container a path step takes a field from. This is another
name for `Compiler.AST.DecisionTree.TypedPath.ContainerHint`, which describes
it.
-}
type alias ContainerHint =
    TypedPath.ContainerHint


{-| A position in the scrutinee, as the steps that reach it. This is another
name for `Compiler.AST.DecisionTree.TypedPath.Path`, which describes it.
-}
type alias Path =
    TypedPath.Path



-- ====== ACTUALLY BUILD DECISION TREES ======


{-| One row: a `case` branch's number, and the positions it still has to
check, each with the pattern expected there.
-}
type Branch
    = Branch Int (List ( Path, Can.Pattern ))


{-| Builds the decision tree for the rows, earliest row first, as the module
docstring describes.
-}
toDecisionTree : List Branch -> DecisionTree
toDecisionTree rawBranches =
    let
        branches : List Branch
        branches =
            List.map flattenPatterns rawBranches
    in
    case checkForMatch branches of
        Just goal ->
            Match goal

        Nothing ->
            let
                path : Path
                path =
                    pickPath branches

                ( edges, fallback ) =
                    gatherEdges branches path

                decisionEdges : List ( Test, DecisionTree )
                decisionEdges =
                    List.map (Tuple.mapSecond toDecisionTree) edges
            in
            case ( decisionEdges, fallback ) of
                ( [ ( _, decisionTree ) ], [] ) ->
                    decisionTree

                ( _, [] ) ->
                    Decision path decisionEdges Nothing

                ( [], _ :: _ ) ->
                    toDecisionTree fallback

                _ ->
                    Decision path decisionEdges (Just (toDecisionTree fallback))


{-| Returns whether the tests, all made at one position and with no duplicates,
cover every value that can be there, so that no fallback is needed.

The kind of test is read from the first one, which must exist. Tests of `Int`,
`Char` or `String` literals are never complete, and a tuple test always is.

-}
isComplete : List Test -> Bool
isComplete tests =
    case Prelude.head tests of
        Test.IsCtor _ _ _ numAlts _ ->
            numAlts == List.length tests

        Test.IsCons ->
            List.length tests == 2

        Test.IsNil ->
            List.length tests == 2

        Test.IsTuple ->
            True

        Test.IsInt _ ->
            False

        Test.IsChr _ ->
            False

        Test.IsStr _ ->
            False

        Test.IsBool _ ->
            List.length tests == 2



-- ====== FLATTEN PATTERNS ======


{-| Returns the row with every pattern whose shape the type already fixes
expanded, as `flatten` does.
-}
flattenPatterns : Branch -> Branch
flattenPatterns (Branch goal pathPatterns) =
    Branch goal (List.foldr flatten [] pathPatterns)


{-| Puts a position and its pattern in front of the other positions, first
expanding any pattern whose shape the type already fixes.

A tuple, or a constructor of a type with one constructor, is replaced by its
parts at sub-positions. A one-constructor type is expanded this way whatever
its `Can.CtorOpts`: a single argument is taken with `Unbox`, several with
`Index` steps. An alias pattern becomes its inner pattern and a variable
pattern for the alias name at the same position. Unit is dropped. Every
other pattern is kept as it is.

-}
flatten : ( Path, Can.Pattern ) -> List ( Path, Can.Pattern ) -> List ( Path, Can.Pattern )
flatten (( path, A.At region patternInfo ) as pathPattern) otherPathPatterns =
    case patternInfo.node of
        Can.PVar _ ->
            pathPattern :: otherPathPatterns

        Can.PAnything ->
            pathPattern :: otherPathPatterns

        Can.PCtor { union, name, args } ->
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
                pathPattern :: otherPathPatterns

        Can.PTuple a b cs ->
            let
                all =
                    a :: b :: cs

                len =
                    List.length all

                hint =
                    case len of
                        2 ->
                            TypedPath.HintTuple2

                        3 ->
                            TypedPath.HintTuple3

                        _ ->
                            -- A tuple of more than three; canonicalization rejects these.
                            TypedPath.HintCustom ""
            in
            all
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

        Can.PAlias realPattern alias ->
            flatten ( path, realPattern ) <|
                ( path, A.At region { id = -1, node = Can.PVar alias } )
                    :: otherPathPatterns

        Can.PRecord _ ->
            pathPattern :: otherPathPatterns

        Can.PList _ ->
            pathPattern :: otherPathPatterns

        Can.PCons _ _ ->
            pathPattern :: otherPathPatterns

        Can.PChr _ ->
            pathPattern :: otherPathPatterns

        Can.PStr _ _ ->
            pathPattern :: otherPathPatterns

        Can.PInt _ ->
            pathPattern :: otherPathPatterns

        Can.PBool _ _ ->
            pathPattern :: otherPathPatterns


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



-- ====== SUCCESSFULLY MATCH ======


{-| Returns the number of the first row when none of its remaining patterns
needs a test, and `Nothing` otherwise or when there are no rows.
-}
checkForMatch : List Branch -> Maybe Int
checkForMatch branches =
    case branches of
        (Branch goal patterns) :: _ ->
            if List.all (Tuple.second >> needsTests >> not) patterns then
                Just goal

            else
                Nothing

        _ ->
            Nothing



-- ====== GATHER OUTGOING EDGES ======


{-| Returns the edges of a node testing `path`, one per distinct test that rows
make there, each with the rows that can still match when that test succeeds,
together with the fallback rows.

The fallback rows are the rows that make no test at `path`, and there are none
when the tests are complete.

-}
gatherEdges : List Branch -> Path -> ( List ( Test, List Branch ), List Branch )
gatherEdges branches path =
    let
        relevantTests : List Test
        relevantTests =
            testsAtPath path branches

        allEdges : List ( Test, List Branch )
        allEdges =
            List.map (edgesFor path branches) relevantTests

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
testsAtPath : Path -> List Branch -> List Test
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
    Tuple.first (List.foldr skipVisited ( [], EverySet.empty ) allTests)


{-| Returns the test a row makes at `selectedPath`, or `Nothing` when it has no
pattern there or its pattern there is a variable, a wildcard or a record.

A tuple or unit pattern gives `IsTuple`. An alias pattern crashes, since
`flatten` has removed every alias.

-}
testAtPath : Path -> Branch -> Maybe Test
testAtPath selectedPath (Branch _ pathPatterns) =
    Utils.listLookup selectedPath pathPatterns
        |> Maybe.andThen
            (\(A.At _ patternInfo) ->
                case patternInfo.node of
                    Can.PCtor { home, union, name, index } ->
                        let
                            (Can.Union unionData) =
                                union
                        in
                        Just (Test.IsCtor home name index unionData.numAlts unionData.opts)

                    Can.PList ps ->
                        Just
                            (case ps of
                                [] ->
                                    Test.IsNil

                                _ ->
                                    Test.IsCons
                            )

                    Can.PCons _ _ ->
                        Just Test.IsCons

                    Can.PTuple _ _ _ ->
                        Just Test.IsTuple

                    Can.PUnit ->
                        Just Test.IsTuple

                    Can.PVar _ ->
                        Nothing

                    Can.PAnything ->
                        Nothing

                    Can.PInt int ->
                        Just (Test.IsInt int)

                    Can.PStr str _ ->
                        Just (Test.IsStr str)

                    Can.PChr chr ->
                        Just (Test.IsChr chr)

                    Can.PBool _ bool ->
                        Just (Test.IsBool bool)

                    Can.PRecord _ ->
                        Nothing

                    Can.PAlias _ _ ->
                        crash "aliases should never reach 'testAtPath' function"
            )



-- ====== BUILD EDGES ======


{-| Returns the edge for `test`: the test, and the rows that can still match
when it succeeds at `path`.
-}
edgesFor : Path -> List Branch -> Test -> ( Test, List Branch )
edgesFor path branches test =
    ( test
    , List.filterMap (toRelevantBranch test path) branches
    )


{-| Returns the row as it stands once `test` has succeeded at `path`, or
`Nothing` when the row's pattern there cannot match a value that passes.

A row whose pattern agrees with the test has that pattern replaced by its
parts at sub-positions: a constructor's arguments, or a list's head and tail.
A literal, or an empty list under `IsNil`, that agrees is removed. Whatever
the test, a unit pattern is removed and a tuple is replaced by its elements.
A row with no pattern at `path`, or with a variable, wildcard, record or
alias pattern there, is kept unchanged.

-}
toRelevantBranch : Test -> Path -> Branch -> Maybe Branch
toRelevantBranch test path ((Branch goal pathPatterns) as branch) =
    case extract path pathPatterns of
        Found start (A.At region patternInfo) end ->
            case patternInfo.node of
                Can.PCtor { union, name, args } ->
                    case test of
                        Test.IsCtor _ testName _ _ _ ->
                            if name == testName then
                                Just
                                    (Branch goal <|
                                        case List.map dearg args of
                                            (arg :: []) as args_ ->
                                                let
                                                    (Can.Union unionData) =
                                                        union
                                                in
                                                if unionData.numAlts == 1 then
                                                    start ++ (( TypedPath.Unbox path, arg ) :: end)

                                                else
                                                    start ++ subPositions (TypedPath.HintCustom name) path args_ ++ end

                                            args_ ->
                                                start ++ subPositions (TypedPath.HintCustom name) path args_ ++ end
                                    )

                            else
                                Nothing

                        _ ->
                            Nothing

                Can.PList [] ->
                    case test of
                        Test.IsNil ->
                            Just (Branch goal (start ++ end))

                        _ ->
                            Nothing

                Can.PList (hd :: tl) ->
                    case test of
                        Test.IsCons ->
                            let
                                -- The tail pattern is synthesized, so it has no real id.
                                tl_ : Can.Pattern
                                tl_ =
                                    A.At region { id = -1, node = Can.PList tl }
                            in
                            Just (Branch goal (start ++ subPositions TypedPath.HintList path [ hd, tl_ ] ++ end))

                        _ ->
                            Nothing

                Can.PCons hd tl ->
                    case test of
                        Test.IsCons ->
                            Just (Branch goal (start ++ subPositions TypedPath.HintList path [ hd, tl ] ++ end))

                        _ ->
                            Nothing

                Can.PChr chr ->
                    case test of
                        Test.IsChr testChr ->
                            if ES.valueKey chr == ES.valueKey testChr then
                                Just (Branch goal (start ++ end))

                            else
                                Nothing

                        _ ->
                            Nothing

                Can.PStr str _ ->
                    case test of
                        Test.IsStr testStr ->
                            if ES.valueKey str == ES.valueKey testStr then
                                Just (Branch goal (start ++ end))

                            else
                                Nothing

                        _ ->
                            Nothing

                Can.PInt int ->
                    case test of
                        Test.IsInt testInt ->
                            if int == testInt then
                                Just (Branch goal (start ++ end))

                            else
                                Nothing

                        _ ->
                            Nothing

                Can.PBool _ bool ->
                    case test of
                        Test.IsBool testBool ->
                            if bool == testBool then
                                Just (Branch goal (start ++ end))

                            else
                                Nothing

                        _ ->
                            Nothing

                Can.PUnit ->
                    Just (Branch goal (start ++ end))

                Can.PTuple a b cs ->
                    let
                        all =
                            a :: b :: cs

                        len =
                            List.length all

                        hint =
                            case len of
                                2 ->
                                    TypedPath.HintTuple2

                                3 ->
                                    TypedPath.HintTuple3

                                _ ->
                                    -- A tuple of more than three; canonicalization rejects these.
                                    TypedPath.HintCustom ""
                    in
                    Just
                        (Branch goal
                            (start
                                ++ subPositions hint path all
                                ++ end
                            )
                        )

                Can.PVar _ ->
                    Just branch

                Can.PAnything ->
                    Just branch

                Can.PRecord _ ->
                    Just branch

                Can.PAlias _ _ ->
                    Just branch

        NotFound ->
            Just branch


{-| The result of looking for a position in a row: the positions before it,
its pattern, and the positions after it, or `NotFound`.
-}
type Extract
    = NotFound
    | Found (List ( Path, Can.Pattern )) Can.Pattern (List ( Path, Can.Pattern ))


{-| Finds the first entry for `selectedPath` in a row's positions.
-}
extract : Path -> List ( Path, Can.Pattern ) -> Extract
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


{-| Returns whether matching the pattern needs a test. Variables, wildcards and
record patterns do not. An alias pattern crashes, since `flatten` has removed
every alias.
-}
needsTests : Can.Pattern -> Bool
needsTests (A.At _ patternInfo) =
    case patternInfo.node of
        Can.PVar _ ->
            False

        Can.PAnything ->
            False

        Can.PRecord _ ->
            False

        Can.PCtor _ ->
            True

        Can.PList _ ->
            True

        Can.PCons _ _ ->
            True

        Can.PUnit ->
            True

        Can.PTuple _ _ _ ->
            True

        Can.PChr _ ->
            True

        Can.PStr _ _ ->
            True

        Can.PInt _ ->
            True

        Can.PBool _ _ ->
            True

        Can.PAlias _ _ ->
            crash "aliases should never reach 'isIrrelevantTo' function"



-- ====== PICK A PATH ======


{-| Chooses the position to test next among those where some row needs a test,
by the two heuristics the module docstring describes. Of positions still tied
after both, the one whose first occurrence in the rows comes first wins.
-}
pickPath : List Branch -> Path
pickPath branches =
    let
        allPaths : List Path
        allPaths =
            List.filterMap isChoicePath (List.concatMap (\(Branch _ patterns) -> patterns) branches)
    in
    case bests (addWeights (smallDefaults branches) allPaths) of
        [ path ] ->
            path

        tiedPaths ->
            Prelude.head (bests (addWeights (smallBranchingFactor branches) tiedPaths))


{-| Returns the position when its pattern needs a test.
-}
isChoicePath : ( Path, Can.Pattern ) -> Maybe Path
isChoicePath ( path, pattern ) =
    if needsTests pattern then
        Just path

    else
        Nothing


{-| Pairs each path with its weight.
-}
addWeights : (Path -> Int) -> List Path -> List ( Path, Int )
addWeights toWeight paths =
    List.map (\path -> ( path, toWeight path )) paths


{-| Returns the paths of least weight, in reverse order of the list given.
Crashes on an empty list.
-}
bests : List ( Path, Int ) -> List Path
bests allPaths =
    case allPaths of
        [] ->
            crash "Cannot choose the best of zero paths. This should never happen."

        ( headPath, headWeight ) :: weightedPaths ->
            let
                gatherMinimum : ( a, comparable ) -> ( comparable, List a ) -> ( comparable, List a )
                gatherMinimum ( path, weight ) (( minWeight, paths ) as acc) =
                    if weight == minWeight then
                        ( minWeight, path :: paths )

                    else if weight < minWeight then
                        ( weight, [ path ] )

                    else
                        acc
            in
            Tuple.second (List.foldl gatherMinimum ( headWeight, [ headPath ] ) weightedPaths)



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
    List.length edges
        + (if List.isEmpty fallback then
            0

           else
            1
          )
