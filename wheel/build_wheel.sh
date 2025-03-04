#!/usr/bin/env bash
set -ex
SOURCE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

# Env variables that should be set:
#   DESIRED_PYTHON
#     Which Python version to build for in format 'Maj.min' e.g. '2.7' or '3.6'
#
#   PYTORCH_FINAL_PACKAGE_DIR
#     **absolute** path to folder where final whl packages will be stored. The
#     default should not be used when calling this from a script. The default
#     is 'whl', and corresponds to the default in the wheel/upload.sh script.
#
#   MAC_PACKAGE_WORK_DIR
#     absolute path to a workdir in which to clone an isolated conda
#     installation and pytorch checkout. If the pytorch checkout already exists
#     then it will not be overwritten.

# Function to retry functions that sometimes timeout or have flaky failures
retry () {
    $*  || (sleep 1 && $*) || (sleep 2 && $*) || (sleep 4 && $*) || (sleep 8 && $*)
}

# Parameters
if [[ -n "$DESIRED_PYTHON" && -n "$PYTORCH_BUILD_VERSION" && -n "$PYTORCH_BUILD_NUMBER" ]]; then
    desired_python="$DESIRED_PYTHON"
    build_version="$PYTORCH_BUILD_VERSION"
    build_number="$PYTORCH_BUILD_NUMBER"
else
    if [ "$#" -ne 3 ]; then
        echo "illegal number of parameters. Need PY_VERSION BUILD_VERSION BUILD_NUMBER"
        echo "for example: build_wheel.sh 2.7 0.1.6 20"
        echo "Python version should be in format 'M.m'"
        exit 1
    fi
    desired_python=$1
    build_version=$2
    build_number=$3
fi

echo "Building for Python: $desired_python Version: $build_version Build: $build_number"
echo "This is for OSX. There is no CUDA/CUDNN"
python_nodot="$(echo $desired_python | tr -d m.u)"

# Version: setup.py uses $PYTORCH_BUILD_VERSION.post$PYTORCH_BUILD_NUMBER if
# PYTORCH_BUILD_NUMBER > 1
if [[ -n "$OVERRIDE_PACKAGE_VERSION" ]]; then
    # This will be the *exact* version, since build_number<1
    build_version="$OVERRIDE_PACKAGE_VERSION"
    build_number=0
    build_number_prefix=''
else
    if [[ $build_number -eq 1 ]]; then
        build_number_prefix=""
    else
        build_number_prefix=".post$build_number"
    fi
fi
export PYTORCH_BUILD_VERSION=$build_version
export PYTORCH_BUILD_NUMBER=$build_number

# Fill in empty parameters with defaults
if [[ -z "$TORCH_PACKAGE_NAME" ]]; then
    TORCH_PACKAGE_NAME='torch'
fi
TORCH_PACKAGE_NAME="$(echo $TORCH_PACKAGE_NAME | tr '-' '_')"
if [[ -z "$PYTORCH_REPO" ]]; then
    PYTORCH_REPO='pytorch'
fi
if [[ -z "$PYTORCH_BRANCH" ]]; then
    PYTORCH_BRANCH="v${build_version}"
fi
if [[ -z "$RUN_TEST_PARAMS" ]]; then
    RUN_TEST_PARAMS=()
fi
if [[ -z "$PYTORCH_FINAL_PACKAGE_DIR" ]]; then
    if [[ -n "$BUILD_PYTHONLESS" ]]; then
        PYTORCH_FINAL_PACKAGE_DIR='libtorch'
    else
        PYTORCH_FINAL_PACKAGE_DIR='whl'
    fi
fi
mkdir -p "$PYTORCH_FINAL_PACKAGE_DIR" || true

# Create an isolated directory to store this builds pytorch checkout and conda
# installation
if [[ -z "$MAC_PACKAGE_WORK_DIR" ]]; then
    MAC_PACKAGE_WORK_DIR="$(pwd)/tmp_wheel_conda_${DESIRED_PYTHON}_$(date +%H%M%S)"
fi
mkdir -p "$MAC_PACKAGE_WORK_DIR" || true
if [[ -n ${GITHUB_ACTIONS} ]]; then
    pytorch_rootdir="${PYTORCH_ROOT:-${MAC_PACKAGE_WORK_DIR}/pytorch}"
