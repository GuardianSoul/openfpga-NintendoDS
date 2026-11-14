#!/usr/bin/env python3
"""Quartus Standard syntax pitfalls that Verilator accepts (nds-fit #269).

    tools/ds/qlint.py [files...]     default: rtl/**/*.sv except rtl/*/study

Flags a `for (genvar ...)` loop: Quartus Standard rejects a module-level for
loop with an inline genvar ("expecting endmodule"); write `genvar k;` and the
loop inside `generate ... endgenerate`. Also flags (nds-fit #350):
- a named `if (...) begin : name` outside `generate`: Quartus Standard
  wants module-level if-generate blocks inside `generate ... endgenerate`;
- a function call's result indexed directly, `f(x)[3]`: Quartus rejects it
  ("expecting )"); index a local copy instead.
- a `localparam` in a module's parameter port list `#(...)`: Quartus Standard
  rejects it (nds-fit #718, "localparam is a reserved keyword"); declare it in
  the module body and write the expression into the port widths.
- a simulation system task ($test$plusargs, $value$plusargs, $display,
  $fopen, $fwrite, $fdisplay) that Quartus reads: Quartus rejects
  $test$plusargs (fits #560/#561), and the builds define no SYNTHESIS, so
  `ifndef SYNTHESIS does not hide it. Put it under `ifndef ALTERA_RESERVED_QIS
  (or synthesis translate_off/on); an `ifdef of a simulation macro (G3D_EQ)
  also hides it.
- genvar-controlled loops without explicit generate/endgenerate, or without
  a named begin/end body (nds-fit #1162/#1163). Procedural int loops are legal.
- a member of a module-level struct variable read before the variable's
  declaration, `eu.wfi` above `uop_t eu;` (nds-fit #1867, Error 10733 "wfi is
  not declared under this prefix"): Verilator accepts it, Quartus does not.
  Declare the variable above its first use. (Quartus does take plain forward
  references to signals and localparams, so those are not flagged.)
- an implicit `.name` (or `.*`) port connection whose port and parent signal
  widths differ (nds-fit #2076, Error 10897 "can't implicitly connect port
  ... does not have an equivalent data type"): Verilator only pads the width.
  Checked across the given files (all of rtl/ by default) where both widths
  evaluate from literal or parameter-default bounds; connect such a port
  explicitly or fix the width.
Exit 1 if anything is flagged.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
files = [Path(a) for a in sys.argv[1:]] or [p for p in (ROOT / 'rtl').rglob('*.sv') if 'study' not in p.parts]
KEYWORDS = {'if', 'for', 'while', 'case', 'casez', 'casex', 'foreach', 'repeat', 'return', 'assert'}


def module_header_import_errors(source):
    """Catch the observed Standard rejection, without limiting body imports."""
    source = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"',
                    lambda m: re.sub(r'[^\n]', ' ', m[0]), source, flags=re.S)
    for match in re.finditer(r'\bmodule\s+(?:(?:automatic|static)\s+)?\w+\s*'
                             r'(?P<imports>(?:import\s+[^;]+;\s*)+)', source):
        imports = list(re.finditer(r'\bimport\b', match['imports']))
        if len(imports) > 1:
            pos = match.start('imports') + imports[1].start()
            yield source.count('\n', 0, pos) + 1, 'second module-header import (Quartus Standard Error 10170; move body-only imports into the module body)'


def generate_loop_errors(source):
    """Check declared-genvar loops, independent of indentation/header wrapping.

    This is a check for known Standard pitfalls, not a SystemVerilog parser.
    Keep offsets while hiding comments/strings so diagnostics retain line numbers.
    """
    source = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"',
                    lambda m: re.sub(r'[^\n]', ' ', m[0]), source, flags=re.S)
    tokens = re.compile(r'\b(module|endmodule|generate|endgenerate)\b|'
                        r'\bgenvar\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*;|'
                        r'\bfor\s*\(')
    names = set()
    depth = 0
    for match in tokens.finditer(source):
        word = match[1]
        if word in ('module', 'endmodule'):
            names.clear()
            depth = 0
        elif word == 'generate':
            depth += 1
        elif word == 'endgenerate':
            depth -= 1
        elif match[2]:
            names.update(re.findall(r'[A-Za-z_]\w*', match[2]))
        else:
            start = match.end()
            var = re.match(r'\s*([A-Za-z_]\w*)\s*=', source[start:])
            if not var or var[1] not in names:
                continue  # int-declared procedural loop; inline genvar checked below
            nesting, end = 1, start
            while end < len(source) and nesting:
                nesting += (source[end] == '(') - (source[end] == ')')
                end += 1
            line = source.count('\n', 0, match.start()) + 1
            if depth <= 0:
                yield line, 'genvar loop outside generate/endgenerate (Quartus Standard rejects it)'
            if not re.match(r'\s*begin\s*:\s*[A-Za-z_]\w*', source[end:]):
                yield line, 'genvar loop needs a named begin/end body (Quartus Standard rejects it)'


DECL_TYPES = {'logic', 'wire', 'reg', 'bit', 'int', 'integer', 'byte', 'shortint', 'longint',
              'genvar', 'localparam', 'parameter', 'real'}
SCOPE_OPEN = {'begin', 'function', 'task', 'fork'}
SCOPE_CLOSE = {'end', 'endfunction', 'endtask', 'join', 'join_any', 'join_none'}


def use_before_decl_errors(source):
    """Module-level names used before their declaration (Quartus Error 10733).

    A token scan, not a parser: comments, strings and code Quartus skips
    (`ifndef ALTERA_RESERVED_QIS, translate_off) are blanked; typedef bodies are
    skipped; a declaration is a type keyword (or a typedef name) at the start of
    a statement, its names those followed by , ; = or [ at bracket depth 0.
    """
    blank = lambda m: re.sub(r'[^\n]', ' ', m[0])
    src = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', blank, source, flags=re.S)
    src = re.sub(r'synthesis\s+translate_off.*?synthesis\s+translate_on', blank, src, flags=re.S)
    # `ifndef ALTERA_RESERVED_QIS ... matching `endif / `else
    out, i = [], 0
    for m in re.finditer(r'`ifndef\s+ALTERA_RESERVED_QIS\b', src):
        if m.start() < i:
            continue
        depth, j = 1, m.end()
        for t in re.finditer(r'`(ifdef|ifndef|else|endif)\b', src[m.end():]):
            k = t.group(1)
            if k in ('ifdef', 'ifndef'): depth += 1
            elif k == 'endif': depth -= 1
            elif k == 'else' and depth == 1: depth = 0
            if depth == 0:
                j = m.end() + t.start(); break
        out.append(src[i:m.start()]); out.append(re.sub(r'[^\n]', ' ', src[m.start():j])); i = j
    out.append(src[i:]); src = ''.join(out)
    toks = [(t[0], t.start()) for t in re.finditer(r'[A-Za-z_][\w$]*|\S', src)]
    types = set(DECL_TYPES)
    for t in re.finditer(r'\btypedef\b.*?\}\s*([A-Za-z_]\w*)\s*;|\btypedef\b[^;{]*?\b([A-Za-z_]\w*)\s*;', src, flags=re.S):
        types.add(t[1] or t[2])

    def decls(start):
        """names declared by the statement starting at toks[start] (a type), and the index after it"""
        names, k, depth = [], start + 1, 0
        while k < len(toks) and toks[k][0] != ';':
            w = toks[k][0]
            if w in '([{': depth += 1
            elif w in ')]}': depth -= 1
            elif depth == 0 and re.match(r'[A-Za-z_]', w) and k + 1 < len(toks) and toks[k + 1][0] in ',;=[' \
                    and toks[k - 1][0] not in ('=',) and w not in types:
                names.append((w, toks[k][1]))
            if depth == 0 and w == '=':          # skip the initializer up to , or ;
                d2 = 0
                while k + 1 < len(toks) and not (d2 == 0 and toks[k + 1][0] in ',;'):
                    k += 1
                    d2 += toks[k][0] in '([{'
                    d2 -= toks[k][0] in ')]}'
            k += 1
        return names, k

    def skip_typedef(k):
        d = 0
        while k < len(toks) and not (toks[k][0] == ';' and d == 0):
            d += toks[k][0] == '{'
            d -= toks[k][0] == '}'
            k += 1
        return k + 1

    # pass 1: module-scope declarations (position of the first; -1: the module header)
    first = {}
    scope = 0
    stmt_start = True
    k = 0
    while k < len(toks):
        w, pos = toks[k]
        if w == 'module':
            scope = 0
        if w in SCOPE_OPEN: scope += 1
        elif w in SCOPE_CLOSE: scope -= 1
        if w == 'typedef':                  # skip to the typedef's ; (past its { } body)
            k = skip_typedef(k); stmt_start = True; continue
        if w == 'module':                   # ports and parameters of the header: declared first
            k2, d = k + 1, 0
            while k2 < len(toks) and not (toks[k2][0] == ';' and d == 0):
                d += toks[k2][0] in '(['
                d -= toks[k2][0] in ')]'
                if re.match(r'[A-Za-z_]', toks[k2][0]) and k2 + 1 < len(toks) and toks[k2 + 1][0] in ',)=[':
                    first.setdefault(toks[k2][0], -1)
                k2 += 1
            k = k2 + 1; stmt_start = True; continue
        if stmt_start and scope == 0 and w in types:
            names, k2 = decls(k)
            for n, p in names:
                first.setdefault(n, p)
            k = k2; stmt_start = True; k += 1; continue
        stmt_start = w in (';', 'begin', 'end', ')') or w in ('endfunction', 'endtask', 'endcase', 'generate', 'endgenerate') or (w == ':' and False)
        k += 1
    if not first:
        return
    # pass 2: uses of those names before their declaration, outside a scope that declares them locally
    stack = [set()]
    reported = set()
    stmt_start = True
    k = 0
    while k < len(toks):
        w, pos = toks[k]
        if w == 'typedef':
            k = skip_typedef(k); stmt_start = True; continue
        if w in SCOPE_OPEN:
            stack.append(set())
            if w in ('function', 'task'):    # the header's names are local
                k2 = k
                while k2 < len(toks) and toks[k2][0] != ';':
                    if re.match(r'[A-Za-z_]', toks[k2][0]): stack[-1].add(toks[k2][0])
                    k2 += 1
                k = k2 + 1; stmt_start = True; continue
        elif w in SCOPE_CLOSE and len(stack) > 1:
            stack.pop()
        if stmt_start and w in types and (len(stack) > 1 or pos in {p for p in first.values()}):
            names, k2 = decls(k)
            if len(stack) > 1:
                stack[-1].update(n for n, _ in names)
                # initializers inside are uses too, but rare: skip the statement
                k = k2 + 1; stmt_start = True; continue
            k = k2 + 1; stmt_start = True; continue
        if w == '(' and k + 1 < len(toks) and toks[k + 1][0] in types:   # for (int i = ...)
            stack[-1].add(toks[k + 2][0] if k + 2 < len(toks) else '')
        if w in first and pos < first[w] and w not in reported and not any(w in s for s in stack[1:]) \
                and toks[k - 1][0] not in ('.', '`', '$', "'") and k + 1 < len(toks) and toks[k + 1][0] == '.':
            reported.add(w)
            yield src.count('\n', 0, pos) + 1, f'{w}.<member> before {w} is declared (line {src.count(chr(10), 0, first[w]) + 1}; Quartus Error 10733)'
        stmt_start = w in (';', 'begin', 'end', ')', 'endfunction', 'endtask', 'endcase', 'generate', 'endgenerate')
        k += 1


# ---- implicit .name / .* connections against the child's port width (across files)
def strip(src):
    src = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), src, flags=re.S)
    return re.sub(r'//[^\n]*', '', src)
