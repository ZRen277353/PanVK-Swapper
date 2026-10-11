/*
 * panvk_parse.h 的主机端单元测试。
 *
 * 起因: 真机上 "echo 1 > .../parameters/enabled" 写的是 "1\n", 而模块里
 * 曾经用 strcmp 精确比较, 导致 enable 永远失败; 规则串的尾部换行也会被
 * 当成路径的一部分。这两个教训都在这里固化成用例。
 *
 * 本机 (Windows SDK + MSVC):
 *   cmd /c "call vcvars64.bat && cl /nologo /TC /I tools\host-stubs tools\param-parse-test.c"
 * CI:
 *   gcc -std=gnu11 -Wall -I tools/host-stubs tools/param-parse-test.c -o /tmp/t && /tmp/t
 */
#define _CRT_SECURE_NO_WARNINGS 1
#include <stdio.h>
#include <string.h>

#define PS_PARSE_WARN(...) ((void)0)
#include "../kernel/panvk_parse.h"

static int failures;

#define CHECK(cond, ...)                                  \
	do {                                              \
		if (!(cond)) {                            \
			printf("FAIL(%s:%d): ", __FILE__, __LINE__); \
			printf(__VA_ARGS__);             \
			printf("\n");                    \
			failures++;                       \
		}                                         \
	} while (0)

static void test_bool(void)
{
	/* 内核 kstrtobool 只看首字符, 所以 yes/no 这类写法也应当接受 */
	static const char *yes[] = { "1", "1\n", " 1 \n", "y", "Y\n", "on", "ON\n",
				     "true", "true\n", "\tt\n", "t", "yes\n" };
	static const char *no[] = { "0", "0\n", " n \n", "N", "off\n", "false",
				    "false\n", "f", "\nf\n", "no" };
	static const char *bad[] = { "", "\n", " ", "2", "xyz", "o", "\n\n" };
	size_t i;
	bool v;

	for (i = 0; i < sizeof(yes) / sizeof(yes[0]); i++)
		CHECK(ps_parse_bool(yes[i], &v) && v, "应当解析为真: %s", yes[i]);
	for (i = 0; i < sizeof(no) / sizeof(no[0]); i++)
		CHECK(ps_parse_bool(no[i], &v) && !v, "应当解析为假: %s", no[i]);
	for (i = 0; i < sizeof(bad) / sizeof(bad[0]); i++)
		CHECK(!ps_parse_bool(bad[i], &v), "应当拒绝: %s", bad[i]);
	CHECK(!ps_parse_bool(NULL, &v), "应当拒绝 NULL");
}

static void test_uids(void)
{
	unsigned int uids[PS_MAX_UIDS];
	unsigned int nr, min, max;

	nr = ps_uids_parse("10123,10500", uids, &min, &max);
	CHECK(nr == 2 && uids[0] == 10123 && uids[1] == 10500, "逗号分隔, got %u", nr);
	CHECK(min == 10123 && max == 10500, "min/max 不对: %u/%u", min, max);

	/* sysfs 写入带换行 */
	nr = ps_uids_parse("10123,10500\n", uids, &min, &max);
	CHECK(nr == 2, "尾部换行应当被忽略, got %u", nr);

	nr = ps_uids_parse(" 1000 10123\n10500\t20000 \n", uids, &min, &max);
	CHECK(nr == 4 && min == 1000 && max == 20000, "空白/制表符/换行分隔, got %u", nr);

	nr = ps_uids_parse("", uids, &min, &max);
	CHECK(nr == 0, "空串应当得到 0 个, got %u", nr);
	nr = ps_uids_parse("\n", uids, &min, &max);
	CHECK(nr == 0, "只有一个换行也应当是 0 个, got %u", nr);

	nr = ps_uids_parse("abc,10123", uids, &min, &max);
	CHECK(nr == 1 && uids[0] == 10123, "非法项跳过, got %u", nr);
}

static void test_rules(void)
{
	struct ps_table t;

	CHECK(ps_rules_parse("/vendor/etc/vulkan/icd.d/*|/system/etc/panvk/icd.d/panvk.json",
			     &t) == 1, "单条规则");
	CHECK(t.nr == 1 && t.rules[0].prefix, "尾部 * 应当作为前缀匹配");
	CHECK(!strcmp(t.rules[0].src, "/vendor/etc/vulkan/icd.d/"), "src=%s", t.rules[0].src);
	CHECK(!strcmp(t.rules[0].dst, "/system/etc/panvk/icd.d/panvk.json"),
	      "dst=%s", t.rules[0].dst);

	/* 关键回归: sysfs 写入的尾部换行不能进到路径里 */
	CHECK(ps_rules_parse("a|b\n", &t) == 1, "带换行的单条规则");
	CHECK(!strcmp(t.rules[0].dst, "b"), "dst 不应带换行: '%s'", t.rules[0].dst);

	CHECK(ps_rules_parse("a|b;c|d\n", &t) == 2, "两条规则");
	CHECK(!strcmp(t.rules[1].src, "c") && !strcmp(t.rules[1].dst, "d"),
	      "第二条: %s -> %s", t.rules[1].src, t.rules[1].dst);

	CHECK(ps_rules_parse(" a|b ;\n c|d \n", &t) == 2, "留白与换行");
	CHECK(!strcmp(t.rules[1].src, "c") && !strcmp(t.rules[1].dst, "d"),
	      "带空白时: %s -> %s", t.rules[1].src, t.rules[1].dst);

	CHECK(ps_rules_parse("garbage", &t) == 0, "缺 | 的规则被丢弃");
	CHECK(ps_rules_parse("|dst", &t) == 0, "空 src 被丢弃");
	CHECK(ps_rules_parse("src|", &t) == 0, "空 dst 被丢弃");
	CHECK(ps_rules_parse("", &t) == 0, "空串");
	CHECK(ps_rules_parse("\n \n", &t) == 0, "只有换行与空格");

	/* 最多 PS_MAX_RULES 条 */
	CHECK(ps_rules_parse("1|a;2|b;3|c;4|d;5|e;6|f;7|g;8|h;9|i;10|j", &t) == PS_MAX_RULES,
	      "超量规则被截断");

	/* 规则表复用时不残留旧内容 */
	CHECK(ps_rules_parse("x|y", &t) == 1 && t.nr == 1, "复用后条数正确");
}

static void test_strip(void)
{
	char buf[64];

	strcpy(buf, "  a b \n");
	ps_str_strip(buf);
	CHECK(!strcmp(buf, "a b"), "只裁首尾: '%s'", buf);

	strcpy(buf, "\n\t \n");
	ps_str_strip(buf);
	CHECK(!strcmp(buf, ""), "全是空白时清空: '%s'", buf);
}

int main(void)
{
	test_bool();
	test_uids();
	test_rules();
	test_strip();

	if (failures) {
		printf("%d 个用例失败\n", failures);
		return 1;
	}
	printf("panvk_parse 全部用例通过\n");
	return 0;
}
