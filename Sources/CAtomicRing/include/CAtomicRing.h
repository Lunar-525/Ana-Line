#pragma once
#include <stdint.h>

/// C11 atomic slots for the lock-free audio ring buffer. Swift has no atomic
/// integer of its own on the deployment targets we support, so the shared
/// counters live here as plain int64 slots accessed through the compiler's
/// atomic builtins. Every function is static inline: no runtime call, no lock,
/// nothing that can block the Core Audio render thread.

static inline void ring_store_relaxed(int64_t *slot, int64_t value) {
    __atomic_store_n(slot, value, __ATOMIC_RELAXED);
}
static inline void ring_store_release(int64_t *slot, int64_t value) {
    __atomic_store_n(slot, value, __ATOMIC_RELEASE);
}
static inline int64_t ring_load_relaxed(int64_t *slot) {
    return __atomic_load_n(slot, __ATOMIC_RELAXED);
}
static inline int64_t ring_load_acquire(int64_t *slot) {
    return __atomic_load_n(slot, __ATOMIC_ACQUIRE);
}
static inline int64_t ring_fetch_add_relaxed(int64_t *slot, int64_t value) {
    return __atomic_fetch_add(slot, value, __ATOMIC_RELAXED);
}
