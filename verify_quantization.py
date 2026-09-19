import onnxruntime as ort
import tensorflow as tf
import numpy as np
import sys
import glob

# Load a sample calibration image for testing (shape: 1, 3, 224, 224)
test_files = glob.glob('calibration_data_sample_data_nchw/*.npy')
test_input_nchw = np.load(test_files[0]) # (1, 3, 224, 224) - ALREADY NORMALIZED!

# 1. Run ONNX (FP32)
session = ort.InferenceSession('optixai_dr_model.onnx')
input_name = session.get_inputs()[0].name
onnx_output = session.run(None, {input_name: test_input_nchw})[0]

# 2. Run TFLite (INT8)
tflite_path = 'optixai_tflite_model/optixai_dr_model_full_integer_quant.tflite'
interpreter = tf.lite.Interpreter(model_path=tflite_path)
interpreter.allocate_tensors()

input_details = interpreter.get_input_details()[0]
output_details = interpreter.get_output_details()[0]

# The TFLite model expects NHWC shape
test_input_nhwc = np.transpose(test_input_nchw, (0, 2, 3, 1))

scale, zero_point = input_details['quantization']
# Quantize the ALREADY NORMALIZED data using the model's scale and zero point
tflite_input = np.clip(np.round(test_input_nhwc / scale) + zero_point, -128, 127).astype(np.int8)

interpreter.set_tensor(input_details['index'], tflite_input)
interpreter.invoke()
tflite_output = interpreter.get_tensor(output_details['index'])

out_scale, out_zero_point = output_details['quantization']
tflite_output_float = (tflite_output.astype(np.float32) - out_zero_point) * out_scale

print("\n--- RESULTS ---")
print("ONNX (FP32) Output probabilities:", onnx_output)
print("TFLite (INT8) Output probabilities:", tflite_output_float)
print("Max absolute difference:", np.max(np.abs(onnx_output - tflite_output_float)))
