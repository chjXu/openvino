#distutils: language=c++
from cython.operator cimport dereference as deref
from libcpp.string cimport string
from libcpp.vector cimport vector
from libcpp cimport bool
from libcpp.pair cimport pair
from libcpp.map cimport map
from libcpp.memory cimport unique_ptr
from libc.stdlib cimport malloc, free
from libc.stdint cimport int64_t, uint8_t, int8_t, int32_t, uint16_t, int16_t
from libc.string cimport memcpy

import os
from pathlib import Path
import threading
import warnings
from copy import deepcopy
from collections import OrderedDict, namedtuple

from .cimport ie_api_impl_defs as C
from .ie_api_impl_defs cimport SizeVector, Precision
from .constants import supported_precisions, known_plugins, layout_int_to_str_map, \
                       format_map, layout_str_to_enum, StatusCode, WaitMode

import numpy as np

cdef extern from "<utility>" namespace "std" nogil:
    cdef unique_ptr[C.IEExecNetwork] move(unique_ptr[C.IEExecNetwork])

cdef string to_std_string(str py_string):
    return py_string.encode()

cdef to_py_string(const string & std_string):
    return bytes(std_string).decode()

cdef dict_to_c_map(py_dict):
    cdef map[string, string] c_map
    for k, v in py_dict.items():
        if type(k) != str or type(v) != str:
            raise TypeError("Only string keys and values are allowed!")
        c_map[k.encode()] = v.encode()
    return c_map

cdef c_map_to_dict(map[string, string] c_map):
    py_dict = {}
    for v in c_map:
        py_dict[v.first.decode()] = v.second.decode()
    return py_dict


def get_version():
    return C.get_version().decode()

## This class defines Tensor description
cdef class IETensorDesc:
    def __eq__(self, other : IETensorDesc):
        return self.layout == other.layout and self.precision == other.precision and self.dims == other.dims
    def __ne__(self, other : IETensorDesc):
        return self.layout != other.layout or self.precision != other.precision or self.dims != other.dims
    def __deepcopy__(self, memodict={}):
        return IETensorDesc(deepcopy(self.precision, memodict), deepcopy(self.dims, memodict), deepcopy(self.layout, memodict))
    ## Class constructor
    # @param precision: target memory precision
    # @param dims: target memory dimensions
    # @param layout: target memory layout
    # @return Instance of defines class
    def __cinit__(self, precision : str, dims : [list, tuple], layout : str):
        if precision not in supported_precisions:
            raise ValueError("Unsupported precision {}! List of supported precisions: {}".format(precision,
                                                                                                 supported_precisions))
        self.impl = C.TensorDesc(C.Precision.FromStr(precision.encode()), dims, layout_str_to_enum[layout])
    ## Shape (dimensions) of the IETensorDesc object
    @property
    def dims(self):
        return self.impl.getDims()
    @dims.setter
    def dims(self, dims_array : [list, tuple]):
        self.impl.setDims(dims_array)
    ## Precision of the IETensorDesc object
    @property
    def precision(self):
        return self.impl.getPrecision().name().decode()
    @precision.setter
    def precision(self, precision : str):
        if precision not in supported_precisions:
            raise ValueError("Unsupported precision {}! List of supported precisions: {}".format(precision,
                                                                                                 supported_precisions))
        self.impl.setPrecision(C.Precision.FromStr(precision.encode()))
    ## Layout of the IETensorDesc object
    @property
    def layout(self):
        return layout_int_to_str_map[self.impl.getLayout()]
    @layout.setter
    def layout(self, layout : str):
        if layout not in layout_str_to_enum.keys():
            raise ValueError("Unsupported layout {}! "
                             "List of supported layouts: {}".format(layout, list(layout_str_to_enum.keys())))
        self.impl.setLayout(layout_str_to_enum[layout])

## This class represents Blob
cdef class IEBlob:
    ## Class constructor
    # @param tensor_desc: IETensorDesc object describing creating IEBlob object.
    # @param array: numpy.ndarray with data to fill blob memory, The array have to have same elements count
    #               as specified in tensor_desc.dims attribute and same elements precision corresponding to
    #               tensor_desc.precision. If array isn't provided empty numpy.ndarray will be created accorsing
    #               to parameters of tensor_desc
    # @return Instance of IEBlob class
    def __cinit__(self, IETensorDesc tensor_desc = None, array : np.ndarray = None):
        cdef TensorDesc c_tensor_desc
        cdef float[::1] fp32_array_memview
        cdef int16_t[::1] I16_array_memview
        cdef uint16_t[::1] U16_array_memview
        cdef uint8_t[::1] U8_array_memview
        cdef int8_t[::1] I8_array_memview
        cdef int32_t[::1] I32_array_memview
        cdef int64_t[::1] I64_array_memview

        cdef int16_t[:] x_as_uint
        cdef int16_t[:] y_as_uint

        self._array_data = array
        self._initial_shape = array.shape if array is not None else None

        if self._array_data is not None:
            if np.isfortran(self._array_data):
                self._array_data = self._array_data.ravel(order="F")
            else:
                self._array_data = self._array_data.ravel(order="C")
        if self._array_data is None and tensor_desc is not None:
            c_tensor_desc = tensor_desc.impl
            precision = tensor_desc.precision
            if precision == "FP32":
                self._ptr = C.make_shared_blob[float](c_tensor_desc)
            elif precision == "FP16" or precision == "I16":
                self._ptr = C.make_shared_blob[int16_t](c_tensor_desc)
            elif precision == "Q78" or precision == "U16":
                self._ptr = C.make_shared_blob[uint16_t](c_tensor_desc)
            elif  precision == "U8" or precision == "BOOL":
                self._ptr = C.make_shared_blob[uint8_t](c_tensor_desc)
            elif  precision == "I8" or precision == "BIN":
                self._ptr = C.make_shared_blob[int8_t](c_tensor_desc)
            elif  precision == "I32":
                self._ptr = C.make_shared_blob[int32_t](c_tensor_desc)
            elif  precision == "I64":
                self._ptr = C.make_shared_blob[int64_t](c_tensor_desc)
            else:
                raise AttributeError("Unsupported precision {} for blob".format(precision))
            deref(self._ptr).allocate()
        elif tensor_desc is not None and self._array_data is not None:
            c_tensor_desc = tensor_desc.impl
            precision = tensor_desc.precision
            size_arr = np.prod(array.shape)
            size_td = np.prod(tensor_desc.dims)
            if size_arr != size_td:
                raise AttributeError("Number of elements in provided numpy array {} and "
                                     "required by TensorDesc {} are not equal".format(size_arr, size_td))
            if self._array_data.dtype != format_map[precision]:
                raise ValueError("Data type {} of provided numpy array "
                                 "doesn't match to TensorDesc precision {}".format(self._array_data.dtype, precision))
            if not self._array_data.flags['C_CONTIGUOUS']:
                self._array_data = np.ascontiguousarray(self._array_data)
            if precision == "FP32":
                fp32_array_memview = self._array_data
                self._ptr = C.make_shared_blob[float](c_tensor_desc, &fp32_array_memview[0], fp32_array_memview.shape[0])
            elif precision == "FP16":
                raise RuntimeError("Currently, it's impossible to set_blob with FP16 precision")
            elif precision == "I16":
                I16_array_memview = self._array_data
                self._ptr = C.make_shared_blob[int16_t](c_tensor_desc, &I16_array_memview[0], I16_array_memview.shape[0])
            elif precision == "Q78" or precision == "U16":
                U16_array_memview = self._array_data
                self._ptr = C.make_shared_blob[uint16_t](c_tensor_desc, &U16_array_memview[0], U16_array_memview.shape[0])
            elif  precision == "U8" or precision == "BOOL":
                U8_array_memview = self._array_data
                self._ptr = C.make_shared_blob[uint8_t](c_tensor_desc, &U8_array_memview[0], U8_array_memview.shape[0])
            elif  precision == "I8" or precision == "BIN":
                I8_array_memview = self._array_data
                self._ptr = C.make_shared_blob[int8_t](c_tensor_desc, &I8_array_memview[0], I8_array_memview.shape[0])
            elif  precision == "I32":
                I32_array_memview = self._array_data
                self._ptr = C.make_shared_blob[int32_t](c_tensor_desc, &I32_array_memview[0], I32_array_memview.shape[0])
            elif  precision == "I64":
                I64_array_memview = self._array_data
                self._ptr = C.make_shared_blob[int64_t](c_tensor_desc, &I64_array_memview[0], I64_array_memview.shape[0])
            else:
                raise AttributeError("Unsupported precision {} for blob".format(precision))

    def __deepcopy__(self, memodict):
        res = IEBlob(deepcopy(self.tensor_desc, memodict), deepcopy(self._array_data, memodict))
        res.buffer[:] = deepcopy(self.buffer[:], memodict)
        return res

    ## IEBlob's memory as numpy.ndarray representation
    @property
    def buffer(self):
        representation_shape = self._initial_shape if self._initial_shape is not None else []
        cdef BlobBuffer buffer = BlobBuffer()
        buffer.reset(self._ptr, representation_shape)
        return buffer.to_numpy()

    ## IETensorDesc of created IEBlob
    @property
    def tensor_desc(self):
        cdef TensorDesc c_tensor_desc = deref(self._ptr).getTensorDesc()
        precision = c_tensor_desc.getPrecision().name().decode()
        layout = c_tensor_desc.getLayout()
        dims = c_tensor_desc.getDims()
        tensor_desc = IETensorDesc(precision, dims, layout_int_to_str_map[layout])
        return tensor_desc

