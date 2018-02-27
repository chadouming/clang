#!/usr/bin/env bash
#
# Clang compilation script
#
# Copyright (C) 2015-2016 DragonTC
# Copyright (C) 2018 Nathan Chancellor
# Copyright (C) 2018 Chad Cormier Roussel
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>
#
# Mix and mash of various script to build clang master branch and make
# it compatible with the latest release of android. Based on Nathan
# Chancellor's script with updated functions from DragonTC script. I
# added both in the copyright header for good measure.

# Define Color Values
red=$(tput setaf 1) # red
grn=$(tput setaf 2) # green
blu=$(tput setaf 4) # blue
cya=$(tput setaf 6) # cyan
txtbld=$(tput bold) # Bold
bldred=${txtbld}$(tput setaf 1) # red
bldgrn=${txtbld}$(tput setaf 2) # green
bldblu=${txtbld}$(tput setaf 4) # blue
bldcya=${txtbld}$(tput setaf 6) # cyan
txtrst=$(tput sgr0) # Reset

###############
#             #
#  VARIABLES  #
#             #
###############

MAIN_FOLDER=${HOME}/clang
LLVM_FOLDER=${MAIN_FOLDER}/llvm
BUILD_FOLDER=${MAIN_FOLDER}/build
START=$(date +"%s")


###############
#             #
#  FUNCTIONS  #
#             #
###############

function parse_parameters() {
    PARAMS="$*"

    while [[ $# -ge 1 ]]; do
        case ${1} in
            "-t"|"--telegram")
                TG=true
                TG_MSG_FILE=/tmp/tg-msg.2 ;;

            "-v"|"--version")
                shift && enforce_value "$@"
                VERSION=${1} ;;

            *) die "Invalid parameter specified!" ;;
        esac

        shift
    done

    if [[ ${TG} ]]; then
        {
            echo "\`\`\`"
            echo "Currently executing..."
            echo
            echo "$(basename "${0}") ${PARAMS}"
            echo "\`\`\`"
        } > ${TG_MSG_FILE}
        notify "$(cat ${TG_MSG_FILE})"
    fi

    if [[ -z ${VERSION} ]]; then
        VERSION=7
    fi
}

# Syncs requested  projects
function sync() {
    FOLDER=${1}

    if [[ ${FOLDER} =~ "binutils" ]]; then
        URL=http://sourceware.org/git/binutils-gdb.git
        BRANCH=binutils-2_30-branch
    else
        URL=https://git.llvm.org/git/$(basename "${FOLDER}")
        case ${VERSION} in
            "7") BRANCH=master ;;
            *) BRANCH="release_${VERSION}0" ;;
        esac
    fi

    if [[ ${FOLDER} =~ "clang-tools-extra" ]]; then
        FOLDER="clang/tools/extra"
    fi

    if [[ ! -d ${FOLDER} ]]; then
        git clone "${URL}" -b "${BRANCH}" "${FOLDER}"
    else
        (
        cd "${FOLDER}" || die "Error moving into ${FOLDER}"
        git clean -fxdq
        git checkout ${BRANCH}
        git fetch origin
        if ! git rebase origin/${BRANCH}; then
            die "Error updating $(basename "${FOLDER}")!"
        fi
        )
    fi
}

function sync_all() {
    header "Syncing projects"

    mkdir -p "${MAIN_FOLDER}"
    cd "${MAIN_FOLDER}" || die "Error creating ${MAIN_FOLDER}!"

    sync llvm

    mkdir -p "${LLVM_FOLDER}/tools"
    cd "${LLVM_FOLDER}/tools" || die "Error creating tools folder!"

    sync binutils
    sync clang
    sync lld
    sync polly
    sync clang-tools-extra

    mkdir -p "${LLVM_FOLDER}/projects"
    cd "${LLVM_FOLDER}/projects" || die "Error creating projects folder!"

    sync compiler-rt
    sync libcxx
    sync libcxxabi
    sync libunwind
    sync openmp
}

