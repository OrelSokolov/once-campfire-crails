import gdb, struct, traceback, os

BIN_BASE = 0x555555554000
TEXT_LO = BIN_BASE + 0x34000
TEXT_HI = BIN_BASE + 0x35a000
SWAP_RET = BIN_BASE + 0x72e0a   # the `ret` in Fiber.swapcontext (x86_64-sysv.cr:18)

DUMP = open('/tmp/segv-dump-%d.txt' % os.getpid(), 'w')

def out(*a):
    print(*a)
    print(*a, file=DUMP)
    DUMP.flush()

def rd(addr, n):
    try:
        return bytes(gdb.selected_inferior().read_memory(addr, n))
    except Exception:
        return None

def qwords(buf):
    return struct.unpack('<%dQ' % (len(buf)//8), buf[:len(buf)//8*8])

def maps():
    out_l = []
    with open('/proc/%d/maps' % gdb.selected_inferior().pid) as f:
        for line in f:
            parts = line.split()
            rng, perms = parts[0], parts[1]
            if not ('r' in perms and 'w' in perms):
                continue
            if len(parts) > 5 and parts[5].endswith('.sqlite3-shm'):
                continue
            a, b = rng.split('-')
            out_l.append((int(a,16), int(b,16), perms, parts[5] if len(parts)>5 else ''))
    return out_l

def find_qword(value, maxhits=64):
    hits = []
    for a,b,perms,name in maps():
        # app GC/C heap (0x5555...) plus small rw arenas (malloc mmap chunks,
        # sqlite caches) — skip 8MiB fiber stacks and huge regions
        if not (0x555555554000 <= a < 0x555600000000):
            if b - a >= 0x700000: continue
        buf = rd(a, b-a)
        if buf is None: continue
        off = 0
        while True:
            i = buf.find(struct.pack('<Q', value), off)
            if i < 0: break
            hits.append((a+i, name, perms))
            off = i+1
            if len(hits) >= maxhits: return hits
    return hits

def region_of(sp):
    for a,b,perms,name in maps():
        if a <= sp < b:
            return a, b
    return None, None

def try_crystal_string(p):
    hdr = rd(p, 16)
    if not hdr: return None
    t, bs, sz = struct.unpack('<iii', hdr[:12])
    if not (0 < bs <= 64 and bs == sz and 0 < t < 40): return None
    body = rd(p+12, bs+1)
    if body is None: return None
    try:
        return body[:bs].decode('utf-8')
    except Exception:
        return None

def dump_fiber(addr, tag):
    buf = rd(addr, 0x70)
    if buf is None:
        out('--- %s Fiber @ 0x%x UNREADABLE' % (tag, addr)); return
    qs = qwords(buf)
    out('--- %s Fiber @ 0x%x ---' % (tag, addr))
    out('  context.stack_top@0x00 = 0x%016x' % qs[0])
    out('  context.resumable@0x08 = %d' % struct.unpack('<q', buf[8:16])[0])
    out('  @stack@0x10            = 0x%016x' % qs[2])
    for i,q in enumerate(qs[3:12], start=3):
        out('  +0x%02x: 0x%016x' % (i*8, q))
    out('  @alive@0x60            = %d' % buf[0x60])
    for off in (0x28, 0x30, 0x38, 0x40, 0x48, 0x50):
        p = qs[off//8] if off//8 < len(qs) else 0
        if 0x555555554000 <= p < 0x555600000000:
            s = try_crystal_string(p)
            if s: out('  name?@+0x%02x = %r' % (off, s))

class BadResume(gdb.Breakpoint):
    def stop(self):
        try:
            return self._dump()
        except Exception:
            out('=====PY stop() FATAL=====')
            out(traceback.format_exc())
            return True

    def _dump(self):
        rsp = int(gdb.parse_and_eval('$rsp'))
        tq = rd(rsp, 8)
        target = qwords(tq)[0] if tq else -1
        rdi = int(gdb.parse_and_eval('$rdi'))
        # filter: legit resume = ret target inside main .text
        if TEXT_LO <= target < TEXT_HI:
            return False
        out('=====PY_BAD_RESUME rsp=0x%x target=0x%x rdi=0x%x=====' % (rsp, target, rdi))
        lo, hi = region_of(rsp)
        out('rsp region: [0x%x, 0x%x)' % (lo or 0, hi or 0))
        blk = rd(rsp - 0x40, 0x80)
        if blk:
            out('qwords around rsp:')
            for i, q in enumerate(qwords(blk)):
                m = ''
                if BIN_BASE <= q < BIN_BASE + 0x360000: m = ' <MAINBIN text+0x%x>' % (q - BIN_BASE)
                out('  0x%x: 0x%016x%s' % (rsp-0x40+i*8, q, m))
        if 0x555555554000 <= rdi < 0x555600000000:
            dump_fiber(rdi, 'VICTIM(rdi=restored-arg)')
            for hit, name, perms in find_qword(rdi):
                out('  referenced-by 0x%x (%s %s)' % (hit, name, perms))
        try:
            gdb.execute('bt 12')
        except gdb.error as e:
            out('bt failed: %s' % e)
        return True

gdb.execute('set pagination off')
gdb.execute('set confirm off')
gdb.execute('handle SIGPIPE nostop noprint pass')
gdb.execute('handle SIGTERM nostop noprint pass')

bp = BadResume('*0x%x' % SWAP_RET)
out('bad-resume bp armed (python-filtered)')

EXEC_ARGS_ENTRY = BIN_BASE + 0x265af0

class ExecEntry(gdb.Breakpoint):
    def stop(self):
        try:
            rsp = int(gdb.parse_and_eval('$rsp'))
            rq = rd(rsp, 8)
            retaddr = qwords(rq)[0] if rq else -1
            rsi = int(gdb.parse_and_eval('$rsi') & 0xffffffffffffffff)
            if TEXT_LO <= retaddr < TEXT_HI and (0x555555554000 <= rsi < 0x555600000000 or 0x7f0000000000 <= rsi < 0x800000000000):
                arm_shm_trace()
                return False  # legit call
            out('=====PY_BAD_EXEC_ENTRY rsp=0x%x retaddr=0x%x rsi=0x%x=====' % (rsp, retaddr, rsi))
            # decisive: who in runtime memory holds the jump-target value (method entry)?
            entry_val = EXEC_ARGS_ENTRY
            out('--- runtime holders of entry value 0x%x:' % entry_val)
            for hit, name, perms in find_qword(entry_val, maxhits=100):
                out('  at 0x%x (%s %s)' % (hit, name, perms))
                ctx = rd(hit - 0x30, 0x60) if hit > 0x100 else None
                if ctx:
                    out('    ctx:')
                    for i, q in enumerate(qwords(ctx)):
                        m = ''
                        if BIN_BASE <= q < BIN_BASE + 0x360000: m = ' <MAINBIN text+0x%x>' % (q - BIN_BASE)
                        out('      0x%x: 0x%016x%s' % (hit - 0x30 + i*8, q, m))
            # scan fiber stacks (8MiB regions) for the entry value too
            out('--- fiber-stack holders of entry value:')
            pat = struct.pack('<Q', entry_val)
            for a,b,perms,name in maps():
                if b - a < 0x700000: continue
                buf = rd(a, b-a)
                if buf is None: continue
                off = 0
                while True:
                    i = buf.find(pat, off)
                    if i < 0: break
                    out('  stack [0x%x,0x%x): at 0x%x (top-0x%x)' % (a, b, a+i, b-(a+i)))
                    off = i+1
            # read-only RELRO/rodata of main binary: vtables live here (missed by rw-only maps)
            out('--- ro-region holders of entry value:')
            pat2 = struct.pack('<Q', entry_val)
            with open('/proc/%d/maps' % gdb.selected_inferior().pid) as f:
                ro_ranges = []
                for line in f:
                    parts = line.split()
                    if 'r' not in parts[1] or 'w' in parts[1]: continue
                    a, b = parts[0].split('-')
                    a, b = int(a,16), int(b,16)
                    if BIN_BASE <= a < BIN_BASE + 0x600000:
                        ro_ranges.append((a,b))
            for a,b in ro_ranges:
                buf = rd(a, b-a)
                if buf is None: continue
                off = 0
                while True:
                    i = buf.find(pat2, off)
                    if i < 0: break
                    out('  ro 0x%x (bin+0x%x): at 0x%x (bin+0x%x)' % (a, a-BIN_BASE, a+i, a+i-BIN_BASE))
                    ctx = rd(a+i-0x20, 0x40)
                    if ctx:
                        for k, q in enumerate(qwords(ctx)):
                            m = ''
                            if BIN_BASE <= q < BIN_BASE + 0x360000: m = ' <text+0x%x>' % (q-BIN_BASE)
                            out('    0x%x: 0x%016x%s' % (a+i-0x20+k*8, q, m))
                    off = i+1
            # sigreturn theory: search current stack for a ucontext containing
            # our distinctive garbage regs (r8/r9) and rip=entry
            r8v = int(gdb.parse_and_eval('$r8')) & 0xffffffffffffffff
            r9v = int(gdb.parse_and_eval('$r9')) & 0xffffffffffffffff
            out('--- ucontext probe: r8=0x%x r9=0x%x' % (r8v, r9v))
            lo_r, hi_r = region_of(rsp)
            if lo_r:
                sbuf = rd(lo_r, hi_r - lo_r)
                if sbuf:
                    for tag, val in (('r8', r8v), ('r9', r9v)):
                        pat3 = struct.pack('<Q', val)
                        off = 0
                        while True:
                            i = sbuf.find(pat3, off)
                            if i < 0: break
                            addr = lo_r + i
                            out('  %s value found at 0x%x (top-0x%x)' % (tag, addr, hi_r-addr))
                            # r8@ucontext+0x28, r9@+0x30, rip@+0xa8, rsp@+0xa0
                            for base_off, name in ((0x28, 'r8'), (0x30, 'r9')):
                                base = addr - base_off
                                uq = rd(base + 0xa8, 8)
                                if uq:
                                    ripu = qwords(uq)[0]
                                    if ripu == EXEC_ARGS_ENTRY:
                                        out('  >>> MATCH: ucontext @ 0x%x has rip=ENTRY!' % base)
                                        ub = rd(base, 0xd8)
                                        if ub:
                                            names = ['uc_flags','uc_link','ss_sp','ss_flags','ss_size','pad','r8','r9','r10','r11','r12','r13','r14','r15','rdi','rsi','rbp','rbx','rdx','rax','rcx','rsp','rip','eflags']
                                            for k, q in enumerate(qwords(ub)):
                                                nm = names[k] if k < len(names) else '?'
                                                out('    %-9s 0x%016x' % (nm+':', q))
                            off = i+1
            # sqlite3-shm mappings were excluded from maps() from the start;
            # the wal-index lives there and is shared across forked workers
            out('--- shm-region holders of entry value:')
            with open('/proc/%d/maps' % gdb.selected_inferior().pid) as f:
                shm_ranges = []
                for line in f:
                    if 'sqlite3-shm' not in line: continue
                    parts = line.split()
                    a, b = parts[0].split('-')
                    shm_ranges.append((int(a,16), int(b,16), parts[1]))
            for a,b,perms in shm_ranges:
                buf = rd(a, b-a)
                if buf is None: continue
                off = 0
                while True:
                    i = buf.find(pat2, off)
                    if i < 0: break
                    out('  shm 0x%x: at 0x%x (+0x%x)' % (a, a+i, i))
                    off = i+1
            out('  (%d shm regions scanned)' % len(shm_ranges))
            out('--- last sqlite3_close calls before corruption:')
            for dbp, chain in CLOSE_RING[-20:]:
                out('  db=0x%x via %s' % (dbp, chain))
            if not CLOSE_RING:
                out('  (none logged)')
            out('--- last __crystal_raise calls (%d total):' % len(RAISE_RING))
            for chain in RAISE_RING[-20:]:
                out('  raise via %s' % chain)
            gdb.execute('info registers rax rbx rcx rdx rsi rdi rbp rsp r8 r9 r10 r11 r12 r13 r14 r15')
            rax = int(gdb.parse_and_eval('$rax'))
            rdi = int(gdb.parse_and_eval('$rdi'))
            for name, pv in (('rdi', rdi), ('rax', rax)):
                if pv > 0x1000:
                    qv = rd(pv, 8)
                    if qv:
                        out('  [%s]=0x%x' % (name, qwords(qv)[0]))
                    slot = rd(pv + 0x78, 8)
                    if slot:
                        out('  [%s+0x78]=0x%x   <-- xShmBarrier slot' % (name, qwords(slot)[0]))
            # sqlite3_file dump (rdi): first 0x40
            fb = rd(rdi, 0x100) if rdi > 0x1000 else None
            if fb:
                out('  sqlite3_file @ rdi:')
                for i, q in enumerate(qwords(fb)):
                    m = ''
                    if BIN_BASE <= q < BIN_BASE + 0x360000: m = ' <MAINBIN>'
                    out('    +0x%02x: 0x%016x%s' % (i*8, q, m))
            # who holds pFile (the wal->pDbFd slot)?
            out('  --- holders of pFile 0x%x:' % rdi)
            for hit, name, perms in find_qword(rdi):
                out('    at 0x%x (%s %s)' % (hit, name, perms))
                if 0x555555554000 <= hit < 0x555600000000 or 0x7f0000000000 <= hit < 0x800000000000:
                    wb = rd(hit - 0x30, 0x60)
                    if wb:
                        out('      ctx around holder slot:')
                        for i, q in enumerate(qwords(wb)):
                            out('        0x%x: 0x%016x' % (hit - 0x30 + i*8, q))
            # pMethods holders too
            pmq = rd(rdi, 8) if rdi > 0x1000 else None
            if pmq:
                pmv = qwords(pmq)[0]
                out('  --- holders of pMethods 0x%x:' % pmv)
                for hit, name, perms in find_qword(pmv):
                    out('    at 0x%x (%s %s)' % (hit, name, perms))
            blk = rd(rsp - 0x100, 0x180)
            if blk:
                out('qwords rsp-0x100..rsp+0x80:')
                for i, q in enumerate(qwords(blk)):
                    m = ''
                    if BIN_BASE <= q < BIN_BASE + 0x360000: m = ' <MAINBIN text+0x%x>' % (q - BIN_BASE)
                    if 0x7ffff7e00000 <= q < 0x7ffff8000000: m = ' <libsqlite3>'
                    out('  0x%x: 0x%016x%s' % (rsp-0x100+i*8, q, m))
            try:
                gdb.execute('bt 12')
            except gdb.error as e:
                out('bt failed: %s' % e)
            return True
        except Exception:
            out('=====PY ExecEntry FATAL=====')
            out(traceback.format_exc())
            return True

ExecEntry('*0x%x' % EXEC_ARGS_ENTRY)
out('exec:args entry bp armed (python-filtered)')

SQLITE_BASE = 0x7ffff7e0f000
OS_CALL_SITE = SQLITE_BASE + 0x11a158  # call sqlite3OsShmBarrier in WalSavepointUndo

class TraceShmBarrier(gdb.Breakpoint):
    def stop(self):
        try:
            rdi = int(gdb.parse_and_eval('$rdi'))
            pfile = rdi  # WalSavepointUndo+0x146 loaded wal->pDbFd into rdi
            pm_q = rd(pfile, 8) if pfile > 0x1000 else None
            if pm_q is None:
                out('=====PY_SHMB pfile=0x%x unreadable=====' % pfile)
                return False
            pm = qwords(pm_q)[0]
            tgt_q = rd(pm + 0x78, 8) if pm > 0x1000 else None
            tgt = qwords(tgt_q)[0] if tgt_q else -1
            if SQLITE_BASE <= tgt < SQLITE_BASE + 0x200000:
                return False  # legit VFS dispatch
            out('=====PY_SHMB_BAD pfile=0x%x pMethods=0x%x target=0x%x=====' % (pfile, pm, tgt))
            gdb.execute('info registers rdi rsi rdx rcx rsp')
            fb = rd(pfile, 0x100)
            if fb:
                out('pFile dump:')
                for i, q in enumerate(qwords(fb)):
                    m = ''
                    if BIN_BASE <= q < BIN_BASE + 0x360000: m = ' <MAINBIN>'
                    if SQLITE_BASE <= q < SQLITE_BASE + 0x200000: m = ' <libsqlite3>'
                    out('  +0x%02x: 0x%016x%s' % (i*8, q, m))
            if pm > 0x1000:
                vb = rd(pm, 0x100)
                if vb:
                    out('pMethods dump:')
                    for i, q in enumerate(qwords(vb)):
                        m = ''
                        if BIN_BASE <= q < BIN_BASE + 0x360000: m = ' <MAINBIN text+0x%x>' % (q - BIN_BASE)
                        if SQLITE_BASE <= q < SQLITE_BASE + 0x200000: m = ' <libsqlite3>'
                        out('  +0x%02x: 0x%016x%s' % (i*8, q, m))
            out('--- holders of pFile 0x%x (wal->pDbFd slot):' % pfile)
            for hit, name, perms in find_qword(pfile):
                out('  at 0x%x (%s %s)' % (hit, name, perms))
                if 0x555555554000 <= hit < 0x555600000000:
                    wb = rd(hit - 0x40, 0x80)
                    if wb:
                        out('    ctx around wal->pDbFd slot:')
                        for i, q in enumerate(qwords(wb)):
                            out('      0x%x: 0x%016x' % (hit - 0x40 + i*8, q))
            try:
                gdb.execute('bt 12')
            except gdb.error as e:
                out('bt failed: %s' % e)
            return True
        except Exception:
            out('=====PY SHMB FATAL=====')
            out(traceback.format_exc())
            return True

SHM_BP_ARMED = [False]

def arm_shm_trace():
    if SHM_BP_ARMED[0]:
        return
    SHM_BP_ARMED[0] = True
    try:
        TraceShmBarrier('*0x%x' % OS_CALL_SITE)
        out('shmbarrier trace bp armed at runtime')
    except Exception:
        out('arm_shm_trace failed')
        out(traceback.format_exc())

CLOSE_RING = []

class CloseLog(gdb.Breakpoint):
    def stop(self):
        try:
            rdi = int(gdb.parse_and_eval('$rdi'))
            bt = []
            f = gdb.newest_frame()
            for _ in range(10):
                if f is None: break
                try:
                    name = f.name() or '??'
                except Exception:
                    name = '??'
                bt.append(name)
                f = f.older()
            CLOSE_RING.append((rdi, ' <- '.join(bt[:6])))
            if len(CLOSE_RING) > 40:
                CLOSE_RING.pop(0)
            out('PY_CLOSE db=0x%x via %s' % (rdi, ' <- '.join(bt[:4])))
        except Exception:
            out('PY_CLOSE err ' + traceback.format_exc())
        return False

class BootArm(gdb.Breakpoint):
    """Arms the sqlite trace bp once libs are loaded (first unprepared stmt)."""
    def stop(self):
        arm_shm_trace()
        try:
            CloseLog('sqlite3_close')
            CloseLog('sqlite3_close_v2')
            out('close-log bps armed')
        except Exception:
            out('close-log arm failed: ' + traceback.format_exc())
        self.enabled = False
        return False

RAISE_RING = []

class RaiseLog(gdb.Breakpoint):
    def stop(self):
        try:
            f = gdb.newest_frame()
            names = []
            for _ in range(7):
                if f is None: break
                try: names.append(f.name() or '??')
                except Exception: names.append('??')
                f = f.older()
            RAISE_RING.append(' <- '.join(names[:5]))
            if len(RAISE_RING) > 100: RAISE_RING.pop(0)
        except Exception:
            pass
        return False

RaiseLog('*0x%x' % (BIN_BASE + 0x4e580))  # __crystal_raise
out('raise-log bp armed')

CloseLog('*0x%x' % (BIN_BASE + 0x34430))   # sqlite3_close@plt
CloseLog('*0x%x' % (BIN_BASE + 0x34436))   # sqlite3_close@plt slow path
out('close-log bps armed on PLT from start')

WAL_ENTRY_OFF = 0x119ff0  # sqlite3WalSavepointUndo
WAL_ARMED = [False]

def libsqlite_base():
    with open('/proc/%d/maps' % gdb.selected_inferior().pid) as f:
        for line in f:
            if 'libsqlite3.so' in line and ' r--p ' in line:
                return int(line.split('-')[0], 16)
    return None

class WalEntry(gdb.Breakpoint):
    def stop(self):
        try:
            rdi = int(gdb.parse_and_eval('$rdi'))  # pWal
            base = libsqlite_base()
            pdb_q = rd(rdi + 8, 8) if rdi > 0x1000 else None
            if pdb_q is None:
                return False
            pdb = qwords(pdb_q)[0]  # wal->pDbFd
            pm_q = rd(pdb, 8) if pdb > 0x1000 else None
            pm = qwords(pm_q)[0] if pm_q else 0
            if base and base <= pm < base + 0x200000 and base <= pdb < base + 0x400000:
                return False  # healthy
            out('=====PY_WAL_BAD pWal=0x%x pDbFd=0x%x pMethods=0x%x=====' % (rdi, pdb, pm))
            gdb.execute('info registers rdi rsi rsp')
            wb = rd(rdi, 0x60)
            if wb:
                out('pWal dump:')
                for i, q in enumerate(qwords(wb)):
                    out('  +0x%02x: 0x%016x' % (i*8, q))
            out('--- holders of pWal 0x%x (db->pWal slot):' % rdi)
            for hit, name, perms in find_qword(rdi):
                out('  at 0x%x (%s %s)' % (hit, name, perms))
                if hit > 0x10000:
                    dbb = rd(hit - 0x40, 0x80)
                    if dbb:
                        out('    db-handle ctx:')
                        for i, q in enumerate(qwords(dbb)):
                            out('      0x%x: 0x%016x' % (hit - 0x40 + i*8, q))
            try:
                gdb.execute('bt 15')
            except gdb.error as e:
                out('bt failed: %s' % e)
            return True
        except Exception:
            out('=====PY WALENTRY FATAL=====')
            out(traceback.format_exc())
            return True

class OpenArm(gdb.Breakpoint):
    def stop(self):
        try:
            if WAL_ARMED[0]:
                return False
            WAL_ARMED[0] = True
            base = libsqlite_base()
            if base:
                WalEntry('*0x%x' % (base + WAL_ENTRY_OFF))
                out('wal-entry bp armed (libsqlite3 base 0x%x)' % base)
            else:
                out('libsqlite3 not mapped at open_v2?!')
            self.enabled = False
        except Exception:
            out('openarm failed: ' + traceback.format_exc())
        return False

OpenArm('*0x%x' % (BIN_BASE + 0x34ad0))  # sqlite3_open_v2@plt
out('open-arm bp armed')

try:
    gdb.execute('run')
except gdb.error as e:
    out('run error: %s' % e)
out('=====PY run finished=====')
try:
    gdb.execute('info registers rip rsp rdi rsi')
    gdb.execute('x/4i $rip')
    gdb.execute('bt 12')
except gdb.error as e:
    out('post dump failed: %s' % e)
DUMP.flush()
