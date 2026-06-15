#pragma once

// ===========================================================================
// hookengine.h — MSHookFunction <-> Dobby shim.
//
// JB / rootless builds (default): MobileSubstrate's MSHookFunction is live
//                                 in libsubstrate, linked at runtime.
// Jailed (sideload-injected) builds: Dobby, statically linked from
//                                 vendor/dobby/lib/libdobby.a so the .dylib
//                                 has zero external hook-engine dependency.
//
// The shim below maps MSHookFunction(...) onto DobbyHook(...) when IPA_JAILED
// is defined at compile time, so every Hook_*.m stays untouched between the
// two distribution modes.
//
// Each tweak's Makefile sets -DIPA_JAILED=1 via `make JAILED=1`.
// ===========================================================================

#if IPA_JAILED
#import "dobby.h"
// MSHookFunction returns void; DobbyHook returns int. Cast the result away so
// the call site keeps the original void-expression shape.
#define MSHookFunction(sym, repl, orig) \
    ((void)DobbyHook((void *)(sym), (void *)(repl), (void **)(orig)))
#else
#import <substrate.h>
#endif
