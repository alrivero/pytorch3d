// Copyright (c) Facebook, Inc. and its affiliates. All rights reserved.

#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>
#include <c10/cuda/CUDAGuard.h>
#include <algorithm>
#include <list>
#include <queue>
#include <tuple>
#include "utils/float_math.cuh"
#include "utils/geometry_utils.cuh"
#include "utils/warp_reduce.cuh"

// ****************************************************************************
// *                          PointFaceDistance                               *
// ****************************************************************************

__global__ void DistanceForwardKernel(
    const float* __restrict__ objects, // (O * oD * 3)
    const size_t objects_size, // O
    const size_t objects_dim, // oD
    const float* __restrict__ targets, // (T * tD * 3)
    const size_t targets_size, // T
    const size_t targets_dim, // tD
    const int64_t* __restrict__ objects_first_idx, // (B,)
    const int64_t* __restrict__ targets_first_idx, // (B,)
    const size_t batch_size, // B
    float* __restrict__ dist_objects, // (O,)
    int64_t* __restrict__ idx_objects) { // (O,)
  // This kernel is used interchangeably to compute bi-directional distances
  // between points and triangles/lines. The direction of the distance computed,
  // i.e. point to triangle/line or triangle/line to point, depends on the order
  // of the input arguments and is inferred based on their shape. The shape is
  // used to distinguish between triangles and lines

  // Single shared memory buffer which is split and cast to different types.
  extern __shared__ char shared_buf[];
  float* min_dists = (float*)shared_buf; // float[NUM_THREADS]
  int64_t* min_idxs = (int64_t*)&min_dists[blockDim.x]; // int64_t[NUM_THREADS]

  const size_t batch_idx = blockIdx.y; // index of batch element.

  // start and end for objects in batch_idx
  const int64_t starto = objects_first_idx[batch_idx];
  const int64_t endo = batch_idx + 1 < batch_size
      ? objects_first_idx[batch_idx + 1]
      : objects_size;

  // start and end for targets in batch_idx
  const int64_t startt = targets_first_idx[batch_idx];
  const int64_t endt = batch_idx + 1 < batch_size
      ? targets_first_idx[batch_idx + 1]
      : targets_size;

  const size_t i = blockIdx.x; // index within batch element.
  const size_t tid = threadIdx.x; // thread index

  // Set references to points/face based on which of objects/targets refer to
  // points/faces
  float3* points_f3 = objects_dim == 1 ? (float3*)objects : (float3*)targets;
  float3* face_f3 = objects_dim == 1 ? (float3*)targets : (float3*)objects;
  // Distinguishes whether we're computing distance against triangle vs edge
  bool isTriangle = objects_dim == 3 || targets_dim == 3;

  // Each block will compute one element of the output idx_objects[starto + i],
  // dist_objects[starto + i]. Within the block we will use threads to compute
  // the distances between objects[starto + i] and targets[j] for all j
  // belonging in the same batch as i, i.e. j in [startt, endt]. Then use a
  // block reduction to take an argmin of the distances.

  // If i exceeds the number of objects in batch_idx, then do nothing
  if (i < (endo - starto)) {
    // Compute the distances between objects[starto + i] and targets[j] for
    // all j belonging in the same batch as i, i.e. j in [startt, endt].
    // Here each thread will reduce over (endt-startt) / blockDim.x in serial,
    // and store its result to shared memory
    float min_dist = FLT_MAX;
    size_t min_idx = 0;
    for (size_t j = tid; j < (endt - startt); j += blockDim.x) {
      size_t point_idx = objects_dim == 1 ? starto + i : startt + j;
      size_t face_idx = objects_dim == 1 ? (startt + j) * targets_dim
                                         : (starto + i) * objects_dim;

      float dist;
      if (isTriangle) {
        dist = PointTriangle3DistanceForward(
            points_f3[point_idx],
            face_f3[face_idx],
            face_f3[face_idx + 1],
            face_f3[face_idx + 2]);
      } else {
        dist = PointLine3DistanceForward(
            points_f3[point_idx], face_f3[face_idx], face_f3[face_idx + 1]);
      }

      min_dist = (j == tid) ? dist : min_dist;
      min_idx = (dist <= min_dist) ? (startt + j) : min_idx;
      min_dist = (dist <= min_dist) ? dist : min_dist;
    }
    min_dists[tid] = min_dist;
    min_idxs[tid] = min_idx;
    __syncthreads();

    // Perform reduction in shared memory.
    for (int s = blockDim.x / 2; s > 32; s >>= 1) {
      if (tid < s) {
        if (min_dists[tid] > min_dists[tid + s]) {
          min_dists[tid] = min_dists[tid + s];
          min_idxs[tid] = min_idxs[tid + s];
        }
      }
      __syncthreads();
    }

    // Unroll the last 6 iterations of the loop since they will happen
    // synchronized within a single warp.
    if (tid < 32)
      WarpReduce<float>(min_dists, min_idxs, tid);

    // Finally thread 0 writes the result to the output buffer.
    if (tid == 0) {
      idx_objects[starto + i] = min_idxs[0];
      dist_objects[starto + i] = min_dists[0];
    }
  }
}

