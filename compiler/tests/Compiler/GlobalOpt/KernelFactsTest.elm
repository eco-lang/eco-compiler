module Compiler.GlobalOpt.KernelFactsTest exposing (suite)

{-| kernel-opt-07: the KernelFacts table is data, so its consistency is a unit
test rather than a type. Suites 3 and 4 are the load-bearing pair — together
they pin the borrow axis to EXACTLY the 33 legacy KernelSigs rows, which is what
makes this change inert.
-}

import Compiler.GlobalOpt.Borrow.KernelSigs as KernelSigs
import Compiler.GlobalOpt.KernelFacts as KF
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "GlobalOpt.KernelFacts"
        [ Test.test "1. every row satisfies the cross-field implications" <|
            \_ -> Expect.equal [] KF.validationErrors
        , Test.test "2. gcLeafEligible is exactly the audited stampable set" <|
            \_ ->
                KF.rows
                    |> List.filter (\( _, f ) -> KF.gcLeafEligible f)
                    |> List.map Tuple.first
                    |> List.sort
                    |> Expect.equal (List.sort stampable)
        , Test.test "3. the borrow shim reproduces the legacy 33 rows exactly" <|
            \_ ->
                legacyBorrowGolden
                    |> List.map (\( k, sig ) -> ( k, Just sig ))
                    |> Expect.equal (List.map (\( k, _ ) -> ( k, KernelSigs.lookup k )) legacyBorrowGolden)
        , Test.test "4. NO key outside the legacy 33 answers the borrow shim" <|
            \_ ->
                KF.rows
                    |> List.filter (\( k, _ ) -> KernelSigs.lookup k /= Nothing)
                    |> List.map Tuple.first
                    |> List.sort
                    |> Expect.equal (List.sort (List.map Tuple.first legacyBorrowGolden))
        , Test.test "5. lookupSymbol strips the ABI prefix and _Int/_Float/_Char" <|
            \_ ->
                Expect.equal
                    [ KF.lookup ( "Utils", "compare" ), KF.lookup ( "Utils", "compare" ), KF.lookup ( "MVar", "put" ), KF.lookup ( "Bytes", "read_u32" ), Nothing ]
                    [ KF.lookupSymbol "Elm_Kernel_Utils_compare"
                    , KF.lookupSymbol "Elm_Kernel_Utils_compare_Float"
                    , KF.lookupSymbol "Eco_Kernel_MVar_put_Int"
                    , KF.lookupSymbol "Elm_Kernel_Bytes_read_u32"
                    , KF.lookupSymbol "eco_gc_alloc_region_fast"
                    ]
        , Test.test "6. the key-form derived helpers agree with the record form and default False" <|
            \_ ->
                Expect.equal
                    [ True, False, False, False ]
                    [ KF.gcLeafEligibleFor ( "String", "length" )
                    , KF.gcLeafEligibleFor ( "List", "cons" ) -- listed but allocating
                    , KF.gcLeafEligibleFor ( "Platform", "sendToApp" ) -- unlisted
                    , KF.droppableFor ( "Debug", "log" )
                    ]
        , Test.test "7. the table has the expected size and no duplicate keys" <|
            \_ -> Expect.equal ( 52, 52 ) ( List.length KF.rows, List.length (uniqueKeys KF.rows) )
        ]


uniqueKeys : List ( ( String, String ), a ) -> List ( String, String )
uniqueKeys =
    List.map Tuple.first >> List.sort >> dedupeSorted


dedupeSorted : List a -> List a
dedupeSorted xs =
    case xs of
        a :: b :: rest ->
            if a == b then
                dedupeSorted (b :: rest)

            else
                a :: dedupeSorted (b :: rest)

        _ ->
            xs


{-| The 14 keys whose C++ bodies were audited to allocate nothing on the Eco
heap and never to call back into Elm — i.e. exactly the set kernel-opt-08 may
stamp with `eco.gc_leaf`. Written out by hand: this is a golden, not a
projection of the table.
-}
stampable : List ( String, String )
stampable =
    [ ( "Utils", "equal" )
    , ( "Utils", "notEqual" )
    , ( "Utils", "compare" )
    , ( "Utils", "lt" )
    , ( "Utils", "le" )
    , ( "Utils", "gt" )
    , ( "Utils", "ge" )
    , ( "String", "length" )
    , ( "String", "startsWith" )
    , ( "String", "endsWith" )
    , ( "String", "contains" )
    , ( "Bytes", "getStringWidth" )
    , ( "Bytes", "width" )
    , ( "Bytes", "decodeFailure" )
    ]


{-| Transcribed by hand from the PRE-CHANGE Borrow/KernelSigs.elm:51-167, before
Phase 2 rewrote that file into a shim. All 33 rows, with `bb1`/`bb2` expanded
inline. Do NOT regenerate from KernelFacts and do NOT import the shim's helpers
— the whole point is that this is an independent copy.
-}
legacyBorrowGolden : List ( ( String, String ), KernelSigs.KernelSig )
legacyBorrowGolden =
    [ ( ( "Utils", "compare" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Utils", "equal" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Utils", "notEqual" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Utils", "lt" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Utils", "le" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Utils", "gt" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Utils", "ge" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "String", "length" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "String", "startsWith" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "String", "endsWith" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "String", "contains" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "JsArray", "length" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "JsArray", "unsafeGet" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "Debug", "log" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "Debug", "toString" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Bytes", "getStringWidth" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Bytes", "width" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Bytes", "encode" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "Bytes", "decode" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 0, 1 ] } )
    , ( ( "Crash", "crash" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "JsArray", "foldl" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1, 2 ] } )
    , ( ( "JsArray", "foldr" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1, 2 ] } )
    , ( ( "JsArray", "map" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "List", "map2" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1, 2 ] } )
    , ( ( "List", "sortBy" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "List", "sortWith" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 1 ] } )
    , ( ( "String", "slice" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [ 2 ] } )
    , ( ( "String", "uncons" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [ 0 ] } )
    , ( ( "String", "words" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [ 0 ] } )
    , ( ( "String", "trim" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [ 0 ] } )
    , ( ( "String", "toLower" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "String", "toUpper" ), { params = [ KernelSigs.PBorrowed ], resultAliases = [] } )
    , ( ( "String", "all" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    ]