else
    pytorch_rootdir="${MAC_PACKAGE_WORK_DIR}/pytorch"
fi
whl_tmp_dir="${MAC_PACKAGE_WORK_DIR}/dist"
mkdir -p "$whl_tmp_dir"

# Python 3.5 build against macOS 10.6, others build against 10.9
# NB: Sometimes Anaconda revs the version, in which case you'll have to
# update this!
# An example of this happened on Aug 13, 2019, when osx-64/python-2.7.16-h97142e2_2.tar.bz2
# was uploaded to https://anaconda.org/anaconda/python/files
if [[ "$desired_python" == 3.5 ]]; then
    mac_version='macosx_10_6_x86_64'
elif [[ "$desired_python" == 2.7 ]]; then
    mac_version='macosx_10_7_x86_64'
elif [[ -n "$CROSS_COMPILE_ARM64" ]]; then
    mac_version='macosx_11_0_arm64'
else
    mac_version='macosx_10_9_x86_64'
fi

# Create a consistent wheel package name to rename the wheel to
wheel_filename_new="${TORCH_PACKAGE_NAME}-${build_version}${build_number_prefix}-cp${python_nodot}-none-${mac_version}.whl"

###########################################################

# Have a separate Pytorch repo clone
if [[ ! -d "$pytorch_rootdir" ]]; then
    git clone "https://github.com/${PYTORCH_REPO}/pytorch" "$pytorch_rootdir"
    pushd "$pytorch_rootdir"
    if ! git checkout "$PYTORCH_BRANCH" ; then
        echo "Could not checkout $PYTORCH_BRANCH, so trying tags/v${build_version}"
        git checkout tags/v${build_version}
    fi
    popd
fi
pushd "$pytorch_rootdir"
git submodule update --init --recursive --jobs 0
popd

##########################
# now build the binary


export TH_BINARY_BUILD=1
export INSTALL_TEST=0 # dont install test binaries into site-packages
export MACOSX_DEPLOYMENT_TARGET=10.10
export CMAKE_PREFIX_PATH=${CONDA_PREFIX:-"$(dirname $(which conda))/../"}

SETUPTOOLS_PINNED_VERSION="=46.0.0"
PYYAML_PINNED_VERSION="=5.3"
EXTRA_CONDA_INSTALL_FLAGS=""
case ${desired_python} in
    3.10)
        SETUPTOOLS_PINNED_VERSION=">=46.0.0"
        PYYAML_PINNED_VERSION=">=5.3"
        NUMPY_PINNED_VERSION="=1.21.2"
        ;;
    3.9)
        SETUPTOOLS_PINNED_VERSION=">=46.0.0"
        PYYAML_PINNED_VERSION=">=5.3"
        NUMPY_PINNED_VERSION="=1.19"
        ;;
    3.8)
        NUMPY_PINNED_VERSION="=1.17"
        ;;
    *)
        NUMPY_PINNED_VERSION="=1.11.3"
        ;;
esac

# Install into a fresh env
tmp_env_name="wheel_py$python_nodot"
conda create ${EXTRA_CONDA_INSTALL_FLAGS} -yn "$tmp_env_name" python="$desired_python"
source activate "$tmp_env_name"

retry conda install ${EXTRA_CONDA_INSTALL_FLAGS} -yq cmake "numpy${NUMPY_PINNED_VERSION}" nomkl "setuptools${SETUPTOOLS_PINNED_VERSION}" "pyyaml${PYYAML_PINNED_VERSION}" cffi typing_extensions ninja requests
retry conda install ${EXTRA_CONDA_INSTALL_FLAGS} -yq mkl-include==2020.1 mkl-static==2020.1 -c intel
retry pip install -qr "${pytorch_rootdir}/requirements.txt" || true

# For USE_DISTRIBUTED=1 on macOS, need libuv and pkg-config to find libuv.
export USE_DISTRIBUTED=1
retry conda install ${EXTRA_CONDA_INSTALL_FLAGS} -yq libuv pkg-config

if [[ -n "$CROSS_COMPILE_ARM64" ]]; then
    export CMAKE_OSX_ARCHITECTURES=arm64
    export USE_MKLDNN=OFF
    export USE_NNPACK=OFF
    export USE_QNNPACK=OFF
    export BUILD_TEST=OFF
else
    retry conda install ${EXTRA_CONDA_INSTALL_FLAGS} -yq llvmdev=9
    export USE_LLVM="${CONDA_PREFIX}"
