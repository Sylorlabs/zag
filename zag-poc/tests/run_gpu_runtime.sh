#!/usr/bin/env bash
# Runtime GPU gate — compiles and (when explicitly opted in) runs Zag-emitted
# kernels against the installed physical GPU/ICD runtimes.
#
# This script tests the actual end-to-end path:
#   Zag source → znc encoder → SPIR-V/GLSL binary → real GPU driver → output verification
#
# Targets available on this machine (AMD RX 5700 XT, Mesa RADV):
#   - vulkan-compat: SPIR-V → Vulkan compute pipeline → fence → readback
#   - opengl-compat: GLSL 430 → EGL context → glDispatchCompute → readback
#
# OpenCL uses the emitted SPIR-V first and the checked-in pure-Zag OpenCL-C
# fallback when the ICD lacks usable IL entry points. The ROCm ICD exposes the
# local RX 5700 XT. CUDA and Metal cannot run here because the required
# hardware/OS is absent.
#   - opencl-compat: ROCm ICD → SPIR-V/source → bounded dispatch/readback
#   - cuda-compat:   No NVIDIA GPU or driver
#   - metal-compat:  Linux, no Metal framework (run tests/run_metal_mac.sh on macOS)
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-gpu-runtime.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
# Never let the advisory planner race the trap while the gate is cleaning its
# temporary project. The wrapper also makes every compiler invocation in this
# gate deterministic when another Zag process is running on the workstation.
cat >"$tmp/znc-no-zagd" <<EOF
#!/usr/bin/env bash
exec "$ZNC" "\$@" --no-zagd
EOF
chmod +x "$tmp/znc-no-zagd"
ZNC="$tmp/znc-no-zagd"
pass=0
fail=0
gpu_timeout_seconds=${ZAG_GPU_TIMEOUT_SECONDS:-30}
case "$gpu_timeout_seconds" in
    ''|*[!0-9]*) echo "Zag GPU Runtime Tests: ZAG_GPU_TIMEOUT_SECONDS must be a positive integer" >&2; exit 2 ;;
esac
if [ "$gpu_timeout_seconds" -lt 1 ]; then
    echo "Zag GPU Runtime Tests: ZAG_GPU_TIMEOUT_SECONDS must be at least 1" >&2
    exit 2
fi

run_physical() {
    if ! command -v timeout >/dev/null 2>&1; then
        echo "physical dispatch refused: GNU timeout is required for the safety boundary" >&2
        return 124
    fi
    timeout --signal=TERM --kill-after=5s "${gpu_timeout_seconds}s" "$@"
}

ok() { echo "  ok  $1"; pass=$((pass + 1)); }
xx() { echo "  XX  $1"; fail=$((fail + 1)); }

# ── Fill kernel source ──────────────────────────────────────────────────────
cat >"$tmp/fill.zag" <<'ZAG'
fn fillKernel(out: []i32, value: i32, count: i32) void @kernel {
    let i: i32 = @gpuBlockIdx(0) * @gpuBlockDim(0) + @gpuThreadIdx(0);
    if (i < count) { out[i] = value; }
}
fn main() void { print_i32(0); }
ZAG

# A tiny pure-Zag dynamic-ABI witness stays in the checked-in test tree; the
# project wrapper is generated in /tmp so the source tree remains pure Zag.
cp "$PWD/tests/gpu_vulkan_probe.zag" "$tmp/gpu_vulkan_probe.zag"
printf 'name = "gpu-vulkan-probe"\nversion = "0"\nedition = "2027"\n' >"$tmp/zag.mod"

