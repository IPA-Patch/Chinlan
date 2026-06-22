# Chinlan - Cave Hook Injection for Native Latent ARM Notation

<p align="center">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" />
  <img alt="platform" src="https://img.shields.io/badge/platform-iOS%2013.0%2B-lightgrey?style=flat-square" />
  <img alt="arch" src="https://img.shields.io/badge/arch-arm64-555?style=flat-square" />
  <img alt="org" src="https://img.shields.io/badge/org-IPA--Patch-ff66a3?style=flat-square" />
</p>

---

Chinlan is the shared C / Objective-C runtime for [IPA-Patch](https://github.com/IPA-Patch) tweaks that use the **statically-patched `__TEXT` + `__DATA` hook-slot table** distribution shape — the only viable hooking approach on iOS 18 sideloaded targets, where the kernel Code Signing Monitor kills any runtime inline rewrite into `__TEXT`.

## vs. [IPAPatch](https://github.com/naituw/IPAPatch)

| | IPAPatch | Chinlan |
|---|---|---|
| **Hook mechanism** | ObjC method swizzling (`__DATA` method table) | ARM64 code-cave + `__DATA` slot table, written statically before signing |
| **ObjC method targets** | ✓ | ✓ |
| **Internal C / IL2CPP targets** | ✗ — ObjC runtime only; IL2CPP-generated C++ has no ObjC dispatch table | ✓ |
| **Xcode / lldb debugging** | ✓ Full Xcode build + breakpoint support | △ Attach-based only |
| **Setup complexity** | Low — drop IPA, write ObjC, hit Run | Higher — recipe describes RVAs + cave layout |
| **RVA / symbol fragility** | Stable (ObjC selector names) | RVAs pinned to a specific build; drift on app update |

Use IPAPatch when the target exposes ObjC symbols and you want a quick Xcode-driven debug loop. Chinlan's advantage is reaching into IL2CPP and plain C internals that IPAPatch cannot touch.

## vs. [fishhook](https://github.com/facebook/fishhook)

| | fishhook | Chinlan |
|---|---|---|
| **Hook mechanism** | dyld symbol rebinding (`__DATA` GOT pointers) | ARM64 code-cave + `__DATA` slot table, written statically before signing |
| **External C symbol targets** | ✓ — dyld-bound symbols only | ✓ |
| **Internal C / IL2CPP targets** | ✗ — internal symbols have no GOT entry | ✓ |
| **Setup complexity** | Minimal — link library, call `rebind_symbols` | Higher — recipe + Python patcher |
| **RVA / symbol fragility** | Stable (symbol names) | RVAs pinned to a specific build; drift on app update |

Use fishhook when you only need to intercept external C library calls (e.g. `open`, `malloc`). Chinlan is necessary when the target function is internal to the binary and has no GOT entry.

## vs. [MSHookFunction](https://www.cydiasubstrate.com/api/c/MSHookFunction/)

| | MSHookFunction | Chinlan |
|---|---|---|
| **Hook mechanism** | Inline `__TEXT` trampoline patch at runtime | ARM64 code-cave + `__DATA` slot table, written statically before signing |
| **iOS 18 CSM** | ✗ on sideloaded (non-JB) targets — CSM kills runtime `__TEXT` rewrites; ✓ on jailbroken devices where CSM is disabled | ✓ — `__TEXT` is patched before signing; dylib only writes to `__DATA` at runtime |
| **Works without jailbreak** | ✗ | ✓ |
| **Internal C / IL2CPP targets** | ✓ | ✓ |
| **Setup complexity** | Low on JB | Higher — recipe + Python patcher |
| **RVA / symbol fragility** | Stable (symbol names) | RVAs pinned to a specific build; drift on app update |

MSHookFunction is more flexible and easier to set up on a jailbroken device. Chinlan's key advantage is that it works on **stock iOS 18+ without jailbreak** — the only shape that survives CSM on a sideloaded IPA.

## What's in this repo

- `il2cpp.h` — read-only helpers for poking at IL2CPP objects:
  `ptrLooksValid`, `readI32`, `readU8`, `readPtr`, `readRepeatedField`,
  `readArrayElem`, `il2cppStringToNSString`. Header-only (`static inline`)
  so no linker plumbing is needed. **Deliberately read-only** — write
  helpers belong in each tweak's own `Internal.h`.
- `hookengine.h` — `MSHookFunction` <-> `DobbyHook` shim selected at
  compile time via `IPA_JAILED`. Lets `Hook_*.m` stay untouched between
  the rootless-jailbreak build (`libsubstrate`) and the
  sideload-injected build (`libdobby.a` statically linked).
- `logging.h` / `logging.m` — `IPALog` + `IPALoggingInit`. Multiplexes
  every log line to NSLog, `os_log` (subsystem-scoped), and an
  append-only file inside the app sandbox. `IPA_LOG_TO_DOCUMENTS=1` at
  build time routes the file destination to `<sandbox>/Documents/` so
  Files.app can read it on a non-jailbroken device.
- `chinlan.h` / `chinlan.m` — the core Chinlan helpers:
  - `IPAChinlanFindImage(name_substring)` walks `_dyld_image_count()`
    and returns the matching image's `mach_header` VA (call from a 1–2 s
    retry loop until non-zero).
  - `IPAChinlanResolveOrig(imageBase, siteRVA, cavePayloadSize)`
    decodes the `B <cave>` instruction the patcher wrote at the site
    and returns the in-cave orig-trampoline VA so hook bodies can chain
    back. Assumes the cave's last 8 bytes are
    `<displaced prologue insn> + B <site+4>` — read `chinlan.h` for
    the full cave-layout contract and a wiring example.

  Each consumer still owns the slot-table definition itself
  (`void *g_<your>_hook_slot[N];` in `__DATA,__bss`), its slot-index
  enum, and the per-hook `publish_*()` helpers — Chinlan owns only the
  parts that look identical across every consumer.

