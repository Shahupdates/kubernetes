#!/usr/bin/env bash

# Copyright 2016 The Kubernetes Authors.
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

# This file creates release artifacts (tar files, container images) that are
# ready to distribute to install or distribute to end users.

###############################################################################
# Most of the ::release:: namespace functions have been moved to
# github.com/kubernetes/release.  Have a look in that repo and specifically in
# lib/releaselib.sh for ::release::-related functionality.
###############################################################################

# This is where the final release artifacts are created locally
readonly RELEASE_STAGE="${LOCAL_OUTPUT_ROOT}/release-stage"
readonly RELEASE_TARS="${LOCAL_OUTPUT_ROOT}/release-tars"
readonly RELEASE_IMAGES="${LOCAL_OUTPUT_ROOT}/release-images"

KUBE_BUILD_CONFORMANCE=${KUBE_BUILD_CONFORMANCE:-n}
KUBE_BUILD_PULL_LATEST_IMAGES=${KUBE_BUILD_PULL_LATEST_IMAGES:-y}

# Validate release directories
if [[ -z $LOCAL_OUTPUT_ROOT ]]; then
  echo "Error: LOCAL_OUTPUT_ROOT is not set."
  exit 1
fi

if [[ ! -d $RELEASE_STAGE ]]; then
  echo "Error: RELEASE_STAGE directory does not exist."
  exit 1
fi

if [[ ! -d $RELEASE_TARS ]]; then
  echo "Error: RELEASE_TARS directory does not exist."
  exit 1
fi

if [[ ! -d $RELEASE_IMAGES ]]; then
  echo "Error: RELEASE_IMAGES directory does not exist."
  exit 1
fi

kube::release::clean_cruft() {
  # Clean out cruft
  find "${RELEASE_STAGE}" -name '*~' -exec rm {} \;
  find "${RELEASE_STAGE}" -name '#*#' -exec rm {} \;
  find "${RELEASE_STAGE}" -name '.DS*' -exec rm {} \;
}

kube::release::package_src_tarball() {
  local -r src_tarball="${RELEASE_TARS}/kubernetes-src.tar.gz"
  kube::log::status "Building tarball: src"

  if [[ -z $KUBE_GIT_TREE_STATE ]]; then
    echo "Error: KUBE_GIT_TREE_STATE is not set."
    return 1
  fi

  if [[ $KUBE_GIT_TREE_STATE = 'clean' ]]; then
    git archive -o "${src_tarball}" HEAD
  else
    find "${KUBE_ROOT}" -mindepth 1 -maxdepth 1 \
      ! \( \
        \( -path "${KUBE_ROOT}"/_\*       -o \
           -path "${KUBE_ROOT}"/.git\*    -o \
           -path "${KUBE_ROOT}"/.config\* -o \
           -path "${KUBE_ROOT}"/.gsutil\*    \
        \) -prune \
      \) -print0 \
    | "${TAR}" czf "${src_tarball}" --transform "s|${KUBE_ROOT#/*}|kubernetes|" --null -T -
  fi
}