def ev(expr, env):
    e = expr.strip()
    for _ in range(8):
        e2 = re.sub(r"\b([A-Za-z_]\w*)\b", lambda m: str(env[m.group(1)]) if m.group(1) in env else m.group(0), e)
        if e2 == e: break
        e = e2
    e = re.sub(r"\d+'[sS]?[dD](\d+)", r'\1', e)
    if not re.fullmatch(r'[\d\s+\-*/()%<>]+', e): return None
    try: return int(eval(e.replace('/', '//')))
    except Exception: return None
def width(rng, env):
    if not rng: return 1
    m = re.fullmatch(r'\[\s*(.+?)\s*:\s*(.+?)\s*\]', rng.strip())
    if not m: return None
    a, b = ev(m.group(1), env), ev(m.group(2), env)
    return None if a is None or b is None else abs(a - b) + 1
DECL = r'(?:input|output|inout)?\s*(?:wire|logic|reg|bit)?\s*(?:signed|unsigned)?\s*(\[[^\]]+\])?\s*'
def params(body):
    env = {}
    for m in re.finditer(r'\b(?:parameter|localparam)\s+(?:int\s+unsigned\s+|int\s+|integer\s+|bit\s+|logic\s+)?(?:\[[^\]]*\]\s*)?(\w+)\s*=\s*([^,;)]+)', body):
        v = ev(m.group(2), env)
        if v is not None: env[m.group(1)] = v
    return env
