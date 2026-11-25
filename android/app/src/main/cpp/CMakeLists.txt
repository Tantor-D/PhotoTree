cmake_minimum_required(VERSION 3.10)
project(phototree_directories LANGUAGES CXX)

add_library(phototree_directories SHARED directories.cpp)
set_target_properties(phototree_directories PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    CXX_EXTENSIONS OFF
)
target_compile_options(phototree_directories PRIVATE -Wall -Wextra -Werror)
