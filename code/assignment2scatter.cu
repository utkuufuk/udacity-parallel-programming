#include "reference_calc.cpp"
#include "utils.h"
#include <stdio.h>

#define BLOCK_ROWS 32
#define BLOCK_COLS 32

unsigned char *d_red, *d_green, *d_blue;
float         *d_filter;
int 		  *d_redTemp, *d_greenTemp, *d_blueTemp;

__global__
void gaussian_blur(const unsigned char* const inputChannel,
                   int* outputChannel,
                   int numRows, 
				   int numCols,
                   const float* const filter, 
				   const int filterWidth)
{		
	int threadRowOffset = (-filterWidth / 2) + threadIdx.y; 
	int threadColOffset = (-filterWidth / 2) + threadIdx.x;
	int outputPixelRows = min(max(blockIdx.y + threadRowOffset, 0), static_cast<int>(numRows - 1));
	int outputPixelCols = min(max(blockIdx.x + threadColOffset, 0), static_cast<int>(numCols - 1));
	
	int sourcePixelIndex = blockIdx.y * numCols + blockIdx.x;
	int outputPixelIndex = outputPixelRows * numCols + outputPixelCols;
	int filterIndex = threadIdx.y * filterWidth + threadIdx.x;
	
	float source = static_cast<float>(inputChannel[sourcePixelIndex]);
	atomicAdd(&outputChannel[outputPixelIndex], (int) (source * filter[filterIndex]));
}

__global__
void dalga(unsigned char* const outputChannel, int* inputChannel, int numRows, int numCols)
{	
	const int2 threadIndex2D = make_int2(blockIdx.x * blockDim.x + threadIdx.x,blockIdx.y * blockDim.y + threadIdx.y);
	const int index = threadIndex2D.y * numCols + threadIndex2D.x;

	//make sure we don't try and access memory outside the image by having any threads mapped there return early
	if (threadIndex2D.x >= numCols || threadIndex2D.y >= numRows)
    {
		return;
	}
	outputChannel[index] = inputChannel[index];
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

	//make sure we don't try and access memory outside the image by having any threads mapped there return early
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
	const int2 thread_2D_pos = make_int2( blockIdx.x * blockDim.x + threadIdx.x, blockIdx.y * blockDim.y + threadIdx.y);
	const int thread_1D_pos = thread_2D_pos.y * numCols + thread_2D_pos.x;

	//make sure we don't try and access memory outside the image by having any threads mapped there return early
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
	
	checkCudaErrors(cudaMalloc(&d_redTemp, sizeof(int) * numRowsImage * numColsImage));
	checkCudaErrors(cudaMalloc(&d_greenTemp, sizeof(int) * numRowsImage * numColsImage));
	checkCudaErrors(cudaMalloc(&d_blueTemp, sizeof(int) * numRowsImage * numColsImage));
	
	checkCudaErrors(cudaMemset(d_redTemp, 0, sizeof(int) * numRowsImage * numColsImage));
	checkCudaErrors(cudaMemset(d_greenTemp, 0, sizeof(int) * numRowsImage * numColsImage));
	checkCudaErrors(cudaMemset(d_blueTemp, 0, sizeof(int) * numRowsImage * numColsImage));

	checkCudaErrors(cudaMalloc(&d_filter, sizeof(float) * filterWidth * filterWidth));
	checkCudaErrors(cudaMemcpy(d_filter, h_filter, sizeof(float) * filterWidth * filterWidth, cudaMemcpyHostToDevice));
	
	/*
	printf("Filter width: %d\n", filterWidth);
	
	int r, c;
	printf("Filter: ");
	for (r = 0; r < filterWidth; r++)
	{
		for (c = 0; c < filterWidth; c++)
		{
			printf("%f ", h_filter[r * filterWidth + c]);
		}
		printf("\n");
	}
	printf("\n\n");
	*/
}

void your_gaussian_blur(const uchar4 * const h_inputImageRGBA, 
						uchar4 * const d_inputImageRGBA,
                        uchar4* const d_outputImageRGBA, 
						const size_t numRows, 
						const size_t numCols,
                        unsigned char *d_redBlurred, 
                        unsigned char *d_greenBlurred, 
                        unsigned char *d_blueBlurred,
                        const int filterWidth)
{
	// görüntü boyutu 32x32 nin tam katı olmadığı için gereğinden fazla thread oluşturmak gerekiyor
	const dim3 threadsPerBlock(BLOCK_COLS, BLOCK_ROWS);
	const dim3 numBlocks(1 + (numCols / threadsPerBlock.x), 1 + (numRows / threadsPerBlock.y));
	printf("Block size: %dx%d Grid Size: %dx%d\n", threadsPerBlock.x, threadsPerBlock.y, numBlocks.x, numBlocks.y);

	separateChannels<<<numBlocks, threadsPerBlock>>>(d_inputImageRGBA, numRows, numCols, d_red, d_green, d_blue);
	cudaDeviceSynchronize(); 
	checkCudaErrors(cudaGetLastError());

	const dim3 blockSize(filterWidth, filterWidth);
	const dim3 gridSize(numCols, numRows);
	printf("Block size: %dx%d Grid Size: %dx%d\n", blockSize.x, blockSize.y, gridSize.x, gridSize.y);
	
	gaussian_blur<<<gridSize, blockSize>>>(d_red, d_redTemp, numRows, numCols, d_filter, filterWidth);
	gaussian_blur<<<gridSize, blockSize>>>(d_green, d_greenTemp, numRows, numCols, d_filter, filterWidth);
	gaussian_blur<<<gridSize, blockSize>>>(d_blue, d_blueTemp, numRows, numCols, d_filter, filterWidth);
	cudaDeviceSynchronize(); 
	checkCudaErrors(cudaGetLastError());
	
	dalga<<<numBlocks, threadsPerBlock>>>(d_redBlurred, d_redTemp, numRows, numCols);
	dalga<<<numBlocks, threadsPerBlock>>>(d_greenBlurred, d_greenTemp, numRows, numCols);
	dalga<<<numBlocks, threadsPerBlock>>>(d_blueBlurred, d_blueTemp, numRows, numCols);
	
	cudaDeviceSynchronize(); 
	checkCudaErrors(cudaGetLastError());
	
	recombineChannels<<<numBlocks, threadsPerBlock>>>(d_redBlurred, d_greenBlurred, d_blueBlurred, d_outputImageRGBA, numRows, numCols);
	cudaDeviceSynchronize(); 
	checkCudaErrors(cudaGetLastError());
}

void cleanup() 
{
	checkCudaErrors(cudaFree(d_red));
	checkCudaErrors(cudaFree(d_green));
	checkCudaErrors(cudaFree(d_blue));
	checkCudaErrors(cudaFree(d_redTemp));
	checkCudaErrors(cudaFree(d_greenTemp));
	checkCudaErrors(cudaFree(d_blueTemp));
	checkCudaErrors(cudaFree(d_filter));
}
