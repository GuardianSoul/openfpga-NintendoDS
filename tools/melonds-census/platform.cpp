// Minimal headless implementation of melonDS's Platform interface.

#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>

#include "Platform.h"
#include "SPI_Firmware.h"

namespace melonDS::Platform
{

std::string SavePath;          // set by the census frontend
int MinLogLevel = Warn;

void SignalStop(StopReason, void*) {}

FileHandle* OpenFile(const std::string& path, FileMode mode)
{
    const char* m;
    if (mode & Append)
        m = (mode & Read) ? "a+b" : "ab";
    else if ((mode & Read) && (mode & Write))
    {
        if (mode & Preserve)
        {
            FILE* f = fopen(path.c_str(), "r+b");
            if (f || (mode & NoCreate)) return (FileHandle*)f;
            m = "w+b";
        }
        else
            m = "w+b";
    }
    else if (mode & Write)
        m = "wb";
    else
        m = "rb";
    return (FileHandle*)fopen(path.c_str(), m);
}

std::string GetLocalFilePath(const std::string& filename) { return filename; }
FileHandle* OpenLocalFile(const std::string& path, FileMode mode) { return OpenFile(path, mode); }

bool FileExists(const std::string& name)
{
    FILE* f = fopen(name.c_str(), "rb");
    if (!f) return false;
    fclose(f);
    return true;
}
bool LocalFileExists(const std::string& name) { return FileExists(name); }
bool CheckFileWritable(const std::string&) { return true; }
bool CheckLocalFileWritable(const std::string&) { return true; }

bool CloseFile(FileHandle* file) { return fclose((FILE*)file) == 0; }
bool IsEndOfFile(FileHandle* file) { return feof((FILE*)file) != 0; }
bool FileReadLine(char* str, int count, FileHandle* file) { return fgets(str, count, (FILE*)file) != nullptr; }

bool FileSeek(FileHandle* file, s64 offset, FileSeekOrigin origin)
{
    int o = origin == FileSeekOrigin::Start ? SEEK_SET : origin == FileSeekOrigin::Current ? SEEK_CUR : SEEK_END;
    return fseek((FILE*)file, offset, o) == 0;
}
void FileRewind(FileHandle* file) { rewind((FILE*)file); }
u64 FileRead(void* data, u64 size, u64 count, FileHandle* file) { return fread(data, size, count, (FILE*)file); }
bool FileFlush(FileHandle* file) { return fflush((FILE*)file) == 0; }
u64 FileWrite(const void* data, u64 size, u64 count, FileHandle* file) { return fwrite(data, size, count, (FILE*)file); }

u64 FileWriteFormatted(FileHandle* file, const char* fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    u64 n = vfprintf((FILE*)file, fmt, args);
    va_end(args);
    return n;
}

u64 FileLength(FileHandle* file)
{
    FILE* f = (FILE*)file;
    long pos = ftell(f);
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, pos, SEEK_SET);
    return len;
}

void Log(LogLevel level, const char* fmt, ...)
{
    if (level < MinLogLevel) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
}

struct Thread { std::thread t; };
Thread* Thread_Create(std::function<void()> func) { return new Thread{std::thread(std::move(func))}; }
void Thread_Free(Thread* thread) { if (thread->t.joinable()) thread->t.detach(); delete thread; }
void Thread_Wait(Thread* thread) { if (thread->t.joinable()) thread->t.join(); }

struct Semaphore
{
    std::mutex m;
    std::condition_variable cv;
    int count = 0;
};
Semaphore* Semaphore_Create() { return new Semaphore; }
void Semaphore_Free(Semaphore* s) { delete s; }
void Semaphore_Reset(Semaphore* s) { std::lock_guard l(s->m); s->count = 0; }
void Semaphore_Wait(Semaphore* s)
{
    std::unique_lock l(s->m);
    s->cv.wait(l, [s] { return s->count > 0; });
    s->count--;
}
bool Semaphore_TryWait(Semaphore* s, int timeout_ms)
{
    std::unique_lock l(s->m);
    if (!s->cv.wait_for(l, std::chrono::milliseconds(timeout_ms), [s] { return s->count > 0; }))
        return false;
    s->count--;
    return true;
}
void Semaphore_Post(Semaphore* s, int count)
{
    { std::lock_guard l(s->m); s->count += count; }
    s->cv.notify_all();
}

struct Mutex { std::mutex m; };
Mutex* Mutex_Create() { return new Mutex; }
void Mutex_Free(Mutex* m) { delete m; }
void Mutex_Lock(Mutex* m) { m->m.lock(); }
void Mutex_Unlock(Mutex* m) { m->m.unlock(); }
bool Mutex_TryLock(Mutex* m) { return m->m.try_lock(); }

void Sleep(u64 usecs) { std::this_thread::sleep_for(std::chrono::microseconds(usecs)); }

u64 GetMSCount()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
u64 GetUSCount()
{
    return std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

void WriteNDSSave(const u8* savedata, u32 savelen, u32, u32, void*)
{
    if (SavePath.empty()) return;
    if (FILE* f = fopen(SavePath.c_str(), "wb"))
    {
        fwrite(savedata, 1, savelen, f);
        fclose(f);
    }
}
void WriteGBASave(const u8*, u32, u32, u32, void*) {}
void WriteFirmware(const Firmware&, u32, u32, void*) {}
void WriteDateTime(int, int, int, int, int, int, void*) {}

void MP_Begin(void*) {}
void MP_End(void*) {}
int MP_SendPacket(u8*, int, u64, void*) { return 0; }
int MP_RecvPacket(u8*, u64*, void*) { return 0; }
int MP_SendCmd(u8*, int, u64, void*) { return 0; }
int MP_SendReply(u8*, int, u64, u16, void*) { return 0; }
int MP_SendAck(u8*, int, u64, void*) { return 0; }
int MP_RecvHostPacket(u8*, u64*, void*) { return 0; }
u16 MP_RecvReplies(u8*, u64, u16, void*) { return 0; }
int Net_SendPacket(u8*, int, void*) { return 0; }
int Net_RecvPacket(u8*, void*) { return 0; }

void Camera_Start(int, void*) {}
void Camera_Stop(int, void*) {}
void Camera_CaptureFrame(int, u32*, int, int, bool, void*) {}
void Mic_Start(void*) {}
void Mic_Stop(void*) {}
int Mic_ReadInput(s16*, int, void*) { return 0; }

AACDecoder* AAC_Init() { return nullptr; }
void AAC_DeInit(AACDecoder*) {}
bool AAC_Configure(AACDecoder*, int, int) { return false; }
bool AAC_DecodeFrame(AACDecoder*, const void*, int, void*, int) { return false; }

bool Addon_KeyDown(KeyType, void*) { return false; }
void Addon_RumbleStart(u32, void*) {}
void Addon_RumbleStop(void*) {}
float Addon_MotionQuery(MotionQueryType, void*) { return 0.f; }

DynamicLibrary* DynamicLibrary_Load(const char*) { return nullptr; }
void DynamicLibrary_Unload(DynamicLibrary*) {}
void* DynamicLibrary_LoadFunction(DynamicLibrary*, const char*) { return nullptr; }

}