kube::release::package_client_tarballs() {
  if [[ -z $KUBE_BUILD_PLATFORMS ]]; then
    echo "Error: KUBE_BUILD_PLATFORMS is not set."
    return 1
  fi

  local long_platforms=("${LOCAL_OUTPUT_BINPATH}"/*/*)
  read -ra long_platforms <<< "${KUBE_BUILD_PLATFORMS}"

  for platform_long in "${long_platforms[@]}"; do
    local platform
    local platform_tag
    platform=${platform_long##"${LOCAL_OUTPUT_BINPATH}"/}
    platform_tag=${platform/\//-}

    (
      local release_stage="${RELEASE_STAGE}/client/${platform_tag}/kubernetes"
      rm -rf "${release_stage}"
      mkdir -p "${release_stage}/client/bin"

      local client_bins=("${KUBE_CLIENT_BINARIES[@]}")
      if [[ "${platform%/*}" = 'windows' ]]; then
        client_bins=("${KUBE_CLIENT_BINARIES_WIN[@]}")
      fi

      cp "${client_bins[@]/#/${LOCAL_OUTPUT_BINPATH}/${platform}/}" \
        "${release_stage}/client/bin/"

      kube::release::clean_cruft

      local package_name="${RELEASE_TARS}/kubernetes-client-${platform_tag}.tar.gz"
      kube::release::create_tarball "${package_name}" "${release_stage}/.."
    ) &
  done

  kube::log::status "Waiting on tarballs"
  kube::util::wait-for-jobs || { kube::log::error "client tarball creation failed"; exit 1; }
}

kube::release::package_node_tarballs() {
  if [[ -z $KUBE_NODE_PLATFORMS ]]; then
    echo "Error: KUBE_NODE_PLATFORMS is not set."
    return 1
  fi

  local platform
  for platform in "${KUBE_NODE_PLATFORMS[@]}"; do
    local platform_tag
    local arch
    platform_tag=${platform/\//-}
    arch=$(basename "${platform}")

    local release_stage="${RELEASE_STAGE}/node/${platform_tag}/kubernetes"
    rm -rf "${release_stage}"
    mkdir -p "${release_stage}/node/bin"

    local node_bins=("${KUBE_NODE_BINARIES[@]}")
    if [[ "${platform%/*}" = 'windows' ]]; then
      node_bins=("${KUBE_NODE_BINARIES_WIN[@]}")
    fi

    cp "${node_bins[@]/#/${LOCAL_OUTPUT_BINPATH}/${platform}/}" \
      "${release_stage}/node/bin/"

    cp -R "${KUBE_ROOT}/LICENSES" "${release_stage}/"

    cp "${RELEASE_TARS}/kubernetes-src.tar.gz" "${release_stage}/"

    kube::release::clean_cruft

    local package_name="${RELEASE_TARS}/kubernetes-node-${platform_tag}.tar.gz"
    kube::release::create_tarball "${package_name}" "${release_stage}/.."
  done
}

kube::release::build_server_images() {
  kube::util::ensure-docker-buildx

  rm -rf "${RELEASE_IMAGES}"
  local platform
  for platform in "${KUBE_SERVER_PLATFORMS[@]}"; do
    local platform_tag
    local arch
    platform_tag=${platform/\//-}
    arch=$(basename "${platform}")

    local release_stage
    release_stage="${RELEASE_STAGE}/server/${platform_tag}/kubernetes"
    rm -rf "${release_stage}"
    mkdir -p "${release_stage}/server/bin"

    cp "${KUBE_SERVER_IMAGE_BINARIES[@]/#/${LOCAL_OUTPUT_BINPATH}/${platform}/}" \
      "${release_stage}/server/bin/"

    kube::release::create_docker_images_for_server "${release_stage}/server/bin" "${arch}"
  done
}

kube::release::package_server_tarballs() {
  if [[ -z $KUBE_SERVER_PLATFORMS ]]; then
    echo "Error: KUBE_SERVER_PLATFORMS is not set."
    return 1
  fi

  kube::release::build_server_images
  local platform
  for platform in "${KUBE_SERVER_PLATFORMS[@]}"; do
    local platform_tag
    local arch
    platform_tag=${platform/\//-}
    arch=$(basename "${platform}")

    local release_stage
    release_stage="${RELEASE_STAGE}/server/${platform_tag}/kubernetes"
    mkdir -p "${release_stage}/addons"

    cp "${KUBE_SERVER_BINARIES[@]/#/${LOCAL_OUTPUT_BINPATH}/${platform}/}" \
      "${release_stage}/server/bin/"

    local client_bins
    client_bins=("${KUBE_CLIENT_BINARIES[@]}")
    if [[ "${platform%/*}" = 'windows' ]]; then
      client_bins=("${KUBE_CLIENT_BINARIES_WIN[@]}")
    fi

    cp "${client_bins[@]/#/${LOCAL_OUTPUT_BINPATH}/${platform}/}" \
      "${release_stage}/server/bin/"

    cp -R "${KUBE_ROOT}/LICENSES" "${release_stage}/"

    cp "${RELEASE_TARS}/kubernetes-src.tar.gz" "${release_stage}/"

    kube::release::clean_cruft

    local package_name
    package_name="${RELEASE_TARS}/kubernetes-server-${platform_tag}.tar.gz"
    kube::release::create_tarball "${package_name}" "${release_stage}/.."
  done
}

kube::release::create_tarball() {
  local tarfile=$1
  local stagingdir=$2

  "${TAR}" czf "${tarfile}" -C "${stagingdir}" kubernetes --owner=0 --group=0
}

kube::release::clean_cruft

kube::release::package_tarballs() {
  rm -rf "${RELEASE_STAGE}" "${RELEASE_TARS}" "${RELEASE_IMAGES}"
  mkdir -p "${RELEASE_TARS}"
  kube::release::package_src_tarball &
  kube::release::package_client_tarballs &
  kube::release::package_node_tarballs &
  kube::release::package_server_tarballs &
  kube::util::wait-for-jobs || { kube::log::error "tarball creation failed"; exit 1; }
}

kube::release::package_test_platform_tarballs() {
  local platform
  rm -rf "${RELEASE_STAGE}/test"

  for platform in "${KUBE_TEST_PLATFORMS[@]}"; do
    (
      local platform_tag=${platform/\//-}
      kube::log::status "Starting tarball: test $platform_tag"
      local release_stage="${RELEASE_STAGE}/test/${platform_tag}/kubernetes"
      mkdir -p "${release_stage}/test/bin"

      local test_bins=("${KUBE_TEST_BINARIES[@]}")
      if [[ "${platform%/*}" = 'windows' ]]; then
        test_bins=("${KUBE_TEST_BINARIES_WIN[@]}")
      fi

      cp "${test_bins[@]/#/${LOCAL_OUTPUT_BINPATH}/${platform}/}" \
        "${release_stage}/test/bin/"

      local package_name="${RELEASE_TARS}/kubernetes-test-${platform_tag}.tar.gz"
      kube::release::create_tarball "${package_name}" "${release_stage}/.."
    ) &
  done

  kube::log::status "Waiting on test tarballs"
  kube::util::wait-for-jobs || { kube::log::error "test tarball creation failed"; exit 1; }
}

kube::release::package_final_tarball() {
  kube::log::status "Building tarball: final"

  local release_stage="${RELEASE_STAGE}/full/kubernetes"
  rm -rf "${release_stage}"
  mkdir -p "${release_stage}"

  mkdir -p "${release_stage}/client"
  cat <<EOF > "${release_stage}/client/README"
Client binaries are no longer included in the Kubernetes final tarball.

Run cluster/get-kube-binaries.sh to download client and server binaries.
EOF

  cp -R "${KUBE_ROOT}/cluster" "${release_stage}/"

  mkdir -p "${release_stage}/server"
  cp "${RELEASE_TARS}/kubernetes-manifests.tar.gz" "${release_stage}/server/"
  cat <<EOF > "${release_stage}/server/README"
Server binary tarballs are no longer included in the Kubernetes final tarball.

Run cluster/get-kube-binaries.sh to download client and server binaries.
EOF

  mkdir -p "${release_stage}/hack"
  cp -R "${KUBE_ROOT}/hack/lib" "${release_stage}/hack/"

  cp -R "${KUBE_ROOT}/docs" "${release_stage}/"
  cp "${KUBE_ROOT}/README.md" "${release_stage}/"
  cp "${KUBE_ROOT}/LICENSE" "${release_stage}/"
  cp "${KUBE_ROOT}/CHANGELOG/CHANGELOG-${KUBE_GIT_MAJOR}.md" "${release_stage}/CHANGELOG.md"

  kube::release::create_tarball "${RELEASE_TARS}/kubernetes.tar.gz" "${release_stage}/.."
}

kube::release::package_tarballs

kube::release::package_test_platform_tarballs

kube::release::package_final_tarball

