// Optional testbench-only peer. The simulator waits outside the timed call
// while the same Python collector used for Census validates one RAM packet.
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <poll.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static pid_t gxd_child = -1;
static FILE* gxd_to = nullptr;
static FILE* gxd_from = nullptr;
extern "C" int gxd_close();

static bool gxd_line(char* line, size_t length)
{
    pollfd ready {fileno(gxd_from), POLLIN, 0};
    int result;
    do { result = poll(&ready, 1, 5000); } while (result < 0 && errno == EINTR);
    return result == 1 && (ready.revents & POLLIN) &&
           std::fgets(line, length, gxd_from);
}

extern "C" int gxd_open(const char* helper, const char* cases, const char* output)
{
    if (gxd_child > 0) return -1;
    int to_child[2], from_child[2];
    if (pipe(to_child) || pipe(from_child)) return -1;
    gxd_child = fork();
    if (gxd_child == 0) {
        dup2(to_child[0], STDIN_FILENO);
        dup2(from_child[1], STDOUT_FILENO);
        close(to_child[0]); close(to_child[1]);
        close(from_child[0]); close(from_child[1]);
        execlp("python3", "python3", "-B", helper, "--cases", cases, "--out", output,
               static_cast<char*>(nullptr));
        _exit(127);
    }
    close(to_child[0]); close(from_child[1]);
    if (gxd_child < 0) { close(to_child[1]); close(from_child[0]); return -1; }
    gxd_to = fdopen(to_child[1], "w");
    gxd_from = fdopen(from_child[0], "r");
    if (!gxd_to || !gxd_from) return -1;
    setvbuf(gxd_from, nullptr, _IONBF, 0);
    std::fprintf(stderr, "GXD_COLLECTOR_PID %ld\n", static_cast<long>(gxd_child));
    char ready[64];
    if (!gxd_line(ready, sizeof(ready)) || std::strcmp(ready, "GXD_READY\n")) {
        gxd_close();
        return -1;
    }
    return 1;
}

extern "C" int gxd_submit(const char* packet)
{
    if (!gxd_to || !gxd_from || std::fprintf(gxd_to, "%s\n", packet) < 0 ||
        std::fflush(gxd_to)) return -1;
    char line[64];
    if (!gxd_line(line, sizeof(line))) return -1;
    char* end;
    long sequence = std::strtol(line, &end, 10);
    if (sequence <= 0 || sequence >= 65536 || (*end != '\n' && *end != '\0')) return -1;
    return static_cast<int>(sequence);
}

extern "C" int gxd_close()
{
    if (gxd_to) { std::fclose(gxd_to); gxd_to = nullptr; }
    if (gxd_from) { std::fclose(gxd_from); gxd_from = nullptr; }
    if (gxd_child <= 0) return 0;
    int status = 0;
    for (int i = 0; i < 100; ++i) {
        if (waitpid(gxd_child, &status, WNOHANG) == gxd_child) {
            gxd_child = -1;
            return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
        }
        usleep(10000);
    }
    // This PID was created and retained above; never signal by process name.
    kill(gxd_child, SIGTERM);
    waitpid(gxd_child, &status, 0);
    gxd_child = -1;
    return -1;
}
