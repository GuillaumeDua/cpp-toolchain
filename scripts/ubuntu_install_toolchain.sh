#!/bin/bash

echo "usage :
     --all=latest    : all release automatically set to their latest
     --cmake-release : cmake release.              ex : 3.20.1
     --gcc-release   : gcc release (major only).   ex : 10
     --clang-release : clang release (major only). ex : 11
"

all_latest=false
while true; do
    case "$1" in
        --all=latest)
            all_latest=true; shift; break;;
        --cmake-release)
            cmake_release=$2; shift 2;;
        --clang-release)
            clang_release=$2; shift 2;;
        --gcc-release)
            gcc_release=$2; shift 2;;
        --) shift; break;;
        *)
            if [ "$1" = "" ] ; then
                shift; break;
            else
                echo "error : unknown option : $1"
                exit 1
            fi;;
    esac
done

[[ $all_latest = true ]] && manual_or_auto="auto" || manual_or_auto="manual"

echo "Requested releases ($manual_or_auto) :"

if [[ $all_latest = true ]]; then
    echo "fetching latest releases ..."
else
    echo "not implemented yet"
    exit 1
fi

echo "- CMake : $cmake_release"
echo "- GCC   : $gcc_release"
echo "- Clang : $clang_release"



# sudo apt update && sudo apt upgrade
# sudo apt install rsync git build-essential clang gcc

# # GCC
# sudo apt install gcc-9 g++-9 gcc-10 g++-10
# sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 100 \
#     --slave /usr/bin/g++ g++  /usr/bin/g++-10 --slave /usr/bin/gcov gcov /usr/bin/gcov-10

# # Clang
# sudo bash -c "$(wget -O - https://apt.llvm.org/llvm.sh)"
# sudo update-alternatives --install /usr/bin/clang clang /usr/bin/clang-12 100 \
#     --slave /usr/bin/clang++ clang++ /usr/bin/clang++-12

# #CMake
# sudo apt install libssl-dev
# wget https://github.com/Kitware/CMake/releases/download/v3.20.1/cmake-3.20.1.tar.gz
# tar -xvf cmake-3.20.1.tar.gz && cd cmake-3.20.1
# cmake . && sudo make && sudo make install

# sudo ln -s /usr/local/bin/cmake /usr/bin/cmake-3.20.1
# sudo update-alternatives --install /usr/bin/cmake cmake /usr/bin/cmake-3.20.1 100 \
#     --slave /usr/bin/ccmake ccmake /usr/local/bin/ccmake \
#     --slave /usr/bin/cpack cpack /usr/local/bin/cpack \
#     --slave /usr/bin/ctest ctest /usr/local/bin/ctest
