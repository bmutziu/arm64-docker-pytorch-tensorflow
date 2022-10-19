#!/usr/bin/env bash

# *******************************************************************************
# Copyright 2020 Arm Limited and affiliates.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# *******************************************************************************


# Staged docker build for PyTorch
# ==================================

################################################################################
function print_usage_and_exit {
  echo "Usage: build.sh [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -h, --help                   Display this message"
  echo "      --jobs                   Specify number of jobs to run in parallel during the build"
  echo "      --bazel_memory_limit     Set a memory limit (MB) for Bazel build (default: 2048)."
  echo "      --pt_onednn              Build and link to oneDNN / DNNL on PyTorch:"
  echo "                                 * reference    - use the C++ reference kernels throughout."
  echo "                                 * acl          - use Arm Compute Library (default)."
  echo "      --tf_onednn              Build and link to oneDNN / DNNL on TensorFlow:"
  echo "                                 * reference    - use the C++ reference kernels throughout."
  echo "                                 * acl          - use Arm Compute Library (default)."
  echo "      --build-type             Type of build to perform:"
  echo "                                 * base         - build the basic portion of the image, OS and essential packages"
  echo "                                 * libs         - build image including maths libraries and Python3."
  echo "                                 * tools        - build image including Python3 venv, with numpy."
  echo "                                 * dev          - build image including Bazel, TensorFlow and PyTorch, with sources."
  echo "                                 * coding       - build image including TensorFlow and PyTorch"
  echo "                                 * examples     - build image including TensorFlow and PyTorch build and benchmarks installed"
  echo "                                 * full         - build all images."
  echo "      --clean                  Pull a new base image and build without using any cached images."
  echo ""
  echo "Example:"
  echo "  build.sh --build-type full"
  exit $1
}

################################################################################

cpu="native"
tune="native"
arch="native"
blas_cpu=
blas_ncores=
acl_arch="arm64-v8a"

# Enable Buildkit
# Required for advanced multi-stage builds
# Requires Docker v 18.09.1
export DOCKER_BUILDKIT=1

# Default build flags
build_base_image=
build_libs_image=
build_tools_image=
build_dev_image=
build_coding_image=1
build_examples_image=

readonly target_arch="aarch64"
readonly host_arch=$(arch)

if ! [ "$host_arch" == "$target_arch" -o "$host_arch" == "arm64" ]; then
   echo "Error: $(arch) is not supported"
   print_usage_and_exit 1
fi


# Default args
extra_args=""
nproc_build=
bazel_mem="2048"
enable_onednn=0
pt_onednn=
tf_onednn=
target="native"
clean_build=
xla=

while [ $# -gt 0 ]
do
  case $1 in
    --build-type )
      case $2 in
        base )
          build_base_image=1
          build_libs_image=
          build_tools_image=
          build_dev_image=
          build_coding_image=
          build_examples_image=
          ;;
        libs )
          build_base_image=
          build_libs_image=1
          build_tools_image=
          build_dev_image=
          build_coding_image=
          build_examples_image=
          ;;
         tools )
          build_base_image=
          build_libs_image=
          build_tools_image=1
          build_dev_image=
          build_coding_image=
          build_examples_image=
          ;;
        dev )
          build_base_image=
          build_libs_image=
          build_tools_image=
          build_dev_image=1
          build_coding_image=
          build_examples_image=
          ;;
        coding )
          build_base_image=
          build_libs_image=
          build_tools_image=
          build_dev_image=
          build_coding_image=1
          build_examples_image=
          ;;
        full )
          build_base_image=1
          build_libs_image=1
          build_tools_image=1
          build_dev_image=1
          build_coding_image=1
          build_examples_image=1
          ;;
        examples )
          build_base_image=
          build_libs_image=
          build_tools_image=
          build_dev_image=
          build_coding_image=
          build_examples_image=1
          ;;
        * )
          echo "Error: $2 is an invalid build type!"
          print_usage_and_exit 1
          ;;
      esac
      shift
      ;;

    --jobs )
      nproc_build=$2
      shift
      ;;

    --bazel_memory_limit )
      bazel_mem=$2
      shift
      ;;

    --pt_onednn )
      if [[ $# -gt 1 ]]; then
        case $2 in
          reference )
            pt_onednn="reference"
            shift
            ;;
          acl )
            pt_onednn="acl"
            shift
            ;;
          * )
            echo "Defaulting to oneDNN-ACL build."
            echo "Note: support for oneDNN builds with OpenBLAS or ArmPL is now deprecated."
            pt_onednn="acl"
            ;;
        esac
      else
        pt_onednn="acl"
      fi
      ;;

    --tf_onednn )
      enable_onednn=1
      if [[ $# -gt 1 ]]; then
        case $2 in
          reference )
            tf_onednn="reference"
            shift
            ;;
          acl )
            tf_onednn="acl"
            shift
            ;;
          * )
            echo "Defaulting to oneDNN-ACL build."
            echo "Note: support for oneDNN builds with OpenBLAS or ArmPL is now deprecated."
            tf_onednn="acl"
            ;;
        esac
      else
        tf_onednn="acl"
      fi
      ;;

    --clean )
      clean_build=1
      ;;

    -h | --help )
      print_usage_and_exit 0
      ;;

  esac
  shift
