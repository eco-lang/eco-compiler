#pragma once

#include "../TestSuite.hpp"

// Tests covering the dynamic per-allocation lazy-sweep pacing introduced in
// plans/dynamic-pressure-aware-sweep.md.

extern Testing::TestCase testSweepBudgetMonotonicByPressure;
extern Testing::TestCase testSweepBudgetUnsweptRatioBoost;
extern Testing::TestCase testSweepBudgetMinimumIsSweepWorkBudget;
extern Testing::TestCase testSweepBudgetClampedToHardCap;
