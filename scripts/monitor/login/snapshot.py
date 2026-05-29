#!/usr/bin/env python3
"""Collect login-node metrics and print a single JSON line to stdout."""
import sys, json, re, subprocess
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor

hostname = sys.argv[1]
top_n    = int(sys.argv[2])

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def run(cmd):
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return r.stdout.decode('utf-8', errors='replace')
    except Exception:
        return ''

def _float(s):
    try:    return float(s)
    except: return None

def _int(s):
    try:    return int(s)
    except: return None

# ---------------------------------------------------------------------------
# parsers
# ---------------------------------------------------------------------------

def parse_uptime(s):
    m = re.search(r'(\d+)\s+user', s)
    users = int(m.group(1)) if m else 0
    loads = re.findall(r'load average:\s*([\d.]+),\s*([\d.]+),\s*([\d.]+)', s)
    return {
        'users':   users,
        'load_1':  _float(loads[0][0]) if loads else None,
        'load_5':  _float(loads[0][1]) if loads else None,
        'load_15': _float(loads[0][2]) if loads else None,
    }

def parse_w(s):
    users = []
    for line in s.splitlines()[2:]:
        p = line.split(None, 7)
        if len(p) >= 6:
            users.append({
                'user':  p[0],
                'tty':   p[1],
                'from':  p[2],
                'login': p[3],
                'idle':  p[4],
                'jcpu':  p[5],
                'pcpu':  p[6] if len(p) > 6 else '',
                'what':  p[7].strip()[:200] if len(p) > 7 else '',
            })
    return users

def parse_proc_states(s):
    c = {}
    for line in s.splitlines():
        k = line.strip()[:1]
        c[k] = c.get(k, 0) + 1
    return {
        'running':    c.get('R', 0),
        'blocked_io': c.get('D', 0),
        'sleeping':   c.get('S', 0),
        'zombie':     c.get('Z', 0),
        'stopped':    c.get('T', 0),
    }

def parse_memory(s):
    out = {}
    for line in s.splitlines():
        p = line.split()
        if len(p) >= 7 and p[0] in ('Mem:', 'Swap:'):
            key = p[0].rstrip(':').lower()
            out[key] = {
                'total_gb':      round(int(p[1]) / 1e9, 1),
                'used_gb':       round(int(p[2]) / 1e9, 1),
                'free_gb':       round(int(p[3]) / 1e9, 1),
            }
            if p[0] == 'Mem:':
                out[key]['shared_gb']     = round(int(p[4]) / 1e9, 1)
                out[key]['buff_cache_gb'] = round(int(p[5]) / 1e9, 1)
                out[key]['available_gb']  = round(int(p[6]) / 1e9, 1)
    return out

def parse_mpstat(s):
    cpus = []
    for line in s.splitlines():
        if not line.startswith('Average:'):
            continue
        p = line.split()
        if len(p) < 12 or p[1] == 'CPU':
            continue
        try:
            cpus.append({
                'cpu':    p[1],
                'usr':    float(p[2]),
                'sys':    float(p[4]),
                'iowait': float(p[5]),
                'irq':    float(p[6]),
                'soft':   float(p[7]),
                'idle':   float(p[11]),
            })
        except (ValueError, IndexError):
            pass
    return cpus

def parse_vmstat(s):
    lines = [l for l in s.splitlines() if l.strip()]
    if len(lines) < 3:
        return {}
    p = lines[-1].split()
    keys = ['procs_r','procs_b','swpd_kb','free_kb','buff_kb','cache_kb',
            'si','so','bi','bo','interrupts_s','ctxt_switches_s',
            'cpu_us','cpu_sy','cpu_id','cpu_wa']
    return {k: _int(v) for k, v in zip(keys, p)}

def parse_iostat(s):
    lines = s.splitlines()
    # find the second avg-cpu block (first is since-boot)
    n, start = 0, -1
    for i, line in enumerate(lines):
        if line.startswith('avg-cpu:'):
            n += 1
            if n == 2:
                start = i
                break
    if start < 0:
        return {'devices': []}
    devices = []
    for line in lines[start + 2:]:
        if not line.strip() or line.startswith('avg-cpu') or line.startswith('Device'):
            continue
        p = line.split()
        if len(p) >= 15:
            try:
                devices.append({
                    'device':   p[0],
                    'r_s':      float(p[1]),
                    'w_s':      float(p[2]),
                    'rkb_s':    float(p[3]),
                    'wkb_s':    float(p[4]),
                    'r_await':  float(p[9]),
                    'w_await':  float(p[10]),
                    'util_pct': float(p[14]),
                })
            except (ValueError, IndexError):
                pass
    return {'devices': devices}

