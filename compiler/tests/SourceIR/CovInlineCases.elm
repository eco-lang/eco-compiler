module SourceIR.CovInlineCases exposing (expectSuite)

{-| Programs built for the post-monomorphization inliner
(`Compiler.MonoOpt.InlineSimplify`), so that a caller's check can be run on
its less common rewrites: partial and over-application of lambda literals,
inlined calls inside every kind of expression, a function with more inlinable
calls than the per-function budget, loopification of tail-recursive
higher-order functions whose bodies build records, lists, tuples and cases,
a dead `let` bound to a bare kernel, chains of global aliases, partial
applications and closures bound by a `let` and used once in a tail call, a
record, a `case` branch, past a local loop or in an `if`, and calls whose
callee is an `if`, a `case` or a closure literal.

These cases assert nothing themselves. Each one builds a program and hands it
to the expectation function the caller supplies.

Every program is the source text of a module named `Test`, parsed as an
application module, that defines `testValue`. Default imports of modules that
`Compiler.Elm.Interface.Basic.testIfaces` lacks are dropped. The cases, by
label:

  - "Partial application of a lambda literal".
  - "Over-application of a lambda literal".
  - "Inlined functions in every expression kind".
  - "Many inlinable calls in one function".
  - "Loopified higher-order tail recursion".
  - "Loopified fold over a custom type".
  - "Dead bare kernel let".
  - "Alias chains of globals".
  - "Forwarded let chain into a case".
  - "Forwarded partial application into a tail call".
  - "Forwarded partial application into record positions".
  - "Forwarded partial application into a case branch".
  - "Forwarded partial application past a local loop".
  - "Forwarded closure into an if branch".
  - "Calls through if, case and closure-literal callees".

"Many inlinable calls in one function" builds a list of 1,100 calls of a
small function, more than the inliner's default budget of 1,000 inlines per
function.

All the cases run inside one test through `Compiler.BulkCheck.bulkCheck`,
which stops at the first case that fails and reports its label.

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Inliner shapes " followed by `condStr`, that
passes when `expectFn` passes on every case's program and otherwise fails with
the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Inliner shapes " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, each running `expectFn` on its program, in the order
of the module documentation.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map
        (\( label, body ) ->
            { label = label
            , run =
                \_ ->
                    case parse body of
                        Ok modul ->
                            expectFn modul

                        Err message ->
                            Expect.fail message
            }
        )
        programs


{-| Parses `body` after the header `module Test exposing (..)`, keeping only
the imports the mock interfaces can resolve.
-}
parse : String -> Result String Src.Module
parse body =
    case Parse.fromByteString Parse.Application ("module Test exposing (..)\n\n" ++ body) of
        Ok (Src.Module m) ->
            Ok (Src.Module { m | imports = List.filter isMockImport m.imports })

        Err _ ->
            Err "fixture failed to parse"


{-| Whether an import names one of the mock interfaces.
-}
isMockImport : Src.Import -> Bool
isMockImport (Src.Import ( _, A.At _ name ) _ _) =
    Dict.member name Basic.testIfaces


{-| The label and the source after the module header of each case.
-}
programs : List ( String, String )
programs =
    [ ( "Partial application of a lambda literal"
      , """testValue : Int
testValue =
    let
        f =
            (\\a b c -> a + b * c) 1
    in
    f 2 3 + f 4 5
"""
      )
    , ( "Over-application of a lambda literal"
      , """testValue : Int
testValue =
    (\\a -> \\b -> a + b) 1 2
"""
      )
    , ( "Inlined functions in every expression kind"
      , """type Shape
    = Circle Int
    | Square Int
    | Tri Int Int


area : Shape -> Int
area s =
    case s of
        Circle r ->
            r * r * 3

        Square w ->
            w * w

        Tri b h ->
            b * h // 2


double : Int -> Int
double x =
    x * 2


bump : { a : Int, b : Int } -> { a : Int, b : Int }
bump r =
    { r | a = double r.a }


testValue : Int
testValue =
    let
        r =
            bump { a = double 1, b = double 2 }

        t =
            ( double r.a, area (Tri (double 2) 3) )

        xs =
            [ double 3, area (Circle 2), area (Square (double 1)) ]

        y =
            if double 1 > 1 then
                double 5

            else
                area (Square 2)
    in
    Tuple.first t + Tuple.second t + List.length xs + y + r.b
"""
      )
    , ( "Many inlinable calls in one function"
      , """testValue : Int
testValue =
    List.length
        [ inc 0
        , inc 1
        , inc 2
        , inc 3
        , inc 4
        , inc 5
        , inc 6
        , inc 7
        , inc 8
        , inc 9
        , inc 10
        , inc 11
        , inc 12
        , inc 13
        , inc 14
        , inc 15
        , inc 16
        , inc 17
        , inc 18
        , inc 19
        , inc 20
        , inc 21
        , inc 22
        , inc 23
        , inc 24
        , inc 25
        , inc 26
        , inc 27
        , inc 28
        , inc 29
        , inc 30
        , inc 31
        , inc 32
        , inc 33
        , inc 34
        , inc 35
        , inc 36
        , inc 37
        , inc 38
        , inc 39
        , inc 40
        , inc 41
        , inc 42
        , inc 43
        , inc 44
        , inc 45
        , inc 46
        , inc 47
        , inc 48
        , inc 49
        , inc 50
        , inc 51
        , inc 52
        , inc 53
        , inc 54
        , inc 55
        , inc 56
        , inc 57
        , inc 58
        , inc 59
        , inc 60
        , inc 61
        , inc 62
        , inc 63
        , inc 64
        , inc 65
        , inc 66
        , inc 67
        , inc 68
        , inc 69
        , inc 70
        , inc 71
        , inc 72
        , inc 73
        , inc 74
        , inc 75
        , inc 76
        , inc 77
        , inc 78
        , inc 79
        , inc 80
        , inc 81
        , inc 82
        , inc 83
        , inc 84
        , inc 85
        , inc 86
        , inc 87
        , inc 88
        , inc 89
        , inc 90
        , inc 91
        , inc 92
        , inc 93
        , inc 94
        , inc 95
        , inc 96
        , inc 97
        , inc 98
        , inc 99
        , inc 100
        , inc 101
        , inc 102
        , inc 103
        , inc 104
        , inc 105
        , inc 106
        , inc 107
        , inc 108
        , inc 109
        , inc 110
        , inc 111
        , inc 112
        , inc 113
        , inc 114
        , inc 115
        , inc 116
        , inc 117
        , inc 118
        , inc 119
        , inc 120
        , inc 121
        , inc 122
        , inc 123
        , inc 124
        , inc 125
        , inc 126
        , inc 127
        , inc 128
        , inc 129
        , inc 130
        , inc 131
        , inc 132
        , inc 133
        , inc 134
        , inc 135
        , inc 136
        , inc 137
        , inc 138
        , inc 139
        , inc 140
        , inc 141
        , inc 142
        , inc 143
        , inc 144
        , inc 145
        , inc 146
        , inc 147
        , inc 148
        , inc 149
        , inc 150
        , inc 151
        , inc 152
        , inc 153
        , inc 154
        , inc 155
        , inc 156
        , inc 157
        , inc 158
        , inc 159
        , inc 160
        , inc 161
        , inc 162
        , inc 163
        , inc 164
        , inc 165
        , inc 166
        , inc 167
        , inc 168
        , inc 169
        , inc 170
        , inc 171
        , inc 172
        , inc 173
        , inc 174
        , inc 175
        , inc 176
        , inc 177
        , inc 178
        , inc 179
        , inc 180
        , inc 181
        , inc 182
        , inc 183
        , inc 184
        , inc 185
        , inc 186
        , inc 187
        , inc 188
        , inc 189
        , inc 190
        , inc 191
        , inc 192
        , inc 193
        , inc 194
        , inc 195
        , inc 196
        , inc 197
        , inc 198
        , inc 199
        , inc 200
        , inc 201
        , inc 202
        , inc 203
        , inc 204
        , inc 205
        , inc 206
        , inc 207
        , inc 208
        , inc 209
        , inc 210
        , inc 211
        , inc 212
        , inc 213
        , inc 214
        , inc 215
        , inc 216
        , inc 217
        , inc 218
        , inc 219
        , inc 220
        , inc 221
        , inc 222
        , inc 223
        , inc 224
        , inc 225
        , inc 226
        , inc 227
        , inc 228
        , inc 229
        , inc 230
        , inc 231
        , inc 232
        , inc 233
        , inc 234
        , inc 235
        , inc 236
        , inc 237
        , inc 238
        , inc 239
        , inc 240
        , inc 241
        , inc 242
        , inc 243
        , inc 244
        , inc 245
        , inc 246
        , inc 247
        , inc 248
        , inc 249
        , inc 250
        , inc 251
        , inc 252
        , inc 253
        , inc 254
        , inc 255
        , inc 256
        , inc 257
        , inc 258
        , inc 259
        , inc 260
        , inc 261
        , inc 262
        , inc 263
        , inc 264
        , inc 265
        , inc 266
        , inc 267
        , inc 268
        , inc 269
        , inc 270
        , inc 271
        , inc 272
        , inc 273
        , inc 274
        , inc 275
        , inc 276
        , inc 277
        , inc 278
        , inc 279
        , inc 280
        , inc 281
        , inc 282
        , inc 283
        , inc 284
        , inc 285
        , inc 286
        , inc 287
        , inc 288
        , inc 289
        , inc 290
        , inc 291
        , inc 292
        , inc 293
        , inc 294
        , inc 295
        , inc 296
        , inc 297
        , inc 298
        , inc 299
        , inc 300
        , inc 301
        , inc 302
        , inc 303
        , inc 304
        , inc 305
        , inc 306
        , inc 307
        , inc 308
        , inc 309
        , inc 310
        , inc 311
        , inc 312
        , inc 313
        , inc 314
        , inc 315
        , inc 316
        , inc 317
        , inc 318
        , inc 319
        , inc 320
        , inc 321
        , inc 322
        , inc 323
        , inc 324
        , inc 325
        , inc 326
        , inc 327
        , inc 328
        , inc 329
        , inc 330
        , inc 331
        , inc 332
        , inc 333
        , inc 334
        , inc 335
        , inc 336
        , inc 337
        , inc 338
        , inc 339
        , inc 340
        , inc 341
        , inc 342
        , inc 343
        , inc 344
        , inc 345
        , inc 346
        , inc 347
        , inc 348
        , inc 349
        , inc 350
        , inc 351
        , inc 352
        , inc 353
        , inc 354
        , inc 355
        , inc 356
        , inc 357
        , inc 358
        , inc 359
        , inc 360
        , inc 361
        , inc 362
        , inc 363
        , inc 364
        , inc 365
        , inc 366
        , inc 367
        , inc 368
        , inc 369
        , inc 370
        , inc 371
        , inc 372
        , inc 373
        , inc 374
        , inc 375
        , inc 376
        , inc 377
        , inc 378
        , inc 379
        , inc 380
        , inc 381
        , inc 382
        , inc 383
        , inc 384
        , inc 385
        , inc 386
        , inc 387
        , inc 388
        , inc 389
        , inc 390
        , inc 391
        , inc 392
        , inc 393
        , inc 394
        , inc 395
        , inc 396
        , inc 397
        , inc 398
        , inc 399
        , inc 400
        , inc 401
        , inc 402
        , inc 403
        , inc 404
        , inc 405
        , inc 406
        , inc 407
        , inc 408
        , inc 409
        , inc 410
        , inc 411
        , inc 412
        , inc 413
        , inc 414
        , inc 415
        , inc 416
        , inc 417
        , inc 418
        , inc 419
        , inc 420
        , inc 421
        , inc 422
        , inc 423
        , inc 424
        , inc 425
        , inc 426
        , inc 427
        , inc 428
        , inc 429
        , inc 430
        , inc 431
        , inc 432
        , inc 433
        , inc 434
        , inc 435
        , inc 436
        , inc 437
        , inc 438
        , inc 439
        , inc 440
        , inc 441
        , inc 442
        , inc 443
        , inc 444
        , inc 445
        , inc 446
        , inc 447
        , inc 448
        , inc 449
        , inc 450
        , inc 451
        , inc 452
        , inc 453
        , inc 454
        , inc 455
        , inc 456
        , inc 457
        , inc 458
        , inc 459
        , inc 460
        , inc 461
        , inc 462
        , inc 463
        , inc 464
        , inc 465
        , inc 466
        , inc 467
        , inc 468
        , inc 469
        , inc 470
        , inc 471
        , inc 472
        , inc 473
        , inc 474
        , inc 475
        , inc 476
        , inc 477
        , inc 478
        , inc 479
        , inc 480
        , inc 481
        , inc 482
        , inc 483
        , inc 484
        , inc 485
        , inc 486
        , inc 487
        , inc 488
        , inc 489
        , inc 490
        , inc 491
        , inc 492
        , inc 493
        , inc 494
        , inc 495
        , inc 496
        , inc 497
        , inc 498
        , inc 499
        , inc 500
        , inc 501
        , inc 502
        , inc 503
        , inc 504
        , inc 505
        , inc 506
        , inc 507
        , inc 508
        , inc 509
        , inc 510
        , inc 511
        , inc 512
        , inc 513
        , inc 514
        , inc 515
        , inc 516
        , inc 517
        , inc 518
        , inc 519
        , inc 520
        , inc 521
        , inc 522
        , inc 523
        , inc 524
        , inc 525
        , inc 526
        , inc 527
        , inc 528
        , inc 529
        , inc 530
        , inc 531
        , inc 532
        , inc 533
        , inc 534
        , inc 535
        , inc 536
        , inc 537
        , inc 538
        , inc 539
        , inc 540
        , inc 541
        , inc 542
        , inc 543
        , inc 544
        , inc 545
        , inc 546
        , inc 547
        , inc 548
        , inc 549
        , inc 550
        , inc 551
        , inc 552
        , inc 553
        , inc 554
        , inc 555
        , inc 556
        , inc 557
        , inc 558
        , inc 559
        , inc 560
        , inc 561
        , inc 562
        , inc 563
        , inc 564
        , inc 565
        , inc 566
        , inc 567
        , inc 568
        , inc 569
        , inc 570
        , inc 571
        , inc 572
        , inc 573
        , inc 574
        , inc 575
        , inc 576
        , inc 577
        , inc 578
        , inc 579
        , inc 580
        , inc 581
        , inc 582
        , inc 583
        , inc 584
        , inc 585
        , inc 586
        , inc 587
        , inc 588
        , inc 589
        , inc 590
        , inc 591
        , inc 592
        , inc 593
        , inc 594
        , inc 595
        , inc 596
        , inc 597
        , inc 598
        , inc 599
        , inc 600
        , inc 601
        , inc 602
        , inc 603
        , inc 604
        , inc 605
        , inc 606
        , inc 607
        , inc 608
        , inc 609
        , inc 610
        , inc 611
        , inc 612
        , inc 613
        , inc 614
        , inc 615
        , inc 616
        , inc 617
        , inc 618
        , inc 619
        , inc 620
        , inc 621
        , inc 622
        , inc 623
        , inc 624
        , inc 625
        , inc 626
        , inc 627
        , inc 628
        , inc 629
        , inc 630
        , inc 631
        , inc 632
        , inc 633
        , inc 634
        , inc 635
        , inc 636
        , inc 637
        , inc 638
        , inc 639
        , inc 640
        , inc 641
        , inc 642
        , inc 643
        , inc 644
        , inc 645
        , inc 646
        , inc 647
        , inc 648
        , inc 649
        , inc 650
        , inc 651
        , inc 652
        , inc 653
        , inc 654
        , inc 655
        , inc 656
        , inc 657
        , inc 658
        , inc 659
        , inc 660
        , inc 661
        , inc 662
        , inc 663
        , inc 664
        , inc 665
        , inc 666
        , inc 667
        , inc 668
        , inc 669
        , inc 670
        , inc 671
        , inc 672
        , inc 673
        , inc 674
        , inc 675
        , inc 676
        , inc 677
        , inc 678
        , inc 679
        , inc 680
        , inc 681
        , inc 682
        , inc 683
        , inc 684
        , inc 685
        , inc 686
        , inc 687
        , inc 688
        , inc 689
        , inc 690
        , inc 691
        , inc 692
        , inc 693
        , inc 694
        , inc 695
        , inc 696
        , inc 697
        , inc 698
        , inc 699
        , inc 700
        , inc 701
        , inc 702
        , inc 703
        , inc 704
        , inc 705
        , inc 706
        , inc 707
        , inc 708
        , inc 709
        , inc 710
        , inc 711
        , inc 712
        , inc 713
        , inc 714
        , inc 715
        , inc 716
        , inc 717
        , inc 718
        , inc 719
        , inc 720
        , inc 721
        , inc 722
        , inc 723
        , inc 724
        , inc 725
        , inc 726
        , inc 727
        , inc 728
        , inc 729
        , inc 730
        , inc 731
        , inc 732
        , inc 733
        , inc 734
        , inc 735
        , inc 736
        , inc 737
        , inc 738
        , inc 739
        , inc 740
        , inc 741
        , inc 742
        , inc 743
        , inc 744
        , inc 745
        , inc 746
        , inc 747
        , inc 748
        , inc 749
        , inc 750
        , inc 751
        , inc 752
        , inc 753
        , inc 754
        , inc 755
        , inc 756
        , inc 757
        , inc 758
        , inc 759
        , inc 760
        , inc 761
        , inc 762
        , inc 763
        , inc 764
        , inc 765
        , inc 766
        , inc 767
        , inc 768
        , inc 769
        , inc 770
        , inc 771
        , inc 772
        , inc 773
        , inc 774
        , inc 775
        , inc 776
        , inc 777
        , inc 778
        , inc 779
        , inc 780
        , inc 781
        , inc 782
        , inc 783
        , inc 784
        , inc 785
        , inc 786
        , inc 787
        , inc 788
        , inc 789
        , inc 790
        , inc 791
        , inc 792
        , inc 793
        , inc 794
        , inc 795
        , inc 796
        , inc 797
        , inc 798
        , inc 799
        , inc 800
        , inc 801
        , inc 802
        , inc 803
        , inc 804
        , inc 805
        , inc 806
        , inc 807
        , inc 808
        , inc 809
        , inc 810
        , inc 811
        , inc 812
        , inc 813
        , inc 814
        , inc 815
        , inc 816
        , inc 817
        , inc 818
        , inc 819
        , inc 820
        , inc 821
        , inc 822
        , inc 823
        , inc 824
        , inc 825
        , inc 826
        , inc 827
        , inc 828
        , inc 829
        , inc 830
        , inc 831
        , inc 832
        , inc 833
        , inc 834
        , inc 835
        , inc 836
        , inc 837
        , inc 838
        , inc 839
        , inc 840
        , inc 841
        , inc 842
        , inc 843
        , inc 844
        , inc 845
        , inc 846
        , inc 847
        , inc 848
        , inc 849
        , inc 850
        , inc 851
        , inc 852
        , inc 853
        , inc 854
        , inc 855
        , inc 856
        , inc 857
        , inc 858
        , inc 859
        , inc 860
        , inc 861
        , inc 862
        , inc 863
        , inc 864
        , inc 865
        , inc 866
        , inc 867
        , inc 868
        , inc 869
        , inc 870
        , inc 871
        , inc 872
        , inc 873
        , inc 874
        , inc 875
        , inc 876
        , inc 877
        , inc 878
        , inc 879
        , inc 880
        , inc 881
        , inc 882
        , inc 883
        , inc 884
        , inc 885
        , inc 886
        , inc 887
        , inc 888
        , inc 889
        , inc 890
        , inc 891
        , inc 892
        , inc 893
        , inc 894
        , inc 895
        , inc 896
        , inc 897
        , inc 898
        , inc 899
        , inc 900
        , inc 901
        , inc 902
        , inc 903
        , inc 904
        , inc 905
        , inc 906
        , inc 907
        , inc 908
        , inc 909
        , inc 910
        , inc 911
        , inc 912
        , inc 913
        , inc 914
        , inc 915
        , inc 916
        , inc 917
        , inc 918
        , inc 919
        , inc 920
        , inc 921
        , inc 922
        , inc 923
        , inc 924
        , inc 925
        , inc 926
        , inc 927
        , inc 928
        , inc 929
        , inc 930
        , inc 931
        , inc 932
        , inc 933
        , inc 934
        , inc 935
        , inc 936
        , inc 937
        , inc 938
        , inc 939
        , inc 940
        , inc 941
        , inc 942
        , inc 943
        , inc 944
        , inc 945
        , inc 946
        , inc 947
        , inc 948
        , inc 949
        , inc 950
        , inc 951
        , inc 952
        , inc 953
        , inc 954
        , inc 955
        , inc 956
        , inc 957
        , inc 958
        , inc 959
        , inc 960
        , inc 961
        , inc 962
        , inc 963
        , inc 964
        , inc 965
        , inc 966
        , inc 967
        , inc 968
        , inc 969
        , inc 970
        , inc 971
        , inc 972
        , inc 973
        , inc 974
        , inc 975
        , inc 976
        , inc 977
        , inc 978
        , inc 979
        , inc 980
        , inc 981
        , inc 982
        , inc 983
        , inc 984
        , inc 985
        , inc 986
        , inc 987
        , inc 988
        , inc 989
        , inc 990
        , inc 991
        , inc 992
        , inc 993
        , inc 994
        , inc 995
        , inc 996
        , inc 997
        , inc 998
        , inc 999
        , inc 1000
        , inc 1001
        , inc 1002
        , inc 1003
        , inc 1004
        , inc 1005
        , inc 1006
        , inc 1007
        , inc 1008
        , inc 1009
        , inc 1010
        , inc 1011
        , inc 1012
        , inc 1013
        , inc 1014
        , inc 1015
        , inc 1016
        , inc 1017
        , inc 1018
        , inc 1019
        , inc 1020
        , inc 1021
        , inc 1022
        , inc 1023
        , inc 1024
        , inc 1025
        , inc 1026
        , inc 1027
        , inc 1028
        , inc 1029
        , inc 1030
        , inc 1031
        , inc 1032
        , inc 1033
        , inc 1034
        , inc 1035
        , inc 1036
        , inc 1037
        , inc 1038
        , inc 1039
        , inc 1040
        , inc 1041
        , inc 1042
        , inc 1043
        , inc 1044
        , inc 1045
        , inc 1046
        , inc 1047
        , inc 1048
        , inc 1049
        , inc 1050
        , inc 1051
        , inc 1052
        , inc 1053
        , inc 1054
        , inc 1055
        , inc 1056
        , inc 1057
        , inc 1058
        , inc 1059
        , inc 1060
        , inc 1061
        , inc 1062
        , inc 1063
        , inc 1064
        , inc 1065
        , inc 1066
        , inc 1067
        , inc 1068
        , inc 1069
        , inc 1070
        , inc 1071
        , inc 1072
        , inc 1073
        , inc 1074
        , inc 1075
        , inc 1076
        , inc 1077
        , inc 1078
        , inc 1079
        , inc 1080
        , inc 1081
        , inc 1082
        , inc 1083
        , inc 1084
        , inc 1085
        , inc 1086
        , inc 1087
        , inc 1088
        , inc 1089
        , inc 1090
        , inc 1091
        , inc 1092
        , inc 1093
        , inc 1094
        , inc 1095
        , inc 1096
        , inc 1097
        , inc 1098
        , inc 1099
        ]


inc : Int -> Int
inc x =
    x + 1
"""
      )
    , ( "Loopified higher-order tail recursion"
      , """loop : (Int -> Int) -> Int -> Int -> Int
loop f n acc =
    if n <= 0 then
        acc

    else
        let
            rec =
                { v = f acc, w = n }

            upd =
                { rec | w = rec.w - 1 }

            pair =
                ( upd.v, [ upd.w ] )

            next =
                case Tuple.second pair of
                    [] ->
                        0

                    h :: _ ->
                        h
        in
        loop f next (Tuple.first pair)


testValue : Int
testValue =
    let
        k =
            3
    in
    loop (\\x -> x + k) 10 0
"""
      )
    , ( "Loopified fold over a custom type"
      , """type Op
    = Add Int
    | Mul Int
    | Neg


run : (Int -> Op -> Int) -> List Op -> Int -> Int
run step ops acc =
    case ops of
        [] ->
            acc

        op :: rest ->
            run step rest (step acc op)


testValue : Int
testValue =
    let
        base =
            1
    in
    run
        (\\a op ->
            case op of
                Add n ->
                    a + n + base

                Mul n ->
                    a * n

                Neg ->
                    negate a
        )
        [ Add 1, Mul 2, Neg ]
        0
"""
      )
    , ( "Dead bare kernel let"
      , """testValue : Int
testValue =
    let
        unused : Int -> Int -> Int
        unused =
            Elm.Kernel.Basics.add

        kept =
            3
    in
    kept
"""
      )
    , ( "Alias chains of globals"
      , """add2 : Int -> Int -> Int
add2 a b =
    a + b


alias1 : Int -> Int -> Int
alias1 =
    add2


alias2 : Int -> Int -> Int
alias2 =
    alias1


kernelAlias : Int -> Int -> Int
kernelAlias =
    Elm.Kernel.Basics.mul


testValue : Int
testValue =
    List.foldl alias2 0 [ 1, 2 ] + List.foldl kernelAlias 1 [ 2, 3 ]
"""
      )
    , ( "Forwarded let chain into a case"
      , """pick : Int -> Int
pick n =
    let
        a =
            n + 1

        b =
            a

        c =
            b
    in
    case c of
        0 ->
            b

        1 ->
            a

        _ ->
            c * 2


testValue : Int
testValue =
    pick 0 + pick 1 + pick 5
"""
      )
    , ( "Forwarded partial application into a tail call"
      , """add3 : Int -> Int -> Int -> Int
add3 a b c =
    a + b + c


count : Int -> Int -> Int
count n acc =
    let
        g =
            add3 n
    in
    if n <= 0 then
        acc

    else
        count (n - 1) (g 2 acc)


testValue : Int
testValue =
    count 3 0
"""
      )
    , ( "Forwarded partial application into record positions"
      , """mk : Int -> Int -> Int -> { x : Int, y : Int }
mk a b c =
    { x = a + b, y = c }


testValue : Int
testValue =
    let
        g =
            mk 1

        h =
            mk 4

        r =
            { x = 0, y = 0 }

        r2 =
            { r | y = (h 5 6).x }
    in
    (g 2 3).x + r2.y
"""
      )
    , ( "Forwarded partial application into a case branch"
      , """add3 : Int -> Int -> Int -> Int
add3 a b c =
    a * b + c


type Kind
    = One
    | Two
    | Three


choose : Kind -> Int -> Int
choose k n =
    let
        g =
            add3 n
    in
    case k of
        One ->
            0

        Two ->
            g 2 3

        Three ->
            n


testValue : Int
testValue =
    choose One 1 + choose Two 2 + choose Three 3
"""
      )
    , ( "Forwarded partial application past a local loop"
      , """add3 : Int -> Int -> Int -> Int
add3 a b c =
    a + b - c


testValue : Int
testValue =
    let
        g =
            add3 1

        loop k =
            if k > 0 then
                loop (k - 1)

            else
                k
    in
    g (loop 3) 2
"""
      )
    , ( "Forwarded closure into an if branch"
      , """pick : Bool -> Int -> Int
pick b n =
    let
        h =
            \\x -> x + n
    in
    if b then
        h 1

    else if n > 3 then
        0

    else
        2


testValue : Int
testValue =
    pick True 1 + pick False 5 + pick False 1
"""
      )
    , ( "Calls through if, case and closure-literal callees"
      , """inc : Int -> Int
inc x =
    x + 1


dec : Int -> Int
dec x =
    x - 1


apply : Bool -> Int -> Int -> Int
apply b k x =
    (if b then
        inc

     else
        dec
    )
        x
        + (case k of
            0 ->
                inc

            _ ->
                dec
          )
            x
        + (\\y -> y * k) x


testValue : Int
testValue =
    apply True 0 1 + apply False 1 2
"""
      )
    ]
