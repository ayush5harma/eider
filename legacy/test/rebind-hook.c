// A stand-in for a tweak that hooks the keychain by rewriting symbol pointers,
// the way fishhook does, for test/keychain-rebind.sh.
//
// WHY
// Watusi's libWatusiToolsSL.dylib (WhatsApp 26.42.77, measured 2026-11-11)
// hooks SecItemCopyMatching this way. Rewriting pointers reaches every image,
// the keychain shim included, whose own pointer dyld had left on the real
// function (an interposing image is never interposed itself), and the
// "original" the tweak saves is what the main executable's pointer held: the
// shim's replacement, since dyld had already interposed it. So the tweak
// calls the shim, the shim passes a key or certificate query on to "the real
// keychain" through its own rewritten pointer, which is the tweak again, and
// WhatsApp overflowed its stack 6,679 calls deep at every launch.
//
// This library does the same to all four SecItem entry points, taking each
// original from the main executable's pointer, and counts its own depth: a
// loop exits with status 3 and says so, instead of overflowing.

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

// Any genuine chain of keychain hooks is a handful deep; a loop is not.
#define LOOP_DEPTH 64

static __thread int g_depth;
static int g_slots;                 // pointers rewritten, across all images
static int g_calls;                 // calls that went through a hook

static void loop_detected(const char *name) {
    fprintf(stderr, "rebind-hook: %s re-entered %d deep: the hooks call each other\n", name, LOOP_DEPTH);
    _exit(3);
}

#define HOOK(name, params, args)                                         \
    static OSStatus (*orig_##name) params;                               \
    static OSStatus hook_##name params {                                 \
        if (++g_depth > LOOP_DEPTH) loop_detected(#name);                \
        __atomic_add_fetch(&g_calls, 1, __ATOMIC_RELAXED);               \
        OSStatus rc = orig_##name ? orig_##name args : errSecUnimplemented; \
        g_depth--;                                                       \
        return rc;                                                       \
    }

HOOK(SecItemCopyMatching, (CFDictionaryRef q, CFTypeRef *r), (q, r))
HOOK(SecItemAdd, (CFDictionaryRef a, CFTypeRef *r), (a, r))
HOOK(SecItemUpdate, (CFDictionaryRef q, CFDictionaryRef u), (q, u))
HOOK(SecItemDelete, (CFDictionaryRef q), (q))

static const struct { const char *name; void *hook; void **orig; } k_hooks[] = {
    { "_SecItemCopyMatching", (void *)hook_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching },
    { "_SecItemAdd",          (void *)hook_SecItemAdd,          (void **)&orig_SecItemAdd },
    { "_SecItemUpdate",       (void *)hook_SecItemUpdate,       (void **)&orig_SecItemUpdate },
    { "_SecItemDelete",       (void *)hook_SecItemDelete,       (void **)&orig_SecItemDelete },
};
#define NHOOKS (sizeof k_hooks / sizeof k_hooks[0])

static const struct mach_header_64 *g_main;

static void rewrite(void **slot, size_t h, const struct mach_header_64 *mh) {
    if (*slot == k_hooks[h].hook) return;
    if (mh == g_main) *k_hooks[h].orig = *slot;
    // __DATA_CONST is read-only once dyld has bound it.
    if (vm_protect(mach_task_self(), (vm_address_t)slot, sizeof *slot, false,
                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return;
    *slot = k_hooks[h].hook;
    g_slots++;
}

static void rebind_section(const struct section_64 *sect, intptr_t slide, const uint32_t *indirect,
                           const struct nlist_64 *syms, const char *strs, const struct mach_header_64 *mh) {
    void **slots = (void **)((uintptr_t)slide + sect->addr);
    for (size_t k = 0; k < sect->size / sizeof(void *); k++) {
        uint32_t si = indirect[sect->reserved1 + k];
        if (si & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) continue;
        const char *sym = strs + syms[si].n_un.n_strx;
        for (size_t h = 0; h < NHOOKS; h++)
            if (strcmp(sym, k_hooks[h].name) == 0) rewrite(&slots[k], h, mh);
    }
}

static void rebind_image(const struct mach_header *header, intptr_t slide) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)header;
    if (mh->flags & MH_DYLIB_IN_CACHE) return;     // the OS's own libraries: not this tweak's business
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT) == 0)
            linkedit = (const void *)lc;
        else if (lc->cmd == LC_SYMTAB) symtab = (const void *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dysymtab = (const void *)lc;
    }
    if (!linkedit || !symtab || !dysymtab || !dysymtab->nindirectsyms) return;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const void *)(base + symtab->symoff);
    const char *strs = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const void *)(base + dysymtab->indirectsymoff);
    lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const void *)lc;
        const struct section_64 *sect = (const struct section_64 *)(seg + 1);
        for (uint32_t j = 0; j < seg->nsects; j++, sect++) {
            uint32_t type = sect->flags & SECTION_TYPE;
            if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS)
                rebind_section(sect, slide, indirect, syms, strs, mh);
        }
    }
}

__attribute__((constructor)) static void install(void) {
    g_main = (const struct mach_header_64 *)_dyld_get_image_header(0);
    rebind_image(_dyld_get_image_header(0), _dyld_get_image_vmaddr_slide(0));   // the originals come from here
    for (uint32_t i = 1; i < _dyld_image_count(); i++)
        rebind_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
}

// For the probe: how many pointers were rewritten, and how many calls the
// hooks saw, so a pass cannot come from hooks that were never installed.
void rebind_hook_report(int *slots, int *calls) {
    *slots = g_slots;
    *calls = __atomic_load_n(&g_calls, __ATOMIC_RELAXED);
}