# Keep the runtime gate pure-Zag-tree compliant: the small C programs below
# are generated in /tmp, compiled against the installed system loaders, and
# deleted with the rest of the temporary test directory.  They are test
# harnesses only; Zag still owns source parsing and kernel artifact emission.
cat >"$tmp/vulkan_runtime_test.c" <<'C'
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail(const char *where, VkResult r) {
    fprintf(stderr, "VULKAN_RUNTIME_FAIL: %s (%d)\n", where, (int)r);
    return 1;
}
static int read_words(const char *path, uint32_t **out, size_t *words) {
    FILE *f = fopen(path, "rb"); if (!f) return 0;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 0; }
    long n = ftell(f); if (n <= 0 || (n & 3)) { fclose(f); return 0; }
    rewind(f); *words = (size_t)n / 4; *out = malloc((size_t)n);
    if (!*out || fread(*out, 4, *words, f) != *words) { free(*out); *out = NULL; fclose(f); return 0; }
    fclose(f); return 1;
}
int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s shader.spv\n", argv[0]); return 2; }
    uint32_t *code = NULL; size_t words = 0;
    if (!read_words(argv[1], &code, &words)) { fprintf(stderr, "VULKAN_RUNTIME_FAIL: cannot read SPIR-V\n"); return 1; }
    int rc = 1; VkInstance instance = VK_NULL_HANDLE; VkDevice device = VK_NULL_HANDLE;
    VkShaderModule shader = VK_NULL_HANDLE; VkBuffer buffer = VK_NULL_HANDLE; VkDeviceMemory memory = VK_NULL_HANDLE;
    VkDescriptorSetLayout set_layout = VK_NULL_HANDLE; VkPipelineLayout pipeline_layout = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE; VkDescriptorPool pool = VK_NULL_HANDLE; VkCommandPool command_pool = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE; VkFence fence = VK_NULL_HANDLE; VkQueue queue = VK_NULL_HANDLE;
    VkPhysicalDevice physical = VK_NULL_HANDLE; uint32_t queue_family = UINT32_MAX, memory_type = UINT32_MAX;
    VkResult r;
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "zag-runtime", .apiVersion = VK_API_VERSION_1_0 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    r = vkCreateInstance(&ici, NULL, &instance); if (r) { rc = fail("vkCreateInstance", r); goto done; }
    uint32_t device_count = 0; r = vkEnumeratePhysicalDevices(instance, &device_count, NULL);
    if (r || device_count == 0) { rc = fail("vkEnumeratePhysicalDevices", r ? r : VK_ERROR_INITIALIZATION_FAILED); goto done; }
    VkPhysicalDevice *devices = calloc(device_count, sizeof(*devices));
    if (!devices) goto done;
    r = vkEnumeratePhysicalDevices(instance, &device_count, devices); if (r) { free(devices); rc = fail("vkEnumeratePhysicalDevices(list)", r); goto done; }
    for (uint32_t i = 0; i < device_count; i++) {
        VkPhysicalDeviceProperties p; vkGetPhysicalDeviceProperties(devices[i], &p);
        if (p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) { physical = devices[i]; fprintf(stdout, "Physical device: %s\n", p.deviceName); break; }
    }
    if (physical == VK_NULL_HANDLE) { physical = devices[0]; VkPhysicalDeviceProperties p; vkGetPhysicalDeviceProperties(physical, &p); fprintf(stdout, "Physical device: %s\n", p.deviceName); }
    free(devices);
    uint32_t qcount = 0; vkGetPhysicalDeviceQueueFamilyProperties(physical, &qcount, NULL);
    VkQueueFamilyProperties *qprops = calloc(qcount, sizeof(*qprops)); if (!qprops) goto done;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &qcount, qprops);
    for (uint32_t i = 0; i < qcount; i++) if ((qprops[i].queueFlags & VK_QUEUE_COMPUTE_BIT) && qprops[i].queueCount) { queue_family = i; break; }
    free(qprops); if (queue_family == UINT32_MAX) { fprintf(stderr, "VULKAN_RUNTIME_FAIL: no compute queue\n"); goto done; }
    float priority = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = queue_family, .queueCount = 1, .pQueuePriorities = &priority };
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
    r = vkCreateDevice(physical, &dci, NULL, &device); if (r) { rc = fail("vkCreateDevice", r); goto done; }
    vkGetDeviceQueue(device, queue_family, 0, &queue);
    VkShaderModuleCreateInfo smci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = words * 4, .pCode = code };
    r = vkCreateShaderModule(device, &smci, NULL, &shader); if (r) { rc = fail("vkCreateShaderModule", r); goto done; }
    VkDescriptorSetLayoutBinding binding = { .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT };
    VkDescriptorSetLayoutCreateInfo slci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &binding };
    r = vkCreateDescriptorSetLayout(device, &slci, NULL, &set_layout); if (r) { rc = fail("vkCreateDescriptorSetLayout", r); goto done; }
    VkPushConstantRange range = { .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, .offset = 0, .size = 8 };
    VkPipelineLayoutCreateInfo plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &set_layout, .pushConstantRangeCount = 1, .pPushConstantRanges = &range };
    r = vkCreatePipelineLayout(device, &plci, NULL, &pipeline_layout); if (r) { rc = fail("vkCreatePipelineLayout", r); goto done; }
    /* The Vulkan SPIR-V encoder uses the module entry point `main`; the
       source kernel name is retained by the OpenCL/GLSL/Metal encoders. */
    VkPipelineShaderStageCreateInfo stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = shader, .pName = "main" };
    VkComputePipelineCreateInfo cpci = { .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .stage = stage, .layout = pipeline_layout };
    r = vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &cpci, NULL, &pipeline); if (r) { rc = fail("vkCreateComputePipelines", r); goto done; }
    VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 1024 * sizeof(int32_t), .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    r = vkCreateBuffer(device, &bci, NULL, &buffer); if (r) { rc = fail("vkCreateBuffer", r); goto done; }
    VkMemoryRequirements req; vkGetBufferMemoryRequirements(device, buffer, &req);
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(physical, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) if ((req.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) == (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) { memory_type = i; break; }
    if (memory_type == UINT32_MAX) { fprintf(stderr, "VULKAN_RUNTIME_FAIL: no host-visible coherent memory\n"); goto done; }
    VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = memory_type };
    r = vkAllocateMemory(device, &mai, NULL, &memory); if (r) { rc = fail("vkAllocateMemory", r); goto done; }
    r = vkBindBufferMemory(device, buffer, memory, 0); if (r) { rc = fail("vkBindBufferMemory", r); goto done; }
    VkDescriptorPoolSize pool_size = { .type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 };
    VkDescriptorPoolCreateInfo dpci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &pool_size };
    r = vkCreateDescriptorPool(device, &dpci, NULL, &pool); if (r) { rc = fail("vkCreateDescriptorPool", r); goto done; }
    VkDescriptorSetAllocateInfo dsai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = &set_layout }; VkDescriptorSet set;
    r = vkAllocateDescriptorSets(device, &dsai, &set); if (r) { rc = fail("vkAllocateDescriptorSets", r); goto done; }
    VkDescriptorBufferInfo dbi = { .buffer = buffer, .offset = 0, .range = VK_WHOLE_SIZE };
    VkWriteDescriptorSet write = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 0, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi };
    vkUpdateDescriptorSets(device, 1, &write, 0, NULL);
    VkCommandPoolCreateInfo cpci2 = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = queue_family, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
    r = vkCreateCommandPool(device, &cpci2, NULL, &command_pool); if (r) { rc = fail("vkCreateCommandPool", r); goto done; }
    VkCommandBufferAllocateInfo cbai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = command_pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    r = vkAllocateCommandBuffers(device, &cbai, &command); if (r) { rc = fail("vkAllocateCommandBuffers", r); goto done; }
    VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    r = vkBeginCommandBuffer(command, &begin); if (r) { rc = fail("vkBeginCommandBuffer", r); goto done; }
    vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline); vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline_layout, 0, 1, &set, 0, NULL);
    uint32_t push[2] = { 42, 1024 }; vkCmdPushConstants(command, pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(push), push); vkCmdDispatch(command, 1024, 1, 1);
    r = vkEndCommandBuffer(command); if (r) { rc = fail("vkEndCommandBuffer", r); goto done; }
    VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO }; r = vkCreateFence(device, &fci, NULL, &fence); if (r) { rc = fail("vkCreateFence", r); goto done; }
    VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &command };
    r = vkQueueSubmit(queue, 1, &submit, fence); if (r) { rc = fail("vkQueueSubmit", r); goto done; }
    r = vkWaitForFences(device, 1, &fence, VK_TRUE, 1000000000ull); if (r) { rc = fail("vkWaitForFences", r); goto done; }
    int32_t *mapped = NULL; r = vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, (void **)&mapped); if (r) { rc = fail("vkMapMemory", r); goto done; }
    for (size_t i = 0; i < 1024; i++) if (mapped[i] != 42) { vkUnmapMemory(device, memory); fprintf(stderr, "VULKAN_RUNTIME_FAIL: output[%zu]=%d\n", i, mapped[i]); goto done; }
    vkUnmapMemory(device, memory); fprintf(stdout, "VULKAN_RUNTIME_OK: all 1024 elements filled with 42\n"); rc = 0;
