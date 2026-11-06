#!/usr/bin/env python3
"""Rewrite GNU-as divided Thumb syntax that LLVM's assembler rejects.

usage: fix_gas_thumb.py in.s out.s

- In .thumb regions, low-register data-processing instructions without an
  "s" suffix (mov r0, #1 / lsr r1, r5, #1 / orr r1, r5 ...) are the
  flag-setting forms in divided syntax; add the suffix.
- "ldr rX, =#imm" becomes "ldr rX, =imm".
- "ldm.. rN!, {..}^" without the PC (writeback with user registers, which
  LLVM refuses) is emitted as a .word.
"""
import re
import sys

OPS = "mov|add|sub|lsl|lsr|asr|ror|and|orr|eor|bic|mvn|neg|adc|sbc|mul"
LOW = re.compile(r"\br([0-7])\b")
REG = re.compile(r"\b(r\d+|sp|lr|pc)\b")


def low_only(operands):
    regs = REG.findall(operands)
    return regs and all(LOW.fullmatch(r) for r in regs)


def ldm_word(mn, rn, regs):
    mode = {"ia": (0, 1), "ib": (1, 1), "da": (0, 0), "db": (1, 0), "": (0, 1)}[mn]
    names = {"sp": 13, "lr": 14, "pc": 15}

    def num(r):
        return names[r] if r in names else int(r[1:])

    mask = 0
    for part in regs.split(","):
        part = part.strip()
        if "-" in part:
            a, b = (num(x.strip()) for x in part.split("-"))
            for i in range(a, b + 1):
                mask |= 1 << i
        else:
            mask |= 1 << num(part)
    p, u = mode
    return 0xE8000000 | p << 24 | u << 23 | 1 << 22 | 1 << 21 | 1 << 20 | int(rn) << 16 | mask


def main():
    src, dst = sys.argv[1:3]
    thumb = False
    out = []
    for line in open(src):
        code = line.split("@", 1)[0]
        if re.match(r"\s*\.thumb\b", code):
            thumb = True
        elif re.match(r"\s*\.arm\b", code):
            thumb = False
        line = re.sub(r"=\s*#", "=", line)
        m = re.match(r"(\s*)ldm(ia|ib|da|db|)\s+r(\d+)!\s*,\s*\{([^}]*)\}\s*\^", code)
        if m and "pc" not in m.group(4) and "r15" not in m.group(4):
            out.append(f"{m.group(1)}.word 0x{ldm_word(m.group(2), m.group(3), m.group(4)):08X} @ {line.strip()}\n")
            continue
        if thumb:
            m = re.match(rf"(\s*)({OPS})(\s+)(.*)$", code)
            if m and low_only(m.group(4)):
                rest = line[len(m.group(1)) + len(m.group(2)):]
                line = f"{m.group(1)}{m.group(2)}s{rest}"
        out.append(line)
    open(dst, "w").writelines(out)


if __name__ == "__main__":
    main()