## This class represents an Inference Engine entity and allows you to manipulate with plugins using unified interfaces.
cdef class IECore:
    ## Class constructor
    # @param xml_config_file:  A full path to `.xml` file containing plugins configuration.
    #                          If the parameter is not specified, the default configuration is handled automatically.
    # @return Instance of IECore class
    def __cinit__(self, xml_config_file: str = ""):
        self.impl = C.IECore(xml_config_file.encode())

    ## Get a `namedtuple` object with versions of the plugin specified
    #  @param device_name: Name of the the registered plugin
    #  @return Dictionary mapping a plugin name and `Versions` `namedtuple` object with the following fields:
    #            * `major` - major plugin integer version
    #            * `minor` - minor plugin integer version
    #            * `build_number` - plugin build number string
    #            * `description` - plugin description string
    def get_versions(self, device_name: str):
        cdef  map[string, C.Version] versions_
        versions_ = self.impl.getVersions(device_name.encode())
        versions = {}
        for v in versions_:
            device = v.first.decode()
            ver = v.second
            versions[device] = namedtuple("Versions", ["major", "minor", "build_number", "description"])
            versions[device].build_number = ver.buildNumber.decode()
            versions[device].description = ver.description.decode()
            versions[device].minor = ver.apiVersion.minor
            versions[device].major = ver.apiVersion.major
        return versions

    ## Reads a network from the Intermediate Representation (IR) and creates an `IENetwork`.
    #  @param model: A `.xml` file of the IR or string with IR.
    #  @param weights: A `.bin` file of the IR. Depending on `init_from_buffer` value, can be a string path or
    #                  bytes with file content.
    #  @param init_from_buffer: Defines the way of how `model` and `weights` attributes are interpreted.
    #                           If  `False`, attributes are interpreted as strings with paths to .xml and .bin files
    #                           of IR. If `True`, they are  interpreted as Python `bytes` object with .xml and .bin files content.
    #  @return An `IENetwork` object
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  ```
    cpdef IENetwork read_network(self, model: [str, bytes, Path], weights: [str, bytes, Path] = "", init_from_buffer: bool = False):
        cdef char*xml_buffer
        cdef uint8_t*bin_buffer
        cdef string weights_
        cdef string model_
        cdef IENetwork net = IENetwork()
        if init_from_buffer:
            xml_buffer = <char*> malloc(len(model)+1)
            bin_buffer = <uint8_t *> malloc(len(weights))
            memcpy(xml_buffer, <char*> model, len(model))
            memcpy(bin_buffer, <uint8_t *> weights, len(weights))
            xml_buffer[len(model)] = b'\0'
            net.impl = self.impl.readNetwork(xml_buffer, bin_buffer, len(weights))
            free(xml_buffer)
        else:
            if isinstance(model, Path) and isinstance(weights, Path):
                if not model.is_file():
                    raise Exception("Path to the model {} doesn't exist or it's a directory".format(model))
                if not weights.is_file():
                    raise Exception("Path to the weights {} doesn't exist or it's a directory".format(weights))
                model_ = bytes(model)
                weights_ = bytes(weights)
            else:
                if not os.path.isfile(model):
                    raise Exception("Path to the model {} doesn't exist or it's a directory".format(model))
                if not os.path.isfile(weights):
                    raise Exception("Path to the weights {} doesn't exist or it's a directory".format(weights))
                model_ = model.encode()
                weights_ = weights.encode()
            net.impl =  self.impl.readNetwork(model_, weights_)
        return net

    ## Loads a network that was read from the Intermediate Representation (IR) to the plugin with specified device name
    #    and creates an `ExecutableNetwork` object of the `IENetwork` class.
    #    You can create as many networks as you need and use them simultaneously (up to the limitation of the hardware
    #    resources).
    #  @param network: A valid `IENetwork` instance
    #  @param device_name: A device name of a target plugin
    #  @param config: A dictionary of plugin configuration keys and their values
    #  @param num_requests: A positive integer value of infer requests to be created. Number of infer requests is limited
    #                       by device capabilities.
    #                       Value `0` indicates that optimal number of infer requests will be created.
    #  @return An `ExecutableNetwork` object
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  exec_net = ie.load_network(network=net, device_name="CPU", num_requests=2)
    #  ```
    cpdef ExecutableNetwork load_network(self, IENetwork network, str device_name, config=None, int num_requests=1):
        cdef ExecutableNetwork exec_net = ExecutableNetwork()
        cdef map[string, string] c_config
        if num_requests < 0:
            raise ValueError("Incorrect number of requests specified: {}. Expected positive integer number "
                             "or zero for auto detection".format(num_requests))
        if config:
            c_config = dict_to_c_map(config)
        exec_net.ie_core_impl = self.impl
        exec_net.impl = move(self.impl.loadNetwork(network.impl, device_name.encode(), c_config, num_requests))
        return exec_net

    ## Creates an executable network from a previously exported network
    #  @param device_name Name of device load executable network on
    #  @param model_file Full path to the location of the exported file
    #  @param config: A dictionary of plugin configuration keys and their values
    #  @param num_requests: A positive integer value of infer requests to be created. Number of infer requests is limited
    #                       by device capabilities.
    #                       Value `0` indicates that optimal number of infer requests will be created.
    #  @return An `ExecutableNetwork` object
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  exec_net = ie.load_network(network=net, device_name="MYRIAD", num_requsts=2)
    #  # export executable network
    #  exec_net.export(path_to_file_to_save)
    #  # import previously exported executable network
    #  exec_net_imported = ie.import_network(model_file=path_to_file_to_save, device_name="MYRIAD")
    #  ```
    cpdef ExecutableNetwork import_network(self, str model_file, str device_name, config=None, int num_requests=1):
        cdef ExecutableNetwork exec_net = ExecutableNetwork()
        cdef map[string, string] c_config
        if num_requests < 0:
            raise ValueError("Incorrect number of requests specified: {}. Expected positive integer number "
                             "or zero for auto detection".format(num_requests))
        if config:
            c_config = dict_to_c_map(config)
        exec_net.ie_core_impl = self.impl
        exec_net.impl = move(self.impl.importNetwork(model_file.encode(), device_name.encode(), c_config, num_requests))
        return exec_net

    ## Queries the plugin with specified device name what network layers are supported in the current configuration.
    #  Please note that layers support depends on plugin configuration and loaded extensions.
    #  @param network: A valid `IENetwork` instance
    #  @param device_name: A device name of a target plugin
    #  @param config: A dictionary of plugin configuration keys and their values
    #  @return A dictionary mapping layers and device names on which they are supported
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  layers_map = ie.query_network(network=net, device_name="HETERO:GPU,CPU")
    #  ```
    def query_network(self, IENetwork network, str device_name, config=None):
        cdef map[string, string] c_config
        if config:
            c_config = dict_to_c_map(config)
        res = self.impl.queryNetwork(network.impl, device_name.encode(), c_config)
        return c_map_to_dict(res)

    ## Sets a configuration for a plugin
    #
    #  \note When specifying a key value of a config, the "KEY_" prefix is omitted.
    #
    #  @param config: a dictionary of configuration parameters as keys and their values
    #  @param device_name: a device name of a target plugin
    #  @return None
    #
    #  Usage examples:\n
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  ie.set_config(config={"DYN_BATCH_ENABLED": "YES"}, device_name="CPU")
    #  ```
    def set_config(self, config: dict, device_name: str):
        cdef map[string, string] c_config = dict_to_c_map(config)
        self.impl.setConfig(c_config, device_name.encode())

    ## Registers plugins specified in an `.xml` configuration file
    #  @param plugin_name: A name of a plugin. Depending on a platform, plugin_name is wrapped with a shared
    #                      library suffix and a prefix to identify a full name of the library
    #  @param device_name: A target device name for the plugin. If not specified, the method registers
    #                      a plugin with the default name.
    #  @return None
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  ie.register_plugin(plugin="MKLDNNPlugin", device_name="MY_NEW_PLUGIN")
    #  ```
    def register_plugin(self, plugin_name: str, device_name: str = ""):
        self.impl.registerPlugin(plugin_name.encode(), device_name.encode())

    ## Registers plugins specified in an `.xml` configuration file
    # @param xml_config_file: A full path to `.xml` file containing plugins configuration
    # @return None
    #
    #  Usage example:
    #  ```python
    #  ie = IECore()
    #  ie.register_plugins("/localdisk/plugins/my_custom_cfg.xml")
    #  ```
    def register_plugins(self, xml_config_file: str):
        self.impl.registerPlugins(xml_config_file.encode())

    ## Unregisters a plugin with a specified device name
    #  @param device_name: A device name of the plugin to unregister
    #  @return None
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  ie.unregister_plugin(device_name="GPU")
    #  ```
    def unregister_plugin(self, device_name: str):
        self.impl.unregisterPlugin(device_name.encode())

    ## Loads extension library to the plugin with a specified device name
    #  @param extension_path: Path to the extensions library file to load to a plugin
    #  @param device_name: A device name of a plugin to load the extensions to
    #  @return None
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  ie.add_extension(extension_path="/some_dir/libcpu_extension_avx2.so", device_name="CPU")
    #  ```
    def add_extension(self, extension_path: str, device_name: str):
        self.impl.addExtension(extension_path.encode(), device_name.encode())

    ## Gets a general runtime metric for dedicated hardware. Enables to request common device properties,
    #  which are `ExecutableNetwork` agnostic, such as device name, temperature, and other devices-specific values.
    #  @param device_name: A name of a device to get a metric value.
    #  @param metric_name: A metric name to request.
    #  @return A metric value corresponding to a metric key.
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  ie.get_metric(metric_name="SUPPORTED_METRICS", device_name="CPU")
    #  ```
    def get_metric(self, device_name: str, metric_name: str):
        return self.impl.getMetric(device_name.encode(), metric_name.encode())

    ## Gets a configuration dedicated to device behavior. The method targets to extract information
    #  which can be set via set_config method.
    #
    #  \note When specifying a key value of a config, the "KEY_" prefix is omitted.
    #
    #  @param device_name: A name of a device to get a config value.
    #  @param config_name: A config name to request.
    #  @return A config value corresponding to a config key.
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  ie.get_config(device_name="CPU", config_name="CPU_BIND_THREAD")
    #  ```
    def get_config(self, device_name: str, config_name: str):
        return self.impl.getConfig(device_name.encode(), config_name.encode())

    ## A list of devices. The devices are returned as \[CPU, FPGA.0, FPGA.1, MYRIAD\].
    # If there are more than one device of a specific type, they all are listed followed by a dot and a number.
    @property
    def available_devices(self):
        cdef vector[string] c_devices = self.impl.getAvailableDevices()
        return [d.decode() for d in c_devices]

