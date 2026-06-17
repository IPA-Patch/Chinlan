#import "chinlan.h"
#import "logging.h"

#import <mach-o/dyld.h>
#import <stdint.h>
#import <string.h>

// ===========================================================================
// chinlan.m — implementation of the generic helpers declared in
// chinlan.h. Both routines are read-only (they look at __TEXT bytes
// the patcher has already written; they don't write anything). See the
// header for the cave-layout contract and for an end-to-end wiring
// example.
// ===========================================================================

// Plausible user-space pointer range on arm64 iOS. Matches the local
// `ptrLooksValid` helpers used throughout IPA-Patch tweaks (defined
// in Common/il2cpp.h); duplicated here as a private static so this TU
// stays self-contained and the helper can be linked into a target
// that doesn't include il2cpp.h.
static inline int IPAChinlanPtrOk(uintptr_t v) {
    if (v == 0) return 0;
    if (v < 0x1000) return 0;
    if (v >= 0x0001000000000000ULL) return 0;
    return 1;
}

uintptr_t IPAChinlanFindImage(const char *imageNameSubstring) {
    if (!imageNameSubstring || imageNameSubstring[0] == '\0') return 0;

    uint32_t imgCount = _dyld_image_count();
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, imageNameSubstring)) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return 0;
}

uintptr_t IPAChinlanResolveOrig(uintptr_t imageBase,
                                uintptr_t siteRVA,
                                size_t    cavePayloadSize) {
    if (!imageBase || !siteRVA) return 0;
    if (cavePayloadSize < 8 || (cavePayloadSize % 4) != 0) return 0;

    uintptr_t siteVA = imageBase + siteRVA;
    if (!IPAChinlanPtrOk(siteVA)) return 0;

    uint32_t insn = *(const uint32_t *)siteVA;

    // `B imm26` encoding: top 6 bits 0b000101 (0x5). Anything else
    // means the site hasn't been patched (or the patcher wrote
    // something the runtime doesn't know how to read) — bail out so
    // the caller leaves its typed `orig_*` pointer NULL.
    if ((insn >> 26) != 0x05) {
        IPALog([NSString stringWithFormat:
                @"[Chinlan] ResolveOrig: siteRVA=0x%lx "
                @"insn=0x%08x not a B imm26",
                (unsigned long)siteRVA, insn]);
        return 0;
    }

    // imm26 is bits [25:0], word-scaled, two's-complement signed.
    int32_t imm26 = (int32_t)(insn & 0x03FFFFFFu);
    if (imm26 & 0x02000000) imm26 |= (int32_t)0xFC000000u;  // sign-extend
    intptr_t byteOffset = (intptr_t)imm26 * 4;

    uintptr_t caveVA = (uintptr_t)((intptr_t)siteVA + byteOffset);
    if (!IPAChinlanPtrOk(caveVA)) return 0;

    return caveVA + (uintptr_t)cavePayloadSize - 8;
}
