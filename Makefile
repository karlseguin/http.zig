.PHONY: t
t:
	zig build test

.PHONY: s
s:
	zig build run -freference-trace