done:
    if (device != VK_NULL_HANDLE) vkDeviceWaitIdle(device);
    if (fence) vkDestroyFence(device, fence, NULL); if (command_pool) vkDestroyCommandPool(device, command_pool, NULL); if (pool) vkDestroyDescriptorPool(device, pool, NULL);
    if (pipeline) vkDestroyPipeline(device, pipeline, NULL); if (pipeline_layout) vkDestroyPipelineLayout(device, pipeline_layout, NULL); if (set_layout) vkDestroyDescriptorSetLayout(device, set_layout, NULL);
    if (memory) vkFreeMemory(device, memory, NULL); if (buffer) vkDestroyBuffer(device, buffer, NULL); if (shader) vkDestroyShaderModule(device, shader, NULL); if (device) vkDestroyDevice(device, NULL); if (instance) vkDestroyInstance(instance, NULL); free(code); return rc;
}
C

cat >"$tmp/opengl_runtime_test.c" <<'C'
#define GL_GLEXT_PROTOTYPES 1
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <GL/glext.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static char *read_text(const char *path) { FILE *f=fopen(path,"rb"); if(!f)return NULL; fseek(f,0,SEEK_END); long n=ftell(f); rewind(f); char *p=calloc((size_t)n+1,1); if(p)fread(p,1,(size_t)n,f); fclose(f); return p; }
int main(int argc,char **argv) {
    if(argc!=2)return 2; char *source=read_text(argv[1]); if(!source){fprintf(stderr,"OPENGL_RUNTIME_FAIL: cannot read GLSL\n");return 1;}
    int rc=1; EGLDisplay d=EGL_NO_DISPLAY; EGLContext c=EGL_NO_CONTEXT; EGLSurface s=EGL_NO_SURFACE; GLuint sh=0,prog=0,buf=0;
    const EGLint attrs[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_BIT,EGL_NONE};
    const EGLint pbuf[]={EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE}; const EGLint ctx[]={EGL_CONTEXT_MAJOR_VERSION_KHR,4,EGL_CONTEXT_MINOR_VERSION_KHR,3,EGL_NONE};
    d=eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,EGL_DEFAULT_DISPLAY,NULL); if(d==EGL_NO_DISPLAY) d=eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint major=0,minor=0; if(!eglInitialize(d,&major,&minor)){fprintf(stderr,"OPENGL_RUNTIME_FAIL: eglInitialize\n");goto done;}
    if(!eglBindAPI(EGL_OPENGL_API))goto done; EGLConfig config; EGLint count=0; if(!eglChooseConfig(d,attrs,&config,1,&count)||count!=1)goto done;
    s=eglCreatePbufferSurface(d,config,pbuf); c=eglCreateContext(d,config,EGL_NO_CONTEXT,ctx); if(s==EGL_NO_SURFACE||c==EGL_NO_CONTEXT||!eglMakeCurrent(d,s,s,c))goto done;
    sh=glCreateShader(GL_COMPUTE_SHADER); const GLchar *src=source; GLint len=(GLint)strlen(source); glShaderSource(sh,1,&src,&len); glCompileShader(sh); GLint ok=0; glGetShaderiv(sh,GL_COMPILE_STATUS,&ok); if(!ok){char log[1024];GLsizei n=0;glGetShaderInfoLog(sh,sizeof(log),&n,log);fprintf(stderr,"OPENGL_RUNTIME_FAIL: shader: %.*s\n",(int)n,log);goto done;}
    prog=glCreateProgram(); glAttachShader(prog,sh); glLinkProgram(prog); glGetProgramiv(prog,GL_LINK_STATUS,&ok); if(!ok)goto done;
    int32_t zeros[1024]={0}; glGenBuffers(1,&buf); glBindBuffer(GL_SHADER_STORAGE_BUFFER,buf); glBufferData(GL_SHADER_STORAGE_BUFFER,sizeof(zeros),zeros,GL_DYNAMIC_DRAW); glBindBufferBase(GL_SHADER_STORAGE_BUFFER,0,buf); glUseProgram(prog);
    GLint value=glGetUniformLocation(prog,"value"), count_loc=glGetUniformLocation(prog,"count"); if(value>=0)glUniform1i(value,42); if(count_loc>=0)glUniform1i(count_loc,1024); glDispatchCompute(1024,1,1); glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT); glGetBufferSubData(GL_SHADER_STORAGE_BUFFER,0,sizeof(zeros),zeros);
    for(size_t i=0;i<1024;i++)if(zeros[i]!=42){fprintf(stderr,"OPENGL_RUNTIME_FAIL: output[%zu]=%d\n",i,zeros[i]);goto done;} if(glGetError()!=GL_NO_ERROR){fprintf(stderr,"OPENGL_RUNTIME_FAIL: GL error\n");goto done;}
    printf("EGL OpenGL context: %s\n",glGetString(GL_VERSION)); printf("OPENGL_RUNTIME_OK: all 1024 elements filled with 42\n"); rc=0;