def modules(src):
    out = {}
    for m in re.finditer(r'\bmodule\s+(\w+)(.*?)\bendmodule\b', src, flags=re.S):
        name, body = m.group(1), m.group(2)
        hdr_end = body.find(');')
        out[name] = (body, hdr_end)
    return out
def port_widths(body, hdr_end):
    env = params(body)
    hdr = body[:hdr_end + 1]
    pw = {}
    for m in re.finditer(r'\b(input|output|inout)\b\s*(?:wire|logic|reg|bit)?\s*(?:signed|unsigned)?\s*(\[[^\]]+\])?\s*((?:\w+\s*,\s*(?!(?:input|output|inout)\b))*\w+)', hdr):
        for n in re.split(r'\s*,\s*', m.group(3)):
            if n in ('input', 'output', 'inout', 'wire', 'logic', 'reg'): continue
            pw[n] = (m.group(2), env)
    return pw
def sig_widths(body):
    env = params(body)
    sw = {}
    for m in re.finditer(r'(?:^|[;\n(,])\s*(?:input|output|inout)?\s*(?:wire|logic|reg|bit)\s*(?:signed|unsigned)?\s*(\[[^\]]+\])?\s*((?:\w+\s*(?:\[[^\]]*\]\s*)*(?:=[^,;]*)?,\s*)*\w+)', body):
        for n in re.split(r'\s*,\s*', m.group(2)):
            n = re.match(r'\w+', n).group(0)
            sw.setdefault(n, (m.group(1), env))
    return sw
