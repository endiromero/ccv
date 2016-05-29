#include <ccv.h>
#include <ccv_internal.h>
#include <nnc/ccv_nnc.h>
#include <nnc/ccv_nnc_easy.h>
#include <nnc/ccv_nnc_internal.h>

// The header for CUDA related objects.
#include "ccv_nnc_cmd.h"

// nvcc is a C++ compiler, need to specify this is a "C" function to avoid name mangling.
extern "C" void ccv_nnc_gpu_cudnn_init(ccv_nnc_cmd_api_t cmd_api[]);

#ifdef HAVE_CUDNN

#define checkCUDNN(status) {                                      \
	if (status != CUDNN_STATUS_SUCCESS) {                         \
		printf("%s:%d\nCUDNN failure\nError: %s\n",               \
				__FILE__, __LINE__, cudnnGetErrorString(status)); \
		cudaDeviceReset();                                        \
		exit(EXIT_FAILURE);                                       \
	}                                                             \
}

/**
 * Unfortunately, I don't want to deal with stdc++ issue, therefore, cannot have nice things such as
 * RAII behavior to allocate and deallocate descriptor, the reason to use tensor descriptor inline
 * is to avoid any dynamic allocations when having long-running graph operations (such as SGD solver).
 */

typedef struct {
	const ccv_nnc_stream_context_t* stream_context;
	cudnnTensorDescriptor_t descriptor;
	ccv_numeric_data_t data;
} ccv_nnc_cudnn_tensor_view_descriptor_t;

static ccv_nnc_cudnn_tensor_view_descriptor_t _ccv_nnc_cudnn_get_tensor_view_descriptor(const ccv_nnc_stream_context_t* stream_context, const ccv_nnc_tensor_view_t* tensor)
{
	ccv_nnc_cudnn_tensor_view_descriptor_t tensor_desc = {
		stream_context,
		ccv_nnc_stream_context_get_tensor_descriptor(stream_context),
		tensor->data,
	};
	// N is the outer one nevertheless.
	assert(tensor->info.format == CCV_TENSOR_FORMAT_NCHW || tensor->info.format == CCV_TENSOR_FORMAT_NHWC);
	// Fill up dimensions with 1s.
	int dim[CCV_NNC_MAX_DIM_ALLOC] = {0};
	int i;
	const int nd = CCV_NNC_MAX_DIM + 2;
	// This has to follow NCHW
	if (tensor->info.format == CCV_TENSOR_FORMAT_NCHW)
		for (i = 0; i < nd; i++)
			dim[i] = ccv_max(1, tensor->info.dim[nd - 1 - i]);
	else if (tensor->info.format == CCV_TENSOR_FORMAT_NHWC) {
		dim[0] = ccv_max(1, tensor->info.dim[nd - 1]);
		dim[1] = ccv_max(1, tensor->info.dim[0]);
		for (i = 2; i < nd; i++)
			dim[i] = ccv_max(1, tensor->info.dim[nd - i]);
	}
	const int* inc = CCV_IS_TENSOR_VIEW(tensor) ? tensor->inc : tensor->info.dim;
	int stride[CCV_NNC_MAX_DIM_ALLOC];
	stride[nd - 1] = 1;
	// Compute the stride from inc, so it will fit the tensor view.
	if (tensor->info.format == CCV_TENSOR_FORMAT_NCHW)
		for (i = 1; i < CCV_NNC_MAX_DIM_ALLOC && dim[i] > 0; i++)
			stride[nd - 1 - i] = stride[nd - i] * ccv_max(1, inc[i - 1]);
	else if (tensor->info.format == CCV_TENSOR_FORMAT_NHWC) {
		stride[1] = 1;
		stride[nd - 1] = ccv_max(1, inc[0]);
		for (i = 0; i < nd - 3; i++)
			stride[nd - 2 - i] = stride[nd - 1 - i] * ccv_max(1, inc[i + 1]);
		stride[0] = stride[2] * ccv_max(1, inc[nd - 2]);
	}
	cudnnSetTensorNdDescriptor(tensor_desc.descriptor, CUDNN_DATA_FLOAT, nd, dim, stride);
	return tensor_desc;
}