## This class is the layer data representation.
cdef class DataPtr:
    ## Name of the data object
    @property
    def name(self):
        return deref(self._ptr).getName().decode()
    ## Precision of the data object
    @property
    def precision(self):
        return deref(self._ptr).getPrecision().name().decode()
    @precision.setter
    def precision(self, precision):
        if precision not in supported_precisions:
            raise ValueError("Unsupported precision {}! List of supported precisions: {}".format(precision,
                                                                                                 supported_precisions))
        deref(self._ptr).setPrecision(C.Precision.FromStr(precision.encode()))
    ## Shape (dimensions) of the data object
    @property
    def shape(self):
        return deref(self._ptr).getDims()
    ## Layout of the data object
    @property
    def layout(self):
        return layout_int_to_str_map[deref(self._ptr).getLayout()]
    @layout.setter
    def layout(self, layout):
        if layout not in layout_str_to_enum.keys():
            raise ValueError("Unsupported layout {}! "
                             "List of supported layouts: {}".format(layout, list(layout_str_to_enum.keys())))
        deref(self._ptr).setLayout(layout_str_to_enum[layout])
    ## Checks if the current data object is resolved
    @property
    def initialized(self):
        return deref(self._ptr).isInitialized()
    @property
    def creator_layer(self):
        cdef C.CNNLayerWeakPtr _l_ptr = deref(self._ptr).getCreatorLayer()
        cdef IENetLayer creator_layer
        creator_layer = IENetLayer()
        if _l_ptr.lock() != NULL:
            creator_layer._ptr = _l_ptr.lock()
        else:
            raise RuntimeError("Creator IENetLayer of DataPtr object with name {} already released!".format(self.name))
        return creator_layer
    @property
    def input_to(self):
        cdef map[string, C.CNNLayerPtr] _l_ptr_map = deref(self._ptr).getInputTo()
        cdef IENetLayer input_to
        input_to_list = []
        for layer in _l_ptr_map:
            input_to = IENetLayer()
            input_to._ptr = layer.second
            input_to_list.append(input_to)
        return input_to_list

## This class is the layer constant data representation. Provides same interface as DataPtr object except properties setters
cdef class CDataPtr:
    ## Name of the data object
    @property
    def name(self):
        return deref(self._ptr).getName().decode()
    ## Precision of the data object
    @property
    def precision(self):
        return deref(self._ptr).getPrecision().name().decode()
    ## Shape (dimensions) of the data object
    @property
    def shape(self):
        return deref(self._ptr).getDims()
    ## Layout of the data object
    @property
    def layout(self):
        return layout_int_to_str_map[deref(self._ptr).getLayout()]
    ## Checks if the current data object is resolved
    @property
    def initialized(self):
        return deref(self._ptr).isInitialized()

    # TODO: Resolve compilation error
    # @property
    # def creator_layer(self):
    #     cdef C.CNNLayerWeakPtr _l_ptr = deref(self._ptr).getCreatorLayer()
    #     cdef IENetLayer creator_layer
    #     creator_layer = IENetLayer()
    #     if _l_ptr.lock() != NULL:
    #         creator_layer._ptr = _l_ptr.lock()
    #     else:
    #         raise RuntimeError("Creator IENetLayer of DataPtr object with name {} already released!".format(self.name))
    #     return creator_layer
    # @property
    # def input_to(self):
    #     cdef map[string, C.CNNLayerPtr] _l_ptr_map = deref(self._ptr).getInputTo()
    #     cdef IENetLayer input_to
    #     input_to_list = []
    #     for layer in _l_ptr_map:
    #         input_to = IENetLayer()
    #         input_to._ptr = layer.second
    #         input_to_list.append(input_to)
    #     return input_to_list


