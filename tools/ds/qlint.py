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
Exit 1 if anything is flagged.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
files = [Path(a) for a in sys.argv[1:]] or [p for p in (ROOT / 'rtl').rglob('*.sv') if 'study' not in p.parts]
KEYWORDS = {'if', 'for', 'while', 'case', 'casez', 'casex', 'foreach', 'repeat', 'return', 'assert'}


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


bad = 0
for f in files:
    source = f.read_text(errors='replace')
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
