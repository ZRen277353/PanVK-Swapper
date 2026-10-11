/* SPDX-License-Identifier: GPL-2.0 */
/*
 * panvk_parse.h - 模块参数的纯解析逻辑
 *
 * 单独放在头文件里, 是为了能在主机上直接跑单元测试 (tools/param-parse-test.c),
 * 不依赖内核构建。
 *
 * 两条血泪教训:
 *   1. sysfs 写入是带换行的 ("echo 1 > enabled" 得到的是 "1\n"), 所以
 *      bool 参数不能拿 strcmp 去精确比较, 否则真实的 enable 写永远失败;
 *   2. 路径规则同样会被尾部换行污染, 解析时必须把换行/空白当分隔符并裁掉,
 *      否则重定向目标会变成一个带 "\n" 的不存在路径。
 */
#ifndef PANVK_PARSE_H
#define PANVK_PARSE_H

#include <linux/types.h>
#include <linux/string.h>

#define PS_MAX_RULES 8
#define PS_MAX_UIDS  64
#define PS_NAME_MAX  256

/* 告警宏: 内核侧由 linux/module.h 提供 pr_warn, 主机测试里可以自行覆盖 */
#ifndef PS_PARSE_WARN
#define PS_PARSE_WARN(...) pr_warn(__VA_ARGS__)
#endif

struct ps_rule {
	char src[PS_NAME_MAX];
	char dst[PS_NAME_MAX];
	unsigned short srclen;
	unsigned short dstlen;
	bool prefix;
};

struct ps_table {
	unsigned int nr;
	struct ps_rule rules[PS_MAX_RULES];
};

static inline bool ps_is_space(char c)
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

/* 去掉首尾空白 (原地) */
static inline void ps_str_strip(char *s)
{
	char *p = s;
	char *end;

	while (ps_is_space(*p))
		p++;
	if (p != s)
		memmove(s, p, strlen(p) + 1);

	end = s + strlen(s);
	while (end > s && ps_is_space(end[-1]))
		*(--end) = '\0';
}

/*
 * 接受 1/0, y/n, t/f, on/off, true/false (大小写不敏感), 并且忽略首尾空白,
 * 也就是内核 kstrtobool 那套宽松写法 —— "1\n" 必须成功。
 */
static inline bool ps_parse_bool(const char *val, bool *out)
{
	const char *p = val;
	char first;

	if (!p)
		return false;
	while (ps_is_space(*p))
		p++;

	first = *p;
	if (first >= 'A' && first <= 'Z')
		first = (char)(first - 'A' + 'a');

	if (first == 'y' || first == '1' || first == 't') {
		*out = true;
		return true;
	}
	if (first == 'n' || first == '0' || first == 'f') {
		*out = false;
		return true;
	}
	if (first == 'o') {
		p++;
		if (*p == 'n' || *p == 'N') {
			*out = true;
			return true;
		}
		if (*p == 'f' || *p == 'F') {
			*out = false;
			return true;
		}
	}
	return false;
}

/* 解析一个十进制无符号数, 返回数字之后的指针; 不是数字返回 NULL */
static inline const char *ps_span_u32(const char *p, unsigned int *out)
{
	unsigned long v = 0;

	if (*p < '0' || *p > '9')
		return NULL;
	while (*p >= '0' && *p <= '9') {
		v = v * 10 + (unsigned long)(*p - '0');
		if (v > 0xffffffffUL)
			return NULL;
		p++;
	}
	*out = (unsigned int)v;
	return p;
}

/*
 * 解析 UID 列表: "10123,10500 10130" (逗号/空白/换行都能当分隔符)。
 * 返回收录个数, 同时给出最小/最大值供 kprobe 里做快速过滤。
 */
static inline unsigned int ps_uids_parse(const char *val, unsigned int *uids,
					 unsigned int *min, unsigned int *max)
{
	const char *p = val;
	unsigned int nr = 0;
	unsigned int lo = 0, hi = 0;

	while (*p && nr < PS_MAX_UIDS) {
		unsigned int uid;
		const char *next;

		while (ps_is_space(*p) || *p == ',')
			p++;
		if (!*p)
			break;

		next = ps_span_u32(p, &uid);
		if (next) {
			uids[nr++] = uid;
			if (nr == 1 || uid < lo)
				lo = uid;
			if (nr == 1 || uid > hi)
				hi = uid;
		}

		next = strpbrk(next ? next : p, ", \t\n\r");
		if (!next)
			break;
		p = next;
	}

	*min = lo;
	*max = hi;
	return nr;
}

/*
 * 解析重定向规则 "src|dst;src|dst", src 以 * 结尾表示前缀匹配。
 * 换行/空白当分隔符并裁掉, 返回收录条数。
 */
static inline unsigned int ps_rules_parse(const char *val, struct ps_table *t)
{
	const char *p = val;

	t->nr = 0;
	while (*p && t->nr < PS_MAX_RULES) {
		const char *end, *sep;
		struct ps_rule *r;
		size_t slen, dlen;

		while (ps_is_space(*p) || *p == ';' || *p == ',')
			p++;
		if (!*p)
			break;

		end = p;
		while (*end && *end != ';' && *end != '\n' && *end != '\r')
			end++;

		sep = memchr(p, '|', end - p);
		if (!sep) {
			PS_PARSE_WARN("忽略无效规则 (缺少 '|'): %.*s\n", (int)(end - p), p);
			goto next;
		}

		slen = sep - p;
		dlen = end - sep - 1;
		if (!slen || !dlen || slen >= PS_NAME_MAX || dlen >= PS_NAME_MAX) {
			PS_PARSE_WARN("忽略无效规则 (长度越界)\n");
			goto next;
		}

		r = &t->rules[t->nr];
		memcpy(r->src, p, slen);
		r->src[slen] = '\0';
		memcpy(r->dst, sep + 1, dlen);
		r->dst[dlen] = '\0';
		ps_str_strip(r->src);
		ps_str_strip(r->dst);
		slen = strlen(r->src);
		dlen = strlen(r->dst);
		if (!slen || !dlen) {
			PS_PARSE_WARN("忽略无效规则 (空字段)\n");
			goto next;
		}
		if (r->src[slen - 1] == '*') {
			r->src[slen - 1] = '\0';
			r->prefix = true;
			slen--;
		}
		if (!slen) {
			PS_PARSE_WARN("忽略无效规则 (空源路径)\n");
			goto next;
		}
		r->srclen = (unsigned short)slen;
		r->dstlen = (unsigned short)dlen;

		t->nr++;
next:
		p = *end ? end + 1 : end;
	}

	return t->nr;
}

#endif /* PANVK_PARSE_H */
