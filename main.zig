const std = @import("std");
const builtin = @import("builtin");
const sentinel = @import("std").meta.sentinel;
// TODO: add os specific memory allocator
const is_windows = builtin.Os.tag == std.os.windows;
var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;

const CSSAttribute = union(enum) {
    unknown: void,
    color: []const u8,
    background: []const u8,
    background_color: []const u8,
    text_align: []const u8,
    font_family: []const u8,
    font_size: []const u8,
};

fn matchAttribute(name: []const u8, value: []const u8) !CSSAttribute {
    const cssAttributeInfo = @typeInfo(CSSAttribute);
    inline for (cssAttributeInfo.Union.fields) |css_field| {
        if (comptime !std.mem.eql(u8, css_field.name, "unknown")) {
            if (std.mem.eql(u8, css_field.name, name)) {
                return @unionInit(CSSAttribute, css_field.name, value);
            }
        }
    }
    return error.UnknownProperty;
}

const CSSBlock = struct {
    selector: []const u8,
    attributes: []CSSAttribute,
};

const CSSTree = struct {
    blocks: []CSSBlock,
    fn print_tree(tree: *CSSTree) !void {
        for (tree.blocks, 0..) |block, i| {
            std.debug.print("selector {d}: {s}\n", .{ i, block.selector });
            for (block.attributes, 0..) |attr, j| {
                inline for (@typeInfo(CSSAttribute).Union.fields) |css_field| {
                    if (comptime !std.mem.eql(u8, css_field.name, "unknown")) {
                        if (std.mem.eql(u8, css_field.name, @tagName(attr))) {
                            var filteredAttrName = try filterDashes(@tagName(attr));

                            std.debug.print("\tattribute {d}: {s}  value: {s}\n", .{ j, filteredAttrName, @field(attr, css_field.name) });
                        }
                    }
                }
            }
            std.debug.print("\n", .{});
        }
    }

    fn write_to_file(tree: *CSSTree, file_name: []const u8) !void {
        const file = try std.fs.cwd().createFile(file_name, .{});
        defer file.close();

        for (tree.blocks) |block| {
            _ = try file.write(block.selector);
            _ = try file.write(" {\n");

            for (block.attributes) |attr| {
                inline for (@typeInfo(CSSAttribute).Union.fields) |css_field| {
                    if (comptime !std.mem.eql(u8, css_field.name, "unknown")) {
                        if (std.mem.eql(u8, css_field.name, @tagName(attr))) {
                            var filteredAttrName = try filterDashes(@tagName(attr));
                            _ = try file.write("\t");
                            _ = try file.write(filteredAttrName);
                            _ = try file.write(": ");
                            _ = try file.write(@field(attr, css_field.name));
                            _ = try file.write(";\n");
                        }
                    }
                }
            }
            _ = try file.write("}\n");
        }
    }
};

fn eatWhitespace(css: []const u8, initial_index: usize) usize {
    var index = initial_index;
    while (index < css.len and (std.ascii.isWhitespace(css[index]) or css[index] == '\n')) {
        index += 1;
    }

    return index;
}

fn debugAt(css: []const u8, index: usize, comptime msg: []const u8, args: anytype) void {
    var line_no: usize = 1;
    var col_no: usize = 0;
    var i: usize = 0;
    var line_beginning: usize = 0;
    var found_line: bool = false;
    while (i < css.len) : (i += 1) {
        if (css[i] == '\n') {
            if (!found_line) {
                col_no = 0;
                line_beginning = i;
                line_no += 1;
                continue;
            } else {
                break;
            }
        }

        if (i == index) {
            found_line = true;
        }

        if (!found_line) {
            col_no += 1;
        }
    }

    std.debug.print("Error at line {}, column {}.\n", .{ line_no, col_no });
    std.debug.print(msg ++ "\n\n", args);
    std.debug.print("{s}\n", .{css[line_beginning..i]});

    while (col_no > 0) {
        std.debug.print(" ", .{});
        col_no -= 1;
    }
    std.debug.print("^ Near here.\n", .{});
}

const ParseIdentifierResult = struct {
    identifier: []const u8,
    index: usize,
};

fn parseIdentifier(css: []const u8, initial_index: usize) !ParseIdentifierResult {
    var index = initial_index;
    while (index < css.len and (std.ascii.isAlphanumeric(css[index]) or css[index] == '-')) {
        index += 1;
    }

    if (index == initial_index) {
        debugAt(css, initial_index, "Expected valid identifier.", .{});
        return error.InvalidIdentifier;
    }

    return ParseIdentifierResult{
        .identifier = try filterDashes(css[initial_index..index]),
        .index = index,
    };
}

