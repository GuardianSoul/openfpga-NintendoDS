// Census 2D dump reader (format in state2d.h; writer in
// tools/melonds-census/census.cpp, --gpu2d-*).
#include "state2d.h"

namespace g2d
{
bool load_dump(const std::string& path, std::vector<Segment>& out)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    char magic[8];
    if (fread(magic, 1, 8, f) != 8 || memcmp(magic, "G2DDUMP1", 8)) { fclose(f); return false; }
    Segment* seg = nullptr;
    std::vector<Chunk> pending;
    bool ok = true;
    for (;;)
    {
        int t = fgetc(f);
        if (t == EOF) break;
        if (t == 'S')
        {
            u32 n; ok = fread(&n, 4, 1, f) == 1;
            std::string name(n, ' ');
            ok = ok && fread(name.data(), 1, n, f) == n;
            out.push_back(Segment());
            seg = &out.back();
            seg->name = name;
            seg->mem0 = std::make_shared<Mem>();
            memset(seg->mem0.get(), 0, sizeof(Mem));
            pending.clear();
        }
        else if (t == 'C' && seg)
        {
            Chunk c; u32 len;
            ok = fread(&c.off, 4, 1, f) == 1 && fread(&len, 4, 1, f) == 1 && c.off + len <= sizeof(Mem);
            c.data.resize(len);
            ok = ok && fread(c.data.data(), 1, len, f) == len;
            if (seg->steps.empty()) memcpy((u8*)seg->mem0.get() + c.off, c.data.data(), len);
            else pending.push_back(std::move(c));
        }
        else if (t == 'L' && seg)
        {
            Step s;
            ok = fread(&s.st, sizeof(LineState), 1, f) == 1;
            s.mem = std::move(pending);
            pending.clear();
            seg->steps.push_back(std::move(s));
        }
        else if (t == 'R' && seg && !seg->steps.empty())
        {
            ok = fread(seg->steps.back().ref, sizeof(seg->steps.back().ref), 1, f) == 1;
            seg->steps.back().have_ref = true;
        }
        else ok = false;
        if (!ok) break;
    }
    fclose(f);
    return ok;
}
}