Pure runtime code. No Python tooling, no build scripts — the
[IPA-Patch/Shared](https://github.com/IPA-Patch/Shared) repo holds those.

## Cave kinds

Chinlan's runtime contract is shape-agnostic — `IPAChinlanResolveOrig`
only cares that the cave's last 8 bytes are
`<displaced prologue insn> + B <site+4>`. Across IPA-Patch tweaks two
cave shapes have stabilised:

- **`observer`** — peek before orig runs, then the cave executes orig
  automatically. Cheap default for logging / state caching / one-way
  observation.
- **`entry`** — REPLACE orig entirely. The hook receives pristine
  `x0..x7`, decides whether and how to invoke orig (through the
  cave-bypass entry exposed at `cave_va + 0x4C`), and the cave's RET
  propagates the hook's `x0` straight back to the caller. Required when
  you need to override the return value, substitute argument registers,
  or hook a 7+ integer-arg function (observer caves clobber `W6`).

[docs/CAVES.md](docs/CAVES.md) carries the full capability matrix,
annotated cave-byte layouts, and worked recipe / hook / dispatcher
examples for both kinds.

## Usage

Add as a git submodule inside `Sources/`:

```sh
git submodule add https://github.com/IPA-Patch/Chinlan.git Sources/Chinlan
```

Wire it into your Theos tweak:

```makefile
TWEAK_FILES   += Sources/Chinlan/logging.m
# Add chinlan.m only for the statically-patched IPA build:
TWEAK_FILES   += Sources/Chinlan/chinlan.m
TWEAK_CFLAGS  += -ISources/Chinlan
```

Include in source files:

```c
#import "il2cpp.h"
#import "hookengine.h"
#import "logging.h"
#import "chinlan.h"   // only for the statically-patched IPA build
```

## Build-time flags

| Macro | Effect |
|---|---|
| `IPA_JAILED` | `hookengine.h` uses Dobby (statically linked) instead of `libsubstrate`. |
| `IPA_LOG_TO_DOCUMENTS` | `logging.m` writes the file log to `<sandbox>/Documents/<tag>.log` instead of `tmp/`. |

## License

MIT — see [LICENSE](LICENSE).