std::tuple<at::Tensor, at::Tensor> DistanceForwardCuda(
    const at::Tensor& objects,
    const size_t objects_dim,
    const at::Tensor& objects_first_idx,
    const at::Tensor& targets,
    const size_t targets_dim,
    const at::Tensor& targets_first_idx,
    const int64_t max_objects) {
  // Check inputs are on the same device
  at::TensorArg objects_t{objects, "objects", 1},
      objects_first_idx_t{objects_first_idx, "objects_first_idx", 2},
      targets_t{targets, "targets", 3},
      targets_first_idx_t{targets_first_idx, "targets_first_idx", 4};
  at::CheckedFrom c = "DistanceForwardCuda";
  at::checkAllSameGPU(
      c, {objects_t, objects_first_idx_t, targets_t, targets_first_idx_t});
  at::checkAllSameType(c, {objects_t, targets_t});

  // Set the device for the kernel launch based on the device of the input
  at::cuda::CUDAGuard device_guard(objects.device());
  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  const int64_t objects_size = objects.size(0);
  const int64_t targets_size = targets.size(0);
  const int64_t batch_size = objects_first_idx.size(0);

  TORCH_CHECK(targets_first_idx.size(0) == batch_size);
  if (objects_dim == 1) {
    TORCH_CHECK(
        targets_dim >= 2 && targets_dim <= 3,
        "either object or target must be edge or face");
    TORCH_CHECK(objects.size(1) == 3, "points must be of shape Px3");
    TORCH_CHECK(
        targets.size(2) == 3,
        "face must be of shape Tx3x3, lines must be of shape Tx2x3");
  } else {
    TORCH_CHECK(targets_dim == 1, "either object or target must be point");
    TORCH_CHECK(
        objects_dim >= 2 && objects_dim <= 3,
        "either object or target must be edge or face");
    TORCH_CHECK(targets.size(1) == 3, "points must be of shape Px3");
    TORCH_CHECK(
        objects.size(2) == 3,
        "face must be of shape Tx3x3, lines must be of shape Tx2x3");
  }

  // clang-format off
  at::Tensor dists = at::zeros({objects_size,}, objects.options());
  at::Tensor idxs = at::zeros({objects_size,}, objects_first_idx.options());
  // clang-format on

  if (dists.numel() == 0) {
    AT_CUDA_CHECK(cudaGetLastError());
    return std::make_tuple(dists, idxs);
  }

  const int threads = 128;
  const dim3 blocks(max_objects, batch_size);
  size_t shared_size = threads * sizeof(size_t) + threads * sizeof(int64_t);

  DistanceForwardKernel<<<blocks, threads, shared_size, stream>>>(
      objects.contiguous().data_ptr<float>(),
      objects_size,
      objects_dim,
      targets.contiguous().data_ptr<float>(),
      targets_size,
      targets_dim,
      objects_first_idx.contiguous().data_ptr<int64_t>(),
      targets_first_idx.contiguous().data_ptr<int64_t>(),
      batch_size,
      dists.data_ptr<float>(),
      idxs.data_ptr<int64_t>());

  AT_CUDA_CHECK(cudaGetLastError());
  return std::make_tuple(dists, idxs);
}

std::tuple<at::Tensor, at::Tensor> PointFaceDistanceForwardCuda(
    const at::Tensor& points,
    const at::Tensor& points_first_idx,
    const at::Tensor& tris,
    const at::Tensor& tris_first_idx,
    const int64_t max_points) {
  return DistanceForwardCuda(
      points, 1, points_first_idx, tris, 3, tris_first_idx, max_points);
}

