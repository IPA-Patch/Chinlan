#pragma once

#import <Foundation/Foundation.h>
#include <stddef.h>
#include <stdint.h>

// ===========================================================================
// chinlan.h — generic runtime helpers for the "statically-patched
// __TEXT + __DATA hook-slot table" distribution shape.
//
// CHINLAN: Cave Hook Injection for Native Latent ARM Notation
//
// WHO USES THIS
// -------------
// Any IPA-Patch tweak whose distribution mode is "patch the target's
// Mach-O on disk so each hook site BL's into a __TEXT cave that calls
// the dylib through a __DATA,__bss function-pointer slot". On iOS 18
// sideloaded targets that's the only viable hooking shape — runtime
// inline rewrites (MSHookFunction / Dobby / frida-gum) are killed by
// the kernel Code Signing Monitor the moment they `memcpy` into
// __TEXT. Writing the dylib's hook pointer into a __DATA slot is
// CSM-safe, so the cave reads a fresh pointer each time and the
// dylib never touches __TEXT.
//
// This header is target-agnostic. The two things it gives you are:
//
//   1. IPAChinlanFindImage()       — locate the host image by
//                                    name substring at dylib
//                                    constructor time.
//
//   2. IPAChinlanResolveOrig()     — given a site whose first 4
//                                        bytes have been overwritten
//                                        with `B <cave>`, recover
//                                        the in-cave orig-trampoline
//                                        VA so a hook body can call
//                                        `orig_X(args)` and chain
//                                        back into the original
//                                        method.
//
// Both functions are read-only (they look at __TEXT bytes the
// patcher has already written; they don't write anything). They are
// safe to call repeatedly from a retry loop while the target image
// is still being mapped.
//
// WHAT YOU OWN PER TWEAK
// ----------------------
// Everything that depends on the tweak's specific hook set:
//
//   * The slot table itself — `void *g_<your>_hook_slot[N];` placed in
//     __DATA,__bss via a plain uninitialised extern definition. Your
//     patcher recipe targets this symbol; the cave's ADRP+LDR pair
//     materialises its VA at runtime. You pick the array name, the
//     element count, and the slot-index enum.
//
//   * Per-hook `publish_*()` helpers that:
//       g_<your>_hook_slot[SLOT] = (void *)hook_function;
//       orig_function = (typed *)IPAChinlanResolveOrig(
//                           imageBase, SITE_RVA, MY_CAVE_PAYLOAD_SIZE);
//
//   * A small bootstrap helper that calls every publish_*() in some
//     deterministic order once IPAChinlanFindImage() returns a
//     non-zero base; spinning a 1–2 s retry timer until then.
//
// CAVE LAYOUT CONTRACT (binding for every consumer of this header)
// ----------------------------------------------------------------
// IPAChinlanResolveOrig() assumes the cave's LAST 8 bytes hold
// the orig-trampoline tail:
//
//     cave[payloadSize - 8 .. payloadSize - 4)  = <displaced prologue insn>
//     cave[payloadSize - 4 .. payloadSize)      = B <site + 4>
//
// i.e. calling `cave + payloadSize - 8` executes the displaced
// prologue insn verbatim and then jumps back into the original
// method at `site + 4`. The displaced insn MUST be PC-independent
// (STP pre-index, SUB SP, LDR offset, MOV reg, …); never a
// PC-relative instruction (ADR/ADRP/B/BL/CBZ/LDR-literal). If your
// site's first insn is PC-relative, shift the displacement to the
// second insn and have the recipe branch back to `site + 8`
// instead.
//
// The rest of the cave (everything before payloadSize - 8) is the
// tweak's hook-entry trampoline. The canonical shape for a hook
// that returns a value to its caller is:
//
//     STP   x29, x30, [sp, #-0x10]!     ; save LR only; X0..X7 untouched
//     ADRP  x16, page(SLOT)
//     LDR   x16, [x16, #lo12(SLOT)]
//     MOVZ  w9,  #slot_index            ; optional; pass slot index in W9
//     BLR   x16                         ; hook(args...) → X0 = return value
//     LDP   x29, x30, [sp], #0x10
//     RET                                ; hook's X0 propagates to caller
//     NOP × (payloadSize/4 - 9)         ; padding (never executed)
//     <displaced prologue insn>         ; cave + payloadSize - 8
//     B     <site + 4>                  ; cave + payloadSize - 4
//
// This shape lets a hook that returns a different value (e.g.
// IsPremiumUser → true) actually change what the call site sees, and
// lets a hook body that wants to chain back call `orig_X(args)` via
// the cave's tail trampoline.
//
// A consumer that only needs OBSERVATION (no value change, no
// suppression) can use a fall-through cave instead: save x0..x7,
// BLR, restore x0..x7, then the displaced insn + B <site + 4> at
// the cave tail. IPAChinlanResolveOrig() still works because
// the tail-8-bytes contract is unchanged. IPAChinlanResolveOrig
// makes no assumption about what the entry shape does — it only
// reads the `B <cave>` at the site to find the cave VA and adds
// `payloadSize - 8`.
//
// EXAMPLE WIRING (target-agnostic skeleton)
// -----------------------------------------
// ```objc
// // 1) Local slot table (Editor-specific names; placed in __DATA,__bss).
// enum { MY_SLOT_FOO = 0, MY_SLOT_BAR = 1, MY_SLOT_COUNT = 2 };
// #define MY_CAVE_PAYLOAD_SIZE 84    // must match the recipe's value
// void *g_my_hook_slot[MY_SLOT_COUNT];
//
// // 2) Per-hook publishers (live next to the hook bodies).
// static foo_t orig_foo;
// static bar_t orig_bar;
// void publish_foo_slot(uintptr_t base) {
//     g_my_hook_slot[MY_SLOT_FOO] = (void *)hook_foo;
//     orig_foo = (foo_t)IPAChinlanResolveOrig(
//                    base, RVA_FOO, MY_CAVE_PAYLOAD_SIZE);
// }
// // ...same shape for bar.
//
// // 3) Bootstrap from the dylib constructor.
// __attribute__((constructor)) static void init(void) {
//     IPALoggingInit("com.example.tweak.foo");
//     uintptr_t base = IPAChinlanFindImage("TargetFramework");
//     if (base) {
//         publish_foo_slot(base);
//         publish_bar_slot(base);
//     } else {
//         // dispatch_after retry loop — UnityFramework / etc. are
//         // typically not mapped at constructor time.
//     }
// }
// ```
//
// PAIRING WITH THE PATCHER
// ------------------------
// The Python side lives in IPA-Patch/Shared; your tweak supplies a
// recipe (`recipes/<your_tweak>.py`) describing per-site RVAs,
// expected prologue bytes, and the cave payload builder. The patcher
// rewrites each site's first 4 bytes with `B <cave>` and emits the
// cave bytes into the binary's free __TEXT zero-fill tail. See
// `docs/chinlan.md` in any consumer repo for the operator flow.
// ===========================================================================

