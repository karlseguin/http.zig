const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

const PORT = 8810;

// This example demonstrates handling file uploads using multipart/form-data.
// It shows how to:
// 1. Parse multipart form data
// 2. Access uploaded file content and metadata
// 3. Save uploaded files to disk
// 4. Handle both file and regular form fields

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try httpz.Server(void).init(allocator, .{
        .address = .localhost(PORT),
        .request = .{
            // Configure the maximum number of multipart form fields
            // This must be > 0 to use req.multiFormData()
            .max_multiform_count = 10,

            // Set a reasonable max body size for file uploads (10MB in this example)
            .max_body_size = 10 * 1024 * 1024,
        },
    }, {});
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});

    router.get("/", index, .{});
    router.post("/upload", upload, .{});

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});
    std.debug.print("Open http://localhost:{d}/ in your browser to test file uploads\n", .{PORT});

    try server.listen();
}

fn index(_: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body =
        \\<!DOCTYPE html>
        \\<h1>File Upload Example</h1>
        \\<form method=post action=/upload enctype="multipart/form-data">
        \\  <p>Name: <input name=name value=Leto></p>
        \\  <p>Description: <textarea name=description>A test file upload</textarea></p>
        \\  <p>File: <input type=file name=file required></p>
        \\  <p>File 2 (optional): <input type=file name=file2></p>
        \\  <p><button type=submit>Upload</button></p>
        \\</form>
    ;
}

fn upload(req: *httpz.Request, res: *httpz.Response) !void {
    // Parse the multipart form data
    // This returns a MultiFormKeyValue which contains both regular fields and file uploads
    const form_data = try req.multiFormData();

    // Access regular form fields
    const name = form_data.get("name");
    const description = form_data.get("description");

    // Access uploaded files
    // Each value has:
    //   - .value: []const u8 (the file content)
    //   - .filename: ?[]const u8 (the original filename, if provided)
    const file = form_data.get("file");
    const file2 = form_data.get("file2");

    // Build the response
    res.content_type = .HTML;
    const writer = res.writer();

    try writer.writeAll("<!DOCTYPE html><h1>Upload Successful!</h1>");

    // Display regular form fields
    try writer.writeAll("<h2>Form Fields:</h2><ul>");
    if (name) |n| {
        try writer.print("<li><strong>Name:</strong> {s}</li>", .{n.value});
    }
    if (description) |d| {
        try writer.print("<li><strong>Description:</strong> {s}</li>", .{d.value});
    }
    try writer.writeAll("</ul>");

    // Display file information and optionally save to disk
    if (file) |f| {
        try writer.writeAll("<h2>File Upload:</h2><ul>");
        try writer.print("<li><strong>Filename:</strong> {s}</li>", .{f.filename orelse "no filename provided"});
        try writer.print("<li><strong>Size:</strong> {} bytes</li>", .{f.value.len});
        try writer.writeAll("</ul>");

        // // Example: Save the file to disk
        // if (f.filename) |filename| {
        //     const safe_filename = try std.fmt.allocPrint(res.arena, "uploaded_{s}", .{filename});
        //     const file_handle = try std.fs.cwd().createFile(safe_filename, .{});
        //     defer file_handle.close();

        //     try file_handle.writeAll(f.value);
        //     try writer.print("<p>✓ File saved as: <code>{s}</code></p>", .{safe_filename});
        // }

        try writer.writeAll("<h3>Content Preview:</h3><pre>");
        try writer.print("\\x{x}", .{f.value[0..@min(200, f.value.len)]});
        if (f.value.len > 200) {
            try writer.writeAll("...");
        }
        try writer.writeAll("</pre>");
    }

    // Handle optional second file
    if (file2) |f| {
        try writer.writeAll("<h2>Second File Upload:</h2><ul>");
        try writer.print("<li><strong>Filename:</strong> {s}</li>", .{f.filename orelse "no filename provided"});
        try writer.print("<li><strong>Size:</strong> {} bytes</li>", .{f.value.len});
        try writer.writeAll("</ul>");
    }

    // Iterate over all form fields (useful for debugging or when field names are dynamic)
    try writer.writeAll("<h2>All Fields (Debug):</h2><ul>");
    var it = form_data.iterator();
    while (it.next()) |kv| {
        if (kv.value.filename) |filename| {
            try writer.print("<li><strong>{s}</strong> (file): {s} ({} bytes)</li>", .{ kv.key, filename, kv.value.value.len });
        } else {
            try writer.print("<li><strong>{s}</strong>: {s}</li>", .{ kv.key, kv.value.value });
        }
    }
    try writer.writeAll("</ul>");

    try writer.writeAll("<p><a href=\"/\">Upload another file</a></p>");
}