## This class represents a network instance loaded to plugin and ready for inference.
cdef class ExecutableNetwork:
    ## There is no explicit class constructor. To make a valid instance of `ExecutableNetwork`,
    #  use `load_network()` method of the `IECore` class.
    def __init__(self):
        self._infer_requests = []

    ## Starts synchronous inference for the first infer request of the executable network and returns output data.
    #  Wraps `infer()` method of the `InferRequest` class
    #  @param inputs:  A dictionary that maps input layer names to `numpy.ndarray` objects of proper shape with
    #                  input data for the layer
    #  @return A dictionary that maps output layer names to `numpy.ndarray` objects with output data of the layer
    #
    #  Usage example:\n
    #  ```python
    #  ie_core = IECore()
    #  net = ie_core.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  exec_net = ie_core.load_network(network=net, device_name="CPU", num_requests=2)
    #  res = exec_net.infer({'data': img})
    #  res
    #  {'prob': array([[[[2.83426580e-08]],
    #                  [[2.40166020e-08]],
    #                  [[1.29469613e-09]],
    #                  [[2.95946148e-08]]
    #                  ......
    #                 ]])}
    #  ```
    def infer(self, inputs=None):
        current_request = self.requests[0]
        current_request.infer(inputs)
        res = {}
        for out in current_request._outputs_list:
            res[out] = deepcopy(current_request.output_blobs[out].buffer)
        return res


    ## Starts asynchronous inference for specified infer request.
    #  Wraps `async_infer()` method of the `InferRequest` class.
    #  @param request_id: Index of infer request to start inference
    #  @param inputs: A dictionary that maps input layer names to `numpy.ndarray` objects of proper
    #                 shape with input data for the layer
    #  @return A handler of specified infer request, which is an instance of the `InferRequest` class.
    #
    #  Usage example:\n
    #  ```python
    #  infer_request_handle = exec_net.start_async(request_id=0, inputs={input_blob: image})
    #  infer_status = infer_request_handle.wait()
    #  res = infer_request_handle.output_blobs[out_blob_name]
    #  ```
    def start_async(self, request_id, inputs=None):
        if request_id not in list(range(len(self.requests))):
            raise ValueError("Incorrect request_id specified!")
        current_request = self.requests[request_id]
        current_request.async_infer(inputs)
        return current_request

    ## A tuple of `InferRequest` instances
    @property
    def requests(self):
        if len(self._infer_requests) == 0:
            for i in range(deref(self.impl).infer_requests.size()):
                infer_request = InferRequest()
                infer_request.impl = &(deref(self.impl).infer_requests[i])
                infer_request._inputs_list = list(self.inputs.keys())
                infer_request._outputs_list = list(self.outputs.keys())
                self._infer_requests.append(infer_request)

        if len(self._infer_requests) != deref(self.impl).infer_requests.size():
            raise Exception("Mismatch of infer requests number!")

        return self._infer_requests
    ## A dictionary that maps input layer names to DataPtr objects
    @property
    def inputs(self):
        cdef map[string, C.DataPtr] c_inputs = deref(self.impl).getInputs()
        inputs = {}
        cdef DataPtr data_ptr
        for in_ in c_inputs:
            data_ptr = DataPtr()
            data_ptr._ptr = in_.second
            inputs[in_.first.decode()] = data_ptr
        return inputs
    ## A dictionary that maps output layer names to CDataPtr objects
    @property
    def outputs(self):
        cdef map[string, C.CDataPtr] c_outputs = deref(self.impl).getOutputs()
        outputs = {}
        cdef CDataPtr data_ptr
        for in_ in c_outputs:
            data_ptr = CDataPtr()
            data_ptr._ptr = in_.second
            outputs[in_.first.decode()] = data_ptr
        return outputs
    ## Gets executable graph information from a device
    #  @return An instance of `IENetwork`
    #
    #  Usage example:\n
    #  ```python
    #  ie_core = IECore()
    #  net = ie_core.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  exec_net = ie_core.load_network(net, device, num_requests=2)
    #  exec_graph = exec_net.get_exec_graph_info()
    #  ```
    def get_exec_graph_info(self):
        ie_network = IENetwork()
        ie_network.impl = deref(self.impl).GetExecGraphInfo()
        return ie_network

    ## Gets general runtime metric for an executable network. It can be network name, actual device ID on
    #  which executable network is running or all other properties which cannot be changed dynamically.
    #  @param metric_name: A metric name to request.
    #  @return A metric value corresponding to a metric key.
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  exec_net = ie.load_network(net, "CPU")
    #  exec_net.get_metric("NETWORK_NAME")
    #  ```
    def get_metric(self, metric_name: str):
        return deref(self.impl).getMetric(metric_name.encode())

    ## Gets configuration for current executable network. The method is responsible to extract information
    #  which affects executable network execution
    #  @param config_name: A configuration parameter name to request.
    #  @return A configuration value corresponding to a configuration key.
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  exec_net = ie.load_network(net, "CPU")
    #  config = exec_net.get_config("CPU_BIND_THREAD")
    #  ```
    def get_config(self, config_name: str):
        return deref(self.impl).getConfig(config_name.encode())

    ## Exports the current executable network.
    #  @param model_file Full path to the target exported file location
    #  @return None
    #
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  exec_net = ie.load_network(network=net, device_name="MYRIAD", num_requsts=2)
    #  exec_net.export(path_to_file_to_save)
    #  ```
    def export(self, model_file: str):
        deref(self.impl).exportNetwork(model_file.encode())

    ## Waits when the result from any request becomes available. Blocks until specified timeout elapses or the result.
    #  @param num_requests: Number of idle requests for which wait.
    #                       If not specified, `num_requests` value is set to number of requests by default.
    #  @param timeout: Time to wait in milliseconds or special (0, -1) cases described above.
    #                  If not specified, `timeout` value is set to -1 by default.
    #  @return Request status code: OK or RESULT_NOT_READY
    cpdef wait(self, num_requests=None, timeout=None):
        if num_requests is None:
            num_requests = len(self.requests)
        if timeout is None:
            timeout = WaitMode.RESULT_READY
        return deref(self.impl).wait(<int> num_requests, <int64_t> timeout)

    ## Get idle request ID
    #  @return Request index
    cpdef get_idle_request_id(self):
        return deref(self.impl).getIdleRequestId()

ctypedef extern void (*cb_type)(void*, int) with gil

