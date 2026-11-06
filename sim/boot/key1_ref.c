/* KEY1 secure-area reference (host C), written from GBATEK "DS Encryption by
 * Gamecode/Idcode (KEY1)". It is the model sw/boot/key1.s is checked against.
 *
 * usage: key1_ref ROM.nds BIOS7.bin OUTDIR
 *
 * Writes into OUTDIR, for the ROM's ARM9 secure area (0x800 bytes at the
 * header's ARM9 ROM offset, which must lie in 0x4000..0x7FFF):
 *   enc.bin      the secure area as an encrypted cartridge delivers it. Dumps
 *                that are already decrypted (first word 0xE7FFDEFF, word at
 *                +0x10 not) are re-encrypted the way melonDS does on cart insert:
 *                "encryObj" into the first 8 bytes, level-3 encrypt of all
 *                blocks, then level-2 encrypt of the first block.
 *   enc.exp      the direct-boot result of decrypting enc.bin
 *   raw.bin      the secure area exactly as in the file
 *   raw.exp      the direct-boot result of decrypting raw.bin unchanged
 *   params.txt   "gamecode enc_ret raw_ret" (hex; ret 0 = "encryObj" found)
 *
 * Direct-boot result: KEY1 init at level 2 (modulo 2), decrypt the first block;
 * init at level 3, decrypt all 0x100 blocks; then if the first 8 bytes read
 * "encryObj" replace them with 0xE7FFDEFF twice, else fill the area with it.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define KB_WORDS 0x412          /* 18 P-array words + 4 S-boxes of 256 */

typedef struct {
    uint32_t kb[KB_WORDS];
    uint32_t code[3];
} key1_t;

static uint32_t bswap(uint32_t v)
{
    return (v >> 24) | ((v >> 8) & 0xFF00u) | ((v << 8) & 0xFF0000u) | (v << 24);
}

static uint32_t feistel(const key1_t *k, uint32_t z)
{
    const uint32_t *s = k->kb + 18;
    uint32_t f = s[z >> 24];
    f += s[256 + ((z >> 16) & 0xFF)];
    f ^= s[512 + ((z >> 8) & 0xFF)];
    f += s[768 + (z & 0xFF)];
    return f;
}

/* blk[0] is the low word of the 64-bit block, blk[1] the high word */
static void key1_encrypt(const key1_t *k, uint32_t *blk)
{
    uint32_t lo = blk[0], hi = blk[1];
    for (int r = 0; r < 16; r++) {
        uint32_t z = k->kb[r] ^ hi;
        hi = feistel(k, z) ^ lo;
        lo = z;
    }
    blk[0] = hi ^ k->kb[16];
    blk[1] = lo ^ k->kb[17];
}

static void key1_decrypt(const key1_t *k, uint32_t *blk)
{
    uint32_t lo = blk[0], hi = blk[1];
    for (int r = 17; r >= 2; r--) {
        uint32_t z = k->kb[r] ^ hi;
        hi = feistel(k, z) ^ lo;
        lo = z;
    }
    blk[0] = hi ^ k->kb[1];
    blk[1] = lo ^ k->kb[0];
}

static void apply_keycode(key1_t *k, int modulo)
{
    uint32_t scratch[2] = {0, 0};
    key1_encrypt(k, &k->code[1]);
    key1_encrypt(k, &k->code[0]);
    for (int i = 0; i < 18; i++)
        k->kb[i] ^= bswap(k->code[i % modulo]);
    for (int i = 0; i < KB_WORDS; i += 2) {
        key1_encrypt(k, scratch);
        k->kb[i] = scratch[1];
        k->kb[i + 1] = scratch[0];
    }
}

static void init_keycode(key1_t *k, const uint8_t *table, uint32_t id, int level, int modulo)
{
    memcpy(k->kb, table, sizeof k->kb);
    k->code[0] = id;
    k->code[1] = id >> 1;
    k->code[2] = id << 1;
    if (level >= 1) apply_keycode(k, modulo);
    if (level >= 2) apply_keycode(k, modulo);
    k->code[1] <<= 1;
    k->code[2] >>= 1;
    if (level >= 3) apply_keycode(k, modulo);
}

static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static void wr32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

