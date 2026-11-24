const std = @import("std");
const Configuration = std.Build.Configuration;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Driver = enum {
    zig,
    clang,
};

const DirInfo = struct {
    path: []const u8,
    file_names: std.array_hash_map.String(void),
};

const usage =
    \\Usage: zig-compile-commands [options] [-- <zig build flags>]
    \\
    \\Generates a compile_commands.json compilation database for clangd
    \\by parsing Zig 0.17+'s serialized build configuration graph.
    \\
    \\Options:
    \\  -h, --help               Print this help message and exit
    \\  --config <path>          Path to serialized graph binary (.zig-cache/c/<hash>)
    \\                           (Default: queries `zig build --print-configuration-path`)
    \\  -o, --output <path>      Output file path (default: compile_commands.json)
    \\  --build-root <path>      Project build root (default: current directory)
    \\  --driver <zig|clang>     Compiler driver to emit in arguments (default: zig)
    \\  -- <flags>               Additional flags passed to `zig build --print-configuration-path`
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var config_path_opt: ?[]const u8 = null;
    var output_path_opt: ?[]const u8 = null;
    var build_root_opt: ?[]const u8 = null;
    var driver: Driver = .zig;
    var extra_zig_args: std.ArrayList([]const u8) = .empty;

    var it = try init.minimal.args.iterateAllocator(arena);
    defer it.deinit();

    _ = it.skip(); // skip executable name

    var forwarding = false;
    while (it.next()) |arg| {
        if (forwarding) {
            try extra_zig_args.append(arena, arg);
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            forwarding = true;
            continue;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try Io.File.stdout().writeStreamingAll(io, usage);
            return std.process.cleanExit(io);
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_path_opt = it.next() orelse {
                std.debug.print("Error: --config requires a path argument\n", .{});
                return error.InvalidArguments;
            };
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            config_path_opt = arg["--config=".len..];
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path_opt = it.next() orelse {
                std.debug.print("Error: -o/--output requires a path argument\n", .{});
                return error.InvalidArguments;
            };
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            output_path_opt = arg["--output=".len..];
        } else if (std.mem.eql(u8, arg, "--build-root")) {
            build_root_opt = it.next() orelse {
                std.debug.print("Error: --build-root requires a path argument\n", .{});
                return error.InvalidArguments;
            };
        } else if (std.mem.startsWith(u8, arg, "--build-root=")) {
            build_root_opt = arg["--build-root=".len..];
        } else if (std.mem.eql(u8, arg, "--driver")) {
            const driver_str = it.next() orelse {
                std.debug.print("Error: --driver requires 'zig' or 'clang'\n", .{});
                return error.InvalidArguments;
            };
            driver = parseDriver(driver_str) orelse {
                std.debug.print("Error: unknown driver '{s}', expected 'zig' or 'clang'\n", .{driver_str});
                return error.InvalidArguments;
            };
        } else if (std.mem.startsWith(u8, arg, "--driver=")) {
            const driver_str = arg["--driver=".len..];
            driver = parseDriver(driver_str) orelse {
                std.debug.print("Error: unknown driver '{s}', expected 'zig' or 'clang'\n", .{driver_str});
                return error.InvalidArguments;
            };
        } else {
            // Forward unknown options to zig build
            try extra_zig_args.append(arena, arg);
        }
    }

    // Determine absolute build root
    const build_root = if (build_root_opt) |br| blk: {
        if (std.fs.path.isAbsolute(br)) {
            break :blk try arena.dupe(u8, br);
        } else {
            var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const cwd_len = try Io.Dir.cwd().realPath(io, &cwd_buf);
            break :blk try std.fs.path.join(arena, &.{ cwd_buf[0..cwd_len], br });
        }
    } else blk: {
        var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = try Io.Dir.cwd().realPath(io, &cwd_buf);
        break :blk try arena.dupe(u8, cwd_buf[0..cwd_len]);
    };

    // Determine output path (default: <build_root>/compile_commands.json)
    const output_path = if (output_path_opt) |op| blk: {
        if (std.fs.path.isAbsolute(op)) {
            break :blk try arena.dupe(u8, op);
        } else {
            break :blk try std.fs.path.join(arena, &.{ build_root, op });
        }
    } else try std.fs.path.join(arena, &.{ build_root, "compile_commands.json" });

    // Determine config path
    const config_abs_path = if (config_path_opt) |cp| blk: {
        if (std.fs.path.isAbsolute(cp)) {
            break :blk try arena.dupe(u8, cp);
        } else {
            break :blk try std.fs.path.join(arena, &.{ build_root, cp });
        }
    } else blk: {
        // Run: zig build --print-configuration-path [extra args...]
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, "zig");
        try argv.append(arena, "build");
        try argv.append(arena, "--print-configuration-path");
        try argv.appendSlice(arena, extra_zig_args.items);

        const res = std.process.run(arena, io, .{
            .argv = argv.items,
            .cwd = .{ .path = build_root },
        }) catch |err| {
            std.debug.print("Error: failed to run 'zig build --print-configuration-path': {s}\n", .{@errorName(err)});
            return err;
        };

        if (!res.term.success()) {
            std.debug.print("Error: 'zig build --print-configuration-path' failed:\n{s}\n", .{res.stderr});
            return error.ZigBuildFailed;
        }

        const raw_path = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (raw_path.len == 0) {
            std.debug.print("Error: 'zig build --print-configuration-path' returned empty output\n", .{});
            return error.EmptyConfigurationPath;
        }

        if (std.fs.path.isAbsolute(raw_path)) {
            break :blk try arena.dupe(u8, raw_path);
        } else {
            break :blk try std.fs.path.join(arena, &.{ build_root, raw_path });
        }
    };

    // Open and load configuration
    const config_file = Io.Dir.openFileAbsolute(io, config_abs_path, .{}) catch |err| {
        std.debug.print("Error: failed to open configuration file '{s}': {s}\n", .{ config_abs_path, @errorName(err) });
        return err;
    };
    defer config_file.close(io);

    const conf = try Configuration.loadFile(arena, io, config_file);

    var env_map = try init.minimal.environ.createMap(arena);
    const local_cache_root = try std.fs.path.join(arena, &.{ build_root, ".zig-cache" });
    const global_cache_root = try getGlobalCacheDir(arena, &env_map, build_root);

    // Map WriteFile steps by their generated_directory index
    var wf_by_gen_dir = std.array_hash_map.Auto(Configuration.GeneratedFileIndex, Configuration.Step.WriteFile).empty;
    for (conf.steps) |step| {
        if (step.extended.cast(&conf, Configuration.Step.WriteFile)) |wf| {
            try wf_by_gen_dir.put(arena, wf.generated_directory, wf);
        }
    }

    // Pre-scan generated files directory (.zig-cache/o) to resolve generated includes
    var generated_dirs = std.array_hash_map.Auto(Configuration.GeneratedFileIndex, []const u8).empty;
    try scanGeneratedDirs(arena, io, &conf, build_root, local_cache_root, &generated_dirs);

    // Collect all compilation commands
    var entries_map = std.array_hash_map.String([]const []const u8).empty;

    for (conf.steps) |step| {
        const compile = step.extended.cast(&conf, Configuration.Step.Compile) orelse continue;

        const target = compile.rootModuleTarget(&conf).unwrapTarget(&conf);
        const triple = try formatTriple(arena, &target);
        const cpu_name: ?[]const u8 = target.cpu.model.name;

        // BFS modules reachable from root_module
        var modules = std.array_hash_map.Auto(Configuration.Module.Index, void).empty;
        try modules.put(arena, compile.root_module, {});

        var mod_i: usize = 0;
        while (mod_i < modules.count()) : (mod_i += 1) {
            const mod_index = modules.keys()[mod_i];
            const mod = mod_index.get(&conf);
            const imports = mod.import_table.get(&conf).imports;
            try modules.ensureUnusedCapacity(arena, imports.mal.len);
            for (imports.mal.items(.module)) |other_mod| {
                modules.putAssumeCapacity(other_mod, {});
            }
        }

        for (modules.keys()) |mod_index| {
            const mod = mod_index.get(&conf);

            // Collect module include flags
            var mod_includes: std.ArrayList([]const u8) = .empty;
            var seen_includes = std.array_hash_map.String(void).empty;

            for (0..mod.include_dirs.len) |inc_i| {
                const inc = mod.include_dirs.get(conf.extra, inc_i);
                switch (inc) {
                    .path => |lp| {
                        try addLazyPathInclude(arena, &conf, build_root, local_cache_root, global_cache_root, &generated_dirs, &wf_by_gen_dir, "-I", lp.get(&conf), &seen_includes, &mod_includes);
                    },
                    .path_system => |lp| {
                        try addLazyPathInclude(arena, &conf, build_root, local_cache_root, global_cache_root, &generated_dirs, &wf_by_gen_dir, "-isystem", lp.get(&conf), &seen_includes, &mod_includes);
                    },
                    .path_after => |lp| {
                        try addLazyPathInclude(arena, &conf, build_root, local_cache_root, global_cache_root, &generated_dirs, &wf_by_gen_dir, "-idirafter", lp.get(&conf), &seen_includes, &mod_includes);
                    },
                    .framework_path => |lp| {
                        try addLazyPathInclude(arena, &conf, build_root, local_cache_root, global_cache_root, &generated_dirs, &wf_by_gen_dir, "-F", lp.get(&conf), &seen_includes, &mod_includes);
                    },
                    .framework_path_system => |lp| {
                        try addLazyPathInclude(arena, &conf, build_root, local_cache_root, global_cache_root, &generated_dirs, &wf_by_gen_dir, "-iframework", lp.get(&conf), &seen_includes, &mod_includes);
                    },
                    .config_header_step => |ch_step_index| {
                        const ch = ch_step_index.ptr(&conf).extended.cast(&conf, Configuration.Step.ConfigHeader) orelse continue;
                        if (generated_dirs.get(ch.generated_dir)) |gen_dir| {
                            try addIncludeDir(arena, "-I", gen_dir, &seen_includes, &mod_includes);
                        }
                    },
                    .embed_path => {},
                }
            }

            // Collect module macros
            var mod_macros: std.ArrayList([]const u8) = .empty;
            for (mod.c_macros.slice) |macro_str| {
                try mod_macros.append(arena, macro_str.slice(&conf));
            }

            // Collect link objects
            for (0..mod.link_objects.len) |lo_i| {
                switch (mod.link_objects.get(conf.extra, lo_i)) {
                    .c_source_file => |csf_idx| {
                        const csf = csf_idx.get(&conf);
                        const file_path = (try resolveLazyPath(arena, &conf, build_root, local_cache_root, global_cache_root, &generated_dirs, csf.file.get(&conf))) orelse continue;
                        const abs_file_path = if (std.fs.path.isAbsolute(file_path))
                            file_path
                        else
                            try std.fs.path.join(arena, &.{ build_root, file_path });

                        var file_args: std.ArrayList([]const u8) = .empty;
                        for (csf.args.slice) |arg| {
                            try file_args.append(arena, arg.slice(&conf));
                        }

                        const args = try buildCompilerArgs(arena, driver, triple, cpu_name, abs_file_path, csf.flags.lang, mod_includes.items, mod_macros.items, file_args.items);

                        if (!entries_map.contains(abs_file_path)) {
                            try entries_map.put(arena, abs_file_path, args);
                        }
                    },
                    .c_source_files => |csfs_idx| {
                        const csfs = csfs_idx.get(&conf);
                        const root_path = (try resolveLazyPath(arena, &conf, build_root, local_cache_root, global_cache_root, &generated_dirs, csfs.root.get(&conf))) orelse continue;

                        var file_args: std.ArrayList([]const u8) = .empty;
                        for (csfs.args.slice) |arg| {
                            try file_args.append(arena, arg.slice(&conf));
                        }

                        for (csfs.sub_paths.slice) |sub_path_str| {
                            const sub_path = sub_path_str.slice(&conf);
                            const file_path = try std.fs.path.join(arena, &.{ root_path, sub_path });
                            const abs_file_path = if (std.fs.path.isAbsolute(file_path))
                                file_path
                            else
                                try std.fs.path.join(arena, &.{ build_root, file_path });

                            const args = try buildCompilerArgs(arena, driver, triple, cpu_name, abs_file_path, csfs.flags.lang, mod_includes.items, mod_macros.items, file_args.items);

                            if (!entries_map.contains(abs_file_path)) {
                                try entries_map.put(arena, abs_file_path, args);
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    // Write compile_commands.json
    const out_file = Io.Dir.createFileAbsolute(io, output_path, .{}) catch |err| {
        std.debug.print("Error: failed to create output file '{s}': {s}\n", .{ output_path, @errorName(err) });
        return err;
    };
    defer out_file.close(io);

    var write_buf: [4096]u8 = undefined;
    var fw = out_file.writer(io, &write_buf);
    const w = &fw.interface;

    try w.writeAll("[\n");

    const count = entries_map.count();
    for (entries_map.keys(), entries_map.values(), 0..) |file_path, args, idx| {
        try w.writeAll("  {\n");
        try w.writeAll("    \"directory\": ");
        try writeJsonString(w, build_root);
        try w.writeAll(",\n    \"file\": ");
        try writeJsonString(w, file_path);
        try w.writeAll(",\n    \"arguments\": [\n");

        for (args, 0..) |arg, arg_idx| {
            try w.writeAll("      ");
            try writeJsonString(w, arg);
            if (arg_idx + 1 < args.len) {
                try w.writeAll(",\n");
            } else {
                try w.writeAll("\n");
            }
        }

        try w.writeAll("    ]\n");
        try w.writeAll("  }");
        if (idx + 1 < count) {
            try w.writeAll(",\n");
        } else {
            try w.writeAll("\n");
        }
    }

    try w.writeAll("]\n");
    try fw.flush();

    std.debug.print("Generated '{s}' with {d} compilation commands.\n", .{ output_path, count });
}

fn addIncludeDir(
    arena: Allocator,
    flag: []const u8,
    dir_path: []const u8,
    seen: *std.array_hash_map.String(void),
    out_includes: *std.ArrayList([]const u8),
) !void {
    if (dir_path.len == 0) return;
    const gop = try seen.getOrPut(arena, dir_path);
    if (!gop.found_existing) {
        try out_includes.append(arena, flag);
        try out_includes.append(arena, dir_path);
    }
}

fn addLazyPathInclude(
    arena: Allocator,
    c: *const Configuration,
    build_root: []const u8,
    local_cache_root: []const u8,
    global_cache_root: []const u8,
    generated_dirs: *const std.array_hash_map.Auto(Configuration.GeneratedFileIndex, []const u8),
    wf_by_gen_dir: *const std.array_hash_map.Auto(Configuration.GeneratedFileIndex, Configuration.Step.WriteFile),
    flag: []const u8,
    lp: Configuration.LazyPath,
    seen: *std.array_hash_map.String(void),
    out_includes: *std.ArrayList([]const u8),
) !void {
    switch (lp) {
        .source_path => |sp| {
            const resolved = try resolveSourcePath(arena, c, build_root, sp);
            try addIncludeDir(arena, flag, resolved, seen, out_includes);
        },
        .relative => {
            if (try resolveLazyPath(arena, c, build_root, local_cache_root, global_cache_root, generated_dirs, lp)) |resolved| {
                try addIncludeDir(arena, flag, resolved, seen, out_includes);
            }
        },
        .generated => |gen| {
            if (generated_dirs.get(gen.index)) |base_dir| {
                var file_path = base_dir;
                for (0..gen.flags.up) |_| {
                    file_path = std.fs.path.dirname(file_path) orelse file_path;
                }
                const sub = gen.sub_path.slice(c);
                const resolved = if (sub.len == 0) file_path else try std.fs.path.join(arena, &.{ file_path, sub });
                try addIncludeDir(arena, flag, resolved, seen, out_includes);
            }

            if (wf_by_gen_dir.get(gen.index)) |wf| {
                for (wf.directories.slice) |dir_entry| {
                    const sub = dir_entry.sub_path.slice(c);
                    const dir_src = (try resolveLazyPath(arena, c, build_root, local_cache_root, global_cache_root, generated_dirs, dir_entry.src_path.get(c))) orelse continue;

                    if (sub.len == 0) {
                        try addIncludeDir(arena, flag, dir_src, seen, out_includes);
                    } else {
                        // For non-empty sub_path (e.g. "libavcodec", "libavutil"):
                        // dir_src contains files intended to be accessed via sub/filename.
                        // Do NOT add dir_src directly as an include path, because files inside
                        // (like libavutil/time.h) would shadow system headers like <time.h>!
                        // Instead, add the parent directory if dir_src ends with sub.
                        if (std.mem.endsWith(u8, dir_src, sub) and dir_src.len > sub.len and dir_src[dir_src.len - sub.len - 1] == std.fs.path.sep) {
                            const root_src = dir_src[0 .. dir_src.len - sub.len - 1];
                            try addIncludeDir(arena, flag, root_src, seen, out_includes);
                        }
                    }
                }
                for (wf.copies.slice) |cp| {
                    const cp_src = (try resolveLazyPath(arena, c, build_root, local_cache_root, global_cache_root, generated_dirs, cp.src_file.get(c))) orelse continue;
                    const sub = cp.sub_path.slice(c);
                    if (std.fs.path.dirname(sub)) |sub_dir| {
                        if (std.fs.path.dirname(cp_src)) |parent| {
                            if (std.mem.endsWith(u8, parent, sub_dir) and parent.len > sub_dir.len and parent[parent.len - sub_dir.len - 1] == std.fs.path.sep) {
                                const root_src = parent[0 .. parent.len - sub_dir.len - 1];
                                try addIncludeDir(arena, flag, root_src, seen, out_includes);
                            }
                        }
                    } else {
                        if (std.fs.path.dirname(cp_src)) |parent| {
                            try addIncludeDir(arena, flag, parent, seen, out_includes);
                        }
                    }
                }
            }
        },
    }
}

fn buildCompilerArgs(
    arena: Allocator,
    driver: Driver,
    triple: []const u8,
    cpu_name: ?[]const u8,
    file_path: []const u8,
    lang: Configuration.OptionalCSourceLanguage,
    includes: []const []const u8,
    macros: []const []const u8,
    file_args: []const []const u8,
) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;

    const is_cpp = isCppSource(file_path, lang);

    switch (driver) {
        .zig => {
            try args.append(arena, "zig");
            if (is_cpp) {
                try args.append(arena, "c++");
            } else {
                try args.append(arena, "cc");
            }
        },
        .clang => {
            if (is_cpp) {
                try args.append(arena, "clang++");
            } else {
                try args.append(arena, "clang");
            }
        },
    }

    try args.append(arena, "-target");
    try args.append(arena, triple);

    if (cpu_name) |cpu| {
        if (!std.mem.eql(u8, cpu, "generic") and !std.mem.eql(u8, cpu, "native")) {
            const cpu_hyphen = try arena.dupe(u8, cpu);
            for (cpu_hyphen) |*c| {
                if (c.* == '_') c.* = '-';
            }
            try args.append(arena, try std.fmt.allocPrint(arena, "-mcpu={s}", .{cpu_hyphen}));
        }
    }

    try args.appendSlice(arena, includes);
    try args.appendSlice(arena, macros);
    try args.appendSlice(arena, file_args);

    try args.append(arena, "-c");
    try args.append(arena, file_path);

    return args.items;
}

fn isCppSource(file_path: []const u8, lang: Configuration.OptionalCSourceLanguage) bool {
    switch (lang) {
        .cpp, .objective_cpp => return true,
        .c, .objective_c, .assembly, .assembly_with_preprocessor => return false,
        .default => {
            const ext = std.fs.path.extension(file_path);
            return std.mem.eql(u8, ext, ".cpp") or
                std.mem.eql(u8, ext, ".cc") or
                std.mem.eql(u8, ext, ".cxx") or
                std.mem.eql(u8, ext, ".C") or
                std.mem.eql(u8, ext, ".hpp") or
                std.mem.eql(u8, ext, ".hh") or
                std.mem.eql(u8, ext, ".hxx");
        },
    }
}

fn resolveSourcePath(
    arena: Allocator,
    c: *const Configuration,
    build_root: []const u8,
    sp: Configuration.LazyPath.SourcePath,
) ![]const u8 {
    const sub_path = sp.sub_path.slice(c);
    if (sp.owner.get(c)) |pkg| {
        const pkg_root = pkg.root_path.slice(c);
        if (std.fs.path.isAbsolute(pkg_root)) {
            if (sub_path.len == 0) return arena.dupe(u8, pkg_root);
            return std.fs.path.join(arena, &.{ pkg_root, sub_path });
        } else {
            if (sub_path.len == 0) return std.fs.path.join(arena, &.{ build_root, pkg_root });
            return std.fs.path.join(arena, &.{ build_root, pkg_root, sub_path });
        }
    } else {
        if (sub_path.len == 0) return arena.dupe(u8, build_root);
        return std.fs.path.join(arena, &.{ build_root, sub_path });
    }
}

fn resolveLazyPath(
    arena: Allocator,
    c: *const Configuration,
    build_root: []const u8,
    local_cache_root: []const u8,
    global_cache_root: []const u8,
    generated_dirs: *const std.array_hash_map.Auto(Configuration.GeneratedFileIndex, []const u8),
    lazy_path: Configuration.LazyPath,
) !?[]const u8 {
    switch (lazy_path) {
        .source_path => |sp| {
            return try resolveSourcePath(arena, c, build_root, sp);
        },
        .relative => |rel| {
            const sub_path = rel.sub_path.slice(c);
            return switch (rel.flags.base) {
                .cwd, .build_root => try std.fs.path.join(arena, &.{ build_root, sub_path }),
                .local_cache => try std.fs.path.join(arena, &.{ local_cache_root, sub_path }),
                .global_cache => try std.fs.path.join(arena, &.{ global_cache_root, sub_path }),
                .install_prefix => try std.fs.path.join(arena, &.{ build_root, "zig-out", sub_path }),
                .install_include => try std.fs.path.join(arena, &.{ build_root, "zig-out", "include", sub_path }),
                .install_lib => try std.fs.path.join(arena, &.{ build_root, "zig-out", "lib", sub_path }),
                .install_bin => try std.fs.path.join(arena, &.{ build_root, "zig-out", "bin", sub_path }),
                else => try std.fs.path.join(arena, &.{ build_root, sub_path }),
            };
        },
        .generated => |gen| {
            if (generated_dirs.get(gen.index)) |base_dir| {
                var file_path = base_dir;
                for (0..gen.flags.up) |_| {
                    file_path = std.fs.path.dirname(file_path) orelse file_path;
                }
                const sub = gen.sub_path.slice(c);
                if (sub.len == 0) return file_path;
                return try std.fs.path.join(arena, &.{ file_path, sub });
            }
            return null;
        },
    }
}

fn getCachedFileContent(
    arena: Allocator,
    io: Io,
    cache: *std.array_hash_map.String([]const u8),
    file_path: []const u8,
) ?[]const u8 {
    if (cache.get(file_path)) |c| return c;
    const file = Io.Dir.openFileAbsolute(io, file_path, .{}) catch return null;
    defer file.close(io);
    const len = file.length(io) catch return null;
    if (len > 10 * 1024 * 1024) return null;
    const buf = arena.alloc(u8, @intCast(len)) catch return null;
    const bytes_read = file.readPositionalAll(io, buf, 0) catch return null;
    const content = buf[0..bytes_read];
    cache.put(arena, file_path, content) catch return content;
    return content;
}

fn scanGeneratedDirs(
    arena: Allocator,
    io: Io,
    conf: *const Configuration,
    build_root: []const u8,
    local_cache_root: []const u8,
    generated_dirs: *std.array_hash_map.Auto(Configuration.GeneratedFileIndex, []const u8),
) !void {
    const o_dir_path = try std.fs.path.join(arena, &.{ local_cache_root, "o" });

    var o_dir = Io.Dir.openDirAbsolute(io, o_dir_path, .{ .iterate = true }) catch return;
    defer o_dir.close(io);

    // 1. Gather target file names from ConfigHeader and WriteFile steps
    var target_names = std.array_hash_map.String(void).empty;

    for (conf.steps) |step| {
        if (step.extended.cast(conf, Configuration.Step.ConfigHeader)) |ch| {
            const inc_path = ch.include_path.slice(conf);
            try target_names.put(arena, std.fs.path.basename(inc_path), {});
            if (std.mem.indexOfScalar(u8, inc_path, '/')) |slash_idx| {
                try target_names.put(arena, inc_path[0..slash_idx], {});
            }
        }
        if (step.extended.cast(conf, Configuration.Step.WriteFile)) |wf| {
            for (wf.copies.slice) |cp| {
                const sub = cp.sub_path.slice(conf);
                try target_names.put(arena, std.fs.path.basename(sub), {});
            }
            for (wf.embeds.slice) |em| {
                const sub = em.sub_path.slice(conf);
                try target_names.put(arena, std.fs.path.basename(sub), {});
            }
            for (wf.directories.slice) |dir_entry| {
                const sub = dir_entry.sub_path.slice(conf);
                if (sub.len > 0) {
                    try target_names.put(arena, std.fs.path.basename(sub), {});
                } else {
                    switch (dir_entry.src_path.get(conf)) {
                        .source_path => |sp| {
                            if (resolveSourcePath(arena, conf, build_root, sp) catch null) |full_src| {
                                if (Io.Dir.openDirAbsolute(io, full_src, .{ .iterate = true }) catch null) |src_d_const| {
                                    var src_d = src_d_const;
                                    defer src_d.close(io);
                                    var s_it = src_d.iterate();
                                    var checked: usize = 0;
                                    while (s_it.next(io) catch null) |se| {
                                        if (checked >= 10) break;
                                        checked += 1;
                                        try target_names.put(arena, try arena.dupe(u8, se.name), {});
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
        }
    }

    // 2. Scan candidate directories in .zig-cache/o
    var candidate_dirs: std.ArrayList(DirInfo) = .empty;

    var it = o_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const sub_path = try std.fs.path.join(arena, &.{ o_dir_path, entry.name });
        var sub_dir = Io.Dir.openDirAbsolute(io, sub_path, .{ .iterate = true }) catch continue;
        defer sub_dir.close(io);

        var names = std.array_hash_map.String(void).empty;
        var matches_target = false;

        var f_it = sub_dir.iterate();
        while (try f_it.next(io)) |f_entry| {
            try names.put(arena, try arena.dupe(u8, f_entry.name), {});
            if (!matches_target) {
                if (target_names.contains(f_entry.name) or
                    std.mem.endsWith(u8, f_entry.name, ".h") or
                    std.mem.endsWith(u8, f_entry.name, ".def"))
                {
                    matches_target = true;
                }
            }
        }

        if (matches_target) {
            try candidate_dirs.append(arena, .{ .path = sub_path, .file_names = names });
        }
    }

    // 3. Match ConfigHeader steps (by file presence and content score)
    var file_content_cache = std.array_hash_map.String([]const u8).empty;
    for (conf.steps) |step| {
        if (step.extended.cast(conf, Configuration.Step.ConfigHeader)) |ch| {
            const inc_path = ch.include_path.slice(conf);
            const base_name = std.fs.path.basename(inc_path);

            var best_dir: ?[]const u8 = null;
            var best_score: usize = 0;
            var min_count: usize = std.math.maxInt(usize);

            for (candidate_dirs.items) |d| {
                var plausible = d.file_names.contains(base_name);
                if (!plausible and std.mem.indexOfScalar(u8, inc_path, '/') != null) {
                    const first_dir = inc_path[0..std.mem.indexOfScalar(u8, inc_path, '/').?];
                    plausible = d.file_names.contains(first_dir);
                }
                if (!plausible) continue;

                var content_opt: ?[]const u8 = null;
                const full_file_path = std.fs.path.join(arena, &.{ d.path, inc_path }) catch continue;
                if (getCachedFileContent(arena, io, &file_content_cache, full_file_path)) |c| {
                    content_opt = c;
                } else {
                    const alt_file_path = std.fs.path.join(arena, &.{ d.path, base_name }) catch continue;
                    content_opt = getCachedFileContent(arena, io, &file_content_cache, alt_file_path);
                }
                const content = content_opt orelse continue;

                var score: usize = 1;
                if (ch.include_guard.value) |guard_str| {
                    const guard = guard_str.slice(conf);
                    if (guard.len > 0 and std.mem.indexOf(u8, content, guard) != null) {
                        score += 1000;
                    }
                }
                for (ch.values.slice) |pair| {
                    const key = pair.key.slice(conf);
                    if (key.len > 0 and std.mem.indexOf(u8, content, key) != null) {
                        score += 10;
                    }
                }

                if (score > best_score) {
                    best_score = score;
                    best_dir = d.path;
                    min_count = d.file_names.count();
                } else if (score == best_score) {
                    if (d.file_names.count() < min_count) {
                        min_count = d.file_names.count();
                        best_dir = d.path;
                    }
                }
            }

            if (best_dir) |dir| {
                try generated_dirs.put(arena, ch.generated_dir, dir);
            }
        }
    }

    // 4. Match WriteFile steps (highest matching score)
    for (conf.steps) |step| {
        if (step.extended.cast(conf, Configuration.Step.WriteFile)) |wf| {
            var best_dir: ?[]const u8 = null;
            var best_score: usize = 0;

            for (candidate_dirs.items) |d| {
                var score: usize = 0;
                for (wf.copies.slice) |cp| {
                    const sub = std.fs.path.basename(cp.sub_path.slice(conf));
                    if (d.file_names.contains(sub)) score += 10;
                }
                for (wf.embeds.slice) |em| {
                    const sub = std.fs.path.basename(em.sub_path.slice(conf));
                    if (d.file_names.contains(sub)) score += 10;
                }
                for (wf.directories.slice) |dir_entry| {
                    const sub = dir_entry.sub_path.slice(conf);
                    if (sub.len > 0) {
                        const base = std.fs.path.basename(sub);
                        if (d.file_names.contains(base)) score += 10;
                    } else {
                        switch (dir_entry.src_path.get(conf)) {
                            .source_path => |sp| {
                                if (resolveSourcePath(arena, conf, build_root, sp) catch null) |full_src| {
                                    if (Io.Dir.openDirAbsolute(io, full_src, .{ .iterate = true }) catch null) |src_d_const| {
                                        var src_d = src_d_const;
                                        defer src_d.close(io);
                                        var s_it = src_d.iterate();
                                        var checked: usize = 0;
                                        while (s_it.next(io) catch null) |se| {
                                            if (checked >= 10) break;
                                            checked += 1;
                                            if (d.file_names.contains(se.name)) score += 5;
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }

                if (score > best_score) {
                    best_score = score;
                    best_dir = d.path;
                }
            }

            if (best_score > 0 and best_dir != null) {
                try generated_dirs.put(arena, wf.generated_directory, best_dir.?);
            }
        }
    }
}

fn getGlobalCacheDir(arena: Allocator, env_map: *const std.process.Environ.Map, build_root: []const u8) ![]const u8 {
    if (env_map.get("ZIG_GLOBAL_CACHE_DIR")) |env| {
        return arena.dupe(u8, env);
    }
    if (env_map.get("HOME")) |home| {
        return std.fs.path.join(arena, &.{ home, ".cache", "zig" });
    }
    return std.fs.path.join(arena, &.{ build_root, ".zig-cache" });
}

fn formatTriple(arena: Allocator, target: *const std.Target) ![]const u8 {
    if (target.abi != .none) {
        return std.fmt.allocPrint(arena, "{s}-{s}-{s}", .{
            @tagName(target.cpu.arch),
            @tagName(target.os.tag),
            @tagName(target.abi),
        });
    } else {
        return std.fmt.allocPrint(arena, "{s}-{s}", .{
            @tagName(target.cpu.arch),
            @tagName(target.os.tag),
        });
    }
}

fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |byte| {
        switch (byte) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{byte}),
            else => try w.writeByte(byte),
        }
    }
    try w.writeByte('"');
}

fn parseDriver(str: []const u8) ?Driver {
    if (std.mem.eql(u8, str, "zig")) return .zig;
    if (std.mem.eql(u8, str, "clang")) return .clang;
    return null;
}
