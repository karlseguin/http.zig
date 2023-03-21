.PHONY: t
t:
	zig test src/httpz.zig

.PHONY: s
s:
	zig build run -freference-trace
