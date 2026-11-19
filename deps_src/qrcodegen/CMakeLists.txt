cmake_minimum_required(VERSION 3.13)
project(qrcodegen)

# Project Nayuki's QR Code generator (MIT), v1.8.0, unmodified.
add_library(qrcodegen STATIC
    qrcodegen.cpp
    qrcodegen.hpp
)

target_include_directories(qrcodegen SYSTEM PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>)
target_compile_features(qrcodegen PUBLIC cxx_std_11)
set_target_properties(qrcodegen PROPERTIES POSITION_INDEPENDENT_CODE ON)
