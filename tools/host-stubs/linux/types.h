/* 主机端单元测试用的最小内核类型替身 (只为跑 panvk_parse.h, 不模拟整个内核) */
#pragma once
#include <stddef.h>

typedef int bool;
#define true 1
#define false 0
