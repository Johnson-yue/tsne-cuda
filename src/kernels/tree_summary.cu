/*
        Summarize position and mass of cells in quad-tree.
*/

#include "include/kernels/tree_summary.h"

/******************************************************************************/
/*** compute center of mass ***************************************************/
/******************************************************************************/

__global__
void tsnecuda::bh::SummarizationKernel(
                               volatile int * __restrict cell_counts, 
                               volatile float * __restrict cell_mass, 
                               volatile float * __restrict x_pos_device, 
                               volatile float * __restrict y_pos_device,
                               const int * __restrict children,
                               const int num_nodes,
                               const int num_points,
                               const int gpu_summary_threads) 
{
    register int i, j, k, ch, inc, cnt, bottom, flag;
    register float m, cm, px, py;
    extern __shared__ int summary_shared_memory[];
    int* child = (int*) summary_shared_memory;
    float* mass = (float*) (child + 4*gpu_summary_threads);

    bottom = bottomd;
    inc = blockDim.x * gridDim.x;
    k = (bottom & (-32)) + threadIdx.x + blockIdx.x * blockDim.x;    // align to warp size
    if (k < bottom) k += inc;

    register int restart = k;
    for (j = 0; j < 5; j++) {    // wait-free pre-passes
        // iterate over all cells assigned to thread
        while (k <= num_nodes) {
            if (cell_mass[k] < 0.0f) {
                for (i = 0; i < 4; i++) {
                    ch = children[k*4+i];
                    child[i*gpu_summary_threads+threadIdx.x] = ch;    // cache children
                    if ((ch >= num_points) && ((mass[i*gpu_summary_threads+threadIdx.x] = cell_mass[ch]) < 0.0f)) {
                        break;
                    }
                }
                if (i == 4) {
                    // all children are ready
                    cm = 0.0f;
                    px = 0.0f;
                    py = 0.0f;
                    cnt = 0;
                    for (i = 0; i < 4; i++) {
                        ch = child[i*gpu_summary_threads+threadIdx.x];
                        if (ch >= 0) {
                            if (ch >= num_points) {    // count bodies (needed later)
                                m = mass[i*gpu_summary_threads+threadIdx.x];
                                cnt += cell_counts[ch];
                            } else {
                                m = cell_mass[ch];
                                cnt++;
                            }
                            // add child's contribution
                            cm += m;
                            px += x_pos_device[ch] * m;
                            py += y_pos_device[ch] * m;
                        }
                    }
                    cell_counts[k] = cnt;
                    m = 1.0f / cm;
                    x_pos_device[k] = px * m;
                    y_pos_device[k] = py * m;
                    __threadfence();    // make sure data are visible before setting mass
                    cell_mass[k] = cm;
                }
            }
            k += inc;    // move on to next cell
        }
        k = restart;
    }

    flag = 0;
    j = 0;
    // iterate over all cells assigned to thread
    while (k <= num_nodes) {
        if (cell_mass[k] >= 0.0f) {
            k += inc;
        } else {
            if (j == 0) {
                j = 4;
                for (i = 0; i < 4; i++) {
                    ch = children[k*4+i];
                    child[i*gpu_summary_threads+threadIdx.x] = ch;    // cache children
                    if ((ch < num_points) || ((mass[i*gpu_summary_threads+threadIdx.x] = cell_mass[ch]) >= 0.0f)) {
                        j--;
                    }
                }
            } else {
                j = 4;
                for (i = 0; i < 4; i++) {
                    ch = child[i*gpu_summary_threads+threadIdx.x];
                    if ((ch < num_points) || (mass[i*gpu_summary_threads+threadIdx.x] >= 0.0f) || ((mass[i*gpu_summary_threads+threadIdx.x] = cell_mass[ch]) >= 0.0f)) {
                        j--;
                    }
                }
            }

            if (j == 0) {
                // all children are ready
                cm = 0.0f;
                px = 0.0f;
                py = 0.0f;
                cnt = 0;
                for (i = 0; i < 4; i++) {
                    ch = child[i*gpu_summary_threads+threadIdx.x];
                    if (ch >= 0) {
                        if (ch >= num_points) {    // count bodies (needed later)
                            m = mass[i*gpu_summary_threads+threadIdx.x];
                            cnt += cell_counts[ch];
                        } else {
                            m = cell_mass[ch];
                            cnt++;
                        }
                        // add child's contribution
                        cm += m;
                        px += x_pos_device[ch] * m;
                        py += y_pos_device[ch] * m;
                    }
                }
                cell_counts[k] = cnt;
                m = 1.0f / cm;
                x_pos_device[k] = px * m;
                y_pos_device[k] = py * m;
                flag = 1;
            }
        }
        __syncthreads();    
        __threadfence();
        if (flag != 0) {
            cell_mass[k] = cm;
            k += inc;
            flag = 0;
        }
    }
}

void tsnecuda::bh::SummarizeTree(tsnecuda::GpuOptions &gpu_opt,
                                 thrust::device_vector<int> &cell_counts,
                                 thrust::device_vector<int> &children,
                                 thrust::device_vector<float> &cell_mass,
                                 thrust::device_vector<float> &pts_device,
                                 const int num_nodes,
                                 const int num_points,
                                 const int num_blocks)
{
    tsnecuda::bh::SummarizationKernel<<<num_blocks * gpu_opt.summary_kernel_factor,
                                        gpu_opt.summary_kernel_threads,
                                        sizeof(int)*4*gpu_opt.summary_kernel_threads + 
                                        sizeof(float)*4*gpu_opt.summary_kernel_threads>>>(
                                                    thrust::raw_pointer_cast(cell_counts.data()),
                                                    thrust::raw_pointer_cast(cell_mass.data()),
                                                    thrust::raw_pointer_cast(pts_device.data()),
                                                    thrust::raw_pointer_cast(pts_device.data() + num_nodes + 1),
                                                    thrust::raw_pointer_cast(children.data()),
                                                    num_nodes, num_points,
                                                    gpu_opt.summary_kernel_threads);
    GpuErrorCheck(cudaDeviceSynchronize());
}
