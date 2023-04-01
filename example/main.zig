const std = @import("std");
const httpz = @import("httpz");

const Allocator = std.mem.Allocator;

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();

	// This is a server with no context. It's started in a separate thread
	// (so that we can start 2 servers, and to show how to start the server
	// in a separate thread)
	var server1 = try httpz.Server().init(allocator, .{.pool_size = 10});
	var router1 = server1.router();
	router1.get("/", index);
	router1.get("/hello", hello);
	router1.get("/json/hello/:name", json);
	router1.get("/writer/hello/:name", writer);
	std.log.info("listening on http://{s}:{d}", .{server1.config.address, server1.config.port});
	const thread1 = try server1.listenInNewThread();

	// This is a server with a context. It's started on the main thread
	// (thus blocking the thread).
	var ctx = ContextDemo{};
	var server2 = try httpz.ServerCtx(*ContextDemo).init(allocator, .{.pool_size = 10, .port = 5883}, &ctx);
	var router2 = server2.router();
	router2.get("/increment", increment);
	std.log.info("listening on http://{s}:{d}", .{server2.config.address, server2.config.port});
	try server2.listen();

	// for completeleness, let's block on thread1;
	thread1.join();
}

fn index(_: *httpz.Request, res: *httpz.Response) !void {
	res.body = \\<!DOCTYPE html>
	\\ <ul>
	\\ <li><a href="/hello?name=Teg">/hello?name=Teg</a>
	\\ <li><a href="/json/hello/Duncan">/json/hello/Duncan</a>
	\\ <li><a href="/writer/hello/Ghanima">/writer/hello/Ghanima</a>
	\\ <li><a href="http://localhost:5883/increment">http://localhost:5883/increment</a>
	;
}

fn hello(req: *httpz.Request, res: *httpz.Response) !void {
	const query = try req.query();
	const name = query.get("name") orelse "stranger";

	// One solution is to use res.arena
	// var out = try std.fmt.allocPrint(res.arena, "Hello {s}", .{name});
	// res.body = out

	// another is to use res.writer(), which might be more efficient in some cases
	try std.fmt.format(res.writer(), "Hello {s}", .{name});
}

fn json(req: *httpz.Request, res: *httpz.Response) !void {
	const name = req.param("name").?;
	try res.json(.{.hello = name});
}

fn writer(req: *httpz.Request, res: *httpz.Response) !void {
	res.content_type = httpz.ContentType.JSON;

	const name = req.param("name").?;
	var ws = std.json.writeStream(res.writer(), 4);
	try ws.beginObject();
	try ws.objectField("name");
	try ws.emitString(name);
	try ws.endObject();
}

// this route is used for the demoContextServer
fn increment(_: *httpz.Request, res: *httpz.Response, ctx: *ContextDemo) !void {
	ctx.l.lock();
	var hits = ctx.hits + 1;
	ctx.hits = hits;
	ctx.l.unlock();

	res.content_type = httpz.ContentType.TEXT;
	var out = try std.fmt.allocPrint(res.arena, "{d} hits", .{hits});
	res.body = out;
}

const ContextDemo = struct {
	hits: usize = 0,
	l: std.Thread.Mutex = .{},
};