## This class provides an interface to infer requests of `ExecutableNetwork` and serves to handle infer requests execution
#  and to set and get output data.
cdef class InferRequest:
    ## There is no explicit class constructor. To make a valid `InferRequest` instance, use `load_network()`
    #  method of the `IECore` class with specified number of requests to get `ExecutableNetwork` instance
    #  which stores infer requests.
    def __init__(self):
        self._user_blobs = {}
        self._inputs_list = []
        self._outputs_list = []
        self._py_callback = lambda *args, **kwargs: None
        self._py_callback_used = False
        self._py_callback_called = threading.Event()
        self._py_data = None

    cdef void user_callback(self, int status) with gil:
        if self._py_callback:
            # Set flag at first since user can call wait in callback
            self._py_callback_called.set()
            self._py_callback(status, self._py_data)

    ## Description: Sets a callback function that is called on success or failure of an asynchronous request
    #
    #  @param py_callback - Any defined or lambda function
    #  @param py_data - Data that is passed to the callback function
    #  @return None
    #
    #  Usage example:\n
    #  ```python
    #  callback = lambda status, py_data: print("Request with id {} finished with status {}".format(py_data, status))
    #  ie = IECore()
    #  net = ie.read_network(model="./model.xml", weights="./model.bin")
    #  exec_net = ie.load_network(net, "CPU", num_requests=4)
    #  for id, req in enumerate(exec_net.requests):
    #      req.set_completion_callback(py_callback=callback, py_data=id)
    #
    #  for req in exec_net.requests:
    #      req.async_infer({"data": img})
    #  ```
    def set_completion_callback(self, py_callback, py_data = None):
        self._py_callback = py_callback
        self._py_data = py_data
        self._py_callback_used = True
        deref(self.impl).setCyCallback(<cb_type> self.user_callback, <void *> self)

    cpdef BlobBuffer _get_blob_buffer(self, const string & blob_name):
        cdef BlobBuffer buffer = BlobBuffer()
        cdef Blob.Ptr blob_ptr
        deref(self.impl).getBlobPtr(blob_name, blob_ptr)
        buffer.reset(blob_ptr)
        return buffer

    ## Dictionary that maps input layer names to corresponding IEBlobs
    @property
    def input_blobs(self):
        input_blobs = {}
        for input in self._inputs_list:
            # TODO: will not work for setting data via .inputs['data'][:]
            if input in self._user_blobs:
                input_blobs[input] = self._user_blobs[input]
            else:
                blob = IEBlob()
                deref(self.impl).getBlobPtr(input.encode(), blob._ptr)
                input_blobs[input] = blob
        return input_blobs

    ## Dictionary that maps output layer names to corresponding IEBlobs
    @property
    def output_blobs(self):
        output_blobs = {}
        for output in self._outputs_list:
            blob = IEBlob()
            deref(self.impl).getBlobPtr(output.encode(), blob._ptr)
            output_blobs[output] = deepcopy(blob)
        return output_blobs

    ## Sets user defined IEBlob for the infer request
    #  @param blob_name: A name of input blob
    #  @param blob: IEBlob object to set for the infer request
    #  @return None
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  net = IENetwork("./model.xml", "./model.bin")
    #  exec_net = ie.load_network(net, "CPU", num_requests=2)
    #  td = IETensorDesc("FP32", (1, 3, 224, 224), "NCHW")
    #  blob_data = np.ones(shape=(1, 3, 224, 224), dtype=np.float32)
    #  blob = IEBlob(td, blob_data)
    #  exec_net.requests[0].set_blob(blob_name="input_blob_name", blob=blob),
    #  ```
    def set_blob(self, blob_name : str, blob : IEBlob):
        deref(self.impl).setBlob(blob_name.encode(), blob._ptr)
        self._user_blobs[blob_name] = blob
    ## Starts synchronous inference of the infer request and fill outputs array
    #
    #  @param inputs: A dictionary that maps input layer names to `numpy.ndarray` objects of proper shape with
    #                 input data for the layer
    #  @return None
    #
    #  Usage example:\n
    #  ```python
    #  exec_net = ie_core.load_network(network=net, device_name="CPU", num_requests=2)
    #  exec_net.requests[0].infer({input_blob: image})
    #  res = exec_net.requests[0].output_blobs['prob']
    #  np.flip(np.sort(np.squeeze(res)),0)
    #  array([4.85416055e-01, 1.70385033e-01, 1.21873841e-01, 1.18894853e-01,
    #         5.45198545e-02, 2.44456064e-02, 5.41366823e-03, 3.42589128e-03,
    #         2.26027006e-03, 2.12283316e-03 ...])
    #  ```
    cpdef infer(self, inputs=None):
        if inputs is not None:
            self._fill_inputs(inputs)

        deref(self.impl).infer()

    ## Starts asynchronous inference of the infer request and fill outputs array
    #
    #  @param inputs: A dictionary that maps input layer names to `numpy.ndarray` objects of proper shape with input data for the layer
    #  @return: None
    #
    #  Usage example:\n
    #  ```python
    #  exec_net = ie_core.load_network(network=net, device_name="CPU", num_requests=2)
    #  exec_net.requests[0].async_infer({input_blob: image})
    #  request_status = exec_net.requests[0].wait()
    #  res = exec_net.requests[0].output_blobs['prob']
    #  ```
    cpdef async_infer(self, inputs=None):
        if inputs is not None:
            self._fill_inputs(inputs)
        if self._py_callback_used:
            self._py_callback_called.clear()
        deref(self.impl).infer_async()

    ## Waits for the result to become available. Blocks until specified timeout elapses or the result
    #  becomes available, whichever comes first.
    #
    #  \note There are special values of the timeout parameter:
    #  * 0 - Immediately returns the inference status. It does not block or interrupt execution.
    #        To find statuses meaning, please refer to InferenceEngine::StatusCode in Inference Engine C++ documentation
    #  * -1 - Waits until inference result becomes available (default value)
    #
    #  @param timeout: Time to wait in milliseconds or special (0, -1) cases described above.
    #                  If not specified, `timeout` value is set to -1 by default.
    #  @return Request status code.
    #
    #  Usage example: See `async_infer()` method of the the `InferRequest` class.
    cpdef wait(self, timeout=None):
        if self._py_callback_used:
            # check request status to avoid blocking for idle requests
            status = deref(self.impl).wait(WaitMode.STATUS_ONLY)
            if status != StatusCode.RESULT_NOT_READY:
                return status
            if not self._py_callback_called.is_set():
                if timeout == WaitMode.RESULT_READY:
                    timeout = None
                if timeout is not None:
                    # Convert milliseconds to seconds
                    timeout = float(timeout)/1000
                if not self._py_callback_called.wait(timeout):
                    return StatusCode.REQUEST_BUSY
            return StatusCode.OK

        if timeout is None:
            timeout = WaitMode.RESULT_READY

        return deref(self.impl).wait(<int64_t> timeout)

    ## Queries performance measures per layer to get feedback of what is the most time consuming layer.
    #
    #  \note Performance counters data and format depends on the plugin
    #
    #  @return Dictionary containing per-layer execution information.
    #
    #  Usage example:
    #  ```python
    #  exec_net = ie_core.load_network(network=net, device_name="CPU", num_requests=2)
    #  exec_net.requests[0].infer({input_blob: image})
    #  exec_net.requests[0].get_perf_counts()
    #  {'Conv2D': {'exec_type': 'jit_avx2_1x1',
    #              'real_time': 154,
    #              'cpu_time': 154,
    #              'status': 'EXECUTED',
    #              'layer_type': 'Convolution'},
    #   'Relu6':  {'exec_type': 'undef',
    #              'real_time': 0,
    #              'cpu_time': 0,
    #              'status': 'NOT_RUN',
    #              'layer_type': 'Clamp'}
    #   ...
    #  }
    #  ```
    cpdef get_perf_counts(self):
        cdef map[string, C.ProfileInfo] c_profile = deref(self.impl).getPerformanceCounts()
        profile = {}
        for l in c_profile:
            info = l.second
            # TODO: add execution index. Check if unsigned int is properly converted to int in python.
            profile[l.first.decode()] = {"status": info.status.decode(), "exec_type": info.exec_type.decode(),
                                         "layer_type": info.layer_type.decode(), "real_time": info.real_time,
                                         "cpu_time": info.cpu_time, "execution_index": info.execution_index}
        return profile

    ## A dictionary that maps input layer names to `numpy.ndarray`
    #  objects of proper shape with input data for the layer
    @property
    def inputs(self):
        warnings.filterwarnings("always", category=DeprecationWarning)
        warnings.warn("'inputs' property of InferRequest is deprecated. Please instead use 'input_blobs' property.",
                      DeprecationWarning)
        inputs = {}
        for input in self._inputs_list:
            inputs[input] = self._get_blob_buffer(input.encode()).to_numpy()
        return inputs

    ## A dictionary that maps output layer names to `numpy.ndarray` objects with output data of the layer
    @property
    def outputs(self):
        warnings.filterwarnings("always", category=DeprecationWarning)
        warnings.warn("'outputs' property of InferRequest is deprecated. Please instead use 'output_blobs' property.",
                      DeprecationWarning)
        outputs = {}
        for output in self._outputs_list:
            outputs[output] = self._get_blob_buffer(output.encode()).to_numpy()
        return deepcopy(outputs)

    ## Current infer request inference time in milliseconds
    @property
    def latency(self):
        return self.impl.exec_time

    ## Sets new batch size for certain infer request when dynamic batching is enabled in executable network
    #  that created this request.
    #
    #  \note Support of dynamic batch size depends on the target plugin.
    #
    #  @param size: New batch size to be used by all the following inference calls for this request
    #  @return None
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  # Set max batch size
    #  net.batch = 10
    #  ie.set_config(config={"DYN_BATCH_ENABLED": "YES"}, device_name=device)
    #  exec_net = ie.load_network(network=net, device_name=device)
    #  # Set batch size for certain network.
    #  # NOTE: Input data shape will not be changed, but will be used partially in inference which increases performance
    #  exec_net.requests[0].set_batch(2)
    #  ```
    def set_batch(self, size):
        if size <= 0:
            raise ValueError("Batch size should be positive integer number but {} specified".format(size))
        deref(self.impl).setBatch(size)

    def _fill_inputs(self, inputs):
        for k, v in inputs.items():
            assert k in self._inputs_list, "No input with name {} found in network".format(k)
            self.input_blobs[k].buffer[:] = v