__global__ void PointFaceBackwardKernel(
    const float* __restrict__ points, // (P, 3)
    const float* __restrict__ tris, // (T, 3, 3)
    const int64_t* __restrict__ idx_points, // (P,)
    const float* __restrict__ grad_dists, // (P,)
    float* __restrict__ grad_points, // (P, 3)
    float* __restrict__ grad_tris, // (T, 3, 3)
    const size_t P) {
  float3* points_f3 = (float3*)points;
  float3* tris_f3 = (float3*)tris;

  const size_t tid = blockIdx.x * blockDim.x + threadIdx.x;
  const size_t stride = gridDim.x * blockDim.x;

  for (size_t p = tid; p < P; p += stride) {
    const float3 p_f3 = points_f3[p];

    const int64_t tidx = idx_points[p];
    const float3 v0 = tris_f3[tidx * 3 + 0];
    const float3 v1 = tris_f3[tidx * 3 + 1];
    const float3 v2 = tris_f3[tidx * 3 + 2];

    const float grad_dist = grad_dists[p];

    const auto grads =
        PointTriangle3DistanceBackward(p_f3, v0, v1, v2, grad_dist);
    const float3 grad_point = thrust::get<0>(grads);
    const float3 grad_v0 = thrust::get<1>(grads);
    const float3 grad_v1 = thrust::get<2>(grads);
    const float3 grad_v2 = thrust::get<3>(grads);

    atomicAdd(grad_points + p * 3 + 0, grad_point.x);
    atomicAdd(grad_points + p * 3 + 1, grad_point.y);
    atomicAdd(grad_points + p * 3 + 2, grad_point.z);

    atomicAdd(grad_tris + tidx * 3 * 3 + 0 * 3 + 0, grad_v0.x);
    atomicAdd(grad_tris + tidx * 3 * 3 + 0 * 3 + 1, grad_v0.y);
    atomicAdd(grad_tris + tidx * 3 * 3 + 0 * 3 + 2, grad_v0.z);

    atomicAdd(grad_tris + tidx * 3 * 3 + 1 * 3 + 0, grad_v1.x);
    atomicAdd(grad_tris + tidx * 3 * 3 + 1 * 3 + 1, grad_v1.y);
    atomicAdd(grad_tris + tidx * 3 * 3 + 1 * 3 + 2, grad_v1.z);

    atomicAdd(grad_tris + tidx * 3 * 3 + 2 * 3 + 0, grad_v2.x);
    atomicAdd(grad_tris + tidx * 3 * 3 + 2 * 3 + 1, grad_v2.y);
    atomicAdd(grad_tris + tidx * 3 * 3 + 2 * 3 + 2, grad_v2.z);
  }
}

std::tuple<at::Tensor, at::Tensor> PointFaceDistanceBackwardCuda(
    const at::Tensor& points,
    const at::Tensor& tris,
    const at::Tensor& idx_points,
    const at::Tensor& grad_dists) {
  // Check inputs are on the same device
  at::TensorArg points_t{points, "points", 1},
      idx_points_t{idx_points, "idx_points", 2}, tris_t{tris, "tris", 3},
      grad_dists_t{grad_dists, "grad_dists", 4};
  at::CheckedFrom c = "PointFaceDistanceBackwardCuda";
  at::checkAllSameGPU(c, {points_t, idx_points_t, tris_t, grad_dists_t});
  at::checkAllSameType(c, {points_t, tris_t, grad_dists_t});

  // Set the device for the kernel launch based on the device of the input
  at::cuda::CUDAGuard device_guard(points.device());
  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  const int64_t P = points.size(0);
  const int64_t T = tris.size(0);

  TORCH_CHECK(points.size(1) == 3, "points must be of shape Px3");
  TORCH_CHECK(
      (tris.size(1) == 3) && (tris.size(2) == 3),
      "tris must be of shape Tx3x3");
  TORCH_CHECK(idx_points.size(0) == P);
  TORCH_CHECK(grad_dists.size(0) == P);

  // clang-format off
  at::Tensor grad_points = at::zeros({P, 3}, points.options());
  at::Tensor grad_tris = at::zeros({T, 3, 3}, tris.options());
  // clang-format on

  if (grad_points.numel() == 0 || grad_tris.numel() == 0) {
    AT_CUDA_CHECK(cudaGetLastError());
    return std::make_tuple(grad_points, grad_tris);
  }

  const int blocks = 64;
  const int threads = 512;

  PointFaceBackwardKernel<<<blocks, threads, 0, stream>>>(
      points.contiguous().data_ptr<float>(),
      tris.contiguous().data_ptr<float>(),
      idx_points.contiguous().data_ptr<int64_t>(),
      grad_dists.contiguous().data_ptr<float>(),
      grad_points.data_ptr<float>(),
      grad_tris.data_ptr<float>(),
      P);

  AT_CUDA_CHECK(cudaGetLastError());
  return std::make_tuple(grad_points, grad_tris);
}