def parse_nfsiostat(s):
    mounts, seen, cur, in_second, state = [], {}, None, False, None
    for line in s.splitlines():
        m = re.match(r'.+ mounted on ([^:]+):', line)
        if m:
            mp = m.group(1)
            in_second = mp in seen
            seen[mp] = True
            cur = {'mountpoint': mp, 'ops_s': 0.0,
                   'rd_kb_s': 0.0, 'rd_rtt_ms': 0.0, 'rd_exe_ms': 0.0, 'rd_retrans': 0,
                   'wr_kb_s': 0.0, 'wr_rtt_ms': 0.0, 'wr_exe_ms': 0.0, 'wr_retrans': 0,
                   } if in_second else None
            state = None
            continue
        if cur is None:
            continue
        ls = line.strip()
        if re.match(r'ops/s', ls):
            state = 'ops'
        elif state == 'ops' and ls and ls[0].isdigit():
            p = ls.split()
            cur['ops_s'] = _float(p[0]) or 0.0
            state = None
        elif ls.startswith('read:'):
            state = 'read'
        elif state == 'read' and ls and (ls[0].isdigit() or ls[0] == '-'):
            p = ls.split()
            # columns: ops/s  kB/s  kB/op  retrans  [retrans%]  avg_rtt  avg_exe
            # retrans may be "0 (0.0%)" (2 tokens) or just "0" — use -2/-1 for rtt/exe
            cur['rd_kb_s']    = _float(p[1]) or 0.0
            cur['rd_retrans'] = _int(p[3]) or 0
            cur['rd_rtt_ms']  = _float(p[-2]) or 0.0
            cur['rd_exe_ms']  = _float(p[-1]) or 0.0
            state = None
        elif ls.startswith('write:'):
            state = 'write'
        elif state == 'write' and ls and (ls[0].isdigit() or ls[0] == '-'):
            p = ls.split()
            cur['wr_kb_s']    = _float(p[1]) or 0.0
            cur['wr_retrans'] = _int(p[3]) or 0
            cur['wr_rtt_ms']  = _float(p[-2]) or 0.0
            cur['wr_exe_ms']  = _float(p[-1]) or 0.0
            if cur['ops_s'] > 0.005:
                mounts.append(cur)
            cur = None
            state = None
    return sorted(mounts, key=lambda x: x['ops_s'], reverse=True)


def parse_mountstats():
    """Cumulative NFS retransmits, bad_xid, slot backlog, and RTT breakdown."""
    try:
        with open('/proc/self/mountstats') as f:
            text = f.read()
    except Exception:
        return []
    mounts, cur = [], None
    for line in text.splitlines():
        m = re.match(r'device\s+\S+\s+mounted on\s+(\S+)\s+with fstype\s+(nfs\S*)', line)
        if m:
            cur = {'mountpoint': m.group(1), 'fstype': m.group(2),
                   'bad_xid': 0, 'backlog_u': 0.0}
            mounts.append(cur)
            continue
        if cur is None:
            continue
        ls = line.strip()
        # xprt: tcp srcport bind_cnt conn_cnt conn_time idle_time sends recvs bad_xids req_u backlog_u
        if ls.startswith('xprt:') and 'tcp' in ls:
            p = ls.split()
            try:
                cur['bad_xid']  = int(p[9])
                cur['backlog_u'] = float(p[11]) if len(p) > 11 else 0.0
            except (ValueError, IndexError):
                pass
        # per-op: OP: ops retrans bytes_sent bytes_recv queue_ms rtt_ms exe_ms
        for op_tag, op_key in (('READ:', 'read'), ('WRITE:', 'write')):
            if ls.startswith(op_tag):
                p = ls.split()
                if len(p) >= 8:
                    try:
                        ops = int(p[1])
                        if ops > 0:
                            cur[op_key] = {
                                'ops':          ops,
                                'retrans':      int(p[2]),
                                'avg_queue_ms': round(int(p[5]) / ops, 2),
                                'avg_rtt_ms':   round(int(p[6]) / ops, 2),
                                'avg_exe_ms':   round(int(p[7]) / ops, 2),
                            }
                    except (ValueError, IndexError):
                        pass
    return [m for m in mounts if m.get('fstype', '').startswith('nfs')]


