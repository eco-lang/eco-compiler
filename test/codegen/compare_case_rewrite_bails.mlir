// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// EcoCompareCaseRewrite v1 is deliberately narrow. These three shapes must be
// left exactly as written; the whole-output CHECK-NOTs assert that none of the
// rewrite's artifacts (sign tests, bool cases, cmp3) appear anywhere.
//
// Sibling: compare_case_rewrite_structural.mlir (the shapes that DO rewrite).

module {
  // BAIL: the Order value escapes (returned), so its single use is not a case.
  func.func private @bail_escapes(%a: i64, %b: i64) -> !eco.value {
    %o = eco.int.cmp_order %a, %b : i64
    eco.return %o : !eco.value
  }
  // CHECK-LABEL: @bail_escapes
  // CHECK: eco.int.cmp_order

  // BAIL: a partial tag list (a wildcard collapse) is not a permutation of
  // [0,1,2]. Rewriting it would need a default-arm story v1 does not have.
  func.func private @bail_partial(%a: i64, %b: i64, %l: !eco.value, %r: !eco.value) -> !eco.value {
    %o = eco.int.cmp_order %a, %b : i64
    %res = eco.case %o : !eco.value [0, 1] -> (!eco.value) {case_kind = "ctor"} {
      eco.yield %l : !eco.value
    }, {
      eco.yield %r : !eco.value
    }
    eco.return %res : !eco.value
  }
  // CHECK-LABEL: @bail_partial
  // CHECK: [0, 1]

  // BAIL: multi-use (get_tag chain alongside the case) — the lexicographic
  // tuple-compare shape, where the Order value itself is also consumed.
  func.func private @bail_multiuse(%a: i64, %b: i64, %l: !eco.value, %r: !eco.value) -> !eco.value {
    %o = eco.int.cmp_order %a, %b : i64
    %t = eco.get_tag %o : !eco.value -> i32
    %res = eco.case %o : !eco.value [0, 1, 2] -> (!eco.value) {case_kind = "ctor"} {
      eco.yield %l : !eco.value
    }, {
      %e = eco.constant Empty : !eco.value
      eco.yield %e : !eco.value
    }, {
      eco.yield %r : !eco.value
    }
    eco.return %res : !eco.value
  }
  // CHECK-LABEL: @bail_multiuse
  // CHECK: eco.get_tag
  // CHECK: [0, 1, 2]

  // No rewrite artifact anywhere in the output.
  // CHECK-NOT: eco.int.lt
  // CHECK-NOT: eco.int.gt
  // CHECK-NOT: cmp3
  // CHECK-NOT: case_kind = "bool"
}
