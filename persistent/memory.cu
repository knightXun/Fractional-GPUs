/* 
 * This file takes care of memory coloring in GPU. To do this, we make 
 * custom ioctl() calls to nvidia uvm driver.  These ioctls have been added to 
 * vanilla uvm driver to expose certain functionality.
 * This file traps some calls made by CUDA library using preload mechanisms.
 * This is needed because CUDA library is closed source.
 */

/* TODO: Use better error codes */
/* TODO: Half of colored memory is being wasted. Need to resolve this issue */
/* 
 * TODO: Make PTEs on GPU consistent (on memprefetch to CPU they are invidated
 * for uvm to work). But make sure data migrates when data changes (When user 
 * explicitly requests)
 */
/* 
 * TODO: There shouldn't be need to memprefetch incase data hasn't changed
 * between CPU and GPU. This should work when GPU TLBs are made persistent.
 * Check what happens currently.
 */

#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <iostream>
#include <inttypes.h>
#include <linux/ioctl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <unistd.h>

/* CUDA/NVML */
#include <cuda.h>
#include <cuda_runtime_api.h>
#include <nvml.h>
#include <driver_types.h>

/* NVIDIA driver */
#include <uvm_minimal_init.h>

#include <fractional_gpu.hpp>
#include <fractional_gpu_cuda.cuh>
#include <fgpu_internal_memory.hpp>

#ifdef FGPU_MEM_COLORING_ENABLED

#define NVIDIA_UVM_DEVICE_PATH  "/dev/" NVIDIA_UVM_DEVICE_NAME
/* TODO: This path can be changed via environment variable */
#define NVIDIA_MPS_CONTROL_PATH "/tmp/nvidia-mps/control"

/* Ioctl codes */
#define IOCTL_GET_DEVICE_COLOR_INFO     _IOC(0, 0, UVM_GET_DEVICE_COLOR_INFO, 0)
#define IOCTL_GET_PROCESS_COLOR_INFO    _IOC(0, 0, UVM_GET_PROCESS_COLOR_INFO, 0)
#define IOCTL_SET_PROCESS_COLOR_INFO    _IOC(0, 0, UVM_SET_PROCESS_COLOR_INFO, 0)

/* UVM device fd */
static int g_uvm_fd = -1;

typedef int (*orig_open_f_type)(const char *pathname, int flags, int mode);
orig_open_f_type g_orig_open;

typedef int (*orig_connect_f_type)(int sockfd, const struct sockaddr *addr,
                   socklen_t addrlen);
orig_connect_f_type g_orig_connect;

pthread_once_t g_pre_init_once = PTHREAD_ONCE_INIT;
pthread_once_t g_post_init_once = PTHREAD_ONCE_INIT;
bool g_init_failed;

/* All information needed for tracking memory */
struct {
    bool is_initialized;

    /* Start physical address of allocation */
    void *base_phy_addr;

    /* Actual memory available for coloring */
    size_t reserved_len;

    /* Actual memory allocation */
    void *base_addr;

    int color;

    /* 
     * TODO: Use better data structures for memory management
     * TODO: Support alignment etc.
     */
    uintptr_t cur_addr;
    size_t left;

} g_memory_ctx;

/* Does the most neccesary initialization */
static void pre_initialization(void)
{
    g_orig_open = (orig_open_f_type)dlsym(RTLD_NEXT,"open");
    if (!g_orig_open) {
        g_init_failed = true;
        return;
    }

    g_orig_connect = (orig_connect_f_type)dlsym(RTLD_NEXT,"connect");
    if (!g_orig_connect) {
        g_init_failed = true;
        return;
    }
}

static void post_initialization(void)
{
    nvmlReturn_t ncode;

    ncode = nvmlInit();
    if (ncode != NVML_SUCCESS) {
        g_init_failed = true;
        return;
    }
}

/* Does the initialization atmost once */
static int init(bool do_post_init)
{
    int ret;

    ret = pthread_once(&g_pre_init_once, pre_initialization);
    if (ret < 0)
        return ret;
    
    if (g_init_failed)
        return -1;
    
    if (!do_post_init)
        return 0;

    ret = pthread_once(&g_post_init_once, post_initialization);
    if (ret < 0)
        return ret;
    
    if (g_init_failed)
        return -1;

    return 0;
}