def parse_nfs_rpc():
    """NFS client-level RPC call and retransmit counts from /proc/net/rpc/nfs."""
    try:
        with open('/proc/net/rpc/nfs') as f:
            text = f.read()
    except Exception:
        return {}
    for line in text.splitlines():
        if line.startswith('rpc '):
            p = line.split()
            if len(p) >= 3:
                return {
                    'calls':           int(p[1]),
                    'retransmissions': int(p[2]),
                    'auth_refreshes':  int(p[3]) if len(p) > 3 else 0,
                }
    return {}


def parse_d_state_procs(s):
    """Processes blocked in uninterruptible I/O wait (D state)."""
    procs = []
    for line in s.splitlines():
        p = line.split(None, 3)
        if len(p) >= 4 and p[1].startswith('D'):
            try:
                procs.append({
                    'pid':  int(p[0]),
                    'stat': p[1],
                    'user': p[2],
                    'args': p[3][:200],
                })
            except (ValueError, IndexError):
                pass
    return procs

def parse_sar_dev(s):
    ifaces = []
    for line in s.splitlines():
        if not line.startswith('Average:'):
            continue
        p = line.split()
        if len(p) < 9 or p[1] == 'IFACE':
            continue
        try:
            rx_kb, tx_kb = float(p[4]), float(p[5])
            if rx_kb + tx_kb < 0.1:
                continue
            ifaces.append({
                'iface':    p[1],
                'rx_pkt_s': float(p[2]),
                'tx_pkt_s': float(p[3]),
                'rx_kb_s':  rx_kb,
                'tx_kb_s':  tx_kb,
                'util_pct': float(p[8]),
            })
        except (ValueError, IndexError):
            pass
    return sorted(ifaces, key=lambda x: x['rx_kb_s'] + x['tx_kb_s'], reverse=True)

def parse_ss(s):
    out = {}
    m = re.search(r'Total:\s+(\d+)', s)
    if m: out['total'] = int(m.group(1))
    m = re.search(r'TCP:\s+\d+ \(estab (\d+), closed (\d+), orphaned (\d+), timewait (\d+)\)', s)
    if m:
        out['tcp_estab']    = int(m.group(1))
        out['tcp_closed']   = int(m.group(2))
        out['tcp_orphaned'] = int(m.group(3))
        out['tcp_timewait'] = int(m.group(4))
    m = re.search(r'^UDP\s+(\d+)', s, re.MULTILINE)
    if m: out['udp_total'] = int(m.group(1))
    m = re.search(r'^TCP\s+(\d+)', s, re.MULTILINE)
    if m: out['tcp_total'] = int(m.group(1))
    return out

def parse_per_user(s, n):
    users = {}
    for line in s.splitlines():
        p = line.split()
        if len(p) < 3:
            continue
        u = p[0]
        if u not in users:
            users[u] = {'user': u, 'cpu_pct': 0.0, 'rss_mb': 0.0, 'procs': 0}
        users[u]['cpu_pct'] += _float(p[1]) or 0.0
        users[u]['rss_mb']  += ((_int(p[2]) or 0) / 1024.0)
        users[u]['procs']   += 1
    result = sorted(users.values(), key=lambda x: x['cpu_pct'], reverse=True)
    for u in result:
        u['cpu_pct'] = round(u['cpu_pct'], 1)
        u['rss_mb']  = round(u['rss_mb'],  1)
    return result[:n]

def parse_ps(s, n):
    procs = []
    for line in s.splitlines():
        p = line.split()
        if len(p) < 8:
            continue
        # start field is 1 token (HH:MM:SS) or 2 tokens (Mon DD / May 26)
        if len(p) > 6 and p[6][0].isdigit():
            started, time_i = p[6], 7
        elif len(p) > 7:
            started, time_i = p[6] + ' ' + p[7], 8
        else:
            continue
        if time_i >= len(p):
            continue
        try:
            procs.append({
                'pid':     int(p[0]),
                'user':    p[1],
                'cpu_pct': float(p[2]),
                'mem_pct': float(p[3]),
                'rss_kb':  int(p[4]),
                'stat':    p[5],
                'started': started,
                'time':    p[time_i],
                'args':    ' '.join(p[time_i+1:])[:200],
            })
        except (ValueError, IndexError):
            pass
    return procs[:n]

