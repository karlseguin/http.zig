.PHONY: t
t:
	zig build test -freference-trace --summary all

.PHONY: s
s:
	zig build run -freference-trace