// ****************************************************************************
// *                          FacePointDistance                               *
// ****************************************************************************

std::tuple<at::Tensor, at::Tensor> FacePointDistanceForwardCuda(
    const at::Tensor& points,
    const at::Tensor& points_first_idx,
    const at::Tensor& tris,
    const at::Tensor& tris_first_idx,
    const int64_t max_tris) {
  return DistanceForwardCuda(
      tris, 3, tris_first_idx, points, 1, points_first_idx, max_tris);
}

__global__ void FacePointBackwardKernel(
    const float* __restrict__ points, // (P, 3)
    const float* __restrict__ tris, // (T, 3, 3)
    const int64_t* __restrict__ idx_tris, // (T,)
    const float* __restrict__ grad_dists, // (T,)
    float* __restrict__ grad_points, // (P, 3)
    float* __restrict__ grad_tris, // (T, 3, 3)
    const size_t T) {
  float3* points_f3 = (float3*)points;
  float3* tris_f3 = (float3*)tris;

  const size_t tid = blockIdx.x * blockDim.x + threadIdx.x;
  const size_t stride = gridDim.x * blockDim.x;

  for (size_t t = tid; t < T; t += stride) {
    const float3 v0 = tris_f3[t * 3 + 0];
    const float3 v1 = tris_f3[t * 3 + 1];
    const float3 v2 = tris_f3[t * 3 + 2];

    const int64_t pidx = idx_tris[t];

    const float3 p_f3 = points_f3[pidx];

    const float grad_dist = grad_dists[t];

    const auto grads =
        PointTriangle3DistanceBackward(p_f3, v0, v1, v2, grad_dist);
    const float3 grad_point = thrust::get<0>(grads);
    const float3 grad_v0 = thrust::get<1>(grads);
    const float3 grad_v1 = thrust::get<2>(grads);
    const float3 grad_v2 = thrust::get<3>(grads);

    atomicAdd(grad_points + pidx * 3 + 0, grad_point.x);
    atomicAdd(grad_points + pidx * 3 + 1, grad_point.y);
    atomicAdd(grad_points + pidx * 3 + 2, grad_point.z);

    atomicAdd(grad_tris + t * 3 * 3 + 0 * 3 + 0, grad_v0.x);
    atomicAdd(grad_tris + t * 3 * 3 + 0 * 3 + 1, grad_v0.y);
    atomicAdd(grad_tris + t * 3 * 3 + 0 * 3 + 2, grad_v0.z);

    atomicAdd(grad_tris + t * 3 * 3 + 1 * 3 + 0, grad_v1.x);
    atomicAdd(grad_tris + t * 3 * 3 + 1 * 3 + 1, grad_v1.y);
    atomicAdd(grad_tris + t * 3 * 3 + 1 * 3 + 2, grad_v1.z);

    atomicAdd(grad_tris + t * 3 * 3 + 2 * 3 + 0, grad_v2.x);
    atomicAdd(grad_tris + t * 3 * 3 + 2 * 3 + 1, grad_v2.y);
    atomicAdd(grad_tris + t * 3 * 3 + 2 * 3 + 2, grad_v2.z);
  }
}