static void _ccv_nnc_cudnn_deinit_tensor_view_descriptor(const ccv_nnc_cudnn_tensor_view_descriptor_t tensor_desc)
{
	ccv_nnc_stream_context_return_tensor_descriptor(tensor_desc.stream_context, tensor_desc.descriptor);
}

typedef struct {
	const ccv_nnc_stream_context_t* stream_context;
	cudnnFilterDescriptor_t descriptor;
	ccv_numeric_data_t data;
} ccv_nnc_cudnn_filter_descriptor_t;

static ccv_nnc_cudnn_filter_descriptor_t _ccv_nnc_cudnn_get_filter_descriptor(const ccv_nnc_stream_context_t* stream_context, const ccv_nnc_tensor_t* tensor)
{
	ccv_nnc_cudnn_filter_descriptor_t filter_desc = {
		stream_context,
		ccv_nnc_stream_context_get_filter_descriptor(stream_context),
		tensor->data,
	};
	assert(!CCV_IS_TENSOR_VIEW(tensor));
	int nd = ccv_nnc_tensor_nd(tensor->info);
	int dim[CCV_NNC_MAX_DIM_ALLOC] = {0};
	int i;
	// Reorder since nnc have different idea about NCHW and NHWC (N is in 3, C is in 0).
	if (tensor->info.format == CCV_TENSOR_FORMAT_NCHW)
	{
		for (i = 0; i < nd; i++)
			dim[i] = tensor->info.dim[nd - 1 - i];
		cudnnSetFilterNdDescriptor(filter_desc.descriptor, CUDNN_DATA_FLOAT, CUDNN_TENSOR_NCHW, nd, dim);
	} else if (tensor->info.format == CCV_TENSOR_FORMAT_NHWC) {
		dim[0] = tensor->info.dim[nd - 1];
		dim[1] = tensor->info.dim[0];
		for (i = 2; i < nd; i++)
			dim[i] = tensor->info.dim[nd - i];
		cudnnSetFilterNdDescriptor(filter_desc.descriptor, CUDNN_DATA_FLOAT, CUDNN_TENSOR_NHWC, nd, dim);
	}
	return filter_desc;
}

static void _ccv_nnc_cudnn_deinit_filter_descriptor(const ccv_nnc_cudnn_filter_descriptor_t filter_desc)
{
	ccv_nnc_stream_context_return_filter_descriptor(filter_desc.stream_context, filter_desc.descriptor);
}

static int _ccv_nnc_format_transform(const ccv_nnc_cmd_t cmd, const ccv_nnc_hint_t hint, const int flags, ccv_nnc_tensor_t* const* inputs, const int input_size, ccv_nnc_tensor_t** outputs, const int output_size, const ccv_nnc_stream_context_t* stream_context)
{
	assert(output_size == input_size);
	int i;
	cudnnHandle_t cudnn = ccv_nnc_stream_context_get_cudnn(stream_context);
	int device = ccv_nnc_stream_context_get_device(stream_context);
	cudaSetDevice(device);
	for (i = 0; i < input_size; i++)
	{
		const ccv_nnc_cudnn_tensor_view_descriptor_t a = _ccv_nnc_cudnn_get_tensor_view_descriptor(stream_context, (const ccv_nnc_tensor_view_t*)inputs[i]);
		const ccv_nnc_cudnn_tensor_view_descriptor_t b = _ccv_nnc_cudnn_get_tensor_view_descriptor(stream_context, (const ccv_nnc_tensor_view_t*)outputs[i]);
		const float one = 1, zero = 0;
		cudnnTransformTensor(cudnn, &one, a.descriptor, a.data.u8, &zero, b.descriptor, b.data.u8);
		_ccv_nnc_cudnn_deinit_tensor_view_descriptor(a);
		_ccv_nnc_cudnn_deinit_tensor_view_descriptor(b);
	}
	return CCV_NNC_EXEC_SUCCESS;
}

typedef struct {
	const ccv_nnc_stream_context_t* stream_context;
	cudnnConvolutionDescriptor_t descriptor;
} ccv_nnc_cudnn_convolution_descriptor_t;