done: if(prog)glDeleteProgram(prog); if(sh)glDeleteShader(sh); if(buf)glDeleteBuffers(1,&buf); if(d!=EGL_NO_DISPLAY){eglMakeCurrent(d,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);if(c!=EGL_NO_CONTEXT)eglDestroyContext(d,c);if(s!=EGL_NO_SURFACE)eglDestroySurface(d,s);eglTerminate(d);} free(source); return rc;
}
C

cat >"$tmp/opencl_runtime_test.c" <<'C'
#include <CL/cl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned char *read_bytes(const char *path, size_t *n) { FILE *f=fopen(path,"rb"); if(!f)return NULL; fseek(f,0,SEEK_END); long z=ftell(f); rewind(f); if(z<=0){fclose(f);return NULL;} unsigned char *p=malloc((size_t)z); if(p)fread(p,1,(size_t)z,f); fclose(f); *n=(size_t)z; return p; }
static char *read_text(const char *path) { FILE *f=fopen(path,"rb"); if(!f)return NULL; if(fseek(f,0,SEEK_END)!=0){fclose(f);return NULL;} long z=ftell(f); rewind(f); if(z<=0){fclose(f);return NULL;} char *p=calloc((size_t)z+1,1); if(p)fread(p,1,(size_t)z,f); fclose(f); return p; }
static cl_program build_source_program(cl_context context, cl_device_id device, const char *src, cl_int *err) {
    size_t len=strlen(src); cl_program p=clCreateProgramWithSource(context,1,&src,&len,err);
    if(!p || *err != CL_SUCCESS || clBuildProgram(p,1,&device,NULL,NULL,NULL) != CL_SUCCESS) {
        if(p) clReleaseProgram(p); return NULL;
    }
    return p;
}
int main(int argc,char **argv) {
    if(argc!=3)return 2; int rc=1; cl_int e=CL_SUCCESS; cl_platform_id platform=NULL; cl_device_id device=NULL; cl_context context=NULL; cl_command_queue queue=NULL; cl_program program=NULL; cl_kernel kernel=NULL; cl_mem buffer=NULL; unsigned char *il=NULL; char *source=NULL; size_t il_size=0;
    cl_uint np=0; e=clGetPlatformIDs(0,NULL,&np); if(e||np==0){printf("OPENCL_RUNTIME_SKIP: no OpenCL platform (%d)\n",e);return 77;}
    cl_platform_id *platforms=calloc(np,sizeof(*platforms)); if(!platforms)return 1; e=clGetPlatformIDs(np,platforms,NULL); if(e){free(platforms);return 1;}
    for(cl_uint i=0;i<np&&!device;i++){cl_uint nd=0; if(clGetDeviceIDs(platforms[i],CL_DEVICE_TYPE_GPU,0,NULL,&nd)==CL_SUCCESS&&nd){cl_device_id *ds=calloc(nd,sizeof(*ds)); if(ds&&clGetDeviceIDs(platforms[i],CL_DEVICE_TYPE_GPU,nd,ds,NULL)==CL_SUCCESS){platform=platforms[i];device=ds[0];} free(ds);}}
    free(platforms); if(!device){printf("OPENCL_RUNTIME_SKIP: no OpenCL GPU device\n");return 77;}
    char name[256]={0}; clGetDeviceInfo(device,CL_DEVICE_NAME,sizeof(name),name,NULL); printf("OpenCL device: %s\n",name);
    context=clCreateContext(NULL,1,&device,NULL,NULL,&e); if(!context||e)goto done;
#if CL_VERSION_2_0
    const cl_queue_properties qp[]={0}; queue=clCreateCommandQueueWithProperties(context,device,qp,&e);
#else
    queue=clCreateCommandQueue(context,device,0,&e);
#endif
    if(!queue||e)goto done; il=read_bytes(argv[1],&il_size); source=read_text(argv[2]); if(!il||!source)goto done;
#if CL_VERSION_2_1
    program=clCreateProgramWithIL(context,il,il_size,&e);
#endif
    /* Prefer the emitted IL, but fall back to OpenCL C when the ICD rejects
       IL at creation or build time (a common OpenCL 2.x capability split). */
    int il_ready=0; const char *path_used="opencl-c-fallback";
    if(program && e == CL_SUCCESS && clBuildProgram(program,1,&device,NULL,NULL,NULL) == CL_SUCCESS) {
        /* IL path is ready. */
        il_ready=1; path_used="spirv-il";
    } else {
        if(program) { clReleaseProgram(program); program=NULL; }
        e=CL_SUCCESS; program=build_source_program(context,device,source,&e);
        if(!program||e)goto done;
    }
    kernel=clCreateKernel(program,"fillKernel",&e);
    if((!kernel||e) && il_ready) {
        /* Some OpenCL 2.x ICDs accept/build IL but do not expose its kernel
           entry point. Retry from OpenCL C before declaring the backend bad. */
        if(kernel) { clReleaseKernel(kernel); kernel=NULL; }
        clReleaseProgram(program); program=NULL; e=CL_SUCCESS;
        program=build_source_program(context,device,source,&e);
        if(program) { path_used="opencl-c-fallback"; kernel=clCreateKernel(program,"fillKernel",&e); }
    }
    if(!kernel||e)goto done; int32_t data[1024]={0},value=42,count=1024; buffer=clCreateBuffer(context,CL_MEM_READ_WRITE|CL_MEM_COPY_HOST_PTR,sizeof(data),data,&e); if(!buffer||e)goto done;
    if(clSetKernelArg(kernel,0,sizeof(buffer),&buffer)!=CL_SUCCESS||clSetKernelArg(kernel,1,sizeof(value),&value)!=CL_SUCCESS||clSetKernelArg(kernel,2,sizeof(count),&count)!=CL_SUCCESS)goto done;
    size_t global=1024,local=1; if(clEnqueueNDRangeKernel(queue,kernel,1,NULL,&global,&local,0,NULL,NULL)!=CL_SUCCESS||clFinish(queue)!=CL_SUCCESS)goto done; if(clEnqueueReadBuffer(queue,buffer,CL_TRUE,0,sizeof(data),data,0,NULL,NULL)!=CL_SUCCESS)goto done;
    for(size_t i=0;i<1024;i++)if(data[i]!=42){fprintf(stderr,"OPENCL_RUNTIME_FAIL: output[%zu]=%d\n",i,data[i]);goto done;} printf("OpenCL execution path: %s\n",path_used); printf("OPENCL_RUNTIME_OK: all 1024 elements filled with 42\n");rc=0;
done: if(buffer)clReleaseMemObject(buffer);if(kernel)clReleaseKernel(kernel);if(program)clReleaseProgram(program);if(queue)clReleaseCommandQueue(queue);if(context)clReleaseContext(context);free(il);free(source); if(rc)fprintf(stderr,"OPENCL_RUNTIME_FAIL: OpenCL dispatch/build failed (%d)\n",e); return rc;
}
C