std::tuple<at::Tensor, at::Tensor> FacePointDistanceBackwardCuda(
    const at::Tensor& points,
    const at::Tensor& tris,
    const at::Tensor& idx_tris,
    const at::Tensor& grad_dists) {
  // Check inputs are on the same device
  at::TensorArg points_t{points, "points", 1},
      idx_tris_t{idx_tris, "idx_tris", 2}, tris_t{tris, "tris", 3},
      grad_dists_t{grad_dists, "grad_dists", 4};
  at::CheckedFrom c = "FacePointDistanceBackwardCuda";
  at::checkAllSameGPU(c, {points_t, idx_tris_t, tris_t, grad_dists_t});
  at::checkAllSameType(c, {points_t, tris_t, grad_dists_t});

  // Set the device for the kernel launch based on the device of the input
  at::cuda::CUDAGuard device_guard(points.device());
  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  const int64_t P = points.size(0);
  const int64_t T = tris.size(0);

  TORCH_CHECK(points.size(1) == 3, "points must be of shape Px3");
  TORCH_CHECK(
      (tris.size(1) == 3) && (tris.size(2) == 3),
      "tris must be of shape Tx3x3");
  TORCH_CHECK(idx_tris.size(0) == T);
  TORCH_CHECK(grad_dists.size(0) == T);

  // clang-format off
  at::Tensor grad_points = at::zeros({P, 3}, points.options());
  at::Tensor grad_tris = at::zeros({T, 3, 3}, tris.options());
  // clang-format on

  if (grad_points.numel() == 0 || grad_tris.numel() == 0) {
    AT_CUDA_CHECK(cudaGetLastError());
    return std::make_tuple(grad_points, grad_tris);
  }

  const int blocks = 64;
  const int threads = 512;

  FacePointBackwardKernel<<<blocks, threads, 0, stream>>>(
      points.contiguous().data_ptr<float>(),
      tris.contiguous().data_ptr<float>(),
      idx_tris.contiguous().data_ptr<int64_t>(),
      grad_dists.contiguous().data_ptr<float>(),
      grad_points.data_ptr<float>(),
      grad_tris.data_ptr<float>(),
      T);

  AT_CUDA_CHECK(cudaGetLastError());
  return std::make_tuple(grad_points, grad_tris);
}

// ****************************************************************************
// *                     PointFaceArrayDistance                               *
// ****************************************************************************

__global__ void PointFaceArrayForwardKernel(
    const float* __restrict__ points, // (P, 3)
    const float* __restrict__ tris, // (T, 3, 3)
    float* __restrict__ dists, // (P, T)
    const size_t P,
    const size_t T) {
  const float3* points_f3 = (float3*)points;
  const float3* tris_f3 = (float3*)tris;

  // Parallelize over P * S computations
  const int num_threads = gridDim.x * blockDim.x;
  const int tid = blockIdx.x * blockDim.x + threadIdx.x;

  for (int t_i = tid; t_i < P * T; t_i += num_threads) {
    const int t = t_i / P; // segment index.
    const int p = t_i % P; // point index
    const float3 v0 = tris_f3[t * 3 + 0];
    const float3 v1 = tris_f3[t * 3 + 1];
    const float3 v2 = tris_f3[t * 3 + 2];

    const float3 point = points_f3[p];
    float dist = PointTriangle3DistanceForward(point, v0, v1, v2);
    dists[p * T + t] = dist;
  }
}

at::Tensor PointFaceArrayDistanceForwardCuda(
    const at::Tensor& points,
    const at::Tensor& tris) {
  // Check inputs are on the same device
  at::TensorArg points_t{points, "points", 1}, tris_t{tris, "tris", 2};
  at::CheckedFrom c = "PointFaceArrayDistanceForwardCuda";
  at::checkAllSameGPU(c, {points_t, tris_t});
  at::checkAllSameType(c, {points_t, tris_t});

  // Set the device for the kernel launch based on the device of the input
  at::cuda::CUDAGuard device_guard(points.device());
  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  const int64_t P = points.size(0);
  const int64_t T = tris.size(0);

  TORCH_CHECK(points.size(1) == 3, "points must be of shape Px3");
  TORCH_CHECK(
      (tris.size(1) == 3) && (tris.size(2) == 3),
      "tris must be of shape Tx3x3");

  at::Tensor dists = at::zeros({P, T}, points.options());

  if (dists.numel() == 0) {
    AT_CUDA_CHECK(cudaGetLastError());
    return dists;
  }

  const size_t blocks = 1024;
  const size_t threads = 64;

  PointFaceArrayForwardKernel<<<blocks, threads, 0, stream>>>(
      points.contiguous().data_ptr<float>(),
      tris.contiguous().data_ptr<float>(),
      dists.data_ptr<float>(),
      P,
      T);

  AT_CUDA_CHECK(cudaGetLastError());
  return dists;
}

