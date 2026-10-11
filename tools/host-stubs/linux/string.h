/* 主机端单元测试: 直接借用 C 库的字符串函数, 只给出声明 */
#pragma once
#include <stddef.h>

size_t strlen(const char *s);
void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memchr(const void *s, int c, size_t n);
char *strpbrk(const char *s, const char *accept);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
