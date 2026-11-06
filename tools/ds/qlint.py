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


bad = 0
for f in files:
    source = f.read_text(errors='replace')
    for n, message in generate_loop_errors(source):
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
