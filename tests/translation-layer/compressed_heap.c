/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Redirect only the included production TU; test helpers use the host VM APIs directly. */
#define _DARWIN_C_SOURCE
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
static void *test_mmap(void *, size_t, int, int, int, off_t);
kern_return_t bounded_vm_map(vm_map_t, vm_address_t *, vm_size_t, vm_address_t, int,
    mem_entry_name_port_t, vm_offset_t, boolean_t, vm_prot_t, vm_prot_t, vm_inherit_t);
#define mmap test_mmap
#define vm_map bounded_vm_map
#define backtrace test_backtrace
#include "../../src/translation-layer-next/husk-tl-bionic-io.c"
#undef backtrace
#undef vm_map
#undef mmap
#include <assert.h>
extern int backtrace(void **, int);
int test_backtrace(void **frames, int count)
{
    puts("TRACE: entering production backtrace adapter");
    int captured = backtrace(frames, count);
    printf("TRACE: production backtrace returned %d frames\n", captured);
    return captured;
}
static void *test_mmap(void *address, size_t length, int protection, int flags, int fd, off_t offset)
{
    if (length == 0x1fffc000ULL && protection == PROT_NONE && (flags & MAP_ANON) && !(flags & MAP_FIXED)) {
        puts("TRACE: host mmap adapter rejecting Unity allocation");
        setenv("HUSK_TEST_UNITY_MAP_FAILURE_SEEN", "1", 1);
        errno = ENOMEM;
        return MAP_FAILED;
    }
    if (length >= 0x100000000ULL && (flags & MAP_ANON) && !(flags & MAP_FIXED)) {
        errno = ENOMEM;
        return MAP_FAILED;
    }
    return mmap(address, length, protection, flags, fd, offset);
}
void tl_log_line(const char *fmt, ...) { (void)fmt; }
bool husk_binder_is_fd(int fd) { (void)fd; return false; }
bool tl_codewrite_enabled(void) { return false; }
bool tl_ld_aot_contains(const void *addr) { (void)addr; return false; }
bool tl_ld_covers(const void *addr, size_t len) { (void)addr; (void)len; return false; }
bool tl_xmem_contains(const void *addr) { (void)addr; return false; }
void tl_set_guest_errno(int error) { (void)error; }
void tl_note_once(const char *what) { (void)what; }
static bool return_fixed_code_map;
static int code_map_calls;
void *tl_ld_map_code(const char *path, uint64_t off, size_t len, void *at)
{
    code_map_calls++;
    if (!return_fixed_code_map || !at) return NULL;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;
    void *r = mmap(at, len, PROT_READ, MAP_PRIVATE | MAP_FIXED, fd, (off_t)off);
    close(fd);
    return r == MAP_FAILED ? NULL : r;
}
const char *tl_ld_symbol_at(const void *addr, const char **lib_name, const void **sym_addr)
{
    (void)addr;
    if (lib_name) *lib_name = NULL;
    if (sym_addr) *sym_addr = NULL;
    return NULL;
}

