/* Hardware-free ARM64 loader smoke test. Uses the stable OrtApiBase ABI only. */
#include <dlfcn.h>
#include <stdio.h>
typedef struct {
    const void *(*GetApi)(unsigned int);
    const char *(*GetVersionString)(void);
} OrtApiBase;
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fprintf(stderr, "%s\n", dlerror()); return 3; }
    const OrtApiBase *(*base)(void) = dlsym(lib, "OrtGetApiBase");
    if (!base || !base()->GetApi(23)) return 4;
    printf("ONNX Runtime %s; C API 23 available\n", base()->GetVersionString());
    dlclose(lib);
    return 0;
}
