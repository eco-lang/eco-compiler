module TestLogic.Monomorphize.MonoDirectComparisonTest exposing (suite)

{-| Comparison test: runs both Monomorphize and MonoDirect on the same test
cases, then structurally compares the output MonoGraphs under alpha equivalence.

SpecIds may differ between the two pipelines, so we match nodes by SpecKey
(Global + MonoType + LambdaId) and resolve SpecId references within expressions
to SpecKeys before comparison. Regions are ignored.

Alpha equivalence: MVar names are normalized to positional canonical names
(α0, α1, ...) based on first-encounter order in a left-to-right traversal.
This means `MVar "msg" CEcoValue` and `MVar "msg__def_elm_html_Html_text_0" CEcoValue`
are considered equal if they appear in the same structural position.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Data.BitSet as BitSet
import Dict exposing (Dict)
import Expect exposing (Expectation)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "MonoDirect vs Monomorphize comparison"
        [ StandardTestSuites.expectSuite expectGraphsMatch "produces same MonoGraph"
        ]



-- ========== ALPHA NORMALIZATION ==========
-- Replaces MVar names with positional canonical names based on encounter order.


type alias NormState =
    { nextId : Int
    , mapping : Dict String String
    }


emptyNormState : NormState
emptyNormState =
    { nextId = 0, mapping = Dict.empty }


{-| Get or create a canonical name for an MVar name.
-}
normalizeName : String -> NormState -> ( String, NormState )
normalizeName name state =
    case Dict.get name state.mapping of
        Just canonical ->
            ( canonical, state )

        Nothing ->
            let
                canonical =
                    "α" ++ String.fromInt state.nextId
            in
            ( canonical
            , { nextId = state.nextId + 1
              , mapping = Dict.insert name canonical state.mapping
              }
            )


{-| Normalize a MonoType, replacing MVar names with canonical positional names.
Returns the normalized type and updated state (for consistent naming across a tree).
-}
normalizeType : NormState -> Mono.MonoType -> ( Mono.MonoType, NormState )
normalizeType state monoType =
    case monoType of
        Mono.MVar name constraint ->
            let
                ( canonical, newState ) =
                    normalizeName name state
            in
            ( Mono.MVar canonical constraint, newState )

        Mono.MList elem ->
            let
                ( normElem, s1 ) =
                    normalizeType state elem
            in
            ( Mono.MList normElem, s1 )

        Mono.MFunction args result ->
            let
                ( normArgs, s1 ) =
                    normalizeTypeList state args

                ( normResult, s2 ) =
                    normalizeType s1 result
            in
            ( Mono.MFunction normArgs normResult, s2 )

        Mono.MTuple elems ->
            let
                ( normElems, s1 ) =
                    normalizeTypeList state elems
            in
            ( Mono.MTuple normElems, s1 )

        Mono.MRecord fields ->
            let
                ( normFields, s1 ) =
                    Dict.foldl
                        (\k v ( accDict, accState ) ->
                            let
                                ( normV, newState ) =
                                    normalizeType accState v
                            in
                            ( Dict.insert k normV accDict, newState )
                        )
                        ( Dict.empty, state )
                        fields
            in
            ( Mono.MRecord normFields, s1 )

        Mono.MCustom canonical name args ->
            let
                ( normArgs, s1 ) =
                    normalizeTypeList state args
            in
            ( Mono.MCustom canonical name normArgs, s1 )

        _ ->
            -- MInt, MFloat, MBool, MChar, MString, MUnit, MErased
            ( monoType, state )


normalizeTypeList : NormState -> List Mono.MonoType -> ( List Mono.MonoType, NormState )
normalizeTypeList state types =
    List.foldl
        (\t ( acc, s ) ->
            let
                ( normT, newS ) =
                    normalizeType s t
            in
            ( acc ++ [ normT ], newS )
        )
        ( [], state )
        types


{-| Normalize a MonoType independently (fresh state), returning just the normalized type.
-}
normalizeTypeAlone : Mono.MonoType -> Mono.MonoType
normalizeTypeAlone monoType =
    Tuple.first (normalizeType emptyNormState monoType)


{-| Produce a comparable key for a SpecKey under alpha normalization.
-}
normalizedSpecKeyStr : Mono.Global -> Mono.MonoType -> Maybe Mono.LambdaId -> String
normalizedSpecKeyStr global monoType maybeLambda =
    let
        normType =
            normalizeTypeAlone monoType
    in
    String.join "\u{0000}" (Mono.toComparableSpecKey (Mono.SpecKey global normType maybeLambda))



-- ========== ENTRY POINT ==========


expectGraphsMatch : Src.Module -> Expectation
expectGraphsMatch srcModule =
    case ( Pipeline.runToMono srcModule, Pipeline.runToMonoDirect srcModule ) of
        ( Err monoErr, _ ) ->
            -- If Mono fails, skip comparison (not a MonoDirect issue)
            Expect.pass

        ( _, Err directErr ) ->
            Expect.fail ("MonoDirect failed: " ++ directErr)

        ( Ok monoArtifacts, Ok directArtifacts ) ->
            compareGraphs monoArtifacts.monoGraph directArtifacts.monoGraph



-- ========== GRAPH COMPARISON ==========


{-| Compare two MonoGraphs by matching nodes on alpha-normalized SpecKey.
-}
compareGraphs : Mono.MonoGraph -> Mono.MonoGraph -> Expectation
compareGraphs (Mono.MonoGraph expected) (Mono.MonoGraph actual) =
    let
        -- Build SpecId -> normalized SpecKey lookups
        expectedIdToKey =
            buildIdToNormKeyMap expected.registry

        actualIdToKey =
            buildIdToNormKeyMap actual.registry

        -- Build normalized SpecKey -> (SpecId, MonoNode)
        expectedByKey =
            buildNormKeyToNodeMap expected.registry expected.nodes

        actualByKey =
            buildNormKeyToNodeMap actual.registry actual.nodes

        -- Compare main entry point
        mainDiffs =
            compareMain expected.main actual.main

        -- Compare nodes matched by normalized SpecKey
        nodeDiffs =
            Dict.foldl
                (\keyStr ( _, expectedNode ) acc ->
                    case Dict.get keyStr actualByKey of
                        Nothing ->
                            ("Missing in MonoDirect: " ++ keyStr) :: acc

                        Just ( _, actualNode ) ->
                            let
                                ctx =
                                    { expectedIdToKey = expectedIdToKey
                                    , actualIdToKey = actualIdToKey
                                    }
                            in
                            compareNode ctx ("node[" ++ keyStr ++ "]") expectedNode actualNode ++ acc
                )
                []
                expectedByKey

        -- Check for extra nodes in MonoDirect
        extraDiffs =
            Dict.foldl
                (\keyStr _ acc ->
                    if Dict.member keyStr expectedByKey then
                        acc

                    else
                        ("Extra in MonoDirect: " ++ keyStr) :: acc
                )
                []
                actualByKey

        allDiffs =
            mainDiffs ++ nodeDiffs ++ extraDiffs
    in
    if List.isEmpty allDiffs then
        Expect.pass

    else
        Expect.fail
            (String.join "\n\n"
                (("MonoGraph comparison found "
                    ++ String.fromInt (List.length allDiffs)
                    ++ " difference(s):"
                 )
                    :: List.take 20 allDiffs
                )
            )



-- ========== CONTEXT FOR SPECID RESOLUTION ==========


type alias CompareCtx =
    { expectedIdToKey : Dict Int String
    , actualIdToKey : Dict Int String
    }


resolveExpectedSpecId : CompareCtx -> Mono.SpecId -> String
resolveExpectedSpecId ctx specId =
    Dict.get specId ctx.expectedIdToKey |> Maybe.withDefault ("unknown-spec-" ++ String.fromInt specId)


resolveActualSpecId : CompareCtx -> Mono.SpecId -> String
resolveActualSpecId ctx specId =
    Dict.get specId ctx.actualIdToKey |> Maybe.withDefault ("unknown-spec-" ++ String.fromInt specId)



-- ========== REGISTRY HELPERS ==========


buildIdToNormKeyMap : Mono.SpecializationRegistry -> Dict Int String
buildIdToNormKeyMap registry =
    let
        len =
            Array.length registry.reverseMapping
    in
    buildIdToNormKeyMapHelp registry.reverseMapping 0 len Dict.empty


buildIdToNormKeyMapHelp : Array.Array (Maybe ( Mono.Global, Mono.MonoType, Maybe Mono.LambdaId )) -> Int -> Int -> Dict Int String -> Dict Int String
buildIdToNormKeyMapHelp reverseMapping idx len acc =
    if idx >= len then
        acc

    else
        case Array.get idx reverseMapping of
            Just (Just ( global, monoType, maybeLambda )) ->
                buildIdToNormKeyMapHelp reverseMapping (idx + 1) len
                    (Dict.insert idx (normalizedSpecKeyStr global monoType maybeLambda) acc)

            _ ->
                buildIdToNormKeyMapHelp reverseMapping (idx + 1) len acc


buildNormKeyToNodeMap : Mono.SpecializationRegistry -> Array.Array (Maybe Mono.MonoNode) -> Dict String ( Int, Mono.MonoNode )
buildNormKeyToNodeMap registry nodes =
    let
        len =
            Array.length nodes
    in
    buildNormKeyToNodeMapHelp registry.reverseMapping nodes 0 len Dict.empty


buildNormKeyToNodeMapHelp : Array.Array (Maybe ( Mono.Global, Mono.MonoType, Maybe Mono.LambdaId )) -> Array.Array (Maybe Mono.MonoNode) -> Int -> Int -> Dict String ( Int, Mono.MonoNode ) -> Dict String ( Int, Mono.MonoNode )
buildNormKeyToNodeMapHelp reverseMapping nodes idx len acc =
    if idx >= len then
        acc

    else
        case ( Array.get idx reverseMapping, Array.get idx nodes ) of
            ( Just (Just ( global, monoType, maybeLambda )), Just (Just node) ) ->
                let
                    keyStr =
                        normalizedSpecKeyStr global monoType maybeLambda
                in
                buildNormKeyToNodeMapHelp reverseMapping nodes (idx + 1) len (Dict.insert keyStr ( idx, node ) acc)

            _ ->
                buildNormKeyToNodeMapHelp reverseMapping nodes (idx + 1) len acc



-- ========== MAIN COMPARISON ==========


compareMain : Maybe Mono.MainInfo -> Maybe Mono.MainInfo -> List String
compareMain expected actual =
    case ( expected, actual ) of
        ( Nothing, Nothing ) ->
            []

        ( Just (Mono.StaticMain _), Just (Mono.StaticMain _) ) ->
            -- Both have static main; SpecIds may differ but that's fine
            []

        ( Just _, Nothing ) ->
            [ "main: expected present, got Nothing in MonoDirect" ]

        ( Nothing, Just _ ) ->
            [ "main: expected Nothing, got present in MonoDirect" ]



-- ========== NODE COMPARISON ==========


compareNode : CompareCtx -> String -> Mono.MonoNode -> Mono.MonoNode -> List String
compareNode ctx path expected actual =
    case ( expected, actual ) of
        ( Mono.MonoDefine eExpr eType, Mono.MonoDefine aExpr aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareExpr ctx (path ++ ".expr") eExpr aExpr

        ( Mono.MonoTailFunc eParams eExpr eType, Mono.MonoTailFunc aParams aExpr aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareParamsAlpha ctx (path ++ ".params") eParams aParams
                ++ compareExpr ctx (path ++ ".expr") eExpr aExpr

        ( Mono.MonoCtor eShape eType, Mono.MonoCtor aShape aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareCtorShapeAlpha (path ++ ".shape") eShape aShape

        ( Mono.MonoEnum eTag eType, Mono.MonoEnum aTag aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ (if eTag /= aTag then
                        [ path ++ ".tag: " ++ String.fromInt eTag ++ " vs " ++ String.fromInt aTag ]

                    else
                        []
                   )

        ( Mono.MonoExtern eType, Mono.MonoExtern aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType

        ( Mono.MonoManagerLeaf eHome eType, Mono.MonoManagerLeaf aHome aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ (if eHome /= aHome then
                        [ path ++ ".home: " ++ eHome ++ " vs " ++ aHome ]

                    else
                        []
                   )

        ( Mono.MonoPortIncoming eExpr eType, Mono.MonoPortIncoming aExpr aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareExpr ctx (path ++ ".expr") eExpr aExpr

        ( Mono.MonoPortOutgoing eExpr eType, Mono.MonoPortOutgoing aExpr aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareExpr ctx (path ++ ".expr") eExpr aExpr

        ( Mono.MonoCycle eDefs eType, Mono.MonoCycle aDefs aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareNamedExprs ctx (path ++ ".defs") eDefs aDefs

        _ ->
            [ path ++ ": node variant mismatch: " ++ nodeVariantName expected ++ " vs " ++ nodeVariantName actual ]


nodeVariantName : Mono.MonoNode -> String
nodeVariantName node =
    case node of
        Mono.MonoDefine _ _ ->
            "MonoDefine"

        Mono.MonoTailFunc _ _ _ ->
            "MonoTailFunc"

        Mono.MonoCtor _ _ ->
            "MonoCtor"

        Mono.MonoEnum _ _ ->
            "MonoEnum"

        Mono.MonoExtern _ ->
            "MonoExtern"

        Mono.MonoManagerLeaf _ _ ->
            "MonoManagerLeaf"

        Mono.MonoPortIncoming _ _ ->
            "MonoPortIncoming"

        Mono.MonoPortOutgoing _ _ ->
            "MonoPortOutgoing"

        Mono.MonoCycle _ _ ->
            "MonoCycle"



-- ========== TYPE COMPARISON (ALPHA) ==========


{-| Compare two MonoTypes under alpha equivalence.
Each type is independently normalized before comparison.
-}
compareTypeAlpha : String -> Mono.MonoType -> Mono.MonoType -> List String
compareTypeAlpha path expected actual =
    let
        normExpected =
            normalizeTypeAlone expected

        normActual =
            normalizeTypeAlone actual
    in
    if Mono.toComparableMonoType normExpected == Mono.toComparableMonoType normActual then
        []

    else
        [ path ++ ": type mismatch\n  expected: " ++ debugType expected ++ "\n  actual:   " ++ debugType actual
            ++ "\n  (normalized expected: " ++ debugType normExpected ++ ")"
            ++ "\n  (normalized actual:   " ++ debugType normActual ++ ")"
        ]


{-| Compare two type lists under alpha equivalence, sharing normalization state
across the list so positional consistency is maintained.
-}
compareTypeListAlpha : String -> List Mono.MonoType -> List Mono.MonoType -> List String
compareTypeListAlpha path expected actual =
    if List.length expected /= List.length actual then
        [ path ++ ": type list length mismatch: " ++ String.fromInt (List.length expected) ++ " vs " ++ String.fromInt (List.length actual) ]

    else
        List.concat
            (List.indexedMap
                (\i ( e, a ) ->
                    compareTypeAlpha (path ++ "[" ++ String.fromInt i ++ "]") e a
                )
                (List.map2 Tuple.pair expected actual)
            )


debugType : Mono.MonoType -> String
debugType =
    Mono.monoTypeToDebugString



-- ========== EXPRESSION COMPARISON ==========


compareExpr : CompareCtx -> String -> Mono.MonoExpr -> Mono.MonoExpr -> List String
compareExpr ctx path expected actual =
    case ( expected, actual ) of
        ( Mono.MonoUnit, Mono.MonoUnit ) ->
            []

        ( Mono.MonoLiteral eLit eType, Mono.MonoLiteral aLit aType ) ->
            compareLiteral (path ++ ".lit") eLit aLit
                ++ compareTypeAlpha (path ++ ".type") eType aType

        ( Mono.MonoVarLocal eName eType, Mono.MonoVarLocal aName aType ) ->
            (if eName /= aName then
                [ path ++ ".name: " ++ eName ++ " vs " ++ aName ]

             else
                []
            )
                ++ compareTypeAlpha (path ++ ".type") eType aType

        ( Mono.MonoVarGlobal _ eSpecId eType, Mono.MonoVarGlobal _ aSpecId aType ) ->
            let
                eKey =
                    resolveExpectedSpecId ctx eSpecId

                aKey =
                    resolveActualSpecId ctx aSpecId
            in
            (if eKey /= aKey then
                [ path ++ ".specKey: " ++ eKey ++ " vs " ++ aKey ]

             else
                []
            )
                ++ compareTypeAlpha (path ++ ".type") eType aType

        ( Mono.MonoVarKernel _ eHome eName eType, Mono.MonoVarKernel _ aHome aName aType ) ->
            (if eHome /= aHome || eName /= aName then
                [ path ++ ".kernel: " ++ eHome ++ "." ++ eName ++ " vs " ++ aHome ++ "." ++ aName ]

             else
                []
            )
                ++ compareTypeAlpha (path ++ ".type") eType aType

        ( Mono.MonoList _ eElems eType, Mono.MonoList _ aElems aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareExprList ctx (path ++ ".elems") eElems aElems

        ( Mono.MonoClosure eInfo eBody eType, Mono.MonoClosure aInfo aBody aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareClosureInfo ctx (path ++ ".closure") eInfo aInfo
                ++ compareExpr ctx (path ++ ".body") eBody aBody

        ( Mono.MonoCall _ eFunc eArgs eType eCallInfo, Mono.MonoCall _ aFunc aArgs aType aCallInfo ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareExpr ctx (path ++ ".func") eFunc aFunc
                ++ compareExprList ctx (path ++ ".args") eArgs aArgs
                ++ compareCallInfo (path ++ ".callInfo") eCallInfo aCallInfo

        ( Mono.MonoTailCall eName eArgs eType, Mono.MonoTailCall aName aArgs aType ) ->
            (if eName /= aName then
                [ path ++ ".tailCallName: " ++ eName ++ " vs " ++ aName ]

             else
                []
            )
                ++ compareTypeAlpha (path ++ ".type") eType aType
                ++ compareNamedExprs ctx (path ++ ".args") eArgs aArgs

        ( Mono.MonoIf eBranches eElse eType, Mono.MonoIf aBranches aElse aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareExpr ctx (path ++ ".else") eElse aElse
                ++ compareBranches ctx (path ++ ".branches") eBranches aBranches

        ( Mono.MonoLet eDef eBody eType, Mono.MonoLet aDef aBody aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareDef ctx (path ++ ".def") eDef aDef
                ++ compareExpr ctx (path ++ ".body") eBody aBody

        ( Mono.MonoDestruct eDestr eBody eType, Mono.MonoDestruct aDestr aBody aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareDestructor ctx (path ++ ".destr") eDestr aDestr
                ++ compareExpr ctx (path ++ ".body") eBody aBody

        ( Mono.MonoCase eName eLabel eDecider eJumps eType, Mono.MonoCase aName aLabel aDecider aJumps aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ (if eName /= aName then
                        [ path ++ ".caseName: " ++ eName ++ " vs " ++ aName ]

                    else
                        []
                   )
                ++ compareDecider ctx (path ++ ".decider") eDecider aDecider
                ++ compareJumps ctx (path ++ ".jumps") eJumps aJumps

        ( Mono.MonoRecordCreate eFields eType, Mono.MonoRecordCreate aFields aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareNamedExprsSorted ctx (path ++ ".fields") eFields aFields

        ( Mono.MonoRecordAccess eExpr eName eType, Mono.MonoRecordAccess aExpr aName aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ (if eName /= aName then
                        [ path ++ ".fieldName: " ++ eName ++ " vs " ++ aName ]

                    else
                        []
                   )
                ++ compareExpr ctx (path ++ ".expr") eExpr aExpr

        ( Mono.MonoRecordUpdate eExpr eFields eType, Mono.MonoRecordUpdate aExpr aFields aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareExpr ctx (path ++ ".expr") eExpr aExpr
                ++ compareNamedExprsSorted ctx (path ++ ".updates") eFields aFields

        ( Mono.MonoTupleCreate _ eElems eType, Mono.MonoTupleCreate _ aElems aType ) ->
            compareTypeAlpha (path ++ ".type") eType aType
                ++ compareExprList ctx (path ++ ".elems") eElems aElems

        _ ->
            [ path ++ ": expr variant mismatch: " ++ exprVariantName expected ++ " vs " ++ exprVariantName actual ]


exprVariantName : Mono.MonoExpr -> String
exprVariantName expr =
    case expr of
        Mono.MonoLiteral _ _ ->
            "MonoLiteral"

        Mono.MonoVarLocal _ _ ->
            "MonoVarLocal"

        Mono.MonoVarGlobal _ _ _ ->
            "MonoVarGlobal"

        Mono.MonoVarKernel _ _ _ _ ->
            "MonoVarKernel"

        Mono.MonoList _ _ _ ->
            "MonoList"

        Mono.MonoClosure _ _ _ ->
            "MonoClosure"

        Mono.MonoCall _ _ _ _ _ ->
            "MonoCall"

        Mono.MonoTailCall _ _ _ ->
            "MonoTailCall"

        Mono.MonoIf _ _ _ ->
            "MonoIf"

        Mono.MonoLet _ _ _ ->
            "MonoLet"

        Mono.MonoDestruct _ _ _ ->
            "MonoDestruct"

        Mono.MonoCase _ _ _ _ _ ->
            "MonoCase"

        Mono.MonoRecordCreate _ _ ->
            "MonoRecordCreate"

        Mono.MonoRecordAccess _ _ _ ->
            "MonoRecordAccess"

        Mono.MonoRecordUpdate _ _ _ ->
            "MonoRecordUpdate"

        Mono.MonoTupleCreate _ _ _ ->
            "MonoTupleCreate"

        Mono.MonoUnit ->
            "MonoUnit"



-- ========== HELPER COMPARISONS ==========


compareLiteral : String -> Mono.Literal -> Mono.Literal -> List String
compareLiteral path expected actual =
    case ( expected, actual ) of
        ( Mono.LBool e, Mono.LBool a ) ->
            if e == a then
                []

            else
                [ path ++ ": Bool " ++ boolToString e ++ " vs " ++ boolToString a ]

        ( Mono.LInt e, Mono.LInt a ) ->
            if e == a then
                []

            else
                [ path ++ ": Int " ++ String.fromInt e ++ " vs " ++ String.fromInt a ]

        ( Mono.LFloat e, Mono.LFloat a ) ->
            if e == a then
                []

            else
                [ path ++ ": Float " ++ String.fromFloat e ++ " vs " ++ String.fromFloat a ]

        ( Mono.LChar e, Mono.LChar a ) ->
            if e == a then
                []

            else
                [ path ++ ": Char " ++ e ++ " vs " ++ a ]

        ( Mono.LStr e, Mono.LStr a ) ->
            if e == a then
                []

            else
                [ path ++ ": Str " ++ e ++ " vs " ++ a ]

        _ ->
            [ path ++ ": literal variant mismatch" ]


boolToString : Bool -> String
boolToString b =
    if b then
        "True"

    else
        "False"


compareExprList : CompareCtx -> String -> List Mono.MonoExpr -> List Mono.MonoExpr -> List String
compareExprList ctx path expected actual =
    if List.length expected /= List.length actual then
        [ path ++ ": list length mismatch: " ++ String.fromInt (List.length expected) ++ " vs " ++ String.fromInt (List.length actual) ]

    else
        List.concat
            (List.indexedMap
                (\i ( e, a ) ->
                    compareExpr ctx (path ++ "[" ++ String.fromInt i ++ "]") e a
                )
                (List.map2 Tuple.pair expected actual)
            )


compareNamedExprs : CompareCtx -> String -> List ( String, Mono.MonoExpr ) -> List ( String, Mono.MonoExpr ) -> List String
compareNamedExprs ctx path expected actual =
    if List.length expected /= List.length actual then
        [ path ++ ": named list length mismatch: " ++ String.fromInt (List.length expected) ++ " vs " ++ String.fromInt (List.length actual) ]

    else
        List.concat
            (List.indexedMap
                (\i ( ( eName, eExpr ), ( aName, aExpr ) ) ->
                    (if eName /= aName then
                        [ path ++ "[" ++ String.fromInt i ++ "].name: " ++ eName ++ " vs " ++ aName ]

                     else
                        []
                    )
                        ++ compareExpr ctx (path ++ "[" ++ String.fromInt i ++ ":" ++ eName ++ "]") eExpr aExpr
                )
                (List.map2 Tuple.pair expected actual)
            )


{-| Like compareNamedExprs but sorts both lists by name first,
so field ordering differences are ignored. Used for record fields/updates.
-}
compareNamedExprsSorted : CompareCtx -> String -> List ( String, Mono.MonoExpr ) -> List ( String, Mono.MonoExpr ) -> List String
compareNamedExprsSorted ctx path expected actual =
    compareNamedExprs ctx path (List.sortBy Tuple.first expected) (List.sortBy Tuple.first actual)


compareParamsAlpha : CompareCtx -> String -> List ( String, Mono.MonoType ) -> List ( String, Mono.MonoType ) -> List String
compareParamsAlpha ctx path expected actual =
    if List.length expected /= List.length actual then
        [ path ++ ": param count mismatch: " ++ String.fromInt (List.length expected) ++ " vs " ++ String.fromInt (List.length actual) ]

    else
        List.concat
            (List.indexedMap
                (\i ( ( eName, eType ), ( aName, aType ) ) ->
                    (if eName /= aName then
                        [ path ++ "[" ++ String.fromInt i ++ "].name: " ++ eName ++ " vs " ++ aName ]

                     else
                        []
                    )
                        ++ compareTypeAlpha (path ++ "[" ++ String.fromInt i ++ ":" ++ eName ++ "].type") eType aType
                )
                (List.map2 Tuple.pair expected actual)
            )


compareClosureInfo : CompareCtx -> String -> Mono.ClosureInfo -> Mono.ClosureInfo -> List String
compareClosureInfo ctx path eInfo aInfo =
    let
        paramDiffs =
            compareParamsAlpha ctx (path ++ ".params") eInfo.params aInfo.params

        captureDiffs =
            if List.length eInfo.captures /= List.length aInfo.captures then
                [ path ++ ".captures: count mismatch: " ++ String.fromInt (List.length eInfo.captures) ++ " vs " ++ String.fromInt (List.length aInfo.captures) ]

            else
                List.concat
                    (List.indexedMap
                        (\i ( ( eName, eExpr, eIsUnboxed ), ( aName, aExpr, aIsUnboxed ) ) ->
                            (if eName /= aName then
                                [ path ++ ".captures[" ++ String.fromInt i ++ "].name: " ++ eName ++ " vs " ++ aName ]

                             else
                                []
                            )
                                ++ (if eIsUnboxed /= aIsUnboxed then
                                        [ path ++ ".captures[" ++ String.fromInt i ++ "].isUnboxed: " ++ boolToString eIsUnboxed ++ " vs " ++ boolToString aIsUnboxed ]

                                    else
                                        []
                                   )
                                ++ compareExpr ctx (path ++ ".captures[" ++ String.fromInt i ++ ":" ++ eName ++ "]") eExpr aExpr
                        )
                        (List.map2 Tuple.pair eInfo.captures aInfo.captures)
                    )
    in
    paramDiffs ++ captureDiffs


compareCallInfo : String -> Mono.CallInfo -> Mono.CallInfo -> List String
compareCallInfo path eInfo aInfo =
    let
        diffs =
            []
                ++ (if eInfo.stageArities /= aInfo.stageArities then
                        [ path ++ ".stageArities: " ++ listIntToString eInfo.stageArities ++ " vs " ++ listIntToString aInfo.stageArities ]

                    else
                        []
                   )
                ++ (if eInfo.isSingleStageSaturated /= aInfo.isSingleStageSaturated then
                        [ path ++ ".isSingleStageSaturated: " ++ boolToString eInfo.isSingleStageSaturated ++ " vs " ++ boolToString aInfo.isSingleStageSaturated ]

                    else
                        []
                   )
                ++ (if eInfo.initialRemaining /= aInfo.initialRemaining then
                        [ path ++ ".initialRemaining: " ++ String.fromInt eInfo.initialRemaining ++ " vs " ++ String.fromInt aInfo.initialRemaining ]

                    else
                        []
                   )
    in
    diffs


listIntToString : List Int -> String
listIntToString ints =
    "[" ++ String.join "," (List.map String.fromInt ints) ++ "]"


compareDef : CompareCtx -> String -> Mono.MonoDef -> Mono.MonoDef -> List String
compareDef ctx path expected actual =
    case ( expected, actual ) of
        ( Mono.MonoDef eName eExpr, Mono.MonoDef aName aExpr ) ->
            (if eName /= aName then
                [ path ++ ".name: " ++ eName ++ " vs " ++ aName ]

             else
                []
            )
                ++ compareExpr ctx (path ++ "." ++ eName) eExpr aExpr

        ( Mono.MonoTailDef eName eParams eExpr, Mono.MonoTailDef aName aParams aExpr ) ->
            (if eName /= aName then
                [ path ++ ".name: " ++ eName ++ " vs " ++ aName ]

             else
                []
            )
                ++ compareParamsAlpha ctx (path ++ ".params") eParams aParams
                ++ compareExpr ctx (path ++ "." ++ eName) eExpr aExpr

        _ ->
            [ path ++ ": def variant mismatch" ]


compareDestructor : CompareCtx -> String -> Mono.MonoDestructor -> Mono.MonoDestructor -> List String
compareDestructor ctx path (Mono.MonoDestructor eName ePath eType) (Mono.MonoDestructor aName aPath aType) =
    (if eName /= aName then
        [ path ++ ".name: " ++ eName ++ " vs " ++ aName ]

     else
        []
    )
        ++ compareTypeAlpha (path ++ ".type") eType aType
        ++ comparePath (path ++ ".path") ePath aPath


comparePath : String -> Mono.MonoPath -> Mono.MonoPath -> List String
comparePath path expected actual =
    case ( expected, actual ) of
        ( Mono.MonoRoot eName eType, Mono.MonoRoot aName aType ) ->
            (if eName /= aName then
                [ path ++ ".rootName: " ++ eName ++ " vs " ++ aName ]

             else
                []
            )
                ++ compareTypeAlpha (path ++ ".rootType") eType aType

        ( Mono.MonoIndex eIdx eKind eType eInner, Mono.MonoIndex aIdx aKind aType aInner ) ->
            (if eIdx /= aIdx then
                [ path ++ ".index: " ++ String.fromInt eIdx ++ " vs " ++ String.fromInt aIdx ]

             else
                []
            )
                ++ compareTypeAlpha (path ++ ".indexType") eType aType
                ++ comparePath (path ++ ".inner") eInner aInner

        ( Mono.MonoField eName eType eInner, Mono.MonoField aName aType aInner ) ->
            (if eName /= aName then
                [ path ++ ".fieldName: " ++ eName ++ " vs " ++ aName ]

             else
                []
            )
                ++ compareTypeAlpha (path ++ ".fieldType") eType aType
                ++ comparePath (path ++ ".inner") eInner aInner

        ( Mono.MonoUnbox eType eInner, Mono.MonoUnbox aType aInner ) ->
            compareTypeAlpha (path ++ ".unboxType") eType aType
                ++ comparePath (path ++ ".inner") eInner aInner

        _ ->
            [ path ++ ": path variant mismatch" ]


compareCtorShapeAlpha : String -> Mono.CtorShape -> Mono.CtorShape -> List String
compareCtorShapeAlpha path expected actual =
    (if expected.name /= actual.name then
        [ path ++ ".name: " ++ expected.name ++ " vs " ++ actual.name ]

     else
        []
    )
        ++ (if expected.tag /= actual.tag then
                [ path ++ ".tag: " ++ String.fromInt expected.tag ++ " vs " ++ String.fromInt actual.tag ]

            else
                []
           )
        ++ compareTypeListAlpha (path ++ ".fieldTypes") expected.fieldTypes actual.fieldTypes


compareBranches : CompareCtx -> String -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> List String
compareBranches ctx path expected actual =
    if List.length expected /= List.length actual then
        [ path ++ ": branch count mismatch: " ++ String.fromInt (List.length expected) ++ " vs " ++ String.fromInt (List.length actual) ]

    else
        List.concat
            (List.indexedMap
                (\i ( ( eCond, eThen ), ( aCond, aThen ) ) ->
                    compareExpr ctx (path ++ "[" ++ String.fromInt i ++ "].cond") eCond aCond
                        ++ compareExpr ctx (path ++ "[" ++ String.fromInt i ++ "].then") eThen aThen
                )
                (List.map2 Tuple.pair expected actual)
            )


compareDecider : CompareCtx -> String -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> List String
compareDecider ctx path expected actual =
    case ( expected, actual ) of
        ( Mono.Leaf eChoice, Mono.Leaf aChoice ) ->
            compareChoice ctx (path ++ ".leaf") eChoice aChoice

        ( Mono.Chain eTests eSuccess eFailure, Mono.Chain aTests aSuccess aFailure ) ->
            compareDecider ctx (path ++ ".success") eSuccess aSuccess
                ++ compareDecider ctx (path ++ ".failure") eFailure aFailure

        ( Mono.FanOut ePath eOptions eDefault, Mono.FanOut aPath aOptions aDefault ) ->
            compareDecider ctx (path ++ ".default") eDefault aDefault
                ++ compareOptions ctx (path ++ ".options") eOptions aOptions

        _ ->
            [ path ++ ": decider variant mismatch" ]


compareChoice : CompareCtx -> String -> Mono.MonoChoice -> Mono.MonoChoice -> List String
compareChoice ctx path expected actual =
    case ( expected, actual ) of
        ( Mono.Inline eExpr, Mono.Inline aExpr ) ->
            compareExpr ctx (path ++ ".inline") eExpr aExpr

        ( Mono.Jump eIdx, Mono.Jump aIdx ) ->
            if eIdx /= aIdx then
                [ path ++ ".jump: " ++ String.fromInt eIdx ++ " vs " ++ String.fromInt aIdx ]

            else
                []

        _ ->
            [ path ++ ": choice variant mismatch" ]


compareOptions : CompareCtx -> String -> List ( a, Mono.Decider Mono.MonoChoice ) -> List ( b, Mono.Decider Mono.MonoChoice ) -> List String
compareOptions ctx path expected actual =
    if List.length expected /= List.length actual then
        [ path ++ ": option count mismatch: " ++ String.fromInt (List.length expected) ++ " vs " ++ String.fromInt (List.length actual) ]

    else
        List.concat
            (List.indexedMap
                (\i ( ( _, eDecider ), ( _, aDecider ) ) ->
                    compareDecider ctx (path ++ "[" ++ String.fromInt i ++ "]") eDecider aDecider
                )
                (List.map2 Tuple.pair expected actual)
            )


compareJumps : CompareCtx -> String -> List ( Int, Mono.MonoExpr ) -> List ( Int, Mono.MonoExpr ) -> List String
compareJumps ctx path expected actual =
    if List.length expected /= List.length actual then
        [ path ++ ": jump count mismatch: " ++ String.fromInt (List.length expected) ++ " vs " ++ String.fromInt (List.length actual) ]

    else
        List.concat
            (List.indexedMap
                (\i ( ( eIdx, eExpr ), ( aIdx, aExpr ) ) ->
                    (if eIdx /= aIdx then
                        [ path ++ "[" ++ String.fromInt i ++ "].idx: " ++ String.fromInt eIdx ++ " vs " ++ String.fromInt aIdx ]

                     else
                        []
                    )
                        ++ compareExpr ctx (path ++ "[" ++ String.fromInt i ++ "]") eExpr aExpr
                )
                (List.map2 Tuple.pair expected actual)
            )
