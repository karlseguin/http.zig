F=
zig ?= zig
.PHONY: t
t:
	TEST_FILTER='${F}' '${zig}' build test -Dforce_blocking=false -freference-trace --summary all
	TEST_FILTER='${F}' '${zig}' build test -Dforce_blocking=true -freference-trace --summary all

.PHONY: tn
tn:
	TEST_FILTER='${F}' '${zig}' build test -Dforce_blocking=false -freference-trace --summary all

.PHONY: tb
tb:
	TEST_FILTER='${F}' '${zig}' build test -Dforce_blocking=true -freference-trace --summary all

.PHONY: s
s:
	zig build example_1 -freference-trace

.phony: d
d:
	cd docs && npx @11ty/eleventy --serve --port 5300