fi

pushd "$pytorch_rootdir"
echo "Calling setup.py bdist_wheel at $(date)"

python setup.py bdist_wheel -d "$whl_tmp_dir"

echo "Finished setup.py bdist_wheel at $(date)"

echo "delocating wheel dependencies"
retry pip install https://github.com/matthew-brett/delocate/archive/master.zip
echo "found the following wheels:"
find $whl_tmp_dir -name "*.whl"
echo "running delocate"
find $whl_tmp_dir -name "*.whl" | xargs -I {} delocate-wheel -v {}
find $whl_tmp_dir -name "*.whl"
find $whl_tmp_dir -name "*.whl" | xargs -I {} delocate-listdeps {}
echo "Finished delocating wheels at $(date)"

echo "The wheel is in $(find $whl_tmp_dir -name '*.whl')"

wheel_filename_gen=$(find $whl_tmp_dir -name '*.whl' | head -n1 | xargs -I {} basename {})
popd

if [[ -z "$BUILD_PYTHONLESS" ]]; then
    # Copy the whl to a final destination before tests are run
    echo "Renaming Wheel file: $wheel_filename_gen to $wheel_filename_new"
    cp "$whl_tmp_dir/$wheel_filename_gen" "$PYTORCH_FINAL_PACKAGE_DIR/$wheel_filename_new"

    ##########################
    # now test the binary, unless it's cross compiled arm64
    if [[ -z "$CROSS_COMPILE_ARM64" ]]; then
        pip uninstall -y "$TORCH_PACKAGE_NAME" || true
        pip uninstall -y "$TORCH_PACKAGE_NAME" || true

        # Create new "clean" conda environment for testing
        conda create ${EXTRA_CONDA_INSTALL_FLAGS} -yn "test_conda_env" python="$desired_python"
        conda activate test_conda_env

        pip install "$PYTORCH_FINAL_PACKAGE_DIR/$wheel_filename_new" -v

        echo "$(date) :: Running tests"
        pushd "$pytorch_rootdir"
        "${SOURCE_DIR}/../run_tests.sh" 'wheel' "$desired_python" 'cpu'
        popd
        echo "$(date) :: Finished tests"
    fi
else
    pushd "$pytorch_rootdir"
    mkdir -p build
    pushd build
    # TODO: Remove this flag once https://github.com/pytorch/pytorch/issues/55952 is closed
    CFLAGS='-Wno-deprecated-declarations' python ../tools/build_libtorch.py
    popd

    mkdir -p libtorch/{lib,bin,include,share}
    cp -r "$(pwd)/build/lib" "$(pwd)/libtorch/"

    # for now, the headers for the libtorch package will just be
    # copied in from the wheel
    unzip -d any_wheel "$whl_tmp_dir/$wheel_filename_gen"
    if [[ -d $(pwd)/any_wheel/torch/include ]]; then
        cp -r "$(pwd)/any_wheel/torch/include" "$(pwd)/libtorch/"
    else
        cp -r "$(pwd)/any_wheel/torch/lib/include" "$(pwd)/libtorch/"
    fi
    cp -r "$(pwd)/any_wheel/torch/share/cmake" "$(pwd)/libtorch/share/"
    if [[ -x "$(pwd)/any_wheel/torch/.dylibs/libiomp5.dylib" ]]; then
        cp -r "$(pwd)/any_wheel/torch/.dylibs/libiomp5.dylib" "$(pwd)/libtorch/lib/"
    else
        cp -r "$(pwd)/any_wheel/torch/lib/libiomp5.dylib" "$(pwd)/libtorch/lib/"
    fi
    rm -rf "$(pwd)/any_wheel"

    echo $PYTORCH_BUILD_VERSION > libtorch/build-version
    echo "$(pushd $pytorch_rootdir && git rev-parse HEAD)" > libtorch/build-hash

    zip -rq "$PYTORCH_FINAL_PACKAGE_DIR/libtorch-macos-$PYTORCH_BUILD_VERSION.zip" libtorch
    cp "$PYTORCH_FINAL_PACKAGE_DIR/libtorch-macos-$PYTORCH_BUILD_VERSION.zip"  \
       "$PYTORCH_FINAL_PACKAGE_DIR/libtorch-macos-latest.zip"
fi
