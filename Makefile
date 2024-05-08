F=
.PHONY: t
t:
	TEST_FILTER="${F}" zig build test -freference-trace --summary all
	TEST_FILTER="${F}" zig build test_blocking -freference-trace --summary all

.PHONY: tn
	TEST_FILTER="${F}" zig build test -freference-trace --summary all

.PHONY: tb
tb:
	TEST_FILTER="${F}" zig build test_blocking -freference-trace --summary all

.PHONY: s
s:
	zig build run -freference-trace
