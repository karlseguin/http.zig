.PHONY: t
t:
	zig build test -fsummary

.PHONY: s
s:
	zig build run -freference-trace
