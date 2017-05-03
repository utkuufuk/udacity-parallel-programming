#include "reference_calc.cpp"
#include "utils.h"
#include <stdio.h>

#define BLOCK_ROWS 32
#define BLOCK_COLS 32

unsigned char *d_red, *d_green, *d_blue;
float         *d_filter;

__global__
void gaussianBlur(const unsigned char* const inputChannel,
                  unsigned char* const outputChannel,
                  int numRows, 
                  int numCols,
                  const float* const filter, 
                  const int filterWidth)
{		
    __shared__ float result;
    
	if (threadIdx.x == 0 && threadIdx.y == 0)
	{
		result = 0;
	}
	__syncthreads();

	int threadRowOffset = (-filterWidth / 2) + threadIdx.y; 
	int threadColOffset = (-filterWidth / 2) + threadIdx.x;
	int threadPixelRows = min(max(blockIdx.y + threadRowOffset, 0), static_cast<int>(numRows - 1));
	int threadPixelCols = min(max(blockIdx.x + threadColOffset, 0), static_cast<int>(numCols - 1));
	
	int sourcePixelIndex = blockIdx.y * numCols + blockIdx.x;
	int threadPixelIndex = threadPixelRows * numCols + threadPixelCols;
	int filterIndex = threadIdx.y * filterWidth + threadIdx.x;
	
	atomicAdd(&result, inputChannel[threadPixelIndex] * filter[filterIndex]);
	__syncthreads();
	
	if (threadIdx.x == 0 && threadIdx.y == 0)
	{
		outputChannel[sourcePixelIndex] = result;
	}
}

__global__
void separateChannels(const uchar4* const inputImageRGBA,
                      int numRows,
                      int numCols,
                      unsigned char* const redChannel,
                      unsigned char* const greenChannel,
                      unsigned char* const blueChannel)
{	
	const int2 threadIndex2D = make_int2(blockIdx.x * blockDim.x + threadIdx.x,
                                         blockIdx.y * blockDim.y + threadIdx.y);

	const int index = threadIndex2D.y * numCols + threadIndex2D.x;

    // avoid accessing the memory outside the image by having any threads mapped there return early
	if (threadIndex2D.x >= numCols || threadIndex2D.y >= numRows)
    { 
		return;
	}
	uchar4 rgba = inputImageRGBA[index];				
	redChannel[index] = rgba.x;
	greenChannel[index] = rgba.y;
	blueChannel[index] = rgba.z;
}

__global__
void recombineChannels(const unsigned char* const redChannel,
                       const unsigned char* const greenChannel,
                       const unsigned char* const blueChannel,
                       uchar4* const outputImageRGBA,
                       int numRows,
                       int numCols)
{
	const int2 thread_2D_pos = make_int2(blockIdx.x * blockDim.x + threadIdx.x, 
                                         blockIdx.y * blockDim.y + threadIdx.y);
	const int thread_1D_pos = thread_2D_pos.y * numCols + thread_2D_pos.x;

    // avoid accessing the memory outside the image by having any threads mapped there return early
	if (thread_2D_pos.x >= numCols || thread_2D_pos.y >= numRows)
	{
		return;
	}

	unsigned char red   = redChannel[thread_1D_pos];
	unsigned char green = greenChannel[thread_1D_pos];
	unsigned char blue  = blueChannel[thread_1D_pos];

	//Alpha should be 255 for no transparency
	uchar4 outputPixel = make_uchar4(red, green, blue, 255);
	outputImageRGBA[thread_1D_pos] = outputPixel;
}

void allocateMemoryAndCopyToGPU(const size_t numRowsImage, const size_t numColsImage,
                                const float* const h_filter, const size_t filterWidth)
{
	checkCudaErrors(cudaMalloc(&d_red,   sizeof(unsigned char) * numRowsImage * numColsImage));
	checkCudaErrors(cudaMalloc(&d_green, sizeof(unsigned char) * numRowsImage * numColsImage));
	checkCudaErrors(cudaMalloc(&d_blue,  sizeof(unsigned char) * numRowsImage * numColsImage));

    size_t filterMemSize = filterWidth * filterWidth * sizeof(float);
	checkCudaErrors(cudaMalloc(&d_filter, filterMemSize));
	checkCudaErrors(cudaMemcpy(d_filter, h_filter, filterMemSize, cudaMemcpyHostToDevice));
}

void your_gaussian_blur(const uchar4* const h_inputRGBA, 
                        uchar4* const d_inputRGBA,
                        uchar4* const d_outputRGBA, 
                        const size_t numRows, 
                        const size_t numCols,
                        unsigned char *d_redBlur, 
                        unsigned char *d_greenBlur, 
                        unsigned char *d_blueBlur,
                        const int filterWidth)
{
	// görüntü boyutu 32x32 nin tam katı olmadığı için gereğinden fazla thread oluşturmak gerekiyor
	const dim3 threads(BLOCK_COLS, BLOCK_ROWS);
	const dim3 blocks(1 + (numCols / threads.x), 1 + (numRows / threads.y));
	printf("Threads: %dx%d Blocks: %dx%d\n", threads.x, threads.y, blocks.x, blocks.y);

	separateChannels<<<blocks, threads>>>(d_inputRGBA, numRows, numCols, d_red, d_green, d_blue);
	cudaDeviceSynchronize(); 
	checkCudaErrors(cudaGetLastError());

	const dim3 blockSize(filterWidth, filterWidth);
	const dim3 gridSize(numCols, numRows);
	printf("Block size: %dx%d Grid Size: %dx%d\n", blockSize.x, blockSize.y, gridSize.x, gridSize.y);
	
	gaussianBlur<<<gridSize, blockSize>>>(d_red, d_redBlur, numRows, numCols, d_filter, filterWidth);
	gaussianBlur<<<gridSize, blockSize>>>(d_green, d_greenBlur, numRows, numCols, d_filter, filterWidth);
	gaussianBlur<<<gridSize, blockSize>>>(d_blue, d_blueBlur, numRows, numCols, d_filter, filterWidth);
	cudaDeviceSynchronize(); 
	checkCudaErrors(cudaGetLastError());
	
	recombineChannels<<<blocks, threads>>>
                     (d_redBlur, d_greenBlur, d_blueBlur, d_outputRGBA, numRows, numCols);
	cudaDeviceSynchronize(); 
	checkCudaErrors(cudaGetLastError());
}

void cleanup() 
{
	checkCudaErrors(cudaFree(d_red));
	checkCudaErrors(cudaFree(d_green));
	checkCudaErrors(cudaFree(d_blue));
	checkCudaErrors(cudaFree(d_filter));
}