// ---------------------------------------------------------------------------
// Locate a loaded Mach-O image by case-sensitive substring of its dyld
// path. Returns the mach_header VA, or 0 if no image matches yet.
//
// Typical use: walk-once at constructor time, then retry from a
// dispatch_after on a 1–2 s cadence until non-zero is returned. The
// host image (UnityFramework, the app's main image, …) is usually
// not yet mapped when the dylib's __attribute__((constructor)) fires.
//
// `imageNameSubstring` is matched with strstr() against
// _dyld_get_image_name(i); pass e.g. "UnityFramework". A NULL or
// empty substring is invalid and returns 0.
// ---------------------------------------------------------------------------
uintptr_t IPAChinlanFindImage(const char *imageNameSubstring);

// ---------------------------------------------------------------------------
// Decode the `B <cave>` instruction the patcher wrote at
// `imageBase + siteRVA` and return the cave's orig-trampoline VA,
// i.e. `cave_va + cavePayloadSize - 8`.
//
// Parameters
//   imageBase        : mach_header VA of the image holding the site
//                      (the value IPAChinlanFindImage returned).
//   siteRVA          : RVA, relative to imageBase, of the site's first
//                      4 bytes — i.e. where the patcher wrote
//                      `B <cave>` over the original prologue insn.
//   cavePayloadSize  : total size of the cave payload in bytes. The
//                      orig-trampoline lives at its last 8 bytes per
//                      the contract documented above; this is how
//                      this helper finds it without needing to know
//                      the cave's entry shape.
//
// Returns 0 on any failure (image base or siteRVA looks bogus, the
// site does not decode as a `B imm26`, etc.). Callers should log the
// failure and leave their typed `orig_*` pointer NULL; every hook
// body should NULL-guard its chain-back call.
//
// This is a read-only operation. It never modifies the binary or the
// slot table.
// ---------------------------------------------------------------------------
uintptr_t IPAChinlanResolveOrig(uintptr_t imageBase,
                                uintptr_t siteRVA,
                                size_t    cavePayloadSize);
