F=
.PHONY: t
t:
	TEST_FILTER=${F} zig build test -freference-trace --summary all

.PHONY: s
s:
	zig build run -freference-trace