echo "════════════════════════════════════════════════════════════════"
echo "  Zag GPU Runtime Tests — physical GPU verification"
echo "  (set ZAG_RUN_PHYSICAL_GPU=1 to opt in; timeout=${gpu_timeout_seconds}s)"
echo "════════════════════════════════════════════════════════════════"

# ── Vulkan runtime test ─────────────────────────────────────────────────────
echo ""
echo "── Vulkan (SPIR-V → RADV) ──"

if (cd "$tmp" && "$ZNC" gpu_vulkan_probe.zag --dynamic --needed libvulkan.so.1 --no-zagd --no-analyze -o gpu_vulkan_probe) >"$tmp/vk_probe_compile.log" 2>&1; then
    ok "pure-Zag Vulkan loader probe compiled"
    if [ "${ZAG_RUN_PHYSICAL_GPU:-0}" = "1" ]; then
        if run_physical "$tmp/gpu_vulkan_probe" >"$tmp/vk_probe_out.txt" 2>&1; then
            ok "pure-Zag Vulkan loader probe enumerated a physical device"
            grep "ZAG_VULKAN_PROBE_OK" "$tmp/vk_probe_out.txt" >/dev/null && ok "ZAG_VULKAN_PROBE_OK marker present"
        else
            probe_rc=$?
            if [ "$probe_rc" -eq 124 ] || [ "$probe_rc" -eq 137 ]; then
                xx "pure-Zag Vulkan loader probe timed out after ${gpu_timeout_seconds}s"
            else
                xx "pure-Zag Vulkan loader probe failed (exit=$probe_rc)"
            fi
            cat "$tmp/vk_probe_out.txt"
        fi
    else
        echo "  --  pure-Zag Vulkan loader probe run skipped (set ZAG_RUN_PHYSICAL_GPU=1 to opt in)"
    fi
