# Chinlan cave kinds

Chinlan's runtime helpers (`chinlan.h` / `chinlan.m`) don't prescribe a
specific cave layout — they only own the slot-resolution + orig-trampoline
contract documented in `chinlan.h`. The cave bytes themselves are emitted
at patch time by each consumer's [Shared](https://github.com/IPA-Patch/Shared)
recipe, and across IPA-Patch tweaks two cave shapes have stabilised. This
page is the cross-tweak reference for picking the right kind and wiring
both sides correctly.

> The 21-instruction / 84-byte envelope is a Bridge / KiouForge convention,
> not a Chinlan-runtime requirement. Other consumers can choose a different
> size as long as the cave's last 8 bytes stay `<displaced prologue insn>
> + B <site+4>` so `IPAChinlanResolveOrig()` keeps working.

## Kinds at a glance

| Capability | `observer` | `entry` |
|---|---|---|
| Peek arguments before orig runs | ✅ | ✅ |
| Run orig automatically | ✅ (cave does it after the dispatcher returns) | ❌ (hook must call the cave-bypass entry itself) |
| Override the return value | ❌ (cave executes orig _after_ the hook) | ✅ (cave's tail is `RET`; the hook's `x0` propagates straight back) |
| Substitute argument registers | ❌ (cave restores `x0..x7` before `B orig+4`) | ✅ (cave passes pristine `x0..x7` through and never restores) |
| Hooks routed through a single shared dispatcher | ✅ (one slot, identified by `W6 = hook_id`) | ❌ (each site has its own slot under an entry-slot table) |
| `W6` (= 7th C arg) survives across the cave | ❌ (clobbered with `hook_id`) | ✅ (only `W9` is touched, an unused arg-9+ slot under AAPCS64) |
| Cave-bypass tail at `cave_va + 0x4C` still valid | ✅ | ✅ |

### Decision flow

Pick `observer` for almost everything. It's the cheap default — orig's
behavior is preserved byte-for-byte, the dispatcher only logs / latches
state, and you don't have to think about how to call orig back.

Reach for `entry` only when one of these is true:

- **You need to override orig's return value.** e.g. flipping
  `AccountExists` to `false`, or rejecting a `MatchFound` reply.
- **You need orig to see different argument registers than the caller
  passed in.** e.g. swapping a `deviceId` string before LoginArgs builds.
- **The hook target takes 7+ integer-class args** and `W6` carries real
  data. Observer caves rewrite `W6` with the dispatcher hook id, so an
  observer of a 7th-arg-bearing function reads garbage in the dispatcher
  (and the cave restores W6 from the saved frame before `B orig+4`, so
  orig itself still sees the right value — the dispatcher's view is the
  one that's wrong).

Anything else — single move observation, state machine peeks, side-effect
logging — stays `observer`.

## Cave layouts

Both caves are 21 instructions = 84 bytes, allocated contiguously from a
`CAVE_REGION_START` in `_SITES` order. The last two instructions are
identical (`displaced_insn` + `B orig+4`) so the cave-bypass entry at
`cave_va + 0x4C` works for both kinds — injection paths and entry hooks
use that to run orig without re-entering the cave.

### `observer`

```text
0x00  STP X29, X30, [SP, #-0x90]!     ; save LR + reserve 0x90 of stack
0x04  STP X19, X20, [SP, #0x10]
0x08  STP X21, X22, [SP, #0x20]
0x0C  STP X0,  X1,  [SP, #0x30]       ; save x0..x7 so orig sees them
0x10  STP X2,  X3,  [SP, #0x40]
0x14  STP X4,  X5,  [SP, #0x50]
0x18  STP X6,  X7,  [SP, #0x60]
0x1C  MOV X29, SP                     ; canonical frame setup
0x20  ADRP X16, page(HOOK_SLOT_RVA)
0x24  LDR  X16, [X16, #lo12(SLOT)]    ; load dispatcher pointer
0x28  MOVZ W6,  #hook_id              ; pass hook id via W6 (clobbers arg #7!)
0x2C  BLR  X16                        ; dispatcher(x0..x5, hook_id_in_w6, x7)
0x30  LDP  X6,  X7,  [SP, #0x60]      ; restore x0..x7 — orig must see originals
0x34  LDP  X4,  X5,  [SP, #0x50]
0x38  LDP  X2,  X3,  [SP, #0x40]
0x3C  LDP  X0,  X1,  [SP, #0x30]
0x40  LDP  X21, X22, [SP, #0x20]
0x44  LDP  X19, X20, [SP, #0x10]
0x48  LDP  X29, X30, [SP], #0x90      ; tear down frame
0x4C  <displaced prologue insn>       ; orig's first 4 bytes, run verbatim
0x50  B    <orig + 4>                 ; continue into orig body
```

The dispatcher receives
`void dispatch(void *x0, void *x1, void *x2, void *x3, void *x4,
              void *x5, uint32_t hook_id, void *x7)` — `x6` is sacrificed
to deliver `hook_id` even though `W6` is the 7th C integer arg under
AAPCS64. Hook bodies with up to six args are safe; anything more needs
`entry`.

### `entry`

```text
0x00  STP X29, X30, [SP, #-0x10]!     ; minimal frame — no arg saving
0x04  ADRP X16, page(entry_slot_va)
0x08  LDR  X16, [X16, #lo12(slot)]    ; load this site's hook fn ptr
0x0C  MOVZ W9,  #slot_index           ; diagnostic; hook may ignore (W9 = arg #9)
0x10  BLR  X16                        ; hook(x0..x7) — return ends up in x0
0x14  LDP  X29, X30, [SP], #0x10
0x18  RET                             ; orig is NOT executed by the cave
0x1C  NOP × 12                        ; padding to keep tail at +0x4C
…
0x4C  <displaced prologue insn>       ; reachable only via the bypass entry
0x50  B    <orig + 4>                 ; (or as the cave-bypass trampoline)
```

The cave hands the hook pristine `x0..x7`. The hook is responsible for
running orig itself when it wants the original behavior — typically by
casting an entry in the consumer's bypass-entry table (already populated
with `cave_va + 0x4C`) and calling it as a function pointer. Whatever `x0`
the hook returns becomes the caller's return value because the cave's tail
is plain `RET`.

`MOVZ W9, #slot_index` is debug-only: it lets you tell entry caves apart
in a register dump without touching any caller-supplied argument. Hooks
ignore it.

## End-to-end examples

The snippets below are abbreviated; for the real wiring see the consumer
tweaks ([Bridge](https://github.com/IPA-Patch/KiouEngineBridge),
[KiouForge](https://github.com/IPA-Patch/KiouForge)).

### `observer`

Useful when you want a free look at every call to a method.

```python
# recipe (Python — Shared/tools)
_SITES = [
    # (rva, prologue_hex, hook_id_name, kind, label)
    (0x5A2CD24, "ff4301d1", "HOOK_NOTIFY_PIECE_MOVED", CAVE_OBSERVER,
     "GameStateStore.NotifyPieceMoved"),
]
```

```c
// Sources/Internal.h
enum hook_id {
    HOOK_NOTIFY_PIECE_MOVED,
    HOOK__COUNT,
};
void HookNotifyPieceMovedObserve(void *self, uint32_t move, int32_t side);
```

```c
// Sources/Hook_BoardObserve.m
void HookNotifyPieceMovedObserve(void *self, uint32_t move, int32_t side) {
    IPALog([NSString stringWithFormat:
              @"[BOARD] notify self=%p move=0x%x side=%d", self, move, side]);
    // No need to call orig — the cave will execute it after we return.
}
```

```c
// Sources/Dispatcher.m (one switch covering every observer site)
static void dispatch_one(void *x0, void *x1, void *x2, void *x3, void *x4,
                         void *x5, uint32_t hook_id, void *x7) {
    switch (hook_id) {
    case HOOK_NOTIFY_PIECE_MOVED:
        HookNotifyPieceMovedObserve(x0, (uint32_t)(uintptr_t)x1,
                                          (int32_t)(intptr_t)x2);
        break;
    // … other observer cases …
    }
}
```

### `entry`

Useful when the hook decides whether and how orig runs, including
overriding its return.

```python
# recipe
_SITES = [
    (0x591E860, "fd7bbfa9", "HOOK_ACCOUNT_EXISTS", CAVE_ENTRY,
     "UserSaveDataExtensions.AccountExists"),
]

_ENTRY_SLOT_INDEX = {"HOOK_ACCOUNT_EXISTS": 0}
ENTRY_SLOT_COUNT  = 1
ENTRY_SLOT_BASE_RVA = 0x8F90CD0  # contiguous bss tail
```

```c
// Sources/Internal.h
enum entry_slot_id {
    ENTRY_SLOT_ACCOUNT_EXISTS = 0,
    ENTRY_SLOT__COUNT,
};
bool HookAccountExistsEntry(void *data);
```

```c
// Sources/Hook_AccountObserve.m
bool HookAccountExistsEntry(void *data) {
    // 1. Pre-orig work (peek, log, decide on override).
    bool forceRegister = SettingsForceRegisterArmed();

    // 2. Run orig via the per-site cave-bypass entry. The consumer
    //    populates g_inject_entry[i] = cave_va + 0x4C at publish time.
    typedef bool (*AccountExists_t)(void *);
    AccountExists_t bypass =
        (AccountExists_t)g_inject_entry[HOOK_ACCOUNT_EXISTS];
    bool origResult = bypass ? bypass(data) : false;

    // 3. Decide the actual return value the caller will see (x0 == this).
    return forceRegister ? false : origResult;
}
```

```c
// Sources/Dispatcher.m
void PublishChinlanSlots(uintptr_t unityBase) {
    // Observer dispatcher slot (one per consumer).
    void *volatile *obs = (void * volatile *)(unityBase + HOOK_SLOT_RVA);
    *obs = (void *)&dispatch_one;

    // Entry slot table — one slot per CAVE_ENTRY site.
    void *volatile *ent = (void * volatile *)(unityBase + ENTRY_SLOT_BASE_RVA);
    ent[ENTRY_SLOT_ACCOUNT_EXISTS] = (void *)&HookAccountExistsEntry;
}
```

### `entry` with argument substitution

Same shape, but the hook rewrites an il2cpp string argument before
forwarding to orig.

```c
void *HookLoginArgsCreateEntry(void *deviceId, void *distinctId) {
    void *useDeviceId = deviceId;
    NSString *pending = SettingsPendingDeviceId();
    if (pending.length > 0) {
        void *swapped = il2cpp_string_new(pending.UTF8String);
        if (swapped) useDeviceId = swapped;
    }
    typedef void *(*Create_t)(void *, void *);
    Create_t bypass = (Create_t)g_inject_entry[HOOK_LOGIN_ARGS_CREATE];
    return bypass ? bypass(useDeviceId, distinctId) : NULL;
}
```

An `observer` here would fail silently: the cave restores `x0` (=
`deviceId`) from the saved frame before `B orig+4`, so the substituted
pointer is dropped on the way into orig.

## Common pitfalls

- **W6 clobber.** Picking `observer` for a 7-arg function corrupts the
  dispatcher's view of the 7th argument. Use `entry` and avoid going
  through the dispatcher at all.
- **Cave order = bypass-entry index.** Consumers compute the bypass entry
  as `unityBase + CAVE_REGION_START + i * 84 + 0x4C`, where `i` is the
  row's position in `_SITES`. Inserting / reordering rows shifts every
  downstream bypass index. Append; don't rearrange.
- **Entry slot table must be in `__DATA,__bss`.** The cave's ADRP+LDR
  resolves against the framework binary, not the dylib — the slot has to
  live somewhere the framework's load address can reach by `ADRP/LDR`,
  which means an `__bss` tail you've validated with the recipe's
  `assert_slot_in_bss` helper.
- **`(void)useArg;` on JB.** Consumers that share their hook body across
  JB and chinlan often have `KIOU_CALL_ORIG_RET(RET_T, ORIG, ...)`
  expand to a no-op on chinlan (the cave runs orig itself). Without a
  `(void)useArg;` or a `#if !KIOU_CHINLAN` wrapper, `-Werror=unused-
  variable` will trip on the chinlan build.
- **`KIOU_CALL_ORIG_RET` drops varargs on chinlan.** Don't rely on it
  to propagate substituted arguments into orig on the chinlan build —
  for that case you have to call the bypass entry yourself (`entry` cave
  pattern above).
