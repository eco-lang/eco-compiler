#ifndef ECO_GENERATORS_HPP
#define ECO_GENERATORS_HPP

#include <random>
#include <rapidcheck.h>
#include <vector>
#include "heap.hpp"

using namespace Elm;

void *createRandomPrimitive(std::mt19937 &rng);
Unboxable createRandomUnboxable(std::mt19937 &rng, const std::vector<void *> &existing_objects, bool &is_boxed);
void *createRandomComposite(std::mt19937 &rng, const std::vector<void *> &existing_objects);

#endif // ECO_RUNTIME_GENERATORS_HPP
