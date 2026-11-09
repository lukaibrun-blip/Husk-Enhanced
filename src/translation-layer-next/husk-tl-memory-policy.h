/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HUSK_TL_MEMORY_POLICY_H
#define HUSK_TL_MEMORY_POLICY_H

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

#define TL_GUEST_MAP_FIXED 0x10
#define TL_GUEST_MAP_ANONYMOUS 0x20

/* Keep the allocator decision and launch argument construction independently testable. */
static inline bool tl_unity_system_allocator_enabled(const char *force, bool address_space_short)
{
    return force ? atoi(force) != 0 : address_space_short;
}

static inline void tl_unity_format_command_line(char *out, size_t size, bool system_allocator, const char *extra_args)
{
    if (!size) return;
    snprintf(out, size, "%s%s%s", system_allocator ? "-systemallocator" : "",
             system_allocator && extra_args ? " " : "", extra_args ? extra_args : "");
}

/* A failed real mapping stays failed unless the narrow, intentional compressed-heap fallback applies. */
typedef void *(*tl_mm_phantom_reserve_fn)(size_t);
static inline void *tl_mm_retry_phantom_reservation(void *mapping, size_t len, int prot, int guest_flags,
                                                     bool force_phantom, tl_mm_phantom_reserve_fn reserve)
{
    if (mapping != MAP_FAILED || !reserve || (errno != ENOMEM && !force_phantom) || prot != 0
        || !(guest_flags & TL_GUEST_MAP_ANONYMOUS) || (guest_flags & TL_GUEST_MAP_FIXED))
        return mapping;

    void *fallback = reserve(len);
    if (fallback != MAP_FAILED) errno = 0;
    return fallback;
}

#endif /* HUSK_TL_MEMORY_POLICY_H */