static void test_memory_accounting(void)
{
    puts("TRACE: memory accounting entered");
    assert(!getenv("TL_MM_MAX_GIB") && !getenv("TL_MM_TOTAL_GIB") && !getenv("TL_MM_PHANTOM"));

    const vm_size_t jit_size = (vm_size_t)512 << 20;
    size_t guest_before = 0;
    puts("TRACE: querying initial address-space usage");
    size_t used_before = tl_mm_address_space_used(&guest_before);
    puts("TRACE: initial address-space query returned");
    vm_address_t rx = 0;
    assert(bounded_vm_map(mach_task_self(), &rx, jit_size, 0, VM_FLAGS_ANYWHERE,
        MACH_PORT_NULL, 0, FALSE, VM_PROT_READ | VM_PROT_WRITE, VM_PROT_ALL,
        VM_INHERIT_NONE) == KERN_SUCCESS);
    printf("TRACE: RX mapping at %p\n", (void *)(uintptr_t)rx);
    vm_address_t rw = 0;
    vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
    assert(vm_remap(mach_task_self(), &rw, jit_size, 0, VM_FLAGS_ANYWHERE,
        mach_task_self(), rx, FALSE, &cur, &max, VM_INHERIT_NONE) == KERN_SUCCESS);
    printf("TRACE: RW alias at %p\n", (void *)(uintptr_t)rw);
    assert(vm_protect(mach_task_self(), rw, jit_size, FALSE,
        VM_PROT_READ | VM_PROT_WRITE) == KERN_SUCCESS);
    assert(vm_protect(mach_task_self(), rx, jit_size, FALSE,
        VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS);
    puts("TRACE: JIT mappings protected");

#if defined(__arm64__) || defined(__aarch64__)
    static const uint32_t code[] = { 0x52800540u, 0xD65F03C0u }; /* mov w0, #42; ret */
#elif defined(__x86_64__)
    static const uint8_t code[] = { 0xb8, 0x2a, 0x00, 0x00, 0x00, 0xc3 }; /* mov eax, 42; ret */
#else
#error "The dual-mapping self-test needs an arm64 or x86_64 host"
#endif
    memcpy((void *)(uintptr_t)rw, code, sizeof(code));
    sys_icache_invalidate((void *)(uintptr_t)rx, sizeof(code));
    uint8_t readback[sizeof(code)];
    memcpy(readback, (void *)(uintptr_t)rx, sizeof(readback));
    assert(memcmp(readback, code, sizeof(code)) == 0);
    int (*jit_function)(void) = (int (*)(void))(void *)(uintptr_t)rx;
    printf("TRACE: invoking JIT entry %p\n", (void *)(uintptr_t)jit_function);
    assert(jit_function() == 42);
    puts("TRACE: JIT returned 42");

    size_t guest_after = 0;
    puts("TRACE: querying final address-space usage");
    size_t used_after = tl_mm_address_space_used(&guest_after);
    puts("TRACE: final address-space query returned");
    assert(used_after >= used_before + 2 * jit_size);
    assert(guest_after == guest_before);

    const size_t unity_request = 0x1fffc000;
    size_t guest_before_failure = anon_total();
    assert(!getenv("HUSK_TEST_UNITY_MAP_FAILURE_SEEN"));
    errno = 0;
    puts("TRACE: entering expected large-map failure");
    void *failed_mapping = b_mmap(NULL, unity_request, PROT_NONE, 0x22, -1, 0);
    puts("TRACE: expected large-map failure returned");
    assert(failed_mapping == MAP_FAILED);
    assert(getenv("HUSK_TEST_UNITY_MAP_FAILURE_SEEN"));
    assert(errno == ENOMEM);
    assert(anon_total() == guest_before_failure);

    size_t page = (size_t)getpagesize();
    size_t baseline = anon_total();
    char *mapping = b_mmap(NULL, 3 * page, PROT_NONE, 0x22, -1, 0);
    assert(mapping != MAP_FAILED);
    assert(anon_total() == baseline + 3 * page);
    assert(b_mprotect(mapping, page, PROT_READ | PROT_WRITE) == 0);
    assert(b_mprotect(mapping, page, PROT_NONE) == 0);
    assert(anon_total() == baseline + 3 * page);

    /* Invalid unmaps and failed MAP_FIXED mappings must not remove bytes from the tracker. */
    assert(b_munmap(mapping + 1, page) == -1);
    assert(anon_total() == baseline + 3 * page);
    assert(b_mmap(mapping + page, page, PROT_READ, 0x12, -1, 0) == MAP_FAILED);
    assert(anon_total() == baseline + 3 * page);
    assert(b_mprotect(mapping + page, page, PROT_READ | PROT_WRITE) == 0);
    assert(b_mprotect(mapping + page, page, PROT_NONE) == 0);

    char path[] = "/tmp/husk-mmap-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    assert(ftruncate(fd, (off_t)page) == 0);
    const unsigned char replacement_byte = 0x5a;
    assert(pwrite(fd, &replacement_byte, sizeof(replacement_byte), 0) == (ssize_t)sizeof(replacement_byte));
    /* A failed loader-style replacement followed by a failed MAP_FIXED mmap must keep the old interval tracked. */
    int code_map_calls_before = code_map_calls;
    return_fixed_code_map = true;
    assert(b_mmap(mapping + 1, page, PROT_READ | PROT_EXEC, 0x12, fd, 0) == MAP_FAILED);
    return_fixed_code_map = false;
    assert(code_map_calls == code_map_calls_before + 1);
    assert(anon_total() == baseline + 3 * page);
    /* A successful loader-style fixed mapping replaces its target before the early return. */
    code_map_calls_before = code_map_calls;
    return_fixed_code_map = true;
    assert(b_mmap(mapping + page, page, PROT_READ | PROT_EXEC, 0x12, fd, 0) == mapping + page);
    return_fixed_code_map = false;
    assert(code_map_calls == code_map_calls_before + 1);
    assert((unsigned char)mapping[page] == replacement_byte);
    assert(anon_total() == baseline + 2 * page);
    /* Rejected executable file mappings still replace their MAP_FIXED target before being unmapped. */
    assert(b_mmap(mapping + page, page, PROT_READ | PROT_EXEC, 0x12, fd, 0) == MAP_FAILED);
    assert(anon_total() == baseline + 2 * page);
    void *file_page = b_mmap(mapping + page, page, PROT_READ, 0x12, fd, 0);
    assert(file_page == mapping + page);
    assert(anon_total() == baseline + 2 * page);
    assert(b_munmap(file_page, page) == 0);
    assert(anon_total() == baseline + 2 * page);
    assert(close(fd) == 0);
    assert(unlink(path) == 0);

    assert(b_munmap(mapping, page) == 0);
    assert(anon_total() == baseline + page);
    assert(b_munmap(mapping + 2 * page, page) == 0);
    assert(anon_total() == baseline);

    void *full = b_mmap(NULL, 2 * page, PROT_READ | PROT_WRITE, 0x22, -1, 0);
    assert(full != MAP_FAILED);
    assert(anon_total() == baseline + 2 * page);
    assert(b_munmap(full, 2 * page) == 0);
    assert(anon_total() == baseline);

    puts("TRACE: releasing JIT aliases");
    assert(vm_deallocate(mach_task_self(), rw, jit_size) == KERN_SUCCESS);
    assert(vm_deallocate(mach_task_self(), rx, jit_size) == KERN_SUCCESS);
    puts("TRACE: JIT aliases released");
    puts("PASS: 512 MiB dual-view JIT self-test, failed Unity map, protections and mapping accounting");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    bool late = argc > 1 && !strcmp(argv[1], "late");
    size_t len = 2 * PHANTOM_HALF - getpagesize();
    assert(compressed_heap_request(len));
    assert(compressed_heap_request(2 * PHANTOM_HALF));
    assert(!compressed_heap_request(len - getpagesize()));
    if (!late) {
        husk_prepare_compressed_heap(); assert(g_compressed_heap);
        vm_address_t first = g_compressed_heap;
        husk_prepare_compressed_heap(); assert(g_compressed_heap == first);
        husk_release_unused_compressed_heap(); assert(!g_compressed_heap);
        husk_prepare_compressed_heap(); assert(g_compressed_heap);
    }
    vm_address_t alias = 0;
    assert(bounded_vm_map(mach_task_self(), &alias, (vm_size_t)512 << 20, 0,
        VM_FLAGS_ANYWHERE, MACH_PORT_NULL, 0, FALSE, VM_PROT_READ | VM_PROT_WRITE,
        VM_PROT_ALL, VM_INHERIT_COPY) == KERN_SUCCESS);
    void *p = phantom_reserve(len);
    if (late) {
        assert(p == MAP_FAILED);
        puts("PASS: late allocation fails in the constrained window");
    } else {
        assert(p != MAP_FAILED && !((uintptr_t)p % PHANTOM_HALF));
        assert(!g_compressed_heap);
        husk_release_unused_compressed_heap(); /* consumed cage must survive */
        assert(phantom_clamp((uintptr_t)p + PHANTOM_HALF, len - PHANTOM_HALF) == 0);
        assert(phantom_clamp((uintptr_t)p, len) == PHANTOM_HALF);
        assert(!mprotect(p, getpagesize(), PROT_READ | PROT_WRITE));
        assert(!mprotect((char *)p + PHANTOM_HALF - getpagesize(), getpagesize(), PROT_READ | PROT_WRITE));
        *(volatile char *)p = 42; *((volatile char *)p + PHANTOM_HALF - 1) = 43;
        assert(!munmap(p, PHANTOM_HALF));
        puts("PASS: early reservation, retry, single transfer, trim, commit at both ends");
    }
    puts("TRACE: releasing constrained-window alias");
    assert(vm_deallocate(mach_task_self(), alias, (vm_size_t)512 << 20) == KERN_SUCCESS);
    puts("TRACE: constrained-window alias released");
    if (late) test_memory_accounting();
}