pub fn filterDashes(str: []const u8) ![]const u8 {
    // Allocate memory equal to str and update the res_str
    var res_str = try allocator.alloc(u8, str.len);

    for (str, 0..) |ch, idx| {
        if (ch == '-') {
            res_str[idx] = '_';
        } else if (ch == '_') {
            res_str[idx] = '-';
        } else {
            res_str[idx] = ch;
        }
    }

    return res_str;
}

fn parseSyntax(css: []const u8, initial_index: usize, syntax: u8) !usize {
    if (initial_index < css.len and css[initial_index] == syntax) {
        return initial_index + 1;
    }
    debugAt(css, initial_index, "Expected syntax: '{c}''.", .{syntax});
    return error.NoSuchSyntax;
}

const ParseAttributeResult = struct {
    attribute: CSSAttribute,
    index: usize,
};

fn parseAttribute(css: []const u8, initial_index: usize) !ParseAttributeResult {
    var index = eatWhitespace(css, initial_index);

    // First parse attribute name
    var name_res = parseIdentifier(css, index) catch |e| {
        std.debug.print("Could not parse attribute name.\n", .{});
        return e;
    };
    index = name_res.index;
    index = eatWhitespace(css, index);

    // Then parse colon: :.
    index = try parseSyntax(css, index, ':');
    index = eatWhitespace(css, index);

    // Then parse attribute value
    var value_res = parseIdentifier(css, index) catch |e| {
        std.debug.print("Could not parse attribute value.\n", .{});
        return e;
    };
    index = value_res.index;

    // Finally parse semi-colon: ;.
    index = try parseSyntax(css, index, ';');

    var attribute = matchAttribute(name_res.identifier, value_res.identifier) catch |e| {
        debugAt(css, initial_index, "Unknown property: '{s}'.", .{name_res.identifier});
        return e;
    };

    if (std.mem.eql(u8, @tagName(attribute), "unknown")) {
        debugAt(css, initial_index, "Unknown attribute: '{s}'.", .{name_res.identifier});
        return error.UnknownAttribute;
    }
    return ParseAttributeResult{ .index = index, .attribute = attribute };
}

const ParseBlockResult = struct {
    block: CSSBlock,
    index: usize,
};

fn parseBlock(css: []const u8, initial_index: usize) !ParseBlockResult {
    var index = eatWhitespace(css, initial_index);

    // First parse selector(s).
    var selector_res = try parseIdentifier(css, index);
    index = selector_res.index;

    index = eatWhitespace(css, index);

    // Then parse opening curly brace. {
    index = try parseSyntax(css, index, '{');

    var attributes = std.ArrayList(CSSAttribute).init(arena.allocator());

    // Then parse any number of attributes.
    while (index < css.len) {
        index = eatWhitespace(css, index);
        if (index < css.len and css[index] == '}') {
            break;
        }
        var attr_res = try parseAttribute(css, index);
        index = attr_res.index;
        try attributes.append(attr_res.attribute);
    }
    index = eatWhitespace(css, index);

    // Then parse closing curly brace.}
    index = try parseSyntax(css, index, '}');

    return ParseBlockResult{
        .block = CSSBlock{
            .selector = selector_res.identifier,
            .attributes = attributes.items,
        },
        .index = index,
    };
}

fn parse(css: []const u8) !CSSTree {
    var index: usize = 0;
    var blocks = std.ArrayList(CSSBlock).init(arena.allocator());
    // Parse blocks until EOF
    while (index < css.len) {
        var res = try parseBlock(css, index);
        index = res.index;
        try blocks.append(res.block);
        index = eatWhitespace(css, index);
    }

    return CSSTree{
        .blocks = blocks.items,
    };
}

pub fn main() !void {
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    allocator = arena.allocator();

    var args = std.process.args();
    // Skipping first arg, the process name
    _ = args.next();

    var file_name: []const u8 = "";
    if (args.next()) |f| {
        file_name = f;
    }

    const file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    var css_file = try allocator.alloc(u8, file_size);
    _ = try file.read(css_file);

    var tree = parse(css_file) catch return;
    try tree.print_tree();
    try tree.write_to_file("test_output.css");
}