__global__ void PointFaceArrayBackwardKernel(
    const float* __restrict__ points, // (P, 3)
    const float* __restrict__ tris, // (T, 3, 3)
    const float* __restrict__ grad_dists, // (P, T)
    float* __restrict__ grad_points, // (P, 3)
    float* __restrict__ grad_tris, // (T, 3, 3)
    const size_t P,
    const size_t T) {
  const float3* points_f3 = (float3*)points;
  const float3* tris_f3 = (float3*)tris;

  // Parallelize over P * S computations
  const int num_threads = gridDim.x * blockDim.x;
  const int tid = blockIdx.x * blockDim.x + threadIdx.x;

  for (int t_i = tid; t_i < P * T; t_i += num_threads) {
    const int t = t_i / P; // triangle index.
    const int p = t_i % P; // point index
    const float3 v0 = tris_f3[t * 3 + 0];
    const float3 v1 = tris_f3[t * 3 + 1];
    const float3 v2 = tris_f3[t * 3 + 2];

    const float3 point = points_f3[p];

    const float grad_dist = grad_dists[p * T + t];
    const auto grad =
        PointTriangle3DistanceBackward(point, v0, v1, v2, grad_dist);

    const float3 grad_point = thrust::get<0>(grad);
    const float3 grad_v0 = thrust::get<1>(grad);
    const float3 grad_v1 = thrust::get<2>(grad);
    const float3 grad_v2 = thrust::get<3>(grad);

    atomicAdd(grad_points + 3 * p + 0, grad_point.x);
    atomicAdd(grad_points + 3 * p + 1, grad_point.y);
    atomicAdd(grad_points + 3 * p + 2, grad_point.z);

    atomicAdd(grad_tris + t * 3 * 3 + 0 * 3 + 0, grad_v0.x);
    atomicAdd(grad_tris + t * 3 * 3 + 0 * 3 + 1, grad_v0.y);
    atomicAdd(grad_tris + t * 3 * 3 + 0 * 3 + 2, grad_v0.z);

    atomicAdd(grad_tris + t * 3 * 3 + 1 * 3 + 0, grad_v1.x);
    atomicAdd(grad_tris + t * 3 * 3 + 1 * 3 + 1, grad_v1.y);
    atomicAdd(grad_tris + t * 3 * 3 + 1 * 3 + 2, grad_v1.z);

    atomicAdd(grad_tris + t * 3 * 3 + 2 * 3 + 0, grad_v2.x);
    atomicAdd(grad_tris + t * 3 * 3 + 2 * 3 + 1, grad_v2.y);
    atomicAdd(grad_tris + t * 3 * 3 + 2 * 3 + 2, grad_v2.z);
  }
}

std::tuple<at::Tensor, at::Tensor> PointFaceArrayDistanceBackwardCuda(
    const at::Tensor& points,
    const at::Tensor& tris,
    const at::Tensor& grad_dists) {
  // Check inputs are on the same device
  at::TensorArg points_t{points, "points", 1}, tris_t{tris, "tris", 2},
      grad_dists_t{grad_dists, "grad_dists", 3};
  at::CheckedFrom c = "PointFaceArrayDistanceBackwardCuda";
  at::checkAllSameGPU(c, {points_t, tris_t, grad_dists_t});
  at::checkAllSameType(c, {points_t, tris_t, grad_dists_t});

  // Set the device for the kernel launch based on the device of the input
  at::cuda::CUDAGuard device_guard(points.device());
  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  const int64_t P = points.size(0);
  const int64_t T = tris.size(0);

  TORCH_CHECK(points.size(1) == 3, "points must be of shape Px3");
  TORCH_CHECK(
      (tris.size(1) == 3) && (tris.size(2) == 3),
      "tris must be of shape Tx3x3");
  TORCH_CHECK((grad_dists.size(0) == P) && (grad_dists.size(1) == T));

  at::Tensor grad_points = at::zeros({P, 3}, points.options());
  at::Tensor grad_tris = at::zeros({T, 3, 3}, tris.options());

  if (grad_points.numel() == 0 || grad_tris.numel() == 0) {
    AT_CUDA_CHECK(cudaGetLastError());
    return std::make_tuple(grad_points, grad_tris);
  }

  const size_t blocks = 1024;
  const size_t threads = 64;

  PointFaceArrayBackwardKernel<<<blocks, threads, 0, stream>>>(
      points.contiguous().data_ptr<float>(),
      tris.contiguous().data_ptr<float>(),
      grad_dists.contiguous().data_ptr<float>(),
      grad_points.data_ptr<float>(),
      grad_tris.data_ptr<float>(),
      P,
      T);

  AT_CUDA_CHECK(cudaGetLastError());
  return std::make_tuple(grad_points, grad_tris);
}