else
    xx "pure-Zag Vulkan loader probe failed to compile"
    sed -n '1,16p' "$tmp/vk_probe_compile.log"
fi

if ! command -v gcc >/dev/null 2>&1; then
    xx "gcc not found — cannot build Vulkan runtime test"
else
    if "$ZNC" "$tmp/fill.zag" --target vulkan-compat -o "$tmp/fill.spv" >/dev/null 2>&1; then
        ok "znc emits SPIR-V binary for vulkan-compat"
    else
        xx "znc failed to emit SPIR-V"
    fi

    if spirv-val --target-env vulkan1.0 "$tmp/fill.spv" >/dev/null 2>&1; then
        ok "SPIR-V passes spirv-val --target-env vulkan1.0"
    else
        xx "SPIR-V fails spirv-val"
    fi

    if gcc -std=c11 -O2 -Wall -Wextra -o "$tmp/vk_test" "$tmp/vulkan_runtime_test.c" -lvulkan 2>"$tmp/vk_compile.log"; then
        ok "Vulkan runtime test harness compiled"
    else
        xx "Failed to compile generated Vulkan runtime harness"
        sed -n '1,12p' "$tmp/vk_compile.log"
    fi

    if [ -x "$tmp/vk_test" ] && [ "${ZAG_RUN_PHYSICAL_GPU:-0}" = "1" ]; then
        if run_physical "$tmp/vk_test" "$tmp/fill.spv" >"$tmp/vk_out.txt" 2>&1; then
            ok "Vulkan kernel ran on GPU and output verified correct"
            grep "VULKAN_RUNTIME_OK" "$tmp/vk_out.txt" >/dev/null && ok "VULKAN_RUNTIME_OK marker present"
            grep "Physical device" "$tmp/vk_out.txt" | head -1
        else
            vk_rc=$?
            if [ "$vk_rc" -eq 124 ] || [ "$vk_rc" -eq 137 ]; then
                xx "Vulkan runtime test timed out after ${gpu_timeout_seconds}s"
            else
                xx "Vulkan runtime test failed (exit=$vk_rc)"
            fi
            cat "$tmp/vk_out.txt"
        fi
    elif [ -x "$tmp/vk_test" ]; then
        echo "  --  physical Vulkan dispatch skipped (set ZAG_RUN_PHYSICAL_GPU=1 to opt in)"
    fi
