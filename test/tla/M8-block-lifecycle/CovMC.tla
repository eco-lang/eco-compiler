------------------------------- MODULE CovMC -------------------------------
(***************************************************************************)
(* By hand, not a models.txt row: which code paths a configuration         *)
(* exercises. Run a configuration with Cov = TRUE, INVARIANT CovInv and    *)
(* POSTCONDITION CovReport (coverage.cfg), one worker (TLC registers are    *)
(* per worker); the report is the union of h.ev over every reachable state. *)
(***************************************************************************)
EXTENDS MC
ASSUME TLCSet(1, {})
CovInv == TLCSet(1, TLCGet(1) \cup h.ev)
CovReport == PrintT(<<"COVERAGE", TLCGet(1)>>)
=============================================================================
