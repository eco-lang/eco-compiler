module WideRecord600Test exposing (main)

{-| 600-field mixed record: inline-alloc bound (4096 B) exceeded -> eco_alloc_record call path.
-}

-- CHECK: f0000: 1000
-- CHECK: f0031: 31.5
-- CHECK: f0032: 'g'
-- CHECK: f0063: "63s"
-- CHECK: f0064: True
-- CHECK: f0599: False
-- CHECK: pattern: (1000, False)
-- CHECK: update: True
-- CHECK: eq self: True
-- CHECK: eq updated: False

import Html exposing (text)

type alias R =
    { f0000 : Int
    , f0001 : Float
    , f0002 : Char
    , f0003 : String
    , f0004 : Bool
    , f0005 : Int
    , f0006 : Float
    , f0007 : Char
    , f0008 : String
    , f0009 : Bool
    , f0010 : Int
    , f0011 : Float
    , f0012 : Char
    , f0013 : String
    , f0014 : Bool
    , f0015 : Int
    , f0016 : Float
    , f0017 : Char
    , f0018 : String
    , f0019 : Bool
    , f0020 : Int
    , f0021 : Float
    , f0022 : Char
    , f0023 : String
    , f0024 : Bool
    , f0025 : Int
    , f0026 : Float
    , f0027 : Char
    , f0028 : String
    , f0029 : Bool
    , f0030 : Int
    , f0031 : Float
    , f0032 : Char
    , f0033 : String
    , f0034 : Bool
    , f0035 : Int
    , f0036 : Float
    , f0037 : Char
    , f0038 : String
    , f0039 : Bool
    , f0040 : Int
    , f0041 : Float
    , f0042 : Char
    , f0043 : String
    , f0044 : Bool
    , f0045 : Int
    , f0046 : Float
    , f0047 : Char
    , f0048 : String
    , f0049 : Bool
    , f0050 : Int
    , f0051 : Float
    , f0052 : Char
    , f0053 : String
    , f0054 : Bool
    , f0055 : Int
    , f0056 : Float
    , f0057 : Char
    , f0058 : String
    , f0059 : Bool
    , f0060 : Int
    , f0061 : Float
    , f0062 : Char
    , f0063 : String
    , f0064 : Bool
    , f0065 : Int
    , f0066 : Float
    , f0067 : Char
    , f0068 : String
    , f0069 : Bool
    , f0070 : Int
    , f0071 : Float
    , f0072 : Char
    , f0073 : String
    , f0074 : Bool
    , f0075 : Int
    , f0076 : Float
    , f0077 : Char
    , f0078 : String
    , f0079 : Bool
    , f0080 : Int
    , f0081 : Float
    , f0082 : Char
    , f0083 : String
    , f0084 : Bool
    , f0085 : Int
    , f0086 : Float
    , f0087 : Char
    , f0088 : String
    , f0089 : Bool
    , f0090 : Int
    , f0091 : Float
    , f0092 : Char
    , f0093 : String
    , f0094 : Bool
    , f0095 : Int
    , f0096 : Float
    , f0097 : Char
    , f0098 : String
    , f0099 : Bool
    , f0100 : Int
    , f0101 : Float
    , f0102 : Char
    , f0103 : String
    , f0104 : Bool
    , f0105 : Int
    , f0106 : Float
    , f0107 : Char
    , f0108 : String
    , f0109 : Bool
    , f0110 : Int
    , f0111 : Float
    , f0112 : Char
    , f0113 : String
    , f0114 : Bool
    , f0115 : Int
    , f0116 : Float
    , f0117 : Char
    , f0118 : String
    , f0119 : Bool
    , f0120 : Int
    , f0121 : Float
    , f0122 : Char
    , f0123 : String
    , f0124 : Bool
    , f0125 : Int
    , f0126 : Float
    , f0127 : Char
    , f0128 : String
    , f0129 : Bool
    , f0130 : Int
    , f0131 : Float
    , f0132 : Char
    , f0133 : String
    , f0134 : Bool
    , f0135 : Int
    , f0136 : Float
    , f0137 : Char
    , f0138 : String
    , f0139 : Bool
    , f0140 : Int
    , f0141 : Float
    , f0142 : Char
    , f0143 : String
    , f0144 : Bool
    , f0145 : Int
    , f0146 : Float
    , f0147 : Char
    , f0148 : String
    , f0149 : Bool
    , f0150 : Int
    , f0151 : Float
    , f0152 : Char
    , f0153 : String
    , f0154 : Bool
    , f0155 : Int
    , f0156 : Float
    , f0157 : Char
    , f0158 : String
    , f0159 : Bool
    , f0160 : Int
    , f0161 : Float
    , f0162 : Char
    , f0163 : String
    , f0164 : Bool
    , f0165 : Int
    , f0166 : Float
    , f0167 : Char
    , f0168 : String
    , f0169 : Bool
    , f0170 : Int
    , f0171 : Float
    , f0172 : Char
    , f0173 : String
    , f0174 : Bool
    , f0175 : Int
    , f0176 : Float
    , f0177 : Char
    , f0178 : String
    , f0179 : Bool
    , f0180 : Int
    , f0181 : Float
    , f0182 : Char
    , f0183 : String
    , f0184 : Bool
    , f0185 : Int
    , f0186 : Float
    , f0187 : Char
    , f0188 : String
    , f0189 : Bool
    , f0190 : Int
    , f0191 : Float
    , f0192 : Char
    , f0193 : String
    , f0194 : Bool
    , f0195 : Int
    , f0196 : Float
    , f0197 : Char
    , f0198 : String
    , f0199 : Bool
    , f0200 : Int
    , f0201 : Float
    , f0202 : Char
    , f0203 : String
    , f0204 : Bool
    , f0205 : Int
    , f0206 : Float
    , f0207 : Char
    , f0208 : String
    , f0209 : Bool
    , f0210 : Int
    , f0211 : Float
    , f0212 : Char
    , f0213 : String
    , f0214 : Bool
    , f0215 : Int
    , f0216 : Float
    , f0217 : Char
    , f0218 : String
    , f0219 : Bool
    , f0220 : Int
    , f0221 : Float
    , f0222 : Char
    , f0223 : String
    , f0224 : Bool
    , f0225 : Int
    , f0226 : Float
    , f0227 : Char
    , f0228 : String
    , f0229 : Bool
    , f0230 : Int
    , f0231 : Float
    , f0232 : Char
    , f0233 : String
    , f0234 : Bool
    , f0235 : Int
    , f0236 : Float
    , f0237 : Char
    , f0238 : String
    , f0239 : Bool
    , f0240 : Int
    , f0241 : Float
    , f0242 : Char
    , f0243 : String
    , f0244 : Bool
    , f0245 : Int
    , f0246 : Float
    , f0247 : Char
    , f0248 : String
    , f0249 : Bool
    , f0250 : Int
    , f0251 : Float
    , f0252 : Char
    , f0253 : String
    , f0254 : Bool
    , f0255 : Int
    , f0256 : Float
    , f0257 : Char
    , f0258 : String
    , f0259 : Bool
    , f0260 : Int
    , f0261 : Float
    , f0262 : Char
    , f0263 : String
    , f0264 : Bool
    , f0265 : Int
    , f0266 : Float
    , f0267 : Char
    , f0268 : String
    , f0269 : Bool
    , f0270 : Int
    , f0271 : Float
    , f0272 : Char
    , f0273 : String
    , f0274 : Bool
    , f0275 : Int
    , f0276 : Float
    , f0277 : Char
    , f0278 : String
    , f0279 : Bool
    , f0280 : Int
    , f0281 : Float
    , f0282 : Char
    , f0283 : String
    , f0284 : Bool
    , f0285 : Int
    , f0286 : Float
    , f0287 : Char
    , f0288 : String
    , f0289 : Bool
    , f0290 : Int
    , f0291 : Float
    , f0292 : Char
    , f0293 : String
    , f0294 : Bool
    , f0295 : Int
    , f0296 : Float
    , f0297 : Char
    , f0298 : String
    , f0299 : Bool
    , f0300 : Int
    , f0301 : Float
    , f0302 : Char
    , f0303 : String
    , f0304 : Bool
    , f0305 : Int
    , f0306 : Float
    , f0307 : Char
    , f0308 : String
    , f0309 : Bool
    , f0310 : Int
    , f0311 : Float
    , f0312 : Char
    , f0313 : String
    , f0314 : Bool
    , f0315 : Int
    , f0316 : Float
    , f0317 : Char
    , f0318 : String
    , f0319 : Bool
    , f0320 : Int
    , f0321 : Float
    , f0322 : Char
    , f0323 : String
    , f0324 : Bool
    , f0325 : Int
    , f0326 : Float
    , f0327 : Char
    , f0328 : String
    , f0329 : Bool
    , f0330 : Int
    , f0331 : Float
    , f0332 : Char
    , f0333 : String
    , f0334 : Bool
    , f0335 : Int
    , f0336 : Float
    , f0337 : Char
    , f0338 : String
    , f0339 : Bool
    , f0340 : Int
    , f0341 : Float
    , f0342 : Char
    , f0343 : String
    , f0344 : Bool
    , f0345 : Int
    , f0346 : Float
    , f0347 : Char
    , f0348 : String
    , f0349 : Bool
    , f0350 : Int
    , f0351 : Float
    , f0352 : Char
    , f0353 : String
    , f0354 : Bool
    , f0355 : Int
    , f0356 : Float
    , f0357 : Char
    , f0358 : String
    , f0359 : Bool
    , f0360 : Int
    , f0361 : Float
    , f0362 : Char
    , f0363 : String
    , f0364 : Bool
    , f0365 : Int
    , f0366 : Float
    , f0367 : Char
    , f0368 : String
    , f0369 : Bool
    , f0370 : Int
    , f0371 : Float
    , f0372 : Char
    , f0373 : String
    , f0374 : Bool
    , f0375 : Int
    , f0376 : Float
    , f0377 : Char
    , f0378 : String
    , f0379 : Bool
    , f0380 : Int
    , f0381 : Float
    , f0382 : Char
    , f0383 : String
    , f0384 : Bool
    , f0385 : Int
    , f0386 : Float
    , f0387 : Char
    , f0388 : String
    , f0389 : Bool
    , f0390 : Int
    , f0391 : Float
    , f0392 : Char
    , f0393 : String
    , f0394 : Bool
    , f0395 : Int
    , f0396 : Float
    , f0397 : Char
    , f0398 : String
    , f0399 : Bool
    , f0400 : Int
    , f0401 : Float
    , f0402 : Char
    , f0403 : String
    , f0404 : Bool
    , f0405 : Int
    , f0406 : Float
    , f0407 : Char
    , f0408 : String
    , f0409 : Bool
    , f0410 : Int
    , f0411 : Float
    , f0412 : Char
    , f0413 : String
    , f0414 : Bool
    , f0415 : Int
    , f0416 : Float
    , f0417 : Char
    , f0418 : String
    , f0419 : Bool
    , f0420 : Int
    , f0421 : Float
    , f0422 : Char
    , f0423 : String
    , f0424 : Bool
    , f0425 : Int
    , f0426 : Float
    , f0427 : Char
    , f0428 : String
    , f0429 : Bool
    , f0430 : Int
    , f0431 : Float
    , f0432 : Char
    , f0433 : String
    , f0434 : Bool
    , f0435 : Int
    , f0436 : Float
    , f0437 : Char
    , f0438 : String
    , f0439 : Bool
    , f0440 : Int
    , f0441 : Float
    , f0442 : Char
    , f0443 : String
    , f0444 : Bool
    , f0445 : Int
    , f0446 : Float
    , f0447 : Char
    , f0448 : String
    , f0449 : Bool
    , f0450 : Int
    , f0451 : Float
    , f0452 : Char
    , f0453 : String
    , f0454 : Bool
    , f0455 : Int
    , f0456 : Float
    , f0457 : Char
    , f0458 : String
    , f0459 : Bool
    , f0460 : Int
    , f0461 : Float
    , f0462 : Char
    , f0463 : String
    , f0464 : Bool
    , f0465 : Int
    , f0466 : Float
    , f0467 : Char
    , f0468 : String
    , f0469 : Bool
    , f0470 : Int
    , f0471 : Float
    , f0472 : Char
    , f0473 : String
    , f0474 : Bool
    , f0475 : Int
    , f0476 : Float
    , f0477 : Char
    , f0478 : String
    , f0479 : Bool
    , f0480 : Int
    , f0481 : Float
    , f0482 : Char
    , f0483 : String
    , f0484 : Bool
    , f0485 : Int
    , f0486 : Float
    , f0487 : Char
    , f0488 : String
    , f0489 : Bool
    , f0490 : Int
    , f0491 : Float
    , f0492 : Char
    , f0493 : String
    , f0494 : Bool
    , f0495 : Int
    , f0496 : Float
    , f0497 : Char
    , f0498 : String
    , f0499 : Bool
    , f0500 : Int
    , f0501 : Float
    , f0502 : Char
    , f0503 : String
    , f0504 : Bool
    , f0505 : Int
    , f0506 : Float
    , f0507 : Char
    , f0508 : String
    , f0509 : Bool
    , f0510 : Int
    , f0511 : Float
    , f0512 : Char
    , f0513 : String
    , f0514 : Bool
    , f0515 : Int
    , f0516 : Float
    , f0517 : Char
    , f0518 : String
    , f0519 : Bool
    , f0520 : Int
    , f0521 : Float
    , f0522 : Char
    , f0523 : String
    , f0524 : Bool
    , f0525 : Int
    , f0526 : Float
    , f0527 : Char
    , f0528 : String
    , f0529 : Bool
    , f0530 : Int
    , f0531 : Float
    , f0532 : Char
    , f0533 : String
    , f0534 : Bool
    , f0535 : Int
    , f0536 : Float
    , f0537 : Char
    , f0538 : String
    , f0539 : Bool
    , f0540 : Int
    , f0541 : Float
    , f0542 : Char
    , f0543 : String
    , f0544 : Bool
    , f0545 : Int
    , f0546 : Float
    , f0547 : Char
    , f0548 : String
    , f0549 : Bool
    , f0550 : Int
    , f0551 : Float
    , f0552 : Char
    , f0553 : String
    , f0554 : Bool
    , f0555 : Int
    , f0556 : Float
    , f0557 : Char
    , f0558 : String
    , f0559 : Bool
    , f0560 : Int
    , f0561 : Float
    , f0562 : Char
    , f0563 : String
    , f0564 : Bool
    , f0565 : Int
    , f0566 : Float
    , f0567 : Char
    , f0568 : String
    , f0569 : Bool
    , f0570 : Int
    , f0571 : Float
    , f0572 : Char
    , f0573 : String
    , f0574 : Bool
    , f0575 : Int
    , f0576 : Float
    , f0577 : Char
    , f0578 : String
    , f0579 : Bool
    , f0580 : Int
    , f0581 : Float
    , f0582 : Char
    , f0583 : String
    , f0584 : Bool
    , f0585 : Int
    , f0586 : Float
    , f0587 : Char
    , f0588 : String
    , f0589 : Bool
    , f0590 : Int
    , f0591 : Float
    , f0592 : Char
    , f0593 : String
    , f0594 : Bool
    , f0595 : Int
    , f0596 : Float
    , f0597 : Char
    , f0598 : String
    , f0599 : Bool
    }