function cleanup() {
    rm -rf "${BUILD_FOLDER}"
    mkdir -p "${BUILD_FOLDER}"
    cd "${BUILD_FOLDER}" || die "Error creating build folder!"
}

function build() {
    header "Building Clang"

    if [[ ${TG} ]]; then
        notify "\`Beginning build of Clang ${VERSION}...\`"
    fi

    INSTALL_FOLDER=${MAIN_FOLDER}/out/clang-${VERSION}.x

    cmake -DLINK_POLLY_INTO_TOOLS:BOOL=ON \
          -DCMAKE_CXX_FLAGS:STRING="-O3 -Wno-macro-redefined -pipe -pthread -fopenmp -g0 -march=native -mtune=native" \
          -DCMAKE_C_FLAGS:STRING="-O3 -Wno-macro-redefined -pipe -pthread -fopenmp -g0 -march=native -mtune=native" \
          -DLLVM_ENABLE_PIC:BOOL=ON \
          -DCMAKE_INSTALL_PREFIX:PATH=${INSTALL_FOLDER} \
          -DLLVM_PARALLEL_COMPILE_JOBS="${THREADS}" \
          -DLLVM_PARALLEL_LINK_JOBS="${THREADS}" \
          -DLLVM_ENABLE_THREADS:BOOL=ON \
          -DLLVM_ENABLE_WARNINGS:BOOL=OFF \
          -DLLVM_ENABLE_WERROR:BOOL=OFF \
          -DLLVM_INCLUDE_EXAMPLES:BOOL=OFF \
          -DLLVM_INCLUDE_TESTS:BOOL=OFF \
          -DLLVM_BINUTILS_INCDIR:PATH="${LLVM_FOLDER}/tools/binutils/include" \
          -DLLVM_TARGETS_TO_BUILD:STRING="X86;ARM;AArch64;NVPTX" \
          -DCMAKE_BUILD_TYPE:STRING=MinSizeRel \
          -DLLVM_OPTIMIZED_TABLEGEN:BOOL=ON \
          -DPOLLY_ENABLE_GPGPU_CODEGEN:BOOL=ON \
          -DLLVM_CCACHE_BUILD:BOOL=ON \
          -DLLVM_USE_LINKER:STRING=gold \
          "${LLVM_FOLDER}"

    if ! time cmake --build . -- "${JOBS_FLAG}"; then
        header "ERROR BUILDING!"
        die "Time elapsed: $(format_time "$(date +"%s")" "${START}")"
    fi
}

function install() {
    header "Installing Clang"

    rm -rf "${INSTALL_FOLDER}-old"
    mv "${INSTALL_FOLDER}" "${INSTALL_FOLDER}-old"
    if ! cmake --build . --target install -- "${JOBS_FLAG}"; then
        header "ERROR INSTALLING!"
        if [[ ${TG} ]]; then
            {
                echo "\`\`\`"
                echo "Error while building Clang ${VERSION}!"
                echo
                echo "Time elapsed: $(format_time "$(date +"%s")" "${START}")"
                echo "\`\`\`"
            } > "${TG_MSG_FILE}"
            notify "$(cat ${TG_MSG_FILE})"
        fi
        die "Time elapsed: $(format_time "$(date +"%s")" "${START}")"
    fi

    cp -R ${MAIN_FOLDER}/aosp_prebuilts/** ${INSTALL_FOLDER}/;

    header "SUCCESS!" "${GRN}"
    echo "${GRN}Successfully built and installed Clang toolchain to ${INSTALL_FOLDER}!${GRN}"
    echo "${GRN}Time elapsed: $(format_time "$(date +"%s")" "${START}")${RST}\n"
    if [[ ${TG} ]]; then
        {
            echo "\`\`\`"
            echo "Clang ${VERSION} build was successful!"
            echo
            echo "Time elapsed: $(format_time "$(date +"%s")" "${START}")"
            echo "\`\`\`"
        } > "${TG_MSG_FILE}"
        notify "$(cat ${TG_MSG_FILE})"
    fi
}

source common
parse_parameters "$@"
sync_all
cleanup
build
install