def parse_pidstat(s, n):
    procs = []
    for line in s.splitlines():
        if not line.startswith('Average:'):
            continue
        p = line.split()
        if len(p) < 8 or not p[1][:1].isdigit():
            continue
        try:
            procs.append({
                'uid':       int(p[1]),
                'pid':       int(p[2]),
                'kb_rd_s':   float(p[3]),
                'kb_wr_s':   float(p[4]),
                'kb_ccwr_s': float(p[5]),
                'iodelay':   int(p[6]),
                'command':   ' '.join(p[7:])[:200],
            })
        except (ValueError, IndexError):
            pass
    return sorted(procs, key=lambda x: x['iodelay'], reverse=True)[:n]

def parse_fds(s):
    p = s.split()
    if len(p) >= 3:
        return {'allocated': int(p[0]), 'free': int(p[1]), 'max': int(p[2])}
    return {}

# ---------------------------------------------------------------------------
# collect
# ---------------------------------------------------------------------------

with ThreadPoolExecutor(max_workers=8) as ex:
    # timed commands — run in parallel
    f_mpstat     = ex.submit(run, ['mpstat', '-P', 'ALL', '1', '1'])
    f_vmstat     = ex.submit(run, ['vmstat', '1', '1'])
    f_iostat     = ex.submit(run, ['iostat', '-xz', '1', '2'])
    f_sar        = ex.submit(run, ['sar', '-n', 'DEV', '1', '2'])
    f_pidstat    = ex.submit(run, ['pidstat', '-dl', '1', '2'])
    f_nfsiostat  = ex.submit(run, ['nfsiostat', '5', '2'])

    # instant reads while timed commands run
    uptime_out    = run(['uptime'])
    w_out         = run(['w'])
    ps_state_out  = run(['ps', '-e', '--no-headers', '-o', 'stat'])
    free_out      = run(['free', '-b'])
    ss_out        = run(['ss', '-s'])
    ps_cpu_out    = run(['ps', '-eo', 'pid,user,%cpu,%mem,rss,stat,start,time,args',
                         '--sort=-%cpu', '--no-headers'])
    ps_rss_out    = run(['ps', '-eo', 'pid,user,%cpu,%mem,rss,stat,start,time,args',
                         '--sort=-rss', '--no-headers'])
    ps_user_out   = run(['ps', '-eo', 'user,%cpu,rss', '--no-headers'])
    ps_dstate_out = run(['ps', 'axo', 'pid,stat,user,args', '--no-headers'])
    try:
        fds_out = open('/proc/sys/fs/file-nr').read().strip()
    except Exception:
        fds_out = ''

snapshot = {
    'timestamp':          datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    'hostname':           hostname,
    'uptime':             parse_uptime(uptime_out),
    'logged_in_users':    parse_w(w_out),
    'process_states':     parse_proc_states(ps_state_out),
    'memory':             parse_memory(free_out),
    'cpu':                parse_mpstat(f_mpstat.result()),
    'vmstat':             parse_vmstat(f_vmstat.result()),
    'local_disk_io':      parse_iostat(f_iostat.result()),
    'nfs_io':             parse_nfsiostat(f_nfsiostat.result()),
    'nfs_mountstats':     parse_mountstats(),
    'nfs_rpc':            parse_nfs_rpc(),
    'network_io':         parse_sar_dev(f_sar.result()),
    'socket_summary':     parse_ss(ss_out),
    'd_state_procs':      parse_d_state_procs(ps_dstate_out),
    'per_user_resources': parse_per_user(ps_user_out, top_n),
    'top_cpu_processes':  parse_ps(ps_cpu_out, top_n),
    'top_rss_processes':  parse_ps(ps_rss_out, top_n),
    'top_io_processes':   parse_pidstat(f_pidstat.result(), top_n),
    'system_fds':         parse_fds(fds_out),
}

print(json.dumps(snapshot))