done

# exec > >(tee -i build.log)
# exec 2>&1

if [[ $nproc_build ]]; then
  # Set -j to use for builds, if specified
  extra_args="$extra_args --build-arg njobs=$nproc_build"
fi

if [[ $bazel_mem ]]; then
  # Set -j to use for builds, if specified
  extra_args="$extra_args --build-arg bazel_mem=$bazel_mem"
fi

if [[ $pt_onednn ]]; then
  # Use oneDNN backend
  extra_args="--build-arg pt_onednn_opt=$pt_onednn $extra_args"
fi

# Add oneDNN build options
if [[ $tf_onednn ]]; then
  extra_args="--build-arg tf_onednn_opt=$tf_onednn $extra_args --build-arg enable_onednn=$enable_onednn"
fi

if [[ $clean_build ]]; then
  # Pull a new base image, and don't use any caches
  extra_args="--pull --no-cache $extra_args"
fi

if [[ $xla ]]; then
  # Build xla backend
  extra_args="--build-arg build_xla=$xla $extra_args"
fi

# Set TensorFlow
tf_version="v2.9.1"
tfserving_version="2.7.0"
extra_args="$extra_args \
  --build-arg tf_version=$tf_version \
  --build-arg tfserving_version=$tfserving_version"

image_tag="pytorch1.12.0_tensorflow2.9.1"

extra_args="$extra_args --build-arg cpu=$cpu \
    --build-arg tune=$tune \
    --build-arg arch=$arch \
    --build-arg blas_cpu=$blas_cpu \
    --build-arg blas_ncores=$blas_ncores \
    --build-arg eigen_l1_cache= \
    --build-arg eigen_l2_cache= \
    --build-arg eigen_l3_cache= \
    --build-arg acl_arch=$acl_arch \
    --build-arg image_tag=$image_tag"

echo $extra_args

if [[ $build_base_image ]]; then
  # Stage 1: Base image, Ubuntu with core packages and GCC
  docker build $extra_args --target deep-learning-base -t deep-learning-base:$image_tag .
fi

if [[ $build_libs_image ]]; then
  # Stage 2: Libs image, essential maths libs and Python built and installed
  docker build $extra_args --target deep-learning-libs -t deep-learning-libs:$image_tag .
fi

if [[ $build_tools_image ]]; then
  # Stage 3: Tools image, Python3 venv added with additional Python essentials
  docker build $extra_args --target deep-learning-tools -t deep-learning-tools:$image_tag .
fi

if [[ $build_dev_image ]]; then
  # Stage 4: Adds TensorFlow and Pytorch build with sources
  # docker buildx create --driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=1073741824 --driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=10240000 --name tp-builder --use
  docker buildx build $extra_args --target deep-learning-dev -t deep-learning-dev:$image_tag .
fi

if [[ $build_coding_image ]]; then
  # Stage 5: Setup Coding Environment
  docker build $extra_args --target deep-learning-coding -t deep-learning-coding:$image_tag .
fi

if [[ $build_examples_image ]]; then
  # Stage 6: Adds Deep Learning examples
  docker build $extra_args --target deep-learning-examples -t deep-learning-examples:$image_tag .
fi

