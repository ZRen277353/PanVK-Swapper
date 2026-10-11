cmake_minimum_required(VERSION 3.22.1)
project(panvkprobe C)

add_library(panvkprobe SHARED vulkan_probe.c)
target_link_libraries(panvkprobe vulkan android log)