def implicit_port_errors(files):
    mods, srcs = {}, {}
    for f in files:
        s = strip(f.read_text(errors='replace')); srcs[f] = s
        for k, v in modules(s).items(): mods[k] = v
    ports = {k: port_widths(*v) for k, v in mods.items()}
    for f, s in srcs.items():
        for mname, (body, _) in modules(s).items():
            sigs = sig_widths(body)
            for im in re.finditer(r'\b(\w+)\s*(#\s*\()?', body):
                child = im.group(1)
                if child not in ports or child == mname: continue
                k = im.end()
                if im.group(2):         # skip the parameter list
                    d = 1
                    while k < len(body) and d: d += {'(': 1, ')': -1}.get(body[k], 0); k += 1
                    overr = True
                else: overr = False
                m2 = re.match(r'\s*(\w+)\s*(\[[^\]]*\])?\s*\(', body[k:])
                if not m2: continue
                k += m2.end(); st = k; d = 1
                while k < len(body) and d: d += {'(': 1, ')': -1}.get(body[k], 0); k += 1
                conns = body[st:k - 1]
                names = set(re.findall(r'\.(\w+)\s*(?=[,)]|$)', conns + ')'))
                if re.search(r'\.\*', conns):
                    explicit = set(re.findall(r'\.(\w+)\s*\(', conns))
                    names |= {p for p in ports[child] if p not in explicit and p in sigs}
                for n in sorted(names):
                    if n not in ports[child] or n not in sigs: continue
                    prng, penv = ports[child][n]
                    if overr and prng and re.search(r'[A-Za-z_]', prng): continue   # the instance may override that width
                    wp, ws = width(prng, penv), width(sigs[n][0], sigs[n][1])
                    if wp is not None and ws is not None and wp != ws:
                        ln = s.count('\n', 0, s.find(body)) + body.count('\n', 0, st) + 1
                        yield f, ln, f'implicit .{n} on {child} {m2.group(1)}: port {wp} bits, {mname}\'s {n} {ws} bits (Quartus Error 10897)'