static ccv_nnc_cudnn_convolution_descriptor_t _ccv_nnc_cudnn_get_convolution_descriptor(const ccv_nnc_stream_context_t* stream_context, const ccv_nnc_hint_t hint)
{
	ccv_nnc_cudnn_convolution_descriptor_t convolution_desc = {
		stream_context,
		ccv_nnc_stream_context_get_convolution_descriptor(stream_context),
	};
	int i;
	int p[CCV_NNC_MAX_DIM];
	for (i = 0; i < CCV_NNC_MAX_DIM; i++)
		p[i] = ccv_max(hint.border.begin[CCV_NNC_MAX_DIM - i], hint.border.end[CCV_NNC_MAX_DIM - i]);
	int v[CCV_NNC_MAX_DIM];
	for (i = 0; i < CCV_NNC_MAX_DIM; i++)
		v[i] = hint.stride.dim[CCV_NNC_MAX_DIM - i];
	int u[CCV_NNC_MAX_DIM];
	for (i = 0; i < CCV_NNC_MAX_DIM; i++)
		u[i] = 1;
	cudnnSetConvolutionNdDescriptor(convolution_desc.descriptor, CCV_NNC_MAX_DIM, p, v, u, CUDNN_CROSS_CORRELATION, CUDNN_DATA_FLOAT);
	return convolution_desc;
}

static void _ccv_nnc_cudnn_deinit_convolution_descriptor(const ccv_nnc_cudnn_convolution_descriptor_t convolution_desc)
{
	ccv_nnc_stream_context_return_convolution_descriptor(convolution_desc.stream_context, convolution_desc.descriptor);
}

enum {
	CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_IMPLICIT_GEMM, // CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_GEMM
	CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_IMPLICIT_PRECOMP_GEMM, // CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_PRECOMP_GEMM
	CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_GEMM, // CUDNN_CONVOLUTION_FWD_ALGO_GEMM
	CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_DIRECT, // CUDNN_CONVOLUTION_FWD_ALGO_DIRECT
	CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_FFT, // CUDNN_CONVOLUTION_FWD_ALGO_FFT
	CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_FFT_TILING, // CUDNN_CONVOLUTION_FWD_ALGO_FFT_TILING
	CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_FFT_WINOGRAD, // CUDNN_CONVOLUTION_FWD_ALGO_WINOGRAD
	CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_COUNT
};

