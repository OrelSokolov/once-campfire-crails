Title: SIGSEGV: scheduler resumes a dead fiber whose stack was recycled by Fiber::StackPool (1.21.1, -Dwithout_mt)

## Summary

Under heavy churn of short-lived fibers (HTTP request fibers dying on client
disconnects) combined with pooled SQLite access, the program crashes with
SIGSEGV. GDB forensics show the faulting instruction is the `ret` at the end
of `Fiber::swapcontext`: a dead fiber is resumed, its `Fiber`/`Context` object
has already been collected by the GC (no reference to its saved `stack_top`
exists anywhere in the heap), and its stack has already been recycled by
`Fiber::StackPool` and handed to another fiber. The restored registers are
garbage from the reused stack, and the restored rip points at arbitrary code.

## Version

- Crystal 1.21.1 [73ea5c2b1] (2026-09-26), LLVM 20.1.8
- Linux x86_64 (Ubuntu 25.04-ish, glibc, libsqlite3 0.8.6)
- Build flags: `--release -Dwithout_mt`

## Reproducer

Application-level (crashes within 1–2 runs, ~20–40 s each):
https://github.com/OrelSokolov/once-campfire-crails — `capybara-tests/`
suite, `TARGET=crails bin/run -n /LiveTest/`.

A standalone reproducer has not been isolated yet; the following were ruled
out by bisection (crash persists with each disabled): connection pool size,
custom sqlite busy handler, background job workers, Action Cable (WS), cable
ping loops, a dedicated writer fiber running closures over parked fibers'
stacks. The trigger lives in the basic per-request path (request fiber +
DB::Database pool + middleware) under connection churn.

## Evidence (gdb, ASLR disabled)

Crash context — PC at a function entry, all registers deterministic garbage:

```
rdi 0x555555a93f48  == &first_thread+312 (Boehm GC static, .bss)
rbp 0x29   r15 0x29   r14 0x1   r12 0x0   rsi 0x1
[rsp] = 0x00007fffef3f1c60  (heap pointer — not a code address)
```

Breakpoint at `Fiber::swapcontext+0x2a` (the `ret`) with the same register
condition hits before the fault: the value popped as rip is a heap pointer.
Searching every writable memory region for the target fiber's saved sp finds
**zero** references — the `Fiber`/`Context` object holding it was collected.
The stack it points into contains live frames of a *different* fiber
(`DB::PoolStatement#exec`) — the stack was recycled by `Fiber::StackPool`
after the victim died, and the garbage context was restored from it.

Interpretation: something resumes a dead fiber (double enqueue in the
scheduler runnables, or a stale channel/timer waiter), whose stack has
already been reused — restoring a corrupted context and jumping to a
garbage rip.

## Expected behavior

Resuming a dead (or already-suspended-elsewhere) fiber should never happen;
if it does (programming error), it should raise a detectable error instead
of executing arbitrary memory.

## Details that may help

- Deterministic register garbage across runs suggests a reproducible
  allocation/reuse pattern, not a random race.
- Does not reproduce on a non-release build in two full runs (timing
  sensitive).
- The workload includes `Channel(Nil).select` with timeouts and buffered
  channels used at high frequency.