/* Retrieve the device UUID from the CUDA device handle */
static int get_device_UUID(int device, NvProcessorUuid *uuid)
{
    nvmlReturn_t ncode;
    cudaError_t ccode;
    char pciID[32];
    nvmlDevice_t handle;
    char buf[100];
    char hex[2];
    char *nbuf;
    int cindex, hindex, uindex, needed_bytes;
    char c;
    int len;
    std::string prefix = "GPU";
    const char *gpu_prefix = prefix.c_str();
    int gpu_prefix_len = strlen(gpu_prefix);

    /* Get PCI ID from the device handle and then use NVML library to get UUID */
    ccode = cudaDeviceGetPCIBusId(pciID, sizeof(pciID), device);
    if (ccode != cudaSuccess)
        return -1;

    ncode = nvmlDeviceGetHandleByPciBusId(pciID, &handle);
    if (ncode != NVML_SUCCESS)
        return -1;

     
    ncode = nvmlDeviceGetUUID(handle, buf, sizeof(buf));
    if (ncode != NVML_SUCCESS)
        return -1;

    if (strncmp(buf, gpu_prefix, gpu_prefix_len != 0))
        return 0;

    nbuf = buf + gpu_prefix_len;

    /*
     * UUID has characters and hexadecimal numbers. 
     * We are only interested in hexadecimal numbers.
     * Each hexadecimal numbers is equal to 1 byte.
     */
    needed_bytes = sizeof(NvProcessorUuid);
    len = strlen(nbuf);

    for (cindex = 0, hindex = 0, uindex = 0; cindex < len; cindex++) {
        c = nbuf[cindex];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
            hex[hindex] = c;
            hindex++;
            if (hindex == 2) {
                uuid->uuid[uindex] = (uint8_t)strtol(hex, NULL, 16);
                uindex++;
                hindex = 0;
                if (uindex > needed_bytes)
                    return -1;
            }
        }
    }

    if (uindex != needed_bytes)
        return -1;

    return 0;
}

extern "C" {

/* Trap open() calls (interested in UVM device opened by CUDA) */
int open(const char *pathname, int flags, int mode)
{
    int ret;

    ret = init(false);
    if (ret < 0)
        return ret;
    
    ret = g_orig_open(pathname,flags, mode);

    if (g_uvm_fd < 0 && 
            strncmp(pathname, NVIDIA_UVM_DEVICE_PATH, strlen(NVIDIA_UVM_DEVICE_PATH)) == 0) {
        g_uvm_fd = ret;
    }

    return ret;
}

/* Trap connect() calls (interested in connection to MPS) */
int connect(int sockfd, const struct sockaddr *addr,
                   socklen_t addrlen)
{
    int ret;

    ret = init(false);
    if (ret < 0)
        return ret;
    
    ret = g_orig_connect(sockfd, addr, addrlen);

    if (ret >= 0 && addr && addr->sa_family == AF_LOCAL && 
            strncmp(addr->sa_data, NVIDIA_MPS_CONTROL_PATH, strlen(NVIDIA_MPS_CONTROL_PATH)) == 0) {
        g_uvm_fd = sockfd;
    }

    return ret;
}

} /* extern "C" */

static int get_device_color_info(int device, int *num_colors, size_t *max_len)
{
    UVM_GET_DEVICE_COLOR_INFO_PARAMS params;
    int ret;

    ret = get_device_UUID(device, &params.destinationUuid);
    if (ret < 0)
        return ret;
    
    ret = ioctl(g_uvm_fd, IOCTL_GET_DEVICE_COLOR_INFO, &params);
    if (ret < 0)
        return ret;

    if (params.rmStatus != NV_OK)
        return -1;

    if (num_colors)
        *num_colors = params.numColors;

    if (max_len)
        *max_len = params.maxLength;

    return 0;

}

/* Get the numbers of colors supported by the memory and maximum memory that can be reserved */
int fgpu_memory_get_device_info(int *num_colors, size_t *max_len)
{
    int ret;

    ret = init(true);
    if (ret < 0)
        return ret;

    if (g_uvm_fd < 0)
        return -EBADF;

    return get_device_color_info(FGPU_DEVICE_NUMBER, num_colors, max_len);

}

static int get_process_color_info(int device, int *color, size_t *length)
{
    UVM_GET_PROCESS_COLOR_INFO_PARAMS params;
    int ret;

    ret = get_device_UUID(device, &params.destinationUuid);
    if (ret < 0)
        return ret;


    ret = ioctl(g_uvm_fd, IOCTL_GET_PROCESS_COLOR_INFO, &params);
    if (ret < 0)
        return ret;

    if (params.rmStatus != NV_OK)
        return -1;

    if (color)
        *color = params.color;

    if (length)
        *length = params.length;

    return 0;

}