static int _ccv_nnc_conv_forw(const ccv_nnc_cmd_t cmd, const ccv_nnc_hint_t hint, const int flags, ccv_nnc_tensor_t* const* inputs, const int input_size, ccv_nnc_tensor_t** outputs, const int output_size, const ccv_nnc_stream_context_t* stream_context)
{
	assert(input_size == 3);
	assert(output_size == 1);
	assert(stream_context);
	cudaStream_t stream = ccv_nnc_stream_context_get_stream(stream_context);
	cudnnHandle_t cudnn = ccv_nnc_stream_context_get_cudnn(stream_context);
	int device = ccv_nnc_stream_context_get_device(stream_context);
	cudaSetDevice(device);
	const ccv_nnc_cudnn_tensor_view_descriptor_t a = _ccv_nnc_cudnn_get_tensor_view_descriptor(stream_context, (const ccv_nnc_tensor_view_t*)inputs[0]);
	const ccv_nnc_cudnn_filter_descriptor_t w = _ccv_nnc_cudnn_get_filter_descriptor(stream_context, (const ccv_nnc_tensor_t*)inputs[1]);
	const ccv_nnc_cudnn_tensor_view_descriptor_t bias = _ccv_nnc_cudnn_get_tensor_view_descriptor(stream_context, (const ccv_nnc_tensor_view_t*)inputs[2]);
	const ccv_nnc_cudnn_tensor_view_descriptor_t b = _ccv_nnc_cudnn_get_tensor_view_descriptor(stream_context, (const ccv_nnc_tensor_view_t*)outputs[0]);
	const ccv_nnc_cudnn_convolution_descriptor_t conv = _ccv_nnc_cudnn_get_convolution_descriptor(stream_context, hint);

	cudnnConvolutionFwdAlgo_t algo;
	// Choose an algorithm
	switch (cmd.algorithm)
	{
		case CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_IMPLICIT_GEMM:
			algo = CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_GEMM;
			break;
		case CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_IMPLICIT_PRECOMP_GEMM:
			algo = CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_PRECOMP_GEMM;
			break;
		case CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_GEMM:
			algo = CUDNN_CONVOLUTION_FWD_ALGO_GEMM;
			break;
		case CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_DIRECT:
			algo = CUDNN_CONVOLUTION_FWD_ALGO_DIRECT;
			break;
		case CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_FFT:
			algo = CUDNN_CONVOLUTION_FWD_ALGO_FFT;
			break;
		case CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_FFT_TILING:
			algo = CUDNN_CONVOLUTION_FWD_ALGO_FFT_TILING;
			break;
		case CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_FFT_WINOGRAD:
			algo = CUDNN_CONVOLUTION_FWD_ALGO_WINOGRAD;
			break;
		default: // -1: Using preferences to find a suitable algorithm
			cudnnGetConvolutionForwardAlgorithm(cudnn, a.descriptor, w.descriptor, conv.descriptor, b.descriptor, CUDNN_CONVOLUTION_FWD_PREFER_FASTEST, 0, &algo);
	}

	size_t workspace_size = 0;
	cudnnGetConvolutionForwardWorkspaceSize(cudnn, a.descriptor, w.descriptor, conv.descriptor, b.descriptor, algo, &workspace_size);
	void* workspace = 0;
	// TODO: If error, return OOM
	if (workspace_size)
		cudaMalloc(&workspace, workspace_size);
	const float one = 1, zero = 0;
	cudnnConvolutionForward(cudnn, &one, a.descriptor, a.data.u8, w.descriptor, w.data.u8, conv.descriptor, algo, workspace, workspace_size, &zero, b.descriptor, b.data.u8);
	cudnnAddTensor(cudnn, &one, bias.descriptor, bias.data.u8, &one, b.descriptor, b.data.u8);
	if (workspace)
		cudaFreeAsync(workspace, stream);
	_ccv_nnc_cudnn_deinit_tensor_view_descriptor(a);
	_ccv_nnc_cudnn_deinit_filter_descriptor(w);
	_ccv_nnc_cudnn_deinit_tensor_view_descriptor(bias);
	_ccv_nnc_cudnn_deinit_tensor_view_descriptor(b);
	_ccv_nnc_cudnn_deinit_convolution_descriptor(conv);
	return CCV_NNC_EXEC_SUCCESS;
}

