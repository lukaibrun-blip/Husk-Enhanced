/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <sys/mman.h>

#include "husk-tl-memory-policy.h"

static int reserve_calls;
static size_t reserved_length;

static void *refuse_reservation(size_t len)
{
    reserve_calls++;
    reserved_length = len;
    return MAP_FAILED;
}

static void test_allocator_selection_and_arguments(void)
{
    assert(tl_unity_system_allocator_enabled(NULL, true));
    assert(!tl_unity_system_allocator_enabled(NULL, false));
    assert(tl_unity_system_allocator_enabled("1", false));
    assert(!tl_unity_system_allocator_enabled("0", true));

    char line[128];
    tl_unity_format_command_line(line, sizeof(line), true, "-logFile player.log");
    assert(strcmp(line, "-systemallocator -memorysetup-job-temp-allocator-block-size-background=262144 -logFile player.log") == 0);
    tl_unity_format_command_line(line, sizeof(line), false, "-logFile player.log");
    assert(strcmp(line, "-logFile player.log") == 0);
    tl_unity_format_command_line(line, sizeof(line), false, NULL);
    assert(line[0] == 0);
}

static void test_failed_unity_sized_mapping_remains_failed(void)
{
    const size_t unity_request = 0x1fffc000;
    reserve_calls = 0;
    reserved_length = 0;
    errno = ENOMEM;

    void *mapping = tl_mm_retry_phantom_reservation(MAP_FAILED, unity_request, 0, 0x22,
                                                     false, refuse_reservation);
    assert(mapping == MAP_FAILED);
    assert(errno == ENOMEM);
    assert(reserve_calls == 1);
    assert(reserved_length == unity_request);
}

static void test_nonmatching_failures_do_not_enter_fallback(void)
{
    int storage = 0;
    reserve_calls = 0;

    errno = EACCES;
    assert(tl_mm_retry_phantom_reservation(MAP_FAILED, 4096, 0, 0x22, false,
                                           refuse_reservation) == MAP_FAILED);
    assert(errno == EACCES);

    errno = ENOMEM;
    assert(tl_mm_retry_phantom_reservation(MAP_FAILED, 4096, 1, 0x22, false,
                                           refuse_reservation) == MAP_FAILED);
    assert(errno == ENOMEM);
    assert(tl_mm_retry_phantom_reservation(MAP_FAILED, 4096, 0, 0x12, false,
                                           refuse_reservation) == MAP_FAILED);
    assert(tl_mm_retry_phantom_reservation(MAP_FAILED, 4096, 0, 0x02, false,
                                           refuse_reservation) == MAP_FAILED);
    assert(reserve_calls == 0);

    assert(tl_mm_retry_phantom_reservation(&storage, 4096, 0, 0x22, true,
                                           refuse_reservation) == &storage);
    assert(reserve_calls == 0);
}

static void test_forced_phantom_still_requires_anonymous_prot_none_nonfixed_map(void)
{
    reserve_calls = 0;
    errno = EINVAL;
    assert(tl_mm_retry_phantom_reservation(MAP_FAILED, 8192, 0, 0x22, true,
                                           refuse_reservation) == MAP_FAILED);
    assert(reserve_calls == 1);
    assert(reserved_length == 8192);
    assert(errno == EINVAL);
}

int main(void)
{
    test_allocator_selection_and_arguments();
    test_failed_unity_sized_mapping_remains_failed();
    test_nonmatching_failures_do_not_enter_fallback();
    test_forced_phantom_still_requires_anonymous_prot_none_nonfixed_map();
    return 0;
}