## Layer calibration statistic container.
class LayerStats:

    ## Class constructor
    #
    #  @param min: Tuple with per-channel minimum layer activation values
    #  @param max: Tuple with per-channel maximum layer activation values
    #  @return An instance of LayerStats class
    def __init__(self, min: tuple = (), max: tuple = ()):
        self._min = min
        self._max = max

    ## Tuple with per-channel minimum layer activation values
    @property
    def min(self):
        return self._min

    ## Tuple with per-channel maximum layer activation values
    @property
    def max(self):
        return self._max


## Class inherited from built-in python `dict` class and overrides default `update()`method to allow
#  to set or modify layers calibration statistics.
cdef class LayersStatsMap(dict):
    def update(self, other=None, **kwargs):
        super(LayersStatsMap, self).update(other, **kwargs)
        cdef map[string, map[string, vector[float]]] c_stats_map
        cdef map[string, vector[float]] c_node_stats
        for k, v in self.items():
            c_node_stats["min".encode()] = v.min
            c_node_stats["max".encode()] = v.max
            c_stats_map[k.encode()] = c_node_stats
        self.net_impl.setStats(c_stats_map)

## This class represents a main layer information and providing setters allowing to modify layer properties
cdef class IENetLayer:
    ## Name of the layer
    @property
    def name(self):
        return deref(self._ptr).name.decode()

    ## Layer type
    @property
    def type(self):
        return deref(self._ptr).type.decode()

    ## \note This property is deprecated.
    #  Please, use out_data property to access DataPtr objects for all output ports, which contains full
    #  information about layer's output data including precision.
    #
    #  Layer base operating precision. Provides getter and setter interfaces.
    @property
    def precision(self):
        warnings.filterwarnings("always", category=DeprecationWarning)
        warnings.warn("precision property of IENetLayer is deprecated. "
                      "Please instead use precision property of DataPtr objects "
                      "returned by out_data property",
                      DeprecationWarning)
        return deref(self._ptr).precision.name().decode()

    @precision.setter
    def precision(self, precision: str):
        deref(self._ptr).precision = C.Precision.FromStr(precision.encode())

    ## Layer affinity set by user or a default affinity may be setted using `IECore.query_network() method`
    #  which returns dictionary {layer_name : device}.
    #  The affinity attribute provides getter and setter interfaces, so the layer affinity can be modified directly.
    #  For example:\n
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  layers_map = ie.query_network(network=net, device_name="HETERO:GPU,CPU")
    #  layers = net.layers
    #  for layer, device in layers_map.items():
    #      layers[layer].affinity = device
    #  ```
    @property
    def affinity(self):
        return deref(self._ptr).affinity.decode()
    @affinity.setter
    def affinity(self, target_affinity):
        deref(self._ptr).affinity = target_affinity.encode()

    ## Layer specific parameters. Provides getter and setter interfaces to get and modify layer parameters.
    #  Please note that some modifications can be ignored and/or overwritten by target plugin (e.g. modification of
    #  convolution kernel size will be reflected in layer parameters but finally the plugin will ignore it and will
    #  use initial kernel size)
    @property
    def params(self):
        return {k.decode(): v.decode() for k, v in deref(self._ptr).params}
    @params.setter
    def params(self, new_params):
        deref(self._ptr).params = dict_to_c_map(new_params)
    ## Returns a list, which contains names of layers preceding this layer
    @property
    def parents(self):
        cdef vector[C.DataWeakPtr] c_inputs = deref(self._ptr).insData
        parents = []
        for l in c_inputs:
            if l.lock() != NULL:
                parents.append(deref(l.lock()).getName().decode())
            else:
                raise RuntimeError("Input Data of layer {} already released!".format(self.name))
        return parents
    ## Returns a list, which contains names of layers following this layer
    @property
    def children(self):
        cdef vector[C.DataPtr] c_outs = deref(self._ptr).outData
        children = []
        cdef map[string, C.CNNLayerPtr] _l_ptr_map
        input_to_list = []
        for l in c_outs:
            _l_ptr_map = deref(l).getInputTo()
            for layer in _l_ptr_map:
                input_to_list.append(deref(layer.second).name.decode())
        return input_to_list

    ## \note This property is deprecated.
    # Please, use out_data property to access DataPtr objects for all output ports, which contains full
    # information about layer's output data including layout
    #
    # Returns the layout of the layer output data on 1st port
    @property
    def layout(self):
        warnings.filterwarnings("always", category=DeprecationWarning)
        warnings.warn("layout property of IENetLayer is deprecated. "
                      "Please instead use shape property of DataPtr objects "
                      "returned by in_data or out_data property to access shape of input or output data "
                      "on corresponding ports",
                      DeprecationWarning)
        cdef C.DataPtr c_input = deref(self._ptr).outData[0]
        return layout_int_to_str_map[deref(c_input).getLayout()]

    ## \note This property is deprecated.
    # Please, use out_data property to access DataPtr objects for all output ports, which contains full
    # information about layer's output data including shape
    #
    # Return the list of dimension of the layer output data on 1st port
    @property
    def shape(self):
        warnings.filterwarnings("always", category=DeprecationWarning)
        warnings.warn("shape property of IENetLayer is deprecated. "
                      "Please use shape property of DataPtr instead objects "
                      "returned by in_data or out_data property to access shape of input or output data "
                      "on corresponding ports",
                      DeprecationWarning)
        cdef C.DataPtr c_input = deref(self._ptr).outData[0]
        return deref(c_input).getDims()

    ## Returns a list of DataPtr objects representing the output data of the layer on corresponding port
    @property
    def out_data(self):
        cdef vector[C.DataPtr] c_outputs = deref(self._ptr).outData
        cdef DataPtr data_ptr
        out_data = []
        for output in c_outputs:
            data_ptr = DataPtr()
            data_ptr._ptr = output
            out_data.append(data_ptr)
        return out_data
    ## Returns a list of DataPtr objects representing the input data of the layer on corresponding port
    @property
    def in_data(self):
        cdef vector[C.DataWeakPtr] c_inputs = deref(self._ptr).insData
        cdef DataPtr data_ptr
        in_data = []
        for input in c_inputs:
            data_ptr = DataPtr()
            if input.lock() != NULL:
                data_ptr._ptr = input.lock()
            else:
                raise RuntimeError("Input Data of layer {} already released!".format(self.name))
            in_data.append(data_ptr)
        return in_data

    ## Dictionary with layer arbitrary layer blobs including weights and biases as any.
    @property
    def blobs(self):
        cdef map[string, Blob.Ptr] c_blobs_map
        c_blobs_map = deref(self._ptr).blobs
        blobs_map = {}
        cdef BlobBuffer weights_buffer
        for blob in c_blobs_map:
            weights_buffer = BlobBuffer()
            weights_buffer.reset(blob.second)
            blobs_map[blob.first.decode()] = weights_buffer.to_numpy()
        return blobs_map
    ## \note This property is deprecated.
    #  Please use blobs property instead.
    #
    #  Dictionary with layer weights, biases or custom blobs if any
    @property
    def weights(self):
        warnings.filterwarnings("always", category=DeprecationWarning)
        warnings.warn("weights property of IENetLayer is deprecated. "
                      "Please use blobs property instead.",
                      DeprecationWarning)
        return self.blobs