fi

# ── OpenGL runtime test ─────────────────────────────────────────────────────
echo ""
echo "── OpenGL (GLSL 430 → Mesa) ──"

if "$ZNC" "$tmp/fill.zag" --target opengl-compat -o "$tmp/fill.glsl" >/dev/null 2>&1; then
    ok "znc emits GLSL source for opengl-compat"
else
    xx "znc failed to emit GLSL"
fi

if gcc -std=c11 -O2 -Wall -Wextra -o "$tmp/gl_test" "$tmp/opengl_runtime_test.c" -lEGL -lGL 2>"$tmp/gl_compile.log"; then
    ok "OpenGL runtime test harness compiled"
else
    xx "Failed to compile generated OpenGL runtime harness"
    sed -n '1,12p' "$tmp/gl_compile.log"
fi

if [ -x "$tmp/gl_test" ] && [ "${ZAG_RUN_PHYSICAL_GPU:-0}" = "1" ]; then
    if run_physical "$tmp/gl_test" "$tmp/fill.glsl" >"$tmp/gl_out.txt" 2>&1; then
        ok "OpenGL kernel ran on GPU and output verified correct"
        grep "OPENGL_RUNTIME_OK" "$tmp/gl_out.txt" >/dev/null && ok "OPENGL_RUNTIME_OK marker present"
        grep "EGL OpenGL context" "$tmp/gl_out.txt" | head -1
    else
        gl_rc=$?
        if [ "$gl_rc" -eq 124 ] || [ "$gl_rc" -eq 137 ]; then
            xx "OpenGL runtime test timed out after ${gpu_timeout_seconds}s"
        else
            xx "OpenGL runtime test failed (exit=$gl_rc)"
        fi
        cat "$tmp/gl_out.txt"
    fi