/* Indicates the color set currently for the process and the length reserved */
int fgpu_process_get_colors_info(int device, int *color, size_t *length)
{
    int ret;

    ret = init(true);
    if (ret < 0)
        return ret;

    if (g_uvm_fd < 0)
        return -EBADF;

    return get_process_color_info(device, color, length);
}

/* Set memory color and also reserve memory */
static int set_process_color_info(int device, int color, size_t req_length,
        cudaStream_t stream)
{
    UVM_SET_PROCESS_COLOR_INFO_PARAMS params;
    size_t actual_length = req_length;
    int ret;

    /* Color can only be set once */
    if (g_memory_ctx.is_initialized)
        return -1;

#if defined(FGPU_USER_MEM_COLORING_ENABLED)
    int num_colors;
    ret = get_device_color_info(device, &num_colors, NULL);
    if (ret < 0)
        return ret;
    
    actual_length = req_length * num_colors;
#endif

    ret = get_device_UUID(device, &params.destinationUuid);
    if (ret < 0)
        return ret;

    params.color = color;
    params.length = actual_length;

    ret = ioctl(g_uvm_fd, IOCTL_SET_PROCESS_COLOR_INFO, &params);
    if (ret < 0)
        return ret;

    if (params.rmStatus != NV_OK)
        return -1;

    ret = gpuErrCheck(cudaMallocManaged(&g_memory_ctx.base_addr, actual_length));
    if (ret < 0)
        return ret;

    /* Do the actual allocation on device */
    ret = gpuErrCheck(cudaMemPrefetchAsync(g_memory_ctx.base_addr, actual_length,
                device, stream));
    if (ret < 0) {
        cudaFree(g_memory_ctx.base_addr);
        return ret;
    }

    ret = gpuErrCheck(cudaStreamSynchronize(stream));
    if (ret < 0) {
    	cudaFree(g_memory_ctx.base_addr);
        return ret;
    }

    g_memory_ctx.is_initialized = true;
    g_memory_ctx.base_phy_addr = (void *)params.address;
    g_memory_ctx.reserved_len = req_length;
    g_memory_ctx.color = color;

    g_memory_ctx.cur_addr = (uintptr_t)g_memory_ctx.base_addr;
    g_memory_ctx.left = req_length;

    return 0;
}

/* Indicates the color set currently for the process and the length reserved */
int fgpu_memory_set_colors_info(int device, int color, size_t length,
        cudaStream_t stream)
{
    int ret;

    ret = init(true);
    if (ret < 0)
        return ret;

    if (g_uvm_fd < 0)
        return -EBADF;

    return set_process_color_info(device, color, length, stream);
}

void fgpu_memory_deinit(void)
{
    if (!g_memory_ctx.is_initialized)
        return;

    cudaFree(g_memory_ctx.base_addr);

    g_memory_ctx.is_initialized = false;
}

int fgpu_memory_allocate(void **p, size_t len)
{
    if (!g_memory_ctx.is_initialized)
        return -1;

    if (g_memory_ctx.left < len)
        return -1;

    *p = (void *)g_memory_ctx.cur_addr;
    g_memory_ctx.cur_addr += len;
    g_memory_ctx.left -= len;
    return 0;
}

int fgpu_memory_free(void *p)
{
    if (!g_memory_ctx.is_initialized)
        return -1;

    return 0;
}

/* Useful for only reverse engineering */
void *fgpu_memory_get_phy_address(void *addr)
{
    if (!g_memory_ctx.base_phy_addr)
        return NULL;

    return (void *)((uintptr_t)g_memory_ctx.base_phy_addr + 
            (uintptr_t)addr - (uintptr_t)g_memory_ctx.base_addr);
}


#else /* FGPU_MEM_COLORING_ENABLED */

int fgpu_memory_allocate(void **p, size_t len)
{
    return gpuErrCheck(cudaMallocManaged(p, len));
}

int fgpu_memory_free(void *p)
{
    return gpuErrCheck(cudaFree(p));
}

void *fgpu_memory_get_phy_address(void *addr)
{
    return NULL;
}

#endif /* FGPU_MEM_COLORING_ENABLED */

#if defined(FGPU_USER_MEM_COLORING_ENABLED)
int fgpu_memory_get_device_pointer(void **d_p, void *h_p)
{
    if (!g_memory_ctx.is_initialized)
        return -1;

    *d_p = (void *)((uintptr_t)h_p - (uintptr_t)g_memory_ctx.base_addr);
    return 0;
}