## This class contains the information about the network model read from IR and allows you to manipulate with
#  some model parameters such as layers affinity and output layers.
cdef class IENetwork:
    ## Class constructor
    #
    #  \note Reading networks using IENetwork constructor is deprecated.
    #  Please, use IECore.read_network() method instead.
    #
    #  @param model: A `.xml` file of the IR or PyCapsule containing smart pointer to nGraph function.
    #                In case of passing a `.xml` file  attribute value can be a string path or bytes with file content
    #                depending on `init_from_buffer` attribute value
    #                .
    #  @param weights: A `.bin` file of the IR. Depending on `init_from_buffer` value, can be a string path or
    #                  bytes with file content.
    #  @param init_from_buffer: Defines the way of how `model` and `weights` attributes are interpreted.
    #                           If  `False`, attributes are interpreted as strings with paths to .xml and .bin files
    #                           of IR. If `True`, they are  interpreted as Python `bytes` object with .xml and .bin files content.
    #                           Ignored in case of `IENetwork` object  initialization from nGraph function.
    #  @return Instance of IENetwork class
    #
    #  Usage example:\n
    #   Initializing `IENetwork` object from IR files:
    #   ```python
    #   net = IENetwork(model=path_to_xml_file, weights=path_to_bin_file)
    #   ```
    #
    #   Initializing `IENetwork` object bytes with content of IR files:
    #   ```python
    #   with open(path_to_bin_file, 'rb') as f:
    #       bin = f.read()
    #   with open(path_to_xml_file, 'rb') as f:
    #       xml = f.read()
    #   net = IENetwork(model=xml, weights=bin, init_from_buffer=True)
    #   ```

    def __cinit__(self, model: [str, bytes] = "", weights: [str, bytes] = "", init_from_buffer: bool = False):
        # TODO: ucomment when ngraph python api will work
        # Try to create Inference Engine network from capsule
        # if model.__class__.__name__ == 'PyCapsule' and weights == '' and init_from_buffer is False:
        #     self.impl = C.IENetwork(model)
        #     return
        cdef char*xml_buffer = <char*> malloc(len(model)+1)
        cdef uint8_t*bin_buffer = <uint8_t *> malloc(len(weights))
        cdef string model_
        cdef string weights_
        if init_from_buffer:
            warnings.filterwarnings("always", category=DeprecationWarning)
            warnings.warn("Reading network using constructor is deprecated. "
                          "Please, use IECore.read_network() method instead",
                          DeprecationWarning)
            memcpy(xml_buffer, <char*> model, len(model))
            memcpy(bin_buffer, <uint8_t *> weights, len(weights))
            xml_buffer[len(model)] = b'\0'
            self.impl = C.IENetwork()
            self.impl.load_from_buffer(xml_buffer, len(model), bin_buffer, len(weights))
        else:
            if model and weights:
                warnings.filterwarnings("always", category=DeprecationWarning)
                warnings.warn("Reading network using constructor is deprecated. "
                          "Please, use IECore.read_network() method instead",
                          DeprecationWarning)
                if not os.path.isfile(model):
                    raise Exception("Path to the model {} doesn't exist or it's a directory".format(model))
                if not os.path.isfile(weights):
                    raise Exception("Path to the weights {} doesn't exist or it's a directory".format(weights))
                model_ = model.encode()
                weights_ = weights.encode()
                self.impl = C.IENetwork(model_, weights_)
            else:
                self.impl = C.IENetwork()
        free(xml_buffer)

    ## Name of the loaded network
    @property
    def name(self):
        name = bytes(self.impl.name)
        return name.decode()

    ## A dictionary that maps input layer names to DataPtr objects.
    @property
    def inputs(self):
        cdef map[string, C.DataPtr] c_inputs = self.impl.getInputs()
        inputs = {}
        cdef DataPtr data_ptr
        for input in c_inputs:
            data_ptr = DataPtr()
            data_ptr._ptr = input.second
            inputs[input.first.decode()] = data_ptr
        return inputs

    ## A dictionary that maps output layer names to DataPtr objects
    @property
    def outputs(self):
        cdef map[string, C.DataPtr] c_outputs = self.impl.getOutputs()
        outputs = {}
        cdef DataPtr data_ptr
        for output in c_outputs:
            data_ptr = DataPtr()
            data_ptr._ptr = output.second
            outputs[output.first.decode()] = data_ptr
        return outputs

    ## Batch size of the network. Provides getter and setter interfaces to get and modify the
    #  network batch size. For example:\n
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  print(net.batch_size)
    #  net.batch_size = 4
    #  print(net.batch_size)
    #  print(net.inputs['data'].shape)
    #  ```
    @property
    def batch_size(self):
        return self.impl.getBatch()
    ## \note This property is deprecated:
    #  network precision does not make sense, use precision on edges.
    #
    #  Precision of the network
    @property
    def precision(self):
        warnings.filterwarnings("always", category=DeprecationWarning)
        warnings.warn("Network precision is deprecated "
                      "because it does not make sence, "
                      "use precision on egdes.",
                      DeprecationWarning)
        return self.impl.precision.decode()

    @batch_size.setter
    def batch_size(self, batch: int):
        if batch <= 0:
            raise AttributeError("Invalid batch size {}! Batch size should be positive integer value".format(batch))
        self.impl.setBatch(batch)

    ## Return dictionary that maps network layer names in topological order to IENetLayer
    #  objects containing layer properties
    @property
    def layers(self):
        cdef vector[C.CNNLayerPtr] c_layers = self.impl.getLayers()
        layers = OrderedDict()
        cdef IENetLayer net_l
        for l in c_layers:
            net_l = IENetLayer()
            net_l._ptr = l
            layers[deref(l).name.decode()] = net_l
        return layers

    ## \note This property is deprecated.
    #  New Calibration Tool doesn't generate statistics
    #
    #  Returns `LayersStatsMap` object containing dictionary that maps network layer names to calibration statistics
    #  represented by `LayerStats`  objects.
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  net.stats.update({"conv1_2d" : LayserStats(min=(-25, -1, 0), max=(63, 124, 70)),
    #                    "conv2_2d" : LayserStats(min=(-5, -1, 0, 1, -7, 2), max=(63, 124, 70, 174, 99, 106))
    #                   })
    #  ```
    @property
    def stats(self):
        warnings.filterwarnings("always", category=DeprecationWarning)
        warnings.warn("stats property of IENetwork is deprecated.",
                          DeprecationWarning)
        cdef map[string, map[string, vector[float]]] c_stats_map = self.impl.getStats()
        py_stats_map = LayersStatsMap()
        py_stats_map.net_impl = self.impl
        for it in c_stats_map:
            py_stats_map[it.first.decode()] = LayerStats(min=tuple(it.second["min".encode()]),
                                                         max=tuple(it.second["max".encode()]))
        return py_stats_map


    ## Marks any intermediate layer as output layer to retrieve the inference results from the specified layers.
    #  @param outputs: List of layers to be set as model outputs. The list can contain strings with layer names to be set
    #                  as outputs or tuples with layer name as first element and output port id as second element.
    #                  In case of setting one layer as output, string or tuple with one layer can be provided.
    #  @return None
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  net.add_outputs(["conv5_1', conv2_1', (split_2, 1)])]
    #  ```
    def add_outputs(self, outputs):
        if not isinstance(outputs, list):
            outputs = [outputs]
        for i, l in enumerate(outputs):
            if isinstance(l, str):
                self.impl.addOutput(l.encode(), 0)
            elif isinstance(l, tuple) and len(l) == 2:
                self.impl.addOutput(l[0].encode(), l[1])
            else:
                raise TypeError("Incorrect type {type} for layer to add at index {ind}. "
                                "Expected string with layer name or tuple with two elements: layer name as "
                                "first element and port id as second".format(type=type(l), ind=i))

    ## Serializes the network and stores it in files.
    #
    #  @param path_to_xml: Path to a file, where a serialized model will be stored
    #  @param path_to_bin: Path to a file, where serialized weights will be stored
    #  @return None
    #
    #  Usage example:
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml, weights=path_to_bin)
    #  net.serialize(path_to_xml, path_to_bin)
    #  ```
    def serialize(self, path_to_xml, path_to_bin: str = ""):
        self.impl.serialize(path_to_xml.encode(), path_to_bin.encode())

    ## Reshapes the network to change spatial dimensions, batch size, or any dimension.
    #
    #  \note Before using this method, make sure that the target shape is applicable for the network.
    #        Changing the network shape to an arbitrary value may lead to unpredictable behaviour.
    #
    #  @param input_shapes: A dictionary that maps input layer names to tuples with the target shape
    #  @return None
    #
    #  Usage example:\n
    #  ```python
    #  ie = IECore()
    #  net = ie.read_network(model=path_to_xml_file, weights=path_to_bin_file)
    #  input_layer = next(iter(net.inputs))
    #  n, c, h, w = net.inputs[input_layer]
    #  net.reshape({input_layer: (n, c, h*2, w*2)})
    #  ```
    def reshape(self, input_shapes: dict):
        cdef map[string, vector[size_t]] c_input_shapes;
        cdef vector[size_t] c_shape
        net_inputs = self.inputs
        for input, shape in input_shapes.items():
            c_shape = []
            if input not in net_inputs:
                raise AttributeError("Specified '{}' layer not in network inputs '{}'! ".format(input, net_inputs))
            for v in shape:
                c_shape.push_back(v)
            c_input_shapes[input.encode()] = c_shape
        self.impl.reshape(c_input_shapes)

    # TODO: ucomment when ngraph python api will work

    # def get_function(self):
    #     return self.impl.getFunction()

## This class is the main plugin interface and serves to initialize and configure the plugin.
#
#\note This class is deprecated: Use IECore instead
#
cdef class IEPlugin:
    ##  Class constructor
    #
    #  @param device: Target device name. Supported devices: CPU, GPU, FPGA, MYRIAD, HETERO, MULTI
    #  @param plugin_dirs: List of paths to plugin directories
    #  @return IEPlugin instance
    def __cinit__(self, device: str, plugin_dirs=None):
        warnings.filterwarnings("always", category=DeprecationWarning)
        warnings.warn("IEPlugin class is deprecated. "
                      "Please use IECore class instead.",
                      DeprecationWarning)
        plugin_base = device.split(':')[0]
        if plugin_base not in known_plugins:
            raise ValueError("Unknown plugin: {}, expected one of: {}"
                             .format(plugin_base, ",".join(known_plugins)))
        if plugin_dirs is None:
            plugin_dirs = [""]
        elif isinstance(plugin_dirs, str):
            plugin_dirs = [plugin_dirs]

        # add package directory to plugin_dirs
        lib_location = os.path.dirname(os.path.realpath(__file__))
        plugin_dirs.append(lib_location)

        cpdef string device_ = <string> device.encode()
        cdef vector[string] dirs_
        for d in plugin_dirs:
            dirs_.push_back(<string> d.encode())

        self.impl = C.IEPlugin(device_, dirs_)

    ## Loads a network that was read from the IR to the plugin and creates an executable network from a network object.
    #  You can create as many networks as you need and use them simultaneously (up to the limitation of the hardware
    #  resources).
    #
    #  @param network:  A valid `IENetwork` instance
    #  @param num_requests: A positive integer value of infer requests to be created. Number of infer
    #                       requests may be limited by device capabilities.
    #  @param config: A dictionary of plugin configuration keys and their values
    #  @return  Valid instance of ExecutableNetwork class
    #
    #  Usage example:\n
    #  ```python
    #  net = IENetwork(model=path_to_xml_file, weights=path_to_bin_file)
    #  ie = IECore()
    #  exec_net = ie.load_network(network=net, device_name="CPU", num_requsts=2)
    #  ```
    cpdef ExecutableNetwork load(self, IENetwork network, int num_requests=1, config=None):
        cdef ExecutableNetwork exec_net = ExecutableNetwork()
        cdef map[string, string] c_config
        if num_requests < 0:
            raise ValueError("Incorrect number of requests specified: {}. Expected positive integer number "
                             "or zero for auto detection".format(num_requests))
        if config:
            for k, v in config.items():
                c_config[to_std_string(k)] = to_std_string(v)
        exec_net.plugin_impl = self.impl
        exec_net.impl = move(self.impl.load(network.impl, num_requests, c_config))
        return exec_net

    ## Sets initial affinity for model layers according to the HETERO plugin logic. Applicable only if
    #  `IEPlugin` was initialized for a HETERO device.
    #
    #  @param net: A valid instance of IENetwork
    #  @return None
    #
    #  Usage example: See `affinity` attribute of the `IENetLayer` class.
    cpdef void set_initial_affinity(self, IENetwork net) except *:
        if self.device.find("HETERO") == -1:
            raise RuntimeError("set_initial_affinity method applicable only for HETERO device")
        self.impl.setInitialAffinity(net.impl)

    cpdef set get_supported_layers(self, IENetwork net):
        return set([l.decode() for l in self.impl.queryNetwork(net.impl)])

    ## A name of the device that was specified to initialize IEPlugin
    @property
    def device(self):
        device_name = bytes(self.impl.device_name)
        return to_py_string(device_name)

    ## A version of the plugin
    @property
    def version(self):
        version = bytes(self.impl.version)
        return version.decode()

    ## Loads extensions library to the plugin. Applicable only for a CPU device and a HETERO device with CPU
    #
    #  @param extension_path: A full path to CPU extensions library
    #  @return None
    cpdef void add_cpu_extension(self, str extension_path) except *:
        if self.device.find("CPU") == -1:
            raise RuntimeError("add_cpu_extension method applicable only for CPU or HETERO devices")
        cdef string extension_str = extension_path.encode()
        self.impl.addCpuExtension(extension_str)

    ## Sets a configuration for the plugin. Refer to `SetConfig()` in Inference Engine C++ documentation for acceptable
    #  keys and values list.
    #
    #  @param config: A dictionary of keys and values of acceptable configuration parameters
    #  @return None
    cpdef void set_config(self, config):
        cdef map[string, string] c_config
        for k, v in config.items():
            c_config[to_std_string(k)] = to_std_string(v)
        self.impl.setConfig(c_config)

    # TODO: Add export compiled network functionality

cdef class BlobBuffer:
    """Copy-less accessor for Inference Engine Blob"""

    cdef reset(self, Blob.Ptr & ptr, vector[size_t] representation_shape = []):
        self.ptr = ptr
        cdef TensorDesc desc = deref(ptr).getTensorDesc()
        cdef SizeVector shape
        if len(representation_shape) == 0:
            shape = desc.getDims()
        else:
            shape = representation_shape
        cdef Py_ssize_t itemsize = deref(ptr).element_size()
        self.strides.resize(shape.size())
        self.shape.resize(shape.size())

        total_stride = itemsize
        # dims are in row major (C - style),
        # thence strides are computed starting from latest dimension
        for i in reversed(range(shape.size())):
            self.strides[i] = total_stride
            self.shape[i] = shape[i]
            total_stride *= shape[i]

        self.total_stride = total_stride
        self.format = self._get_blob_format(desc)
        self.item_size = itemsize

    def __getbuffer__(self, Py_buffer *buffer, int flags):
        buffer.buf = C.get_buffer[char](deref(self.ptr))
        buffer.format = self.format
        buffer.internal = NULL
        buffer.itemsize = self.item_size
        buffer.len = self.total_stride
        buffer.ndim = self.shape.size()
        buffer.obj = self
        buffer.readonly = 0
        buffer.shape = self.shape.data()
        buffer.strides = self.strides.data()
        buffer.suboffsets = NULL

    cdef char*_get_blob_format(self, const TensorDesc & desc):
        cdef Precision precision = desc.getPrecision()
        name = bytes(precision.name()).decode()
        # todo: half floats
        precision_to_format = {
            'FP32': 'f',  # float
            'FP16': 'h',  # signed short
            'U8': 'B',  # unsigned char
            'U16': 'H',  # unsigned short
            'I8': 'b',  # signed char
            'I16': 'h',  # signed short
            'I32': 'i',  # signed int
            'I64': 'q',  # signed long int
            'U64': 'Q',  # signed long int
        }
        if name not in precision_to_format:
            raise ValueError("Unknown Blob precision: {}".format(name))

        return precision_to_format[name].encode()

    def to_numpy(self):
        return np.asarray(self)