.PHONY: t
t:
	# 2>&1|cat from: https://github.com/ziglang/zig/issues/10203
	zig build test 2>&1|cat

.PHONY: s
s:
	zig build run -freference-trace -- tests/config.json
