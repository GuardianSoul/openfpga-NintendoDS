// SPDX-License-Identifier: GPL-3.0-or-later
// Dumps a ROM's header as melonDS reads it (its NDSHeader struct, which
// NDS::SetupDirectBoot uses for the direct boot), and the FAT entries at
// the header's FATOffset/FATSize, and the game's entry in melonDS's game
// list (ROMList.cpp, linked in), as JSON for tests/check_roms.py.
//   g++ -std=c++17 -I references/melonDS/src melonds_header.cpp references/melonDS/src/ROMList.cpp -o melonds_header
#include <cstdio>
#include <cstring>
#include <vector>
#include "NDS_Header.h"
#include "ROMList.h"
using namespace melonDS;

int main(int argc, char** argv)
{
    if (argc != 2) { fprintf(stderr, "usage: melonds_header ROM\n"); return 2; }
    FILE* f = fopen(argv[1], "rb");
    if (!f) return 1;
    NDSHeader h;
    memset(&h, 0, sizeof(h));
    if (fread(&h, 1, 0x200, f) != 0x200) return 1;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    printf("{\"size\": %ld, \"game_code\": %u, \"header_crc16\": %u,\n", size, h.GameCodeAsU32(), h.HeaderCRC16);
    printf(" \"arm9\": [%u, %u, %u, %u], \"arm7\": [%u, %u, %u, %u],\n",
           h.ARM9ROMOffset, h.ARM9EntryAddress, h.ARM9RAMAddress, h.ARM9Size,
           h.ARM7ROMOffset, h.ARM7EntryAddress, h.ARM7RAMAddress, h.ARM7Size);
    printf(" \"fnt\": [%u, %u], \"fat_at\": [%u, %u], \"fat\": [", h.FNTOffset, h.FNTSize, h.FATOffset, h.FATSize);
    std::vector<u32> fat(h.FATSize / 4);
    fseek(f, h.FATOffset, SEEK_SET);
    size_t n = fread(fat.data(), 4, fat.size(), f);
    for (size_t i = 0; i + 1 < n; i += 2) printf("%s[%u,%u]", i ? "," : "", fat[i], fat[i + 1]);
    long save = -1;  // not listed
    for (size_t i = 0; i < ROMListEntryCount; i++)
        if (ROMList[i].GameCode == h.GameCodeAsU32()) save = ROMList[i].SaveMemType;
    printf("], \"save_mem_type\": %ld}\n", save);
    fclose(f);
    return 0;
}
