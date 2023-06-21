.PHONY: t
t:
	zig build test --summary all

.PHONY: s
s:
	zig build run -freference-trace
