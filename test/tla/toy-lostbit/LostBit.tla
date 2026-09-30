------------------------------ MODULE LostBit ------------------------------
\* The primer's example (plans/threaded-gc-tla-primer.md §1): two threads each set
\* a different bit of one mark byte. With a plain `b |= mask` (Plain = TRUE) the
\* load and the store are two steps, and one thread's bit can be lost; `fetch_or`
\* (Plain = FALSE) is one atomic step. The toy model that proves the tla-check
\* targets end to end, including a mutant (parent plan §9 Step 1).
EXTENDS Naturals
CONSTANT Plain
(* --algorithm LostBit
variables byte = {};                  \* the set of bits that are 1
process T \in {1, 2}
variables tmp = {};
begin
  Load:
    if Plain then
        tmp := byte;                  \* uint8_t v = b;
      Store:
        byte := tmp \cup {self};      \* b = v | mask;
    else
        byte := byte \cup {self};     \* fetch_or(mask): one atomic step
    end if;
end process;
end algorithm; *)
\* BEGIN TRANSLATION
VARIABLES pc, byte, tmp

vars == << pc, byte, tmp >>

ProcSet == ({1, 2})

Init == (* Global variables *)
        /\ byte = {}
        (* Process T *)
        /\ tmp = [self \in {1, 2} |-> {}]
        /\ pc = [self \in ProcSet |-> "Load"]

Load(self) == /\ pc[self] = "Load"
              /\ IF Plain
                    THEN /\ tmp' = [tmp EXCEPT ![self] = byte]
                         /\ pc' = [pc EXCEPT ![self] = "Store"]
                         /\ byte' = byte
                    ELSE /\ byte' = (byte \cup {self})
                         /\ pc' = [pc EXCEPT ![self] = "Done"]
                         /\ tmp' = tmp

Store(self) == /\ pc[self] = "Store"
               /\ byte' = (tmp[self] \cup {self})
               /\ pc' = [pc EXCEPT ![self] = "Done"]
               /\ tmp' = tmp

T(self) == Load(self) \/ Store(self)

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == (\E self \in {1, 2}: T(self))
           \/ Terminating

Spec == Init /\ [][Next]_vars

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION
BothBitsSet == (\A t \in {1, 2} : pc[t] = "Done") => byte = {1, 2}
=============================================================================