static void crypt_block(const key1_t *k, uint8_t *p, int enc)
{
    uint32_t b[2] = {rd32(p), rd32(p + 4)};
    if (enc) key1_encrypt(k, b); else key1_decrypt(k, b);
    wr32(p, b[0]);
    wr32(p + 4, b[1]);
}

/* the direct-boot decryption; returns 0 if "encryObj" was found */
static int secure_area_decrypt(uint8_t *a, uint32_t gamecode, const uint8_t *table)
{
    static key1_t k;
    init_keycode(&k, table, gamecode, 2, 2);
    crypt_block(&k, a, 0);
    init_keycode(&k, table, gamecode, 3, 2);
    for (int i = 0; i < 0x800; i += 8)
        crypt_block(&k, a + i, 0);
    if (memcmp(a, "encryObj", 8) == 0) {
        wr32(a, 0xE7FFDEFFu);
        wr32(a + 4, 0xE7FFDEFFu);
        return 0;
    }
    for (int i = 0; i < 0x800; i += 4)
        wr32(a + i, 0xE7FFDEFFu);
    return 1;
}

static void secure_area_encrypt(uint8_t *a, uint32_t gamecode, const uint8_t *table)
{
    static key1_t k;
    memcpy(a, "encryObj", 8);
    init_keycode(&k, table, gamecode, 3, 2);
    for (int i = 0; i < 0x800; i += 8)
        crypt_block(&k, a + i, 1);
    init_keycode(&k, table, gamecode, 2, 2);
    crypt_block(&k, a, 1);
}

static uint8_t *slurp(const char *path, long *len)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END);
    *len = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *d = malloc(*len);
    if (fread(d, 1, *len, f) != (size_t)*len) { perror(path); exit(1); }
    fclose(f);
    return d;
}

static void spit(const char *dir, const char *name, const void *d, size_t n)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(d, 1, n, f) != n) { perror(path); exit(1); }
    fclose(f);
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s ROM.nds BIOS7.bin OUTDIR\n", argv[0]);
        return 2;
    }
    long rlen, blen;
    uint8_t *rom = slurp(argv[1], &rlen);
    uint8_t *bios = slurp(argv[2], &blen);
    if (rlen < 0x8000 + 0x800 || blen < 0x30 + KB_WORDS * 4) {
        fprintf(stderr, "short ROM or BIOS7\n");
        return 1;
    }
    const uint8_t *table = bios + 0x30;
    uint32_t gamecode = rd32(rom + 0x0C);
    uint32_t off = rd32(rom + 0x20);
    if (off < 0x4000 || off >= 0x8000) {
        fprintf(stderr, "ARM9 ROM offset %#x: no secure area\n", off);
        return 1;
    }

    uint8_t raw[0x800], enc[0x800], out[0x800];
    memcpy(raw, rom + off, 0x800);
    memcpy(enc, raw, 0x800);
    int was_decrypted = rd32(raw) == 0xE7FFDEFFu && rd32(raw + 0x10) != 0xE7FFDEFFu;
    if (was_decrypted)
        secure_area_encrypt(enc, gamecode, table);

    spit(argv[3], "enc.bin", enc, 0x800);
    spit(argv[3], "raw.bin", raw, 0x800);
    memcpy(out, enc, 0x800);
    int enc_ret = secure_area_decrypt(out, gamecode, table);
    spit(argv[3], "enc.exp", out, 0x800);
    if (was_decrypted && (enc_ret != 0 || memcmp(out, raw, 0x800) != 0)) {
        fprintf(stderr, "round trip of the decrypted dump failed\n");
        return 1;
    }
    memcpy(out, raw, 0x800);
    int raw_ret = secure_area_decrypt(out, gamecode, table);
    spit(argv[3], "raw.exp", out, 0x800);

    char p[64];
    int n = snprintf(p, sizeof p, "%08x %x %x\n", gamecode, enc_ret, raw_ret);
    spit(argv[3], "params.txt", p, n);
    printf("gamecode %.4s, ARM9 offset %#x, dump %s, encrypted -> %s, raw -> %s\n",
           (char *)rom + 0x0C, off, was_decrypted ? "decrypted" : "encrypted",
           enc_ret ? "no encryObj" : "encryObj", raw_ret ? "no encryObj" : "encryObj");
    return 0;
}