elif [ -x "$tmp/gl_test" ]; then
    echo "  --  physical OpenGL dispatch skipped (set ZAG_RUN_PHYSICAL_GPU=1 to opt in)"
fi

# ── OpenCL runtime probe ────────────────────────────────────────────────────
echo ""
echo "── OpenCL (SPIR-V/source → ICD) ──"
if "$ZNC" "$tmp/fill.zag" --target opencl-compat -o "$tmp/fill-opencl.spv" >/dev/null 2>&1 &&
   spirv-val --target-env opencl2.0 "$tmp/fill-opencl.spv" >/dev/null 2>&1; then
    ok "znc emits OpenCL SPIR-V for the runtime probe"
else
    xx "znc failed to emit/validate OpenCL SPIR-V"
fi
# The checked-in pure-Zag OpenCL-C emitter is compiled as a short-lived tool;
# this keeps the runtime fallback generated from the same source profile even
# when the main compiler only exposes the SPIR-V `opencl-compat` target.
if "$ZNC" "$PWD/tests/opencl_c_emit.zag" --no-analyze --no-zagd -o "$tmp/opencl_c_emit" >/dev/null 2>&1 &&
   "$tmp/opencl_c_emit" "$tmp/fill.zag" "$tmp/fill-opencl.cl" >/dev/null 2>&1 &&
   grep -q "__kernel void fillKernel" "$tmp/fill-opencl.cl"; then
    ok "znc emits OpenCL C fallback source for the runtime probe"
else
    xx "pure-Zag OpenCL C fallback emitter failed"
fi
if gcc -std=c11 -O2 -Wall -Wextra -o "$tmp/cl_test" "$tmp/opencl_runtime_test.c" -lOpenCL 2>"$tmp/cl_compile.log"; then
    ok "OpenCL runtime probe compiled"
else
    xx "Failed to compile generated OpenCL runtime probe"
    sed -n '1,12p' "$tmp/cl_compile.log"
fi
if [ -x "$tmp/cl_test" ] && [ "${ZAG_RUN_PHYSICAL_GPU:-0}" = "1" ]; then
    set +e
    run_physical "$tmp/cl_test" "$tmp/fill-opencl.spv" "$tmp/fill-opencl.cl" >"$tmp/cl_out.txt" 2>&1
    cl_rc=$?
    set -e
    if [ "$cl_rc" = 0 ]; then
        ok "OpenCL kernel ran and output verified correct"
        grep "OPENCL_RUNTIME_OK" "$tmp/cl_out.txt" >/dev/null && ok "OPENCL_RUNTIME_OK marker present"
        grep "OpenCL device" "$tmp/cl_out.txt" | head -1
        grep "OpenCL execution path" "$tmp/cl_out.txt" | head -1
    elif [ "$cl_rc" = 77 ]; then
        echo "  --  OpenCL runtime skipped: no GPU device exposed by the installed ICD"
    else
        cl_rc=$?
        if [ "$cl_rc" -eq 124 ] || [ "$cl_rc" -eq 137 ]; then
            xx "OpenCL runtime probe timed out after ${gpu_timeout_seconds}s"
        else
            xx "OpenCL runtime probe failed (exit=$cl_rc)"
        fi
        cat "$tmp/cl_out.txt"
    fi
elif [ -x "$tmp/cl_test" ]; then
    echo "  --  physical OpenCL dispatch skipped (set ZAG_RUN_PHYSICAL_GPU=1 to opt in)"
fi

# ── Untestable targets on this machine ──────────────────────────────────────
echo ""
echo "── Untestable on this machine (AMD GPU, Linux) ──"
clinfo_snapshot=""
if command -v clinfo >/dev/null 2>&1; then
    clinfo_snapshot=$(clinfo 2>/dev/null || true)
fi
if [[ "$clinfo_snapshot" == *"Board name:"*"AMD Radeon RX 5700 XT"* ]]; then
    echo "  --  opencl-compat: ROCm ICD exposes AMD Radeon RX 5700 XT; dispatch is explicit opt-in"
else
    echo "  --  opencl-compat: no AMD/CPU OpenCL device is installed"
fi
echo "  --  cuda-compat:   no NVIDIA GPU is present; PTX emission remains available"
echo "  --  metal-compat:  Linux has no Metal framework; MSL emission remains available"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Runtime GPU tests: pass=$pass fail=$fail"
echo "════════════════════════════════════════════════════════════════"
[ "$fail" -eq 0 ]