int fgpu_get_memory_info(uintptr_t *start_virt_addr, uintptr_t *start_idx)
{
    if (!g_memory_ctx.is_initialized)
        return -1;

    *start_virt_addr = (uintptr_t)g_memory_ctx.base_addr;
    *start_idx = ((uintptr_t)g_memory_ctx.base_phy_addr) >> FGPU_DEVICE_COLOR_SHIFT;

    return 0;
}

/* 
 * TODO: This might be slower to loop in userspace. Doing this inside kernel
 * might be faster. So measure the reduction in bandwidth and if substantial,
 * do inside kernel
 */
int fgpu_memory_copy_async_to_device_internal(void *dst, const void *src, 
                                                size_t count, cudaStream_t stream)
{
    size_t left = count;
    int ret;

    while (left) {
        uintptr_t base = (uintptr_t)dst & FGPU_DEVICE_PAGE_MASK;
        uintptr_t offset = (uintptr_t)dst - base;
        size_t transfer = min(min(left, (size_t)FGPU_DEVICE_PAGE_SIZE), 
                (size_t)FGPU_DEVICE_PAGE_SIZE - (size_t)offset);
        void *true_virt_addr_dest = fgpu_color_device_true_virt_addr((uint64_t)g_memory_ctx.base_addr,
                                                                     (uint64_t)g_memory_ctx.base_phy_addr,
                                                                     g_memory_ctx.color,
                                                                     dst);

        ret = gpuErrCheck(cudaMemcpyAsync(true_virt_addr_dest, src, transfer, cudaMemcpyHostToDevice, stream));
        if (ret < 0)
            return ret;
        dst = (void *)((uintptr_t)dst + transfer);
        src = (void *)((uintptr_t)src + transfer);
        left -= transfer;
    }
    return 0;
}

int fgpu_memory_copy_async_to_host_internal(void *dst, const void *src, 
                                                size_t count, cudaStream_t stream)
{
    size_t left = count;
    int ret;

    while (left) {
        uintptr_t base = (uintptr_t)src & FGPU_DEVICE_PAGE_MASK;
        uintptr_t offset = (uintptr_t)src - base;
        size_t transfer = min(min(left, (size_t)FGPU_DEVICE_PAGE_SIZE), 
                (size_t)FGPU_DEVICE_PAGE_SIZE - (size_t)offset);
        void *true_virt_addr_src = fgpu_color_device_true_virt_addr((uint64_t)g_memory_ctx.base_addr,
                                                                    (uint64_t)g_memory_ctx.base_phy_addr,
                                                                    g_memory_ctx.color,
                                                                    src);

        ret = gpuErrCheck(cudaMemcpyAsync(dst, true_virt_addr_src, transfer, cudaMemcpyDeviceToHost, stream));
        if (ret < 0)
            return ret;
        dst = (void *)((uintptr_t)dst + transfer);
        src = (void *)((uintptr_t)src + transfer);
        left -= transfer;
    }

    return 0;
}

int fgpu_memory_copy_async_internal(void *dst, const void *src, size_t count,
                                    enum fgpu_memory_copy_type type,
                                    cudaStream_t stream)
{

    switch (type) {
    case FGPU_COPY_CPU_TO_GPU:
        return fgpu_memory_copy_async_to_device_internal(dst, src, count, stream);
    case FGPU_COPY_GPU_TO_CPU:
        return fgpu_memory_copy_async_to_host_internal(dst, src, count, stream);
    default:
        return -1;
    }   
}

#else /* FGPU_USER_MEM_COLORING_ENABLED */

int fgpu_memory_get_device_pointer(void **d_p, void *h_p)
{
    *d_p = h_p;
    return 0;
}

int fgpu_memory_copy_async_internal(void *dst, const void *src, size_t count, enum fgpu_memory_copy_type type, cudaStream_t stream)
{
    switch (type) {
    case FGPU_COPY_CPU_TO_GPU:
        return gpuErrCheck(cudaMemcpyAsync(dst, src, count, cudaMemcpyHostToDevice, stream));
    case FGPU_COPY_GPU_TO_CPU:
        return gpuErrCheck(cudaMemcpyAsync(dst, src, count, cudaMemcpyDeviceToHost, stream));
    default:
        return -1;
    }   
}
#endif /* FGPU_USER_MEM_COLORING_ENABLED */
