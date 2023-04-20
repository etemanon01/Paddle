/* Copyright (c) 2022 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#ifdef PADDLE_WITH_HETERPS
#include <algorithm>
#include <ctime>
#include <memory>
#include <numeric>
#include "paddle/fluid/framework/fleet/heter_ps/optimizer_conf.h"
#include "paddle/fluid/framework/lod_tensor.h"
#include "paddle/fluid/platform/device/gpu/gpu_info.h"
#include "paddle/fluid/framework/fleet/heter_ps/feature_value.h"
namespace paddle {
namespace framework {

template <typename GPUAccessor>
__global__ void PullCopy(float** dest,
                         const float* src,
                         const int64_t* len,
                         int slot_num,
                         int total_len,
                         uint64_t** keys,
                         uint64_t max_val_size,
                         int* gpu_dim,
                         GPUAccessor gpu_accessor) {
  
  CUDA_KERNEL_LOOP(i, total_len) {
    int low = 0;
    int high = slot_num - 1;
    while (low < high) {
      int mid = (low + high) / 2;
      if (i < len[mid])
        high = mid;
      else
        low = mid + 1;
    }
    int x = low;
    int y = i - (x ? len[x - 1] : 0);

    float* feature_value_ptr =
        (float*)((char*)src + uint64_t(i) * uint64_t(max_val_size));
    int mf_dim = gpu_dim[x] - 3;

    gpu_accessor.Select(
        dest[x] + y * (mf_dim + 3), feature_value_ptr, keys[x] + y, mf_dim);
  }
}

template <typename GPUAccessor>
__global__ void PushCopyWithPool(float* dest,
                                 float** src,
                                 int64_t* len,
                                 int slot_num,
                                 uint64_t total_len,
                                 int bs,
                                 int* slot_vector,
                                 int* mf_dim_vector,
                                 size_t grad_value_size,
                                 GPUAccessor gpu_accessor) {

  CUDA_KERNEL_LOOP(i, total_len) {
    int low = 0;
    int high = slot_num - 1;
    while (low < high) {
      int mid = (low + high) / 2;
      if (i < len[mid])
        high = mid;
      else
        low = mid + 1;
    }
    int x = low;
    int y = i - (x ? len[low - 1] : 0);
    float* cur =
        (float*)((char*)dest + i * grad_value_size);
   
    int mf_dim = mf_dim_vector[x];  // slot_vector holds both slot and
                                    // slot:mf_dim information
    gpu_accessor.GradientSelect(cur, src[x] + y * (mf_dim + 3), slot_vector[x], mf_dim, bs);
  }
}

template <typename GPUAccessor>
void AccessorWrapper<GPUAccessor>::CopyForPull(const paddle::platform::Place& place,
                                               uint64_t** gpu_keys,
                                               const std::vector<float*>& values,
                                               const float* total_values_gpu,
                                               const int64_t* gpu_len,
                                               const int slot_num,
                                               const int hidden_size,
                                               const int64_t total_length,
                                               int* gpu_dim,
                                               size_t val_type_size) {
  auto stream = dynamic_cast<platform::CUDADeviceContext*>(
                    platform::DeviceContextPool::Instance().Get(place))
                    ->stream();
  auto buf_value = memory::Alloc(place, values.size() * sizeof(float*));
  float** gpu_values = reinterpret_cast<float**>(buf_value->ptr());
  cudaMemcpy(gpu_values, values.data(), values.size() * sizeof(float*),
             cudaMemcpyHostToDevice);
  PullCopy<<<(total_length + 1024 - 1) / 1024, 1024, 0, stream>>>(
        gpu_values, total_values_gpu, gpu_len, slot_num, total_length, gpu_keys,
        val_type_size, gpu_dim, gpu_accessor_);
  cudaStreamSynchronize(stream);
}

template <typename GPUAccessor>
void AccessorWrapper<GPUAccessor>::CopyForPush(const paddle::platform::Place& place,
                                               const std::vector<const float*>& grad_values,
                                               float* total_grad_values_gpu,
                                               const std::vector<int64_t>& slot_lengths,
                                               const uint64_t total_length,
                                               const int batch_size,
                                               size_t grad_value_size,
                                               std::vector<int>& slot_vector,
                                               std::vector<int>& slot_mf_dim_vector) {

  auto stream = dynamic_cast<platform::CUDADeviceContext*>(
                    platform::DeviceContextPool::Instance().Get(place))
                    ->stream();
  auto slot_lengths_lod = slot_lengths;
  for (int i = 1; i < slot_lengths_lod.size(); i++) {
    slot_lengths_lod[i] += slot_lengths_lod[i - 1];
  }
  auto buf_grad_value =
      memory::Alloc(place, grad_values.size() * sizeof(float*));
  auto buf_length =
      memory::Alloc(place, slot_lengths.size() * sizeof(int64_t));
  auto buf_slot_vector =
      memory::Alloc(place, slot_lengths_lod.size() * sizeof(int));
  auto buf_mf_dim_vector =
      memory::Alloc(place, slot_lengths_lod.size() * sizeof(int));

  float** gpu_values = reinterpret_cast<float**>(buf_grad_value->ptr());
  int64_t* gpu_len = reinterpret_cast<int64_t*>(buf_length->ptr());
  int* d_slot_vector = reinterpret_cast<int*>(buf_slot_vector->ptr());
  int* d_mf_dim_vector = reinterpret_cast<int*>(buf_mf_dim_vector->ptr());

  cudaMemcpy(gpu_values, grad_values.data(),
             grad_values.size() * sizeof(float*), cudaMemcpyHostToDevice);
  cudaMemcpy(gpu_len, slot_lengths_lod.data(),
             slot_lengths.size() * sizeof(int64_t), cudaMemcpyHostToDevice);
  cudaMemcpy(d_slot_vector, slot_vector.data(),
             slot_lengths_lod.size() * sizeof(int), cudaMemcpyHostToDevice);
  cudaMemcpy(d_mf_dim_vector, slot_mf_dim_vector.data(),
             slot_lengths_lod.size() * sizeof(int), cudaMemcpyHostToDevice);

  PushCopyWithPool<<<(total_length + 1024 - 1) / 1024, 1024, 0, stream>>>(
      total_grad_values_gpu, gpu_values, gpu_len, slot_lengths.size(),
      total_length, batch_size, d_slot_vector, d_mf_dim_vector,
      grad_value_size, gpu_accessor_);

  cudaStreamSynchronize(stream);
}

#ifdef PADDLE_WITH_PSLIB
template class AccessorWrapper<CommonFeatureValueAccessor>;
#endif



}  // end namespace framework
}  // end namespace paddle
#endif