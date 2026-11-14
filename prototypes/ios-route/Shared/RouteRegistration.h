#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>

// Publications are serialized by the extension's main actor. Interruption
// callbacks may arrive concurrently, including after a later publication.
typedef struct { _Atomic uint64_t value; } ARRegistration;
enum { ARRegistrationPending = 1, ARRegistrationReady = 2,
       ARRegistrationInterrupted = 3, ARRegistrationStateMask = 3 };

static inline uint64_t ar_registration_begin(ARRegistration *registration) {
    uint64_t token = (atomic_load(&registration->value) & ~UINT64_C(3)) + UINT64_C(4);
    atomic_store(&registration->value, token | ARRegistrationPending);
    return token;
}

static inline bool ar_registration_finish(ARRegistration *registration, uint64_t token, bool success) {
    uint64_t pending = token | ARRegistrationPending;
    bool updated = atomic_compare_exchange_strong(&registration->value, &pending,
        token | (success ? ARRegistrationReady : ARRegistrationInterrupted));
    return success && updated;
}

static inline bool ar_registration_interrupt(ARRegistration *registration, uint64_t token) {
    uint64_t current = atomic_load(&registration->value);
    while ((current & ~UINT64_C(3)) == token &&
           (current & ARRegistrationStateMask) != ARRegistrationInterrupted) {
        if (atomic_compare_exchange_weak(&registration->value, &current,
                                        token | ARRegistrationInterrupted)) return true;
    }
    return false;
}

static inline bool ar_registration_ready(const ARRegistration *registration) {
    return (atomic_load(&registration->value) & ARRegistrationStateMask) == ARRegistrationReady;
}
