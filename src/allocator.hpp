#ifndef ECO_ALLOCATOR_H
#define ECO_ALLOCATOR_H

#include <stdbool.h>
#include <stddef.h>

#include "heap.h"

int GC_init();
void GC_register_root(void **root);
void GC_init_root(void **global_permanent_ptr, void *(*init_func)());
void GC_collect_major();
void GC_collect_minor();
void *GC_execute(Closure *c);

void *GC_allocate(bool push_to_stack, ptrdiff_t words);
void *GC_memcpy(void *dest, void *src, size_t words);

typedef u16 GcStackMapIndex;

void GC_stack_push_value(void *value);
void GC_stack_pop_frame(void *func, void *result, GcStackMapIndex push);
void *GC_stack_pop_value();
void GC_stack_tailcall(int count, ...);
GcStackMapIndex GC_stack_push_frame(char func_type_flag, void *func);

#endif // ECO_ALLOCATOR_H