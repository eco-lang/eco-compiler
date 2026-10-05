module WideRecord1100Test exposing (main)

{-| 1100-field mixed record: > 8 KiB large object (nursery-large / YLOS).
-}

-- CHECK: f0000: 1000
-- CHECK: f0031: 31.5
-- CHECK: f0032: 'g'
-- CHECK: f1023: "1023s"
-- CHECK: f1024: True
-- CHECK: f1099: False
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
    , f0600 : Int
    , f0601 : Float
    , f0602 : Char
    , f0603 : String
    , f0604 : Bool
    , f0605 : Int
    , f0606 : Float
    , f0607 : Char
    , f0608 : String
    , f0609 : Bool
    , f0610 : Int
    , f0611 : Float
    , f0612 : Char
    , f0613 : String
    , f0614 : Bool
    , f0615 : Int
    , f0616 : Float
    , f0617 : Char
    , f0618 : String
    , f0619 : Bool
    , f0620 : Int
    , f0621 : Float
    , f0622 : Char
    , f0623 : String
    , f0624 : Bool
    , f0625 : Int
    , f0626 : Float
    , f0627 : Char
    , f0628 : String
    , f0629 : Bool
    , f0630 : Int
    , f0631 : Float
    , f0632 : Char
    , f0633 : String
    , f0634 : Bool
    , f0635 : Int
    , f0636 : Float
    , f0637 : Char
    , f0638 : String
    , f0639 : Bool
    , f0640 : Int
    , f0641 : Float
    , f0642 : Char
    , f0643 : String
    , f0644 : Bool
    , f0645 : Int
    , f0646 : Float
    , f0647 : Char
    , f0648 : String
    , f0649 : Bool
    , f0650 : Int
    , f0651 : Float
    , f0652 : Char
    , f0653 : String
    , f0654 : Bool
    , f0655 : Int
    , f0656 : Float
    , f0657 : Char
    , f0658 : String
    , f0659 : Bool
    , f0660 : Int
    , f0661 : Float
    , f0662 : Char
    , f0663 : String
    , f0664 : Bool
    , f0665 : Int
    , f0666 : Float
    , f0667 : Char
    , f0668 : String
    , f0669 : Bool
    , f0670 : Int
    , f0671 : Float
    , f0672 : Char
    , f0673 : String
    , f0674 : Bool
    , f0675 : Int
    , f0676 : Float
    , f0677 : Char
    , f0678 : String
    , f0679 : Bool
    , f0680 : Int
    , f0681 : Float
    , f0682 : Char
    , f0683 : String
    , f0684 : Bool
    , f0685 : Int
    , f0686 : Float
    , f0687 : Char
    , f0688 : String
    , f0689 : Bool
    , f0690 : Int
    , f0691 : Float
    , f0692 : Char
    , f0693 : String
    , f0694 : Bool
    , f0695 : Int
    , f0696 : Float
    , f0697 : Char
    , f0698 : String
    , f0699 : Bool
    , f0700 : Int
    , f0701 : Float
    , f0702 : Char
    , f0703 : String
    , f0704 : Bool
    , f0705 : Int
    , f0706 : Float
    , f0707 : Char
    , f0708 : String
    , f0709 : Bool
    , f0710 : Int
    , f0711 : Float
    , f0712 : Char
    , f0713 : String
    , f0714 : Bool
    , f0715 : Int
    , f0716 : Float
    , f0717 : Char
    , f0718 : String
    , f0719 : Bool
    , f0720 : Int
    , f0721 : Float
    , f0722 : Char
    , f0723 : String
    , f0724 : Bool
    , f0725 : Int
    , f0726 : Float
    , f0727 : Char
    , f0728 : String
    , f0729 : Bool
    , f0730 : Int
    , f0731 : Float
    , f0732 : Char
    , f0733 : String
    , f0734 : Bool
    , f0735 : Int
    , f0736 : Float
    , f0737 : Char
    , f0738 : String
    , f0739 : Bool
    , f0740 : Int
    , f0741 : Float
    , f0742 : Char
    , f0743 : String
    , f0744 : Bool
    , f0745 : Int
    , f0746 : Float
    , f0747 : Char
    , f0748 : String
    , f0749 : Bool
    , f0750 : Int
    , f0751 : Float
    , f0752 : Char
    , f0753 : String
    , f0754 : Bool
    , f0755 : Int
    , f0756 : Float
    , f0757 : Char
    , f0758 : String
    , f0759 : Bool
    , f0760 : Int
    , f0761 : Float
    , f0762 : Char
    , f0763 : String
    , f0764 : Bool
    , f0765 : Int
    , f0766 : Float
    , f0767 : Char
    , f0768 : String
    , f0769 : Bool
    , f0770 : Int
    , f0771 : Float
    , f0772 : Char
    , f0773 : String
    , f0774 : Bool
    , f0775 : Int
    , f0776 : Float
    , f0777 : Char
    , f0778 : String
    , f0779 : Bool
    , f0780 : Int
    , f0781 : Float
    , f0782 : Char
    , f0783 : String
    , f0784 : Bool
    , f0785 : Int
    , f0786 : Float
    , f0787 : Char
    , f0788 : String
    , f0789 : Bool
    , f0790 : Int
    , f0791 : Float
    , f0792 : Char
    , f0793 : String
    , f0794 : Bool
    , f0795 : Int
    , f0796 : Float
    , f0797 : Char
    , f0798 : String
    , f0799 : Bool
    , f0800 : Int
    , f0801 : Float
    , f0802 : Char
    , f0803 : String
    , f0804 : Bool
    , f0805 : Int
    , f0806 : Float
    , f0807 : Char
    , f0808 : String
    , f0809 : Bool
    , f0810 : Int
    , f0811 : Float
    , f0812 : Char
    , f0813 : String
    , f0814 : Bool
    , f0815 : Int
    , f0816 : Float
    , f0817 : Char
    , f0818 : String
    , f0819 : Bool
    , f0820 : Int
    , f0821 : Float
    , f0822 : Char
    , f0823 : String
    , f0824 : Bool
    , f0825 : Int
    , f0826 : Float
    , f0827 : Char
    , f0828 : String
    , f0829 : Bool
    , f0830 : Int
    , f0831 : Float
    , f0832 : Char
    , f0833 : String
    , f0834 : Bool
    , f0835 : Int
    , f0836 : Float
    , f0837 : Char
    , f0838 : String
    , f0839 : Bool
    , f0840 : Int
    , f0841 : Float
    , f0842 : Char
    , f0843 : String
    , f0844 : Bool
    , f0845 : Int
    , f0846 : Float
    , f0847 : Char
    , f0848 : String
    , f0849 : Bool
    , f0850 : Int
    , f0851 : Float
    , f0852 : Char
    , f0853 : String
    , f0854 : Bool
    , f0855 : Int
    , f0856 : Float
    , f0857 : Char
    , f0858 : String
    , f0859 : Bool
    , f0860 : Int
    , f0861 : Float
    , f0862 : Char
    , f0863 : String
    , f0864 : Bool
    , f0865 : Int
    , f0866 : Float
    , f0867 : Char
    , f0868 : String
    , f0869 : Bool
    , f0870 : Int
    , f0871 : Float
    , f0872 : Char
    , f0873 : String
    , f0874 : Bool
    , f0875 : Int
    , f0876 : Float
    , f0877 : Char
    , f0878 : String
    , f0879 : Bool
    , f0880 : Int
    , f0881 : Float
    , f0882 : Char
    , f0883 : String
    , f0884 : Bool
    , f0885 : Int
    , f0886 : Float
    , f0887 : Char
    , f0888 : String
    , f0889 : Bool
    , f0890 : Int
    , f0891 : Float
    , f0892 : Char
    , f0893 : String
    , f0894 : Bool
    , f0895 : Int
    , f0896 : Float
    , f0897 : Char
    , f0898 : String
    , f0899 : Bool
    , f0900 : Int
    , f0901 : Float
    , f0902 : Char
    , f0903 : String
    , f0904 : Bool
    , f0905 : Int
    , f0906 : Float
    , f0907 : Char
    , f0908 : String
    , f0909 : Bool
    , f0910 : Int
    , f0911 : Float
    , f0912 : Char
    , f0913 : String
    , f0914 : Bool
    , f0915 : Int
    , f0916 : Float
    , f0917 : Char
    , f0918 : String
    , f0919 : Bool
    , f0920 : Int
    , f0921 : Float
    , f0922 : Char
    , f0923 : String
    , f0924 : Bool
    , f0925 : Int
    , f0926 : Float
    , f0927 : Char
    , f0928 : String
    , f0929 : Bool
    , f0930 : Int
    , f0931 : Float
    , f0932 : Char
    , f0933 : String
    , f0934 : Bool
    , f0935 : Int
    , f0936 : Float
    , f0937 : Char
    , f0938 : String
    , f0939 : Bool
    , f0940 : Int
    , f0941 : Float
    , f0942 : Char
    , f0943 : String
    , f0944 : Bool
    , f0945 : Int
    , f0946 : Float
    , f0947 : Char
    , f0948 : String
    , f0949 : Bool
    , f0950 : Int
    , f0951 : Float
    , f0952 : Char
    , f0953 : String
    , f0954 : Bool
    , f0955 : Int
    , f0956 : Float
    , f0957 : Char
    , f0958 : String
    , f0959 : Bool
    , f0960 : Int
    , f0961 : Float
    , f0962 : Char
    , f0963 : String
    , f0964 : Bool
    , f0965 : Int
    , f0966 : Float
    , f0967 : Char
    , f0968 : String
    , f0969 : Bool
    , f0970 : Int
    , f0971 : Float
    , f0972 : Char
    , f0973 : String
    , f0974 : Bool
    , f0975 : Int
    , f0976 : Float
    , f0977 : Char
    , f0978 : String
    , f0979 : Bool
    , f0980 : Int
    , f0981 : Float
    , f0982 : Char
    , f0983 : String
    , f0984 : Bool
    , f0985 : Int
    , f0986 : Float
    , f0987 : Char
    , f0988 : String
    , f0989 : Bool
    , f0990 : Int
    , f0991 : Float
    , f0992 : Char
    , f0993 : String
    , f0994 : Bool
    , f0995 : Int
    , f0996 : Float
    , f0997 : Char
    , f0998 : String
    , f0999 : Bool
    , f1000 : Int
    , f1001 : Float
    , f1002 : Char
    , f1003 : String
    , f1004 : Bool
    , f1005 : Int
    , f1006 : Float
    , f1007 : Char
    , f1008 : String
    , f1009 : Bool
    , f1010 : Int
    , f1011 : Float
    , f1012 : Char
    , f1013 : String
    , f1014 : Bool
    , f1015 : Int
    , f1016 : Float
    , f1017 : Char
    , f1018 : String
    , f1019 : Bool
    , f1020 : Int
    , f1021 : Float
    , f1022 : Char
    , f1023 : String
    , f1024 : Bool
    , f1025 : Int
    , f1026 : Float
    , f1027 : Char
    , f1028 : String
    , f1029 : Bool
    , f1030 : Int
    , f1031 : Float
    , f1032 : Char
    , f1033 : String
    , f1034 : Bool
    , f1035 : Int
    , f1036 : Float
    , f1037 : Char
    , f1038 : String
    , f1039 : Bool
    , f1040 : Int
    , f1041 : Float
    , f1042 : Char
    , f1043 : String
    , f1044 : Bool
    , f1045 : Int
    , f1046 : Float
    , f1047 : Char
    , f1048 : String
    , f1049 : Bool
    , f1050 : Int
    , f1051 : Float
    , f1052 : Char
    , f1053 : String
    , f1054 : Bool
    , f1055 : Int
    , f1056 : Float
    , f1057 : Char
    , f1058 : String
    , f1059 : Bool
    , f1060 : Int
    , f1061 : Float
    , f1062 : Char
    , f1063 : String
    , f1064 : Bool
    , f1065 : Int
    , f1066 : Float
    , f1067 : Char
    , f1068 : String
    , f1069 : Bool
    , f1070 : Int
    , f1071 : Float
    , f1072 : Char
    , f1073 : String
    , f1074 : Bool
    , f1075 : Int
    , f1076 : Float
    , f1077 : Char
    , f1078 : String
    , f1079 : Bool
    , f1080 : Int
    , f1081 : Float
    , f1082 : Char
    , f1083 : String
    , f1084 : Bool
    , f1085 : Int
    , f1086 : Float
    , f1087 : Char
    , f1088 : String
    , f1089 : Bool
    , f1090 : Int
    , f1091 : Float
    , f1092 : Char
    , f1093 : String
    , f1094 : Bool
    , f1095 : Int
    , f1096 : Float
    , f1097 : Char
    , f1098 : String
    , f1099 : Bool
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
        , f0600 = (base + 1599)
        , f0601 = (toFloat base + 601.5 - 1)
        , f0602 = (Char.fromCode (base + 100))
        , f0603 = (String.fromInt (base + 602) ++ "s")
        , f0604 = (modBy 2 (base + 603) == 0)
        , f0605 = (base + 1604)
        , f0606 = (toFloat base + 606.5 - 1)
        , f0607 = (Char.fromCode (base + 105))
        , f0608 = (String.fromInt (base + 607) ++ "s")
        , f0609 = (modBy 2 (base + 608) == 0)
        , f0610 = (base + 1609)
        , f0611 = (toFloat base + 611.5 - 1)
        , f0612 = (Char.fromCode (base + 110))
        , f0613 = (String.fromInt (base + 612) ++ "s")
        , f0614 = (modBy 2 (base + 613) == 0)
        , f0615 = (base + 1614)
        , f0616 = (toFloat base + 616.5 - 1)
        , f0617 = (Char.fromCode (base + 115))
        , f0618 = (String.fromInt (base + 617) ++ "s")
        , f0619 = (modBy 2 (base + 618) == 0)
        , f0620 = (base + 1619)
        , f0621 = (toFloat base + 621.5 - 1)
        , f0622 = (Char.fromCode (base + 120))
        , f0623 = (String.fromInt (base + 622) ++ "s")
        , f0624 = (modBy 2 (base + 623) == 0)
        , f0625 = (base + 1624)
        , f0626 = (toFloat base + 626.5 - 1)
        , f0627 = (Char.fromCode (base + 99))
        , f0628 = (String.fromInt (base + 627) ++ "s")
        , f0629 = (modBy 2 (base + 628) == 0)
        , f0630 = (base + 1629)
        , f0631 = (toFloat base + 631.5 - 1)
        , f0632 = (Char.fromCode (base + 104))
        , f0633 = (String.fromInt (base + 632) ++ "s")
        , f0634 = (modBy 2 (base + 633) == 0)
        , f0635 = (base + 1634)
        , f0636 = (toFloat base + 636.5 - 1)
        , f0637 = (Char.fromCode (base + 109))
        , f0638 = (String.fromInt (base + 637) ++ "s")
        , f0639 = (modBy 2 (base + 638) == 0)
        , f0640 = (base + 1639)
        , f0641 = (toFloat base + 641.5 - 1)
        , f0642 = (Char.fromCode (base + 114))
        , f0643 = (String.fromInt (base + 642) ++ "s")
        , f0644 = (modBy 2 (base + 643) == 0)
        , f0645 = (base + 1644)
        , f0646 = (toFloat base + 646.5 - 1)
        , f0647 = (Char.fromCode (base + 119))
        , f0648 = (String.fromInt (base + 647) ++ "s")
        , f0649 = (modBy 2 (base + 648) == 0)
        , f0650 = (base + 1649)
        , f0651 = (toFloat base + 651.5 - 1)
        , f0652 = (Char.fromCode (base + 98))
        , f0653 = (String.fromInt (base + 652) ++ "s")
        , f0654 = (modBy 2 (base + 653) == 0)
        , f0655 = (base + 1654)
        , f0656 = (toFloat base + 656.5 - 1)
        , f0657 = (Char.fromCode (base + 103))
        , f0658 = (String.fromInt (base + 657) ++ "s")
        , f0659 = (modBy 2 (base + 658) == 0)
        , f0660 = (base + 1659)
        , f0661 = (toFloat base + 661.5 - 1)
        , f0662 = (Char.fromCode (base + 108))
        , f0663 = (String.fromInt (base + 662) ++ "s")
        , f0664 = (modBy 2 (base + 663) == 0)
        , f0665 = (base + 1664)
        , f0666 = (toFloat base + 666.5 - 1)
        , f0667 = (Char.fromCode (base + 113))
        , f0668 = (String.fromInt (base + 667) ++ "s")
        , f0669 = (modBy 2 (base + 668) == 0)
        , f0670 = (base + 1669)
        , f0671 = (toFloat base + 671.5 - 1)
        , f0672 = (Char.fromCode (base + 118))
        , f0673 = (String.fromInt (base + 672) ++ "s")
        , f0674 = (modBy 2 (base + 673) == 0)
        , f0675 = (base + 1674)
        , f0676 = (toFloat base + 676.5 - 1)
        , f0677 = (Char.fromCode (base + 97))
        , f0678 = (String.fromInt (base + 677) ++ "s")
        , f0679 = (modBy 2 (base + 678) == 0)
        , f0680 = (base + 1679)
        , f0681 = (toFloat base + 681.5 - 1)
        , f0682 = (Char.fromCode (base + 102))
        , f0683 = (String.fromInt (base + 682) ++ "s")
        , f0684 = (modBy 2 (base + 683) == 0)
        , f0685 = (base + 1684)
        , f0686 = (toFloat base + 686.5 - 1)
        , f0687 = (Char.fromCode (base + 107))
        , f0688 = (String.fromInt (base + 687) ++ "s")
        , f0689 = (modBy 2 (base + 688) == 0)
        , f0690 = (base + 1689)
        , f0691 = (toFloat base + 691.5 - 1)
        , f0692 = (Char.fromCode (base + 112))
        , f0693 = (String.fromInt (base + 692) ++ "s")
        , f0694 = (modBy 2 (base + 693) == 0)
        , f0695 = (base + 1694)
        , f0696 = (toFloat base + 696.5 - 1)
        , f0697 = (Char.fromCode (base + 117))
        , f0698 = (String.fromInt (base + 697) ++ "s")
        , f0699 = (modBy 2 (base + 698) == 0)
        , f0700 = (base + 1699)
        , f0701 = (toFloat base + 701.5 - 1)
        , f0702 = (Char.fromCode (base + 96))
        , f0703 = (String.fromInt (base + 702) ++ "s")
        , f0704 = (modBy 2 (base + 703) == 0)
        , f0705 = (base + 1704)
        , f0706 = (toFloat base + 706.5 - 1)
        , f0707 = (Char.fromCode (base + 101))
        , f0708 = (String.fromInt (base + 707) ++ "s")
        , f0709 = (modBy 2 (base + 708) == 0)
        , f0710 = (base + 1709)
        , f0711 = (toFloat base + 711.5 - 1)
        , f0712 = (Char.fromCode (base + 106))
        , f0713 = (String.fromInt (base + 712) ++ "s")
        , f0714 = (modBy 2 (base + 713) == 0)
        , f0715 = (base + 1714)
        , f0716 = (toFloat base + 716.5 - 1)
        , f0717 = (Char.fromCode (base + 111))
        , f0718 = (String.fromInt (base + 717) ++ "s")
        , f0719 = (modBy 2 (base + 718) == 0)
        , f0720 = (base + 1719)
        , f0721 = (toFloat base + 721.5 - 1)
        , f0722 = (Char.fromCode (base + 116))
        , f0723 = (String.fromInt (base + 722) ++ "s")
        , f0724 = (modBy 2 (base + 723) == 0)
        , f0725 = (base + 1724)
        , f0726 = (toFloat base + 726.5 - 1)
        , f0727 = (Char.fromCode (base + 121))
        , f0728 = (String.fromInt (base + 727) ++ "s")
        , f0729 = (modBy 2 (base + 728) == 0)
        , f0730 = (base + 1729)
        , f0731 = (toFloat base + 731.5 - 1)
        , f0732 = (Char.fromCode (base + 100))
        , f0733 = (String.fromInt (base + 732) ++ "s")
        , f0734 = (modBy 2 (base + 733) == 0)
        , f0735 = (base + 1734)
        , f0736 = (toFloat base + 736.5 - 1)
        , f0737 = (Char.fromCode (base + 105))
        , f0738 = (String.fromInt (base + 737) ++ "s")
        , f0739 = (modBy 2 (base + 738) == 0)
        , f0740 = (base + 1739)
        , f0741 = (toFloat base + 741.5 - 1)
        , f0742 = (Char.fromCode (base + 110))
        , f0743 = (String.fromInt (base + 742) ++ "s")
        , f0744 = (modBy 2 (base + 743) == 0)
        , f0745 = (base + 1744)
        , f0746 = (toFloat base + 746.5 - 1)
        , f0747 = (Char.fromCode (base + 115))
        , f0748 = (String.fromInt (base + 747) ++ "s")
        , f0749 = (modBy 2 (base + 748) == 0)
        , f0750 = (base + 1749)
        , f0751 = (toFloat base + 751.5 - 1)
        , f0752 = (Char.fromCode (base + 120))
        , f0753 = (String.fromInt (base + 752) ++ "s")
        , f0754 = (modBy 2 (base + 753) == 0)
        , f0755 = (base + 1754)
        , f0756 = (toFloat base + 756.5 - 1)
        , f0757 = (Char.fromCode (base + 99))
        , f0758 = (String.fromInt (base + 757) ++ "s")
        , f0759 = (modBy 2 (base + 758) == 0)
        , f0760 = (base + 1759)
        , f0761 = (toFloat base + 761.5 - 1)
        , f0762 = (Char.fromCode (base + 104))
        , f0763 = (String.fromInt (base + 762) ++ "s")
        , f0764 = (modBy 2 (base + 763) == 0)
        , f0765 = (base + 1764)
        , f0766 = (toFloat base + 766.5 - 1)
        , f0767 = (Char.fromCode (base + 109))
        , f0768 = (String.fromInt (base + 767) ++ "s")
        , f0769 = (modBy 2 (base + 768) == 0)
        , f0770 = (base + 1769)
        , f0771 = (toFloat base + 771.5 - 1)
        , f0772 = (Char.fromCode (base + 114))
        , f0773 = (String.fromInt (base + 772) ++ "s")
        , f0774 = (modBy 2 (base + 773) == 0)
        , f0775 = (base + 1774)
        , f0776 = (toFloat base + 776.5 - 1)
        , f0777 = (Char.fromCode (base + 119))
        , f0778 = (String.fromInt (base + 777) ++ "s")
        , f0779 = (modBy 2 (base + 778) == 0)
        , f0780 = (base + 1779)
        , f0781 = (toFloat base + 781.5 - 1)
        , f0782 = (Char.fromCode (base + 98))
        , f0783 = (String.fromInt (base + 782) ++ "s")
        , f0784 = (modBy 2 (base + 783) == 0)
        , f0785 = (base + 1784)
        , f0786 = (toFloat base + 786.5 - 1)
        , f0787 = (Char.fromCode (base + 103))
        , f0788 = (String.fromInt (base + 787) ++ "s")
        , f0789 = (modBy 2 (base + 788) == 0)
        , f0790 = (base + 1789)
        , f0791 = (toFloat base + 791.5 - 1)
        , f0792 = (Char.fromCode (base + 108))
        , f0793 = (String.fromInt (base + 792) ++ "s")
        , f0794 = (modBy 2 (base + 793) == 0)
        , f0795 = (base + 1794)
        , f0796 = (toFloat base + 796.5 - 1)
        , f0797 = (Char.fromCode (base + 113))
        , f0798 = (String.fromInt (base + 797) ++ "s")
        , f0799 = (modBy 2 (base + 798) == 0)
        , f0800 = (base + 1799)
        , f0801 = (toFloat base + 801.5 - 1)
        , f0802 = (Char.fromCode (base + 118))
        , f0803 = (String.fromInt (base + 802) ++ "s")
        , f0804 = (modBy 2 (base + 803) == 0)
        , f0805 = (base + 1804)
        , f0806 = (toFloat base + 806.5 - 1)
        , f0807 = (Char.fromCode (base + 97))
        , f0808 = (String.fromInt (base + 807) ++ "s")
        , f0809 = (modBy 2 (base + 808) == 0)
        , f0810 = (base + 1809)
        , f0811 = (toFloat base + 811.5 - 1)
        , f0812 = (Char.fromCode (base + 102))
        , f0813 = (String.fromInt (base + 812) ++ "s")
        , f0814 = (modBy 2 (base + 813) == 0)
        , f0815 = (base + 1814)
        , f0816 = (toFloat base + 816.5 - 1)
        , f0817 = (Char.fromCode (base + 107))
        , f0818 = (String.fromInt (base + 817) ++ "s")
        , f0819 = (modBy 2 (base + 818) == 0)
        , f0820 = (base + 1819)
        , f0821 = (toFloat base + 821.5 - 1)
        , f0822 = (Char.fromCode (base + 112))
        , f0823 = (String.fromInt (base + 822) ++ "s")
        , f0824 = (modBy 2 (base + 823) == 0)
        , f0825 = (base + 1824)
        , f0826 = (toFloat base + 826.5 - 1)
        , f0827 = (Char.fromCode (base + 117))
        , f0828 = (String.fromInt (base + 827) ++ "s")
        , f0829 = (modBy 2 (base + 828) == 0)
        , f0830 = (base + 1829)
        , f0831 = (toFloat base + 831.5 - 1)
        , f0832 = (Char.fromCode (base + 96))
        , f0833 = (String.fromInt (base + 832) ++ "s")
        , f0834 = (modBy 2 (base + 833) == 0)
        , f0835 = (base + 1834)
        , f0836 = (toFloat base + 836.5 - 1)
        , f0837 = (Char.fromCode (base + 101))
        , f0838 = (String.fromInt (base + 837) ++ "s")
        , f0839 = (modBy 2 (base + 838) == 0)
        , f0840 = (base + 1839)
        , f0841 = (toFloat base + 841.5 - 1)
        , f0842 = (Char.fromCode (base + 106))
        , f0843 = (String.fromInt (base + 842) ++ "s")
        , f0844 = (modBy 2 (base + 843) == 0)
        , f0845 = (base + 1844)
        , f0846 = (toFloat base + 846.5 - 1)
        , f0847 = (Char.fromCode (base + 111))
        , f0848 = (String.fromInt (base + 847) ++ "s")
        , f0849 = (modBy 2 (base + 848) == 0)
        , f0850 = (base + 1849)
        , f0851 = (toFloat base + 851.5 - 1)
        , f0852 = (Char.fromCode (base + 116))
        , f0853 = (String.fromInt (base + 852) ++ "s")
        , f0854 = (modBy 2 (base + 853) == 0)
        , f0855 = (base + 1854)
        , f0856 = (toFloat base + 856.5 - 1)
        , f0857 = (Char.fromCode (base + 121))
        , f0858 = (String.fromInt (base + 857) ++ "s")
        , f0859 = (modBy 2 (base + 858) == 0)
        , f0860 = (base + 1859)
        , f0861 = (toFloat base + 861.5 - 1)
        , f0862 = (Char.fromCode (base + 100))
        , f0863 = (String.fromInt (base + 862) ++ "s")
        , f0864 = (modBy 2 (base + 863) == 0)
        , f0865 = (base + 1864)
        , f0866 = (toFloat base + 866.5 - 1)
        , f0867 = (Char.fromCode (base + 105))
        , f0868 = (String.fromInt (base + 867) ++ "s")
        , f0869 = (modBy 2 (base + 868) == 0)
        , f0870 = (base + 1869)
        , f0871 = (toFloat base + 871.5 - 1)
        , f0872 = (Char.fromCode (base + 110))
        , f0873 = (String.fromInt (base + 872) ++ "s")
        , f0874 = (modBy 2 (base + 873) == 0)
        , f0875 = (base + 1874)
        , f0876 = (toFloat base + 876.5 - 1)
        , f0877 = (Char.fromCode (base + 115))
        , f0878 = (String.fromInt (base + 877) ++ "s")
        , f0879 = (modBy 2 (base + 878) == 0)
        , f0880 = (base + 1879)
        , f0881 = (toFloat base + 881.5 - 1)
        , f0882 = (Char.fromCode (base + 120))
        , f0883 = (String.fromInt (base + 882) ++ "s")
        , f0884 = (modBy 2 (base + 883) == 0)
        , f0885 = (base + 1884)
        , f0886 = (toFloat base + 886.5 - 1)
        , f0887 = (Char.fromCode (base + 99))
        , f0888 = (String.fromInt (base + 887) ++ "s")
        , f0889 = (modBy 2 (base + 888) == 0)
        , f0890 = (base + 1889)
        , f0891 = (toFloat base + 891.5 - 1)
        , f0892 = (Char.fromCode (base + 104))
        , f0893 = (String.fromInt (base + 892) ++ "s")
        , f0894 = (modBy 2 (base + 893) == 0)
        , f0895 = (base + 1894)
        , f0896 = (toFloat base + 896.5 - 1)
        , f0897 = (Char.fromCode (base + 109))
        , f0898 = (String.fromInt (base + 897) ++ "s")
        , f0899 = (modBy 2 (base + 898) == 0)
        , f0900 = (base + 1899)
        , f0901 = (toFloat base + 901.5 - 1)
        , f0902 = (Char.fromCode (base + 114))
        , f0903 = (String.fromInt (base + 902) ++ "s")
        , f0904 = (modBy 2 (base + 903) == 0)
        , f0905 = (base + 1904)
        , f0906 = (toFloat base + 906.5 - 1)
        , f0907 = (Char.fromCode (base + 119))
        , f0908 = (String.fromInt (base + 907) ++ "s")
        , f0909 = (modBy 2 (base + 908) == 0)
        , f0910 = (base + 1909)
        , f0911 = (toFloat base + 911.5 - 1)
        , f0912 = (Char.fromCode (base + 98))
        , f0913 = (String.fromInt (base + 912) ++ "s")
        , f0914 = (modBy 2 (base + 913) == 0)
        , f0915 = (base + 1914)
        , f0916 = (toFloat base + 916.5 - 1)
        , f0917 = (Char.fromCode (base + 103))
        , f0918 = (String.fromInt (base + 917) ++ "s")
        , f0919 = (modBy 2 (base + 918) == 0)
        , f0920 = (base + 1919)
        , f0921 = (toFloat base + 921.5 - 1)
        , f0922 = (Char.fromCode (base + 108))
        , f0923 = (String.fromInt (base + 922) ++ "s")
        , f0924 = (modBy 2 (base + 923) == 0)
        , f0925 = (base + 1924)
        , f0926 = (toFloat base + 926.5 - 1)
        , f0927 = (Char.fromCode (base + 113))
        , f0928 = (String.fromInt (base + 927) ++ "s")
        , f0929 = (modBy 2 (base + 928) == 0)
        , f0930 = (base + 1929)
        , f0931 = (toFloat base + 931.5 - 1)
        , f0932 = (Char.fromCode (base + 118))
        , f0933 = (String.fromInt (base + 932) ++ "s")
        , f0934 = (modBy 2 (base + 933) == 0)
        , f0935 = (base + 1934)
        , f0936 = (toFloat base + 936.5 - 1)
        , f0937 = (Char.fromCode (base + 97))
        , f0938 = (String.fromInt (base + 937) ++ "s")
        , f0939 = (modBy 2 (base + 938) == 0)
        , f0940 = (base + 1939)
        , f0941 = (toFloat base + 941.5 - 1)
        , f0942 = (Char.fromCode (base + 102))
        , f0943 = (String.fromInt (base + 942) ++ "s")
        , f0944 = (modBy 2 (base + 943) == 0)
        , f0945 = (base + 1944)
        , f0946 = (toFloat base + 946.5 - 1)
        , f0947 = (Char.fromCode (base + 107))
        , f0948 = (String.fromInt (base + 947) ++ "s")
        , f0949 = (modBy 2 (base + 948) == 0)
        , f0950 = (base + 1949)
        , f0951 = (toFloat base + 951.5 - 1)
        , f0952 = (Char.fromCode (base + 112))
        , f0953 = (String.fromInt (base + 952) ++ "s")
        , f0954 = (modBy 2 (base + 953) == 0)
        , f0955 = (base + 1954)
        , f0956 = (toFloat base + 956.5 - 1)
        , f0957 = (Char.fromCode (base + 117))
        , f0958 = (String.fromInt (base + 957) ++ "s")
        , f0959 = (modBy 2 (base + 958) == 0)
        , f0960 = (base + 1959)
        , f0961 = (toFloat base + 961.5 - 1)
        , f0962 = (Char.fromCode (base + 96))
        , f0963 = (String.fromInt (base + 962) ++ "s")
        , f0964 = (modBy 2 (base + 963) == 0)
        , f0965 = (base + 1964)
        , f0966 = (toFloat base + 966.5 - 1)
        , f0967 = (Char.fromCode (base + 101))
        , f0968 = (String.fromInt (base + 967) ++ "s")
        , f0969 = (modBy 2 (base + 968) == 0)
        , f0970 = (base + 1969)
        , f0971 = (toFloat base + 971.5 - 1)
        , f0972 = (Char.fromCode (base + 106))
        , f0973 = (String.fromInt (base + 972) ++ "s")
        , f0974 = (modBy 2 (base + 973) == 0)
        , f0975 = (base + 1974)
        , f0976 = (toFloat base + 976.5 - 1)
        , f0977 = (Char.fromCode (base + 111))
        , f0978 = (String.fromInt (base + 977) ++ "s")
        , f0979 = (modBy 2 (base + 978) == 0)
        , f0980 = (base + 1979)
        , f0981 = (toFloat base + 981.5 - 1)
        , f0982 = (Char.fromCode (base + 116))
        , f0983 = (String.fromInt (base + 982) ++ "s")
        , f0984 = (modBy 2 (base + 983) == 0)
        , f0985 = (base + 1984)
        , f0986 = (toFloat base + 986.5 - 1)
        , f0987 = (Char.fromCode (base + 121))
        , f0988 = (String.fromInt (base + 987) ++ "s")
        , f0989 = (modBy 2 (base + 988) == 0)
        , f0990 = (base + 1989)
        , f0991 = (toFloat base + 991.5 - 1)
        , f0992 = (Char.fromCode (base + 100))
        , f0993 = (String.fromInt (base + 992) ++ "s")
        , f0994 = (modBy 2 (base + 993) == 0)
        , f0995 = (base + 1994)
        , f0996 = (toFloat base + 996.5 - 1)
        , f0997 = (Char.fromCode (base + 105))
        , f0998 = (String.fromInt (base + 997) ++ "s")
        , f0999 = (modBy 2 (base + 998) == 0)
        , f1000 = (base + 1999)
        , f1001 = (toFloat base + 1001.5 - 1)
        , f1002 = (Char.fromCode (base + 110))
        , f1003 = (String.fromInt (base + 1002) ++ "s")
        , f1004 = (modBy 2 (base + 1003) == 0)
        , f1005 = (base + 2004)
        , f1006 = (toFloat base + 1006.5 - 1)
        , f1007 = (Char.fromCode (base + 115))
        , f1008 = (String.fromInt (base + 1007) ++ "s")
        , f1009 = (modBy 2 (base + 1008) == 0)
        , f1010 = (base + 2009)
        , f1011 = (toFloat base + 1011.5 - 1)
        , f1012 = (Char.fromCode (base + 120))
        , f1013 = (String.fromInt (base + 1012) ++ "s")
        , f1014 = (modBy 2 (base + 1013) == 0)
        , f1015 = (base + 2014)
        , f1016 = (toFloat base + 1016.5 - 1)
        , f1017 = (Char.fromCode (base + 99))
        , f1018 = (String.fromInt (base + 1017) ++ "s")
        , f1019 = (modBy 2 (base + 1018) == 0)
        , f1020 = (base + 2019)
        , f1021 = (toFloat base + 1021.5 - 1)
        , f1022 = (Char.fromCode (base + 104))
        , f1023 = (String.fromInt (base + 1022) ++ "s")
        , f1024 = (modBy 2 (base + 1023) == 0)
        , f1025 = (base + 2024)
        , f1026 = (toFloat base + 1026.5 - 1)
        , f1027 = (Char.fromCode (base + 109))
        , f1028 = (String.fromInt (base + 1027) ++ "s")
        , f1029 = (modBy 2 (base + 1028) == 0)
        , f1030 = (base + 2029)
        , f1031 = (toFloat base + 1031.5 - 1)
        , f1032 = (Char.fromCode (base + 114))
        , f1033 = (String.fromInt (base + 1032) ++ "s")
        , f1034 = (modBy 2 (base + 1033) == 0)
        , f1035 = (base + 2034)
        , f1036 = (toFloat base + 1036.5 - 1)
        , f1037 = (Char.fromCode (base + 119))
        , f1038 = (String.fromInt (base + 1037) ++ "s")
        , f1039 = (modBy 2 (base + 1038) == 0)
        , f1040 = (base + 2039)
        , f1041 = (toFloat base + 1041.5 - 1)
        , f1042 = (Char.fromCode (base + 98))
        , f1043 = (String.fromInt (base + 1042) ++ "s")
        , f1044 = (modBy 2 (base + 1043) == 0)
        , f1045 = (base + 2044)
        , f1046 = (toFloat base + 1046.5 - 1)
        , f1047 = (Char.fromCode (base + 103))
        , f1048 = (String.fromInt (base + 1047) ++ "s")
        , f1049 = (modBy 2 (base + 1048) == 0)
        , f1050 = (base + 2049)
        , f1051 = (toFloat base + 1051.5 - 1)
        , f1052 = (Char.fromCode (base + 108))
        , f1053 = (String.fromInt (base + 1052) ++ "s")
        , f1054 = (modBy 2 (base + 1053) == 0)
        , f1055 = (base + 2054)
        , f1056 = (toFloat base + 1056.5 - 1)
        , f1057 = (Char.fromCode (base + 113))
        , f1058 = (String.fromInt (base + 1057) ++ "s")
        , f1059 = (modBy 2 (base + 1058) == 0)
        , f1060 = (base + 2059)
        , f1061 = (toFloat base + 1061.5 - 1)
        , f1062 = (Char.fromCode (base + 118))
        , f1063 = (String.fromInt (base + 1062) ++ "s")
        , f1064 = (modBy 2 (base + 1063) == 0)
        , f1065 = (base + 2064)
        , f1066 = (toFloat base + 1066.5 - 1)
        , f1067 = (Char.fromCode (base + 97))
        , f1068 = (String.fromInt (base + 1067) ++ "s")
        , f1069 = (modBy 2 (base + 1068) == 0)
        , f1070 = (base + 2069)
        , f1071 = (toFloat base + 1071.5 - 1)
        , f1072 = (Char.fromCode (base + 102))
        , f1073 = (String.fromInt (base + 1072) ++ "s")
        , f1074 = (modBy 2 (base + 1073) == 0)
        , f1075 = (base + 2074)
        , f1076 = (toFloat base + 1076.5 - 1)
        , f1077 = (Char.fromCode (base + 107))
        , f1078 = (String.fromInt (base + 1077) ++ "s")
        , f1079 = (modBy 2 (base + 1078) == 0)
        , f1080 = (base + 2079)
        , f1081 = (toFloat base + 1081.5 - 1)
        , f1082 = (Char.fromCode (base + 112))
        , f1083 = (String.fromInt (base + 1082) ++ "s")
        , f1084 = (modBy 2 (base + 1083) == 0)
        , f1085 = (base + 2084)
        , f1086 = (toFloat base + 1086.5 - 1)
        , f1087 = (Char.fromCode (base + 117))
        , f1088 = (String.fromInt (base + 1087) ++ "s")
        , f1089 = (modBy 2 (base + 1088) == 0)
        , f1090 = (base + 2089)
        , f1091 = (toFloat base + 1091.5 - 1)
        , f1092 = (Char.fromCode (base + 96))
        , f1093 = (String.fromInt (base + 1092) ++ "s")
        , f1094 = (modBy 2 (base + 1093) == 0)
        , f1095 = (base + 2094)
        , f1096 = (toFloat base + 1096.5 - 1)
        , f1097 = (Char.fromCode (base + 101))
        , f1098 = (String.fromInt (base + 1097) ++ "s")
        , f1099 = (modBy 2 (base + 1098) == 0)
    }


viaPat : R -> ( Int, Bool )
viaPat { f0000, f1099 } =
    ( f0000, f1099 )


upd : R -> R
upd r =
    { r | f1099 = not r.f1099 }


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
            Debug.log "f1023" (r.f1023)

        _ =
            Debug.log "f1024" (r.f1024)

        _ =
            Debug.log "f1099" (r.f1099)

        _ =
            Debug.log "pattern" (viaPat r)

        _ =
            Debug.log "update" ((upd r).f1099)

        _ =
            Debug.log "eq self" (r == make base)

        _ =
            Debug.log "eq updated" (r == upd r)

    in
    text "done"