static int _ccv_nnc_conv_forw_autotune(const ccv_nnc_cmd_t cmd, const size_t max_workspace_size, const ccv_nnc_hint_t hint, const int flags, ccv_nnc_tensor_t* const* inputs, const int input_size, ccv_nnc_tensor_t** outputs, const int output_size, const ccv_nnc_stream_context_t* stream_context)
{
	assert(input_size == 3);
	assert(output_size == 1);
	assert(stream_context);
	cudnnHandle_t cudnn = ccv_nnc_stream_context_get_cudnn(stream_context);
	int device = ccv_nnc_stream_context_get_device(stream_context);
	cudaSetDevice(device);
	const ccv_nnc_cudnn_tensor_view_descriptor_t a = _ccv_nnc_cudnn_get_tensor_view_descriptor(stream_context, (const ccv_nnc_tensor_view_t*)inputs[0]);
	const ccv_nnc_cudnn_filter_descriptor_t w = _ccv_nnc_cudnn_get_filter_descriptor(stream_context, (const ccv_nnc_tensor_t*)inputs[1]);
	const ccv_nnc_cudnn_tensor_view_descriptor_t bias = _ccv_nnc_cudnn_get_tensor_view_descriptor(stream_context, (const ccv_nnc_tensor_view_t*)inputs[2]);
	const ccv_nnc_cudnn_tensor_view_descriptor_t b = _ccv_nnc_cudnn_get_tensor_view_descriptor(stream_context, (const ccv_nnc_tensor_view_t*)outputs[0]);
	const ccv_nnc_cudnn_convolution_descriptor_t conv = _ccv_nnc_cudnn_get_convolution_descriptor(stream_context, hint);
	int count = 0;
	cudnnConvolutionFwdAlgoPerf_t perfs[CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_COUNT];
	cudnnFindConvolutionForwardAlgorithm(cudnn, a.descriptor, w.descriptor, conv.descriptor, b.descriptor, CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_COUNT, &count, perfs);
	int i;
	cudnnConvolutionFwdAlgo_t algorithm;
	for(i = 0; i < count; i++)
		if ((size_t)perfs[i].memory <= max_workspace_size && perfs[i].status == CUDNN_STATUS_SUCCESS)
		{
			algorithm = perfs[i].algo;
			break;
		}
	_ccv_nnc_cudnn_deinit_tensor_view_descriptor(a);
	_ccv_nnc_cudnn_deinit_filter_descriptor(w);
	_ccv_nnc_cudnn_deinit_tensor_view_descriptor(bias);
	_ccv_nnc_cudnn_deinit_tensor_view_descriptor(b);
	_ccv_nnc_cudnn_deinit_convolution_descriptor(conv);
	switch (algorithm)
	{
		case CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_GEMM:
			return CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_IMPLICIT_GEMM;
		case CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_PRECOMP_GEMM:
			return CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_IMPLICIT_PRECOMP_GEMM;
		case CUDNN_CONVOLUTION_FWD_ALGO_GEMM:
			return CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_GEMM;
		case CUDNN_CONVOLUTION_FWD_ALGO_DIRECT:
			return CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_DIRECT;
		case CUDNN_CONVOLUTION_FWD_ALGO_FFT:
			return CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_FFT;
		case CUDNN_CONVOLUTION_FWD_ALGO_FFT_TILING:
			return CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_FFT_TILING;
		case CUDNN_CONVOLUTION_FWD_ALGO_WINOGRAD:
			return CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_FFT_WINOGRAD;
	}
	return -1; // Return the most efficient algorithm, return -1 if cannot find one.
}
#endif

//@ccv_nnc_init CCV_NNC_BACKEND_GPU_CUDNN
void ccv_nnc_gpu_cudnn_init(ccv_nnc_cmd_api_t cmd_api[])
{
#ifdef HAVE_CUDNN
	/* Format transform */
	cmd_api[CCV_NNC_COMPUTE_FORMAT_TRANSFORM].tensor_formats = CCV_TENSOR_FORMAT_NCHW | CCV_TENSOR_FORMAT_NHWC;
	cmd_api[CCV_NNC_COMPUTE_FORMAT_TRANSFORM].tensor_memory = CCV_TENSOR_GPU_MEMORY;
	cmd_api[CCV_NNC_COMPUTE_FORMAT_TRANSFORM].algorithms = -1;
	cmd_api[CCV_NNC_COMPUTE_FORMAT_TRANSFORM].exec = _ccv_nnc_format_transform;
	/* Convolutional layer */
	cmd_api[CCV_NNC_COMPUTE_CONVOLUTIONAL_FORWARD].tensor_formats = CCV_TENSOR_FORMAT_NCHW | CCV_TENSOR_FORMAT_NHWC;
	cmd_api[CCV_NNC_COMPUTE_CONVOLUTIONAL_FORWARD].tensor_memory = CCV_TENSOR_GPU_MEMORY;
	cmd_api[CCV_NNC_COMPUTE_CONVOLUTIONAL_FORWARD].algorithms = CCV_NNC_CMD_CUDNN_CONV_FWD_ALGO_COUNT;
	cmd_api[CCV_NNC_COMPUTE_CONVOLUTIONAL_FORWARD].exec = _ccv_nnc_conv_forw;
	cmd_api[CCV_NNC_COMPUTE_CONVOLUTIONAL_FORWARD].autotune = _ccv_nnc_conv_forw_autotune;
	/* Full connect layer */
	/* Max pool layer */
	/* Average pool layer */
	/* Softmax layer */
	/* ReLU activation */
#endif
}