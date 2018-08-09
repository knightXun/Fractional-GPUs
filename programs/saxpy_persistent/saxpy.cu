#include <stdio.h>

#include <common.h>
#include <fractional_gpu.h>
#include <fractional_gpu_cuda.cuh>


__global__
FGPU_DEFINE_KERNEL(saxpy, int n, float a, float *x, float *y)
{
  fgpu_dev_ctx_t *ctx;
  uint3 _blockIdx;
  ctx = FGPU_DEVICE_INIT();

  FGPU_FOR_EACH_DEVICE_BLOCK(_blockIdx) {
    int i = _blockIdx.x*blockDim.x + threadIdx.x;
    if (i < n) {
      float res = a * FGPU_COLOR_LOAD(ctx, &x[i]) + FGPU_COLOR_LOAD(ctx, &y[i]);
//      printf("Res:%f, X:%f, Y:%f, A:%f\n", res, FGPU_COLOR_LOAD(ctx, &x[i]) , FGPU_COLOR_LOAD(ctx, &y[i]), a);
      FGPU_COLOR_STORE(ctx, &y[i], res);
    }
  } FGPU_FOR_EACH_END;
}

int main(int argc, char **argv)
{
  int N = 1<<20;
  int nIter = 10000;
  double start, total;
  pstats_t stats;

  dim3 grid((N+255)/256, 1, 1), threads(256, 1, 1);
  int ret;
  int color;

  if (argc != 2) {
    fprintf(stderr, "Insufficient number of arguments\n");
    exit(-1);
  }

  color = atoi(argv[1]);

  printf("Color selected:%d\n", color);

  ret = fgpu_init();
  if (ret < 0)
    return ret;

  ret = fgpu_set_color_prop(color, 128 * 1024 * 1024);
  if (ret < 0)
    return ret;

  float *x, *y, *h_x, *h_y, *d_x, *d_y;
  x = (float*)malloc(N*sizeof(float));
  y = (float*)malloc(N*sizeof(float));

  ret = fgpu_memory_allocate((void **) &h_x, N*sizeof(float));
  if (ret < 0)
    return ret;
  ret = fgpu_memory_allocate((void **) &h_y, N*sizeof(float));
  if (ret < 0)
    return ret;

  for (int i = 0; i < N; i++) {
    x[i] = 1.0f;
    y[i] = 2.0f;
  }

  ret = fgpu_memory_copy_async(h_x, x, N*sizeof(float), FGPU_COPY_CPU_TO_GPU);
  if (ret < 0)
      return ret;

  ret = fgpu_memory_copy_async(h_y, y, N*sizeof(float), FGPU_COPY_CPU_TO_GPU);
  if (ret < 0)
      return ret;


  ret = fgpu_memory_get_device_pointer((void **)&d_x, h_x);
  if (ret < 0)
    return ret;

  ret = fgpu_memory_get_device_pointer((void **)&d_y, h_y);
  if (ret < 0)
    return ret;

  // Functional test
  FGPU_LAUNCH_KERNEL(grid, threads, 0, saxpy, N, 2.0f, d_x, d_y);
  
  ret = fgpu_memory_copy_async(y, h_y, N*sizeof(float), FGPU_COPY_GPU_TO_CPU);
  if (ret < 0)
      return ret;

  float maxError = 0.0f;
  for (int i = 0; i < N; i++)
    maxError = max(maxError, abs(y[i]-4.0f));
  printf("Max error: %f\n", maxError);
  if (maxError != 0) {
      fprintf(stderr, "Failed: Error too large\n");
      exit(-1);
  }

  // Warmup
  for (int i = 0; i < nIter; i++) {

    start = dtime_usec(0);
    
    FGPU_LAUNCH_KERNEL(grid, threads, 0, saxpy, N, 2.0f, d_x, d_y);
    cudaDeviceSynchronize();

    total = dtime_usec(start);
    printf("Time:%f\n", total);
  }

  // Actual
  pstats_init(&stats);
  start = dtime_usec(0);
  for (int j = 0; j < nIter; j++)
  {
    double sub_start = dtime_usec(0);
    FGPU_LAUNCH_KERNEL(grid, threads, 0, saxpy, N, 2.0f, d_x, d_y);    
    cudaDeviceSynchronize();
    pstats_add_observation(&stats, dtime_usec(sub_start));
  }
    
  cudaDeviceSynchronize();
  total = dtime_usec(start);

  pstats_print(&stats);

  // Termination - To allow other color's application to overlap in time
  for (int j = 0; j < nIter; j++)
  {
    FGPU_LAUNCH_KERNEL(grid, threads, 0, saxpy, N, 2.0f, d_x, d_y);    
    cudaDeviceSynchronize();
  }
    
  fgpu_memory_free(h_x);
  fgpu_memory_free(h_y);
  free(x);
  free(y);

  fgpu_deinit();
}