make : Int -> R
make base =
    { f0000 = (base + 999)
        , f0001 = (toFloat base + 1.5 - 1)
        , f0002 = (Char.fromCode (base + 98))
        , f0003 = (String.fromInt (base + 2) ++ "s")
        , f0004 = (modBy 2 (base + 3) == 0)
        , f0005 = (base + 1004)
        , f0006 = (toFloat base + 6.5 - 1)
        , f0007 = (Char.fromCode (base + 103))
        , f0008 = (String.fromInt (base + 7) ++ "s")
        , f0009 = (modBy 2 (base + 8) == 0)
        , f0010 = (base + 1009)
        , f0011 = (toFloat base + 11.5 - 1)
        , f0012 = (Char.fromCode (base + 108))
        , f0013 = (String.fromInt (base + 12) ++ "s")
        , f0014 = (modBy 2 (base + 13) == 0)
        , f0015 = (base + 1014)
        , f0016 = (toFloat base + 16.5 - 1)
        , f0017 = (Char.fromCode (base + 113))
        , f0018 = (String.fromInt (base + 17) ++ "s")
        , f0019 = (modBy 2 (base + 18) == 0)
        , f0020 = (base + 1019)
        , f0021 = (toFloat base + 21.5 - 1)
        , f0022 = (Char.fromCode (base + 118))
        , f0023 = (String.fromInt (base + 22) ++ "s")
        , f0024 = (modBy 2 (base + 23) == 0)
        , f0025 = (base + 1024)
        , f0026 = (toFloat base + 26.5 - 1)
        , f0027 = (Char.fromCode (base + 97))
        , f0028 = (String.fromInt (base + 27) ++ "s")
        , f0029 = (modBy 2 (base + 28) == 0)
        , f0030 = (base + 1029)
        , f0031 = (toFloat base + 31.5 - 1)
        , f0032 = (Char.fromCode (base + 102))
        , f0033 = (String.fromInt (base + 32) ++ "s")
        , f0034 = (modBy 2 (base + 33) == 0)
        , f0035 = (base + 1034)
        , f0036 = (toFloat base + 36.5 - 1)
        , f0037 = (Char.fromCode (base + 107))
        , f0038 = (String.fromInt (base + 37) ++ "s")
        , f0039 = (modBy 2 (base + 38) == 0)
        , f0040 = (base + 1039)
        , f0041 = (toFloat base + 41.5 - 1)
        , f0042 = (Char.fromCode (base + 112))
        , f0043 = (String.fromInt (base + 42) ++ "s")
        , f0044 = (modBy 2 (base + 43) == 0)
        , f0045 = (base + 1044)
        , f0046 = (toFloat base + 46.5 - 1)
        , f0047 = (Char.fromCode (base + 117))
        , f0048 = (String.fromInt (base + 47) ++ "s")
        , f0049 = (modBy 2 (base + 48) == 0)
        , f0050 = (base + 1049)
        , f0051 = (toFloat base + 51.5 - 1)
        , f0052 = (Char.fromCode (base + 96))
        , f0053 = (String.fromInt (base + 52) ++ "s")
        , f0054 = (modBy 2 (base + 53) == 0)
        , f0055 = (base + 1054)
        , f0056 = (toFloat base + 56.5 - 1)
        , f0057 = (Char.fromCode (base + 101))
        , f0058 = (String.fromInt (base + 57) ++ "s")
        , f0059 = (modBy 2 (base + 58) == 0)
        , f0060 = (base + 1059)
        , f0061 = (toFloat base + 61.5 - 1)
        , f0062 = (Char.fromCode (base + 106))
        , f0063 = (String.fromInt (base + 62) ++ "s")
        , f0064 = (modBy 2 (base + 63) == 0)
        , f0065 = (base + 1064)
        , f0066 = (toFloat base + 66.5 - 1)
        , f0067 = (Char.fromCode (base + 111))
        , f0068 = (String.fromInt (base + 67) ++ "s")
        , f0069 = (modBy 2 (base + 68) == 0)
        , f0070 = (base + 1069)
        , f0071 = (toFloat base + 71.5 - 1)
        , f0072 = (Char.fromCode (base + 116))
        , f0073 = (String.fromInt (base + 72) ++ "s")
        , f0074 = (modBy 2 (base + 73) == 0)
        , f0075 = (base + 1074)
        , f0076 = (toFloat base + 76.5 - 1)
        , f0077 = (Char.fromCode (base + 121))
        , f0078 = (String.fromInt (base + 77) ++ "s")
        , f0079 = (modBy 2 (base + 78) == 0)
        , f0080 = (base + 1079)
        , f0081 = (toFloat base + 81.5 - 1)
        , f0082 = (Char.fromCode (base + 100))
        , f0083 = (String.fromInt (base + 82) ++ "s")
        , f0084 = (modBy 2 (base + 83) == 0)
        , f0085 = (base + 1084)
        , f0086 = (toFloat base + 86.5 - 1)
        , f0087 = (Char.fromCode (base + 105))
        , f0088 = (String.fromInt (base + 87) ++ "s")
        , f0089 = (modBy 2 (base + 88) == 0)
        , f0090 = (base + 1089)
        , f0091 = (toFloat base + 91.5 - 1)
        , f0092 = (Char.fromCode (base + 110))
        , f0093 = (String.fromInt (base + 92) ++ "s")
        , f0094 = (modBy 2 (base + 93) == 0)
        , f0095 = (base + 1094)
        , f0096 = (toFloat base + 96.5 - 1)
        , f0097 = (Char.fromCode (base + 115))
        , f0098 = (String.fromInt (base + 97) ++ "s")
        , f0099 = (modBy 2 (base + 98) == 0)
        , f0100 = (base + 1099)
        , f0101 = (toFloat base + 101.5 - 1)
        , f0102 = (Char.fromCode (base + 120))
        , f0103 = (String.fromInt (base + 102) ++ "s")
        , f0104 = (modBy 2 (base + 103) == 0)
        , f0105 = (base + 1104)
        , f0106 = (toFloat base + 106.5 - 1)
        , f0107 = (Char.fromCode (base + 99))
        , f0108 = (String.fromInt (base + 107) ++ "s")
        , f0109 = (modBy 2 (base + 108) == 0)
        , f0110 = (base + 1109)
        , f0111 = (toFloat base + 111.5 - 1)
        , f0112 = (Char.fromCode (base + 104))
        , f0113 = (String.fromInt (base + 112) ++ "s")
        , f0114 = (modBy 2 (base + 113) == 0)
        , f0115 = (base + 1114)
        , f0116 = (toFloat base + 116.5 - 1)
        , f0117 = (Char.fromCode (base + 109))
        , f0118 = (String.fromInt (base + 117) ++ "s")
        , f0119 = (modBy 2 (base + 118) == 0)
        , f0120 = (base + 1119)
        , f0121 = (toFloat base + 121.5 - 1)
        , f0122 = (Char.fromCode (base + 114))
        , f0123 = (String.fromInt (base + 122) ++ "s")
        , f0124 = (modBy 2 (base + 123) == 0)
        , f0125 = (base + 1124)
        , f0126 = (toFloat base + 126.5 - 1)
        , f0127 = (Char.fromCode (base + 119))
        , f0128 = (String.fromInt (base + 127) ++ "s")
        , f0129 = (modBy 2 (base + 128) == 0)
        , f0130 = (base + 1129)
        , f0131 = (toFloat base + 131.5 - 1)
        , f0132 = (Char.fromCode (base + 98))
        , f0133 = (String.fromInt (base + 132) ++ "s")
        , f0134 = (modBy 2 (base + 133) == 0)
        , f0135 = (base + 1134)
        , f0136 = (toFloat base + 136.5 - 1)
        , f0137 = (Char.fromCode (base + 103))
        , f0138 = (String.fromInt (base + 137) ++ "s")
        , f0139 = (modBy 2 (base + 138) == 0)
        , f0140 = (base + 1139)
        , f0141 = (toFloat base + 141.5 - 1)
        , f0142 = (Char.fromCode (base + 108))
        , f0143 = (String.fromInt (base + 142) ++ "s")
        , f0144 = (modBy 2 (base + 143) == 0)
        , f0145 = (base + 1144)
        , f0146 = (toFloat base + 146.5 - 1)
        , f0147 = (Char.fromCode (base + 113))
        , f0148 = (String.fromInt (base + 147) ++ "s")
        , f0149 = (modBy 2 (base + 148) == 0)
        , f0150 = (base + 1149)
        , f0151 = (toFloat base + 151.5 - 1)
        , f0152 = (Char.fromCode (base + 118))
        , f0153 = (String.fromInt (base + 152) ++ "s")
        , f0154 = (modBy 2 (base + 153) == 0)
        , f0155 = (base + 1154)
        , f0156 = (toFloat base + 156.5 - 1)
        , f0157 = (Char.fromCode (base + 97))
        , f0158 = (String.fromInt (base + 157) ++ "s")
        , f0159 = (modBy 2 (base + 158) == 0)
        , f0160 = (base + 1159)
        , f0161 = (toFloat base + 161.5 - 1)
        , f0162 = (Char.fromCode (base + 102))
        , f0163 = (String.fromInt (base + 162) ++ "s")
        , f0164 = (modBy 2 (base + 163) == 0)
        , f0165 = (base + 1164)
        , f0166 = (toFloat base + 166.5 - 1)
        , f0167 = (Char.fromCode (base + 107))
        , f0168 = (String.fromInt (base + 167) ++ "s")
        , f0169 = (modBy 2 (base + 168) == 0)
        , f0170 = (base + 1169)
        , f0171 = (toFloat base + 171.5 - 1)
        , f0172 = (Char.fromCode (base + 112))
        , f0173 = (String.fromInt (base + 172) ++ "s")
        , f0174 = (modBy 2 (base + 173) == 0)
        , f0175 = (base + 1174)
        , f0176 = (toFloat base + 176.5 - 1)
        , f0177 = (Char.fromCode (base + 117))
        , f0178 = (String.fromInt (base + 177) ++ "s")
        , f0179 = (modBy 2 (base + 178) == 0)
        , f0180 = (base + 1179)
        , f0181 = (toFloat base + 181.5 - 1)
        , f0182 = (Char.fromCode (base + 96))
        , f0183 = (String.fromInt (base + 182) ++ "s")
        , f0184 = (modBy 2 (base + 183) == 0)
        , f0185 = (base + 1184)
        , f0186 = (toFloat base + 186.5 - 1)
        , f0187 = (Char.fromCode (base + 101))
        , f0188 = (String.fromInt (base + 187) ++ "s")
        , f0189 = (modBy 2 (base + 188) == 0)
        , f0190 = (base + 1189)
        , f0191 = (toFloat base + 191.5 - 1)
        , f0192 = (Char.fromCode (base + 106))
        , f0193 = (String.fromInt (base + 192) ++ "s")
        , f0194 = (modBy 2 (base + 193) == 0)
        , f0195 = (base + 1194)
        , f0196 = (toFloat base + 196.5 - 1)
        , f0197 = (Char.fromCode (base + 111))
        , f0198 = (String.fromInt (base + 197) ++ "s")
        , f0199 = (modBy 2 (base + 198) == 0)
        , f0200 = (base + 1199)
        , f0201 = (toFloat base + 201.5 - 1)
        , f0202 = (Char.fromCode (base + 116))
        , f0203 = (String.fromInt (base + 202) ++ "s")
        , f0204 = (modBy 2 (base + 203) == 0)
        , f0205 = (base + 1204)
        , f0206 = (toFloat base + 206.5 - 1)
        , f0207 = (Char.fromCode (base + 121))
        , f0208 = (String.fromInt (base + 207) ++ "s")
        , f0209 = (modBy 2 (base + 208) == 0)
        , f0210 = (base + 1209)
        , f0211 = (toFloat base + 211.5 - 1)
        , f0212 = (Char.fromCode (base + 100))
        , f0213 = (String.fromInt (base + 212) ++ "s")
        , f0214 = (modBy 2 (base + 213) == 0)
        , f0215 = (base + 1214)
        , f0216 = (toFloat base + 216.5 - 1)
        , f0217 = (Char.fromCode (base + 105))
        , f0218 = (String.fromInt (base + 217) ++ "s")
        , f0219 = (modBy 2 (base + 218) == 0)
        , f0220 = (base + 1219)
        , f0221 = (toFloat base + 221.5 - 1)
        , f0222 = (Char.fromCode (base + 110))
        , f0223 = (String.fromInt (base + 222) ++ "s")
        , f0224 = (modBy 2 (base + 223) == 0)
        , f0225 = (base + 1224)
        , f0226 = (toFloat base + 226.5 - 1)
        , f0227 = (Char.fromCode (base + 115))
        , f0228 = (String.fromInt (base + 227) ++ "s")
        , f0229 = (modBy 2 (base + 228) == 0)
        , f0230 = (base + 1229)
        , f0231 = (toFloat base + 231.5 - 1)
        , f0232 = (Char.fromCode (base + 120))
        , f0233 = (String.fromInt (base + 232) ++ "s")
        , f0234 = (modBy 2 (base + 233) == 0)
        , f0235 = (base + 1234)
        , f0236 = (toFloat base + 236.5 - 1)
        , f0237 = (Char.fromCode (base + 99))
        , f0238 = (String.fromInt (base + 237) ++ "s")
        , f0239 = (modBy 2 (base + 238) == 0)
        , f0240 = (base + 1239)
        , f0241 = (toFloat base + 241.5 - 1)
        , f0242 = (Char.fromCode (base + 104))
        , f0243 = (String.fromInt (base + 242) ++ "s")
        , f0244 = (modBy 2 (base + 243) == 0)
        , f0245 = (base + 1244)
        , f0246 = (toFloat base + 246.5 - 1)
        , f0247 = (Char.fromCode (base + 109))
        , f0248 = (String.fromInt (base + 247) ++ "s")
        , f0249 = (modBy 2 (base + 248) == 0)
        , f0250 = (base + 1249)
        , f0251 = (toFloat base + 251.5 - 1)
        , f0252 = (Char.fromCode (base + 114))
        , f0253 = (String.fromInt (base + 252) ++ "s")
        , f0254 = (modBy 2 (base + 253) == 0)
        , f0255 = (base + 1254)
        , f0256 = (toFloat base + 256.5 - 1)
        , f0257 = (Char.fromCode (base + 119))
        , f0258 = (String.fromInt (base + 257) ++ "s")
        , f0259 = (modBy 2 (base + 258) == 0)
        , f0260 = (base + 1259)
        , f0261 = (toFloat base + 261.5 - 1)
        , f0262 = (Char.fromCode (base + 98))
        , f0263 = (String.fromInt (base + 262) ++ "s")
        , f0264 = (modBy 2 (base + 263) == 0)
        , f0265 = (base + 1264)
        , f0266 = (toFloat base + 266.5 - 1)
        , f0267 = (Char.fromCode (base + 103))
        , f0268 = (String.fromInt (base + 267) ++ "s")
        , f0269 = (modBy 2 (base + 268) == 0)
        , f0270 = (base + 1269)
        , f0271 = (toFloat base + 271.5 - 1)
        , f0272 = (Char.fromCode (base + 108))
        , f0273 = (String.fromInt (base + 272) ++ "s")
        , f0274 = (modBy 2 (base + 273) == 0)
        , f0275 = (base + 1274)
        , f0276 = (toFloat base + 276.5 - 1)
        , f0277 = (Char.fromCode (base + 113))
        , f0278 = (String.fromInt (base + 277) ++ "s")
        , f0279 = (modBy 2 (base + 278) == 0)
        , f0280 = (base + 1279)
        , f0281 = (toFloat base + 281.5 - 1)
        , f0282 = (Char.fromCode (base + 118))
        , f0283 = (String.fromInt (base + 282) ++ "s")
        , f0284 = (modBy 2 (base + 283) == 0)
        , f0285 = (base + 1284)
        , f0286 = (toFloat base + 286.5 - 1)
        , f0287 = (Char.fromCode (base + 97))
        , f0288 = (String.fromInt (base + 287) ++ "s")
        , f0289 = (modBy 2 (base + 288) == 0)
        , f0290 = (base + 1289)
        , f0291 = (toFloat base + 291.5 - 1)
        , f0292 = (Char.fromCode (base + 102))
        , f0293 = (String.fromInt (base + 292) ++ "s")
        , f0294 = (modBy 2 (base + 293) == 0)
        , f0295 = (base + 1294)
        , f0296 = (toFloat base + 296.5 - 1)
        , f0297 = (Char.fromCode (base + 107))
        , f0298 = (String.fromInt (base + 297) ++ "s")
        , f0299 = (modBy 2 (base + 298) == 0)
        , f0300 = (base + 1299)
        , f0301 = (toFloat base + 301.5 - 1)
        , f0302 = (Char.fromCode (base + 112))
        , f0303 = (String.fromInt (base + 302) ++ "s")
        , f0304 = (modBy 2 (base + 303) == 0)
        , f0305 = (base + 1304)
        , f0306 = (toFloat base + 306.5 - 1)
        , f0307 = (Char.fromCode (base + 117))
        , f0308 = (String.fromInt (base + 307) ++ "s")
        , f0309 = (modBy 2 (base + 308) == 0)
        , f0310 = (base + 1309)
        , f0311 = (toFloat base + 311.5 - 1)
        , f0312 = (Char.fromCode (base + 96))
        , f0313 = (String.fromInt (base + 312) ++ "s")
        , f0314 = (modBy 2 (base + 313) == 0)
        , f0315 = (base + 1314)
        , f0316 = (toFloat base + 316.5 - 1)
        , f0317 = (Char.fromCode (base + 101))
        , f0318 = (String.fromInt (base + 317) ++ "s")
        , f0319 = (modBy 2 (base + 318) == 0)
        , f0320 = (base + 1319)
        , f0321 = (toFloat base + 321.5 - 1)
        , f0322 = (Char.fromCode (base + 106))
        , f0323 = (String.fromInt (base + 322) ++ "s")
        , f0324 = (modBy 2 (base + 323) == 0)
        , f0325 = (base + 1324)
        , f0326 = (toFloat base + 326.5 - 1)
        , f0327 = (Char.fromCode (base + 111))
        , f0328 = (String.fromInt (base + 327) ++ "s")
        , f0329 = (modBy 2 (base + 328) == 0)
        , f0330 = (base + 1329)
        , f0331 = (toFloat base + 331.5 - 1)
        , f0332 = (Char.fromCode (base + 116))
        , f0333 = (String.fromInt (base + 332) ++ "s")
        , f0334 = (modBy 2 (base + 333) == 0)
        , f0335 = (base + 1334)
        , f0336 = (toFloat base + 336.5 - 1)
        , f0337 = (Char.fromCode (base + 121))
        , f0338 = (String.fromInt (base + 337) ++ "s")
        , f0339 = (modBy 2 (base + 338) == 0)
        , f0340 = (base + 1339)
        , f0341 = (toFloat base + 341.5 - 1)
        , f0342 = (Char.fromCode (base + 100))
        , f0343 = (String.fromInt (base + 342) ++ "s")
        , f0344 = (modBy 2 (base + 343) == 0)
        , f0345 = (base + 1344)
        , f0346 = (toFloat base + 346.5 - 1)
        , f0347 = (Char.fromCode (base + 105))
        , f0348 = (String.fromInt (base + 347) ++ "s")
        , f0349 = (modBy 2 (base + 348) == 0)
        , f0350 = (base + 1349)
        , f0351 = (toFloat base + 351.5 - 1)
        , f0352 = (Char.fromCode (base + 110))
        , f0353 = (String.fromInt (base + 352) ++ "s")
        , f0354 = (modBy 2 (base + 353) == 0)
        , f0355 = (base + 1354)
        , f0356 = (toFloat base + 356.5 - 1)
        , f0357 = (Char.fromCode (base + 115))
        , f0358 = (String.fromInt (base + 357) ++ "s")
        , f0359 = (modBy 2 (base + 358) == 0)
        , f0360 = (base + 1359)
        , f0361 = (toFloat base + 361.5 - 1)
        , f0362 = (Char.fromCode (base + 120))
        , f0363 = (String.fromInt (base + 362) ++ "s")
        , f0364 = (modBy 2 (base + 363) == 0)
        , f0365 = (base + 1364)
        , f0366 = (toFloat base + 366.5 - 1)
        , f0367 = (Char.fromCode (base + 99))
        , f0368 = (String.fromInt (base + 367) ++ "s")
        , f0369 = (modBy 2 (base + 368) == 0)
        , f0370 = (base + 1369)
        , f0371 = (toFloat base + 371.5 - 1)
        , f0372 = (Char.fromCode (base + 104))
        , f0373 = (String.fromInt (base + 372) ++ "s")
        , f0374 = (modBy 2 (base + 373) == 0)
        , f0375 = (base + 1374)
        , f0376 = (toFloat base + 376.5 - 1)
        , f0377 = (Char.fromCode (base + 109))
        , f0378 = (String.fromInt (base + 377) ++ "s")
        , f0379 = (modBy 2 (base + 378) == 0)
        , f0380 = (base + 1379)
        , f0381 = (toFloat base + 381.5 - 1)
        , f0382 = (Char.fromCode (base + 114))
        , f0383 = (String.fromInt (base + 382) ++ "s")
        , f0384 = (modBy 2 (base + 383) == 0)
        , f0385 = (base + 1384)
        , f0386 = (toFloat base + 386.5 - 1)
        , f0387 = (Char.fromCode (base + 119))
        , f0388 = (String.fromInt (base + 387) ++ "s")
        , f0389 = (modBy 2 (base + 388) == 0)
        , f0390 = (base + 1389)
        , f0391 = (toFloat base + 391.5 - 1)
        , f0392 = (Char.fromCode (base + 98))
        , f0393 = (String.fromInt (base + 392) ++ "s")
        , f0394 = (modBy 2 (base + 393) == 0)
        , f0395 = (base + 1394)
        , f0396 = (toFloat base + 396.5 - 1)
        , f0397 = (Char.fromCode (base + 103))
        , f0398 = (String.fromInt (base + 397) ++ "s")
        , f0399 = (modBy 2 (base + 398) == 0)
        , f0400 = (base + 1399)
        , f0401 = (toFloat base + 401.5 - 1)
        , f0402 = (Char.fromCode (base + 108))
        , f0403 = (String.fromInt (base + 402) ++ "s")
        , f0404 = (modBy 2 (base + 403) == 0)
        , f0405 = (base + 1404)
        , f0406 = (toFloat base + 406.5 - 1)
        , f0407 = (Char.fromCode (base + 113))
        , f0408 = (String.fromInt (base + 407) ++ "s")
        , f0409 = (modBy 2 (base + 408) == 0)
        , f0410 = (base + 1409)
        , f0411 = (toFloat base + 411.5 - 1)
        , f0412 = (Char.fromCode (base + 118))
        , f0413 = (String.fromInt (base + 412) ++ "s")
        , f0414 = (modBy 2 (base + 413) == 0)
        , f0415 = (base + 1414)
        , f0416 = (toFloat base + 416.5 - 1)
        , f0417 = (Char.fromCode (base + 97))
        , f0418 = (String.fromInt (base + 417) ++ "s")
        , f0419 = (modBy 2 (base + 418) == 0)
        , f0420 = (base + 1419)
        , f0421 = (toFloat base + 421.5 - 1)
        , f0422 = (Char.fromCode (base + 102))
        , f0423 = (String.fromInt (base + 422) ++ "s")
        , f0424 = (modBy 2 (base + 423) == 0)
        , f0425 = (base + 1424)
        , f0426 = (toFloat base + 426.5 - 1)
        , f0427 = (Char.fromCode (base + 107))
        , f0428 = (String.fromInt (base + 427) ++ "s")
        , f0429 = (modBy 2 (base + 428) == 0)
        , f0430 = (base + 1429)
        , f0431 = (toFloat base + 431.5 - 1)
        , f0432 = (Char.fromCode (base + 112))
        , f0433 = (String.fromInt (base + 432) ++ "s")
        , f0434 = (modBy 2 (base + 433) == 0)
        , f0435 = (base + 1434)
        , f0436 = (toFloat base + 436.5 - 1)
        , f0437 = (Char.fromCode (base + 117))
        , f0438 = (String.fromInt (base + 437) ++ "s")
        , f0439 = (modBy 2 (base + 438) == 0)
        , f0440 = (base + 1439)
        , f0441 = (toFloat base + 441.5 - 1)
        , f0442 = (Char.fromCode (base + 96))
        , f0443 = (String.fromInt (base + 442) ++ "s")
        , f0444 = (modBy 2 (base + 443) == 0)
        , f0445 = (base + 1444)
        , f0446 = (toFloat base + 446.5 - 1)
        , f0447 = (Char.fromCode (base + 101))
        , f0448 = (String.fromInt (base + 447) ++ "s")
        , f0449 = (modBy 2 (base + 448) == 0)
        , f0450 = (base + 1449)
        , f0451 = (toFloat base + 451.5 - 1)
        , f0452 = (Char.fromCode (base + 106))
        , f0453 = (String.fromInt (base + 452) ++ "s")
        , f0454 = (modBy 2 (base + 453) == 0)
        , f0455 = (base + 1454)
        , f0456 = (toFloat base + 456.5 - 1)
        , f0457 = (Char.fromCode (base + 111))
        , f0458 = (String.fromInt (base + 457) ++ "s")
        , f0459 = (modBy 2 (base + 458) == 0)
        , f0460 = (base + 1459)
        , f0461 = (toFloat base + 461.5 - 1)
        , f0462 = (Char.fromCode (base + 116))
        , f0463 = (String.fromInt (base + 462) ++ "s")
        , f0464 = (modBy 2 (base + 463) == 0)
        , f0465 = (base + 1464)
        , f0466 = (toFloat base + 466.5 - 1)
        , f0467 = (Char.fromCode (base + 121))
        , f0468 = (String.fromInt (base + 467) ++ "s")
        , f0469 = (modBy 2 (base + 468) == 0)
        , f0470 = (base + 1469)
        , f0471 = (toFloat base + 471.5 - 1)
        , f0472 = (Char.fromCode (base + 100))
        , f0473 = (String.fromInt (base + 472) ++ "s")
        , f0474 = (modBy 2 (base + 473) == 0)
        , f0475 = (base + 1474)
        , f0476 = (toFloat base + 476.5 - 1)
        , f0477 = (Char.fromCode (base + 105))
        , f0478 = (String.fromInt (base + 477) ++ "s")
        , f0479 = (modBy 2 (base + 478) == 0)
        , f0480 = (base + 1479)
        , f0481 = (toFloat base + 481.5 - 1)
        , f0482 = (Char.fromCode (base + 110))
        , f0483 = (String.fromInt (base + 482) ++ "s")
        , f0484 = (modBy 2 (base + 483) == 0)
        , f0485 = (base + 1484)
        , f0486 = (toFloat base + 486.5 - 1)
        , f0487 = (Char.fromCode (base + 115))
        , f0488 = (String.fromInt (base + 487) ++ "s")
        , f0489 = (modBy 2 (base + 488) == 0)
        , f0490 = (base + 1489)
        , f0491 = (toFloat base + 491.5 - 1)
        , f0492 = (Char.fromCode (base + 120))
        , f0493 = (String.fromInt (base + 492) ++ "s")
        , f0494 = (modBy 2 (base + 493) == 0)
        , f0495 = (base + 1494)
        , f0496 = (toFloat base + 496.5 - 1)
        , f0497 = (Char.fromCode (base + 99))
        , f0498 = (String.fromInt (base + 497) ++ "s")
        , f0499 = (modBy 2 (base + 498) == 0)
        , f0500 = (base + 1499)
        , f0501 = (toFloat base + 501.5 - 1)
        , f0502 = (Char.fromCode (base + 104))
        , f0503 = (String.fromInt (base + 502) ++ "s")
        , f0504 = (modBy 2 (base + 503) == 0)
        , f0505 = (base + 1504)
        , f0506 = (toFloat base + 506.5 - 1)
        , f0507 = (Char.fromCode (base + 109))
        , f0508 = (String.fromInt (base + 507) ++ "s")
        , f0509 = (modBy 2 (base + 508) == 0)
        , f0510 = (base + 1509)
        , f0511 = (toFloat base + 511.5 - 1)
        , f0512 = (Char.fromCode (base + 114))
        , f0513 = (String.fromInt (base + 512) ++ "s")
        , f0514 = (modBy 2 (base + 513) == 0)
        , f0515 = (base + 1514)
        , f0516 = (toFloat base + 516.5 - 1)
        , f0517 = (Char.fromCode (base + 119))
        , f0518 = (String.fromInt (base + 517) ++ "s")
        , f0519 = (modBy 2 (base + 518) == 0)
        , f0520 = (base + 1519)
        , f0521 = (toFloat base + 521.5 - 1)
        , f0522 = (Char.fromCode (base + 98))
        , f0523 = (String.fromInt (base + 522) ++ "s")
        , f0524 = (modBy 2 (base + 523) == 0)
        , f0525 = (base + 1524)
        , f0526 = (toFloat base + 526.5 - 1)
        , f0527 = (Char.fromCode (base + 103))
        , f0528 = (String.fromInt (base + 527) ++ "s")
        , f0529 = (modBy 2 (base + 528) == 0)
        , f0530 = (base + 1529)
        , f0531 = (toFloat base + 531.5 - 1)
        , f0532 = (Char.fromCode (base + 108))
        , f0533 = (String.fromInt (base + 532) ++ "s")
        , f0534 = (modBy 2 (base + 533) == 0)
        , f0535 = (base + 1534)
        , f0536 = (toFloat base + 536.5 - 1)
        , f0537 = (Char.fromCode (base + 113))
        , f0538 = (String.fromInt (base + 537) ++ "s")
        , f0539 = (modBy 2 (base + 538) == 0)
        , f0540 = (base + 1539)
        , f0541 = (toFloat base + 541.5 - 1)
        , f0542 = (Char.fromCode (base + 118))
        , f0543 = (String.fromInt (base + 542) ++ "s")
        , f0544 = (modBy 2 (base + 543) == 0)
        , f0545 = (base + 1544)
        , f0546 = (toFloat base + 546.5 - 1)
        , f0547 = (Char.fromCode (base + 97))
        , f0548 = (String.fromInt (base + 547) ++ "s")
        , f0549 = (modBy 2 (base + 548) == 0)
        , f0550 = (base + 1549)
        , f0551 = (toFloat base + 551.5 - 1)
        , f0552 = (Char.fromCode (base + 102))
        , f0553 = (String.fromInt (base + 552) ++ "s")
        , f0554 = (modBy 2 (base + 553) == 0)
        , f0555 = (base + 1554)
        , f0556 = (toFloat base + 556.5 - 1)
        , f0557 = (Char.fromCode (base + 107))
        , f0558 = (String.fromInt (base + 557) ++ "s")
        , f0559 = (modBy 2 (base + 558) == 0)
        , f0560 = (base + 1559)
        , f0561 = (toFloat base + 561.5 - 1)
        , f0562 = (Char.fromCode (base + 112))
        , f0563 = (String.fromInt (base + 562) ++ "s")
        , f0564 = (modBy 2 (base + 563) == 0)
        , f0565 = (base + 1564)
        , f0566 = (toFloat base + 566.5 - 1)
        , f0567 = (Char.fromCode (base + 117))
        , f0568 = (String.fromInt (base + 567) ++ "s")
        , f0569 = (modBy 2 (base + 568) == 0)
        , f0570 = (base + 1569)
        , f0571 = (toFloat base + 571.5 - 1)
        , f0572 = (Char.fromCode (base + 96))
        , f0573 = (String.fromInt (base + 572) ++ "s")
        , f0574 = (modBy 2 (base + 573) == 0)
        , f0575 = (base + 1574)
        , f0576 = (toFloat base + 576.5 - 1)
        , f0577 = (Char.fromCode (base + 101))
        , f0578 = (String.fromInt (base + 577) ++ "s")
        , f0579 = (modBy 2 (base + 578) == 0)
        , f0580 = (base + 1579)
        , f0581 = (toFloat base + 581.5 - 1)
        , f0582 = (Char.fromCode (base + 106))
        , f0583 = (String.fromInt (base + 582) ++ "s")
        , f0584 = (modBy 2 (base + 583) == 0)
        , f0585 = (base + 1584)
        , f0586 = (toFloat base + 586.5 - 1)
        , f0587 = (Char.fromCode (base + 111))
        , f0588 = (String.fromInt (base + 587) ++ "s")
        , f0589 = (modBy 2 (base + 588) == 0)
        , f0590 = (base + 1589)
        , f0591 = (toFloat base + 591.5 - 1)
        , f0592 = (Char.fromCode (base + 116))
        , f0593 = (String.fromInt (base + 592) ++ "s")
        , f0594 = (modBy 2 (base + 593) == 0)
        , f0595 = (base + 1594)
        , f0596 = (toFloat base + 596.5 - 1)
        , f0597 = (Char.fromCode (base + 121))
        , f0598 = (String.fromInt (base + 597) ++ "s")
        , f0599 = (modBy 2 (base + 598) == 0)
    }


viaPat : R -> ( Int, Bool )
viaPat { f0000, f0599 } =
    ( f0000, f0599 )


upd : R -> R
upd r =
    { r | f0599 = not r.f0599 }


main =
    let
        base =
            1 + List.length [ () ] - 1

        r =
            make base

        _ =
            Debug.log "f0000" (r.f0000)

        _ =
            Debug.log "f0031" (r.f0031)

        _ =
            Debug.log "f0032" (r.f0032)

        _ =
            Debug.log "f0063" (r.f0063)

        _ =
            Debug.log "f0064" (r.f0064)

        _ =
            Debug.log "f0599" (r.f0599)

        _ =
            Debug.log "pattern" (viaPat r)

        _ =
            Debug.log "update" ((upd r).f0599)

        _ =
            Debug.log "eq self" (r == make base)

        _ =
            Debug.log "eq updated" (r == upd r)

    in
    text "done"