bad = 0
for f, n, message in implicit_port_errors(files):
    print(f'{f}:{n}: {message}')
    bad += 1
for f in files:
    source = f.read_text(errors='replace')
    for n, message in module_header_import_errors(source):
        print(f'{f}:{n}: {message}')
        bad += 1
    for n, message in generate_loop_errors(source):
        print(f'{f}:{n}: {message}')
        bad += 1
    for n, message in use_before_decl_errors(source):
        print(f'{f}:{n}: {message}')
        bad += 1
    gen = 0
    hidden = 0      # inside `ifndef ALTERA_RESERVED_QIS (Quartus does not read it)
    sim = []        # open `ifdef/`ifndef/`else: True where Quartus skips the code
    tr = False      # inside synthesis translate_off
    plist = False   # inside a module's parameter port list
    for n, line in enumerate(source.splitlines(), 1):
        if re.search(r'synthesis\s+translate_off', line): tr = True
        if re.search(r'synthesis\s+translate_on', line): tr = False
        code = line.split('//')[0]
        m = re.match(r'\s*`(ifdef|ifndef)\s+(\w+)', code)
        if m: sim.append(m.group(1) == 'ifdef' or m.group(2) == 'ALTERA_RESERVED_QIS')
        elif re.match(r'\s*`else', code) and sim: sim[-1] = not sim[-1]
        elif re.match(r'\s*`endif', code) and sim: sim.pop()
        elif not tr and not any(sim) and re.search(r'\$(test\$plusargs|value\$plusargs|display|fopen|fwrite|fdisplay)\b', code):
            print(f'{f}:{n}: simulation system task Quartus reads (put it under `ifndef ALTERA_RESERVED_QIS)')
            bad += 1
        if re.match(r'\s*`ifndef\s+ALTERA_RESERVED_QIS', code): hidden += 1; continue
        if hidden and re.match(r'\s*`ifn?def', code): hidden += 1; continue
        if hidden and re.match(r'\s*`endif', code): hidden -= 1; continue
        if hidden: continue
        gen += len(re.findall(r'\bgenerate\b', code)) - len(re.findall(r'\bendgenerate\b', code))
        if re.match(r'\s*module\b.*#\s*\(', code) or (re.match(r'\s*#\s*\(', code) and not plist): plist = True
        if plist and re.match(r'\s*localparam\b', code):
            print(f'{f}:{n}: localparam in a parameter port list (Quartus Standard rejects it)')
            bad += 1
        if plist and re.match(r'\s*\)\s*(\(|;)', code): plist = False
        if re.search(r'\bfor\s*\(\s*genvar\b', code):
            print(f'{f}:{n}: for loop with an inline genvar (Quartus Standard rejects it)')
            bad += 1
        # (module level: this code base indents module items by four spaces)
        if gen <= 0 and re.match(r' {0,4}(end\s+else\s+)?if\s*\(.*\)\s*begin\s*:\s*\w+', code) and 'generate' not in code:
            print(f'{f}:{n}: named if-generate block outside generate/endgenerate (Quartus Standard rejects it)')
            bad += 1
        for m in re.finditer(r'\b([A-Za-z_]\w*)\s*\(([^()]|\([^()]*\))*\)\s*\[', code):
            if m.group(1) not in KEYWORDS:
                print(f'{f}:{n}: indexed function result {m.group(1)}(...)[...] (Quartus rejects it)')
                bad += 1
sys.exit(1 if bad else 0)
