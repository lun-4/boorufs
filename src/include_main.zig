const std = @import("std");
const sqlite = @import("sqlite");
const manage_main = @import("main.zig");
const Context = manage_main.Context;
const ID = manage_main.ID;
const tunez = @import("tunez");

const libpcre = @import("libpcre");

const logger = std.log.scoped(.ainclude);

const VERSION = "0.0.1";
const HELPTEXT =
    \\ ainclude: include a file/folder into the awtfdb
    \\
    \\ usage:
    \\ 	ainclude [options..] <file/folder path...>
    \\
    \\ options:
    \\ 	-h				prints this help and exits
    \\ 	-V				prints version and exits
    \\ 	-v				turns on verbosity (debug logging)
    \\ 	-t <tag>, --tag <tag>			add the following tag to the given path
    \\ 					 (if its a folder, add the tag to all files in the folder)
    \\ 	--infer-tags <inferrer>		infer tags using a processor.
    \\					all tags after that argument shall be
    \\					processed using that inferrer's options,
    \\					if any of them don't match, then argument
    \\					processing comes back to normal options
    \\ 					 (available processors: regex, audio, mime)
    \\ --filter-indexed-files-only	only include files already indexed
    \\ 					(useful if you're moving files around
    \\ 					and they're not catched by the
    \\ 					rename watcher)
    \\ --dry-run			do not do any index file modifications
    \\ -p pool_id			add given arguments in order into a pool
    \\ 					(recommended to do it with files only,
    \\ 					never folders)
    \\ --strict				do not implicitly add any tags, fail
    \\ 					on unknown tags.
    \\ --use-file-timestamp		use file timestamp on the internal file
    \\ 					id.
    \\
    \\ example, adding a single file:
    \\  ainclude --tag format:mp4 --tag "meme:what the dog doing" /downloads/funny_meme.mp4
    \\
    \\ example, adding a batch of files:
    \\  ainclude --tag format:mp4 --tag "meme:what the dog doing" /downloads/funny_meme.mp4 /download/another_dog_meme.mp4 /downloads/butter_dog.mp4
    \\
    \\ example, adding a media library:
    \\  ainclude --tag type:music --infer-tags media /my/music/collection
    \\
    \\ regex tag inferrer:
    \\ 	runs a regex over the filename of each included file and adds every
    \\ 	match as a tag for that file in the index.
    \\
    \\ 	every match group in the regex will be processed as a new tag
    \\
    \\ regex tag inferrer options:
    \\ 	--regex text			the regex to use (PCRE syntax)
    \\ 	--regex-use-full-path		if we should infer tags from the entire
    \\ 					path, instead of only the filename
    \\ 	--regex-text-scope scope	the tag scope to use (say, "mytag:")
    \\ 	--regex-cast-lowercase		if the content of the tag should be
    \\ 					converted to lowercase before adding it
    \\
    \\ example, using regex to infer tags based on filenames with "[tag]" as tags:
    \\  ainclude --infer-tags regex --regex '\[(.*?)\]' /my/movies/collection
;

fn utilAddScope(maybe_tag_scope: ?[]const u8, out: *std.ArrayList(u8).Writer) !usize {
    if (maybe_tag_scope) |tag_scope| {
        return try out.write(tag_scope);
    } else {
        return 0;
    }
}

fn utilAddRawTag(config: anytype, raw_tag_text: []const u8, out: *std.ArrayList(u8).Writer) !usize {
    if (config.cast_lowercase) {
        for (raw_tag_text) |raw_tag_character| {
            const written = try out.write(
                &[_]u8{std.ascii.toLower(raw_tag_character)},
            );
            std.debug.assert(written == 1);
        }
    } else {
        const written = try out.write(raw_tag_text);
        std.debug.assert(written == raw_tag_text.len);
    }

    return raw_tag_text.len;
}

fn utilAddTag(
    allocator: std.mem.Allocator,
    config: anytype,
    maybe_raw_tag: ?[]const u8,
    maybe_tag_scope: ?[]const u8,
    output_tags_list: *std.ArrayList([]const u8),
) !void {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    if (maybe_raw_tag) |raw_tag| {
        var writer = list.writer();
        _ = try utilAddScope(maybe_tag_scope, &writer);
        _ = try utilAddRawTag(config, raw_tag, &writer);
        try output_tags_list.append(
            try list.toOwnedSlice(),
        );
    }
}

const TestUtil = struct {
    pub fn runTestInferrerFile(
        allocator: std.mem.Allocator,
        filename: []const u8,
        test_vector_bytes: []const u8,
        comptime InferrerType: type,
        first_args: anytype,
        ctx: *Context,
        wanted_tags: anytype,
    ) !void {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        var file = try tmp.dir.createFile(filename, .{});
        defer file.close();
        const written_bytes = try file.write(test_vector_bytes);
        std.debug.assert(written_bytes == test_vector_bytes.len);

        var indexed_file = try ctx.createFileFromDir(tmp.dir, filename, .{});
        defer indexed_file.deinit();

        const file_tags = try indexed_file.fetchTags(allocator);
        defer allocator.free(file_tags);
        try std.testing.expectEqual(@as(usize, 0), file_tags.len);

        var tags_to_add = std.ArrayList([]const u8).init(allocator);
        defer {
            for (tags_to_add.items) |tag| allocator.free(tag);
            tags_to_add.deinit();
        }

        // actually run inferrer
        try @call(.auto, InferrerType.run, first_args ++ .{ &indexed_file, &tags_to_add });

        try addTagList(ctx, &indexed_file, tags_to_add);

        const file_tags_after = try indexed_file.fetchTags(allocator);
        defer allocator.free(file_tags_after);

        var found_tags: [wanted_tags.len]bool = undefined;
        // initialize
        for (found_tags, 0..) |_, idx| found_tags[idx] = false;

        for (file_tags_after) |file_tag| {
            const tag_list = try ctx.fetchTagsFromCore(allocator, file_tag.core);
            defer tag_list.deinit();

            try std.testing.expectEqual(@as(usize, 1), tag_list.items.len);
            const tag = tag_list.items[0];
            try std.testing.expectEqual(file_tag.core.id, tag.core.id);
            inline for (wanted_tags, 0..) |wanted_tag, index| {
                if (std.mem.eql(u8, wanted_tag, tag.kind.Named.text)) {
                    found_tags[index] = true;
                }
            }
        }

        // assert its all true

        for (found_tags, 0..) |value, index| {
            if (!value) {
                logger.err("tag on index {d} not found", .{index});
                for (tags_to_add.items) |tag| {
                    logger.err("given tag {s}", .{tag});
                }
                return error.TestUnexpectedResult;
            }
        }

        try std.testing.expectEqual(@as(usize, wanted_tags.len), file_tags_after.len);
        try std.testing.expectEqual(@as(usize, wanted_tags.len), tags_to_add.items.len);
    }
};

const TagInferrer = enum {
    regex,
    audio,
    mime,
};

const TagInferrerConfig = struct {
    last_argument: []const u8,
    config: union(TagInferrer) {
        regex: RegexTagInferrer.Config,
        audio: AudioMetadataTagInferrer.Config,
        mime: MimeTagInferrer.Config,
    },
};

const TagInferrerContext = union(TagInferrer) {
    regex: RegexTagInferrer.RunContext,
    audio: AudioMetadataTagInferrer.RunContext,
    mime: MimeTagInferrer.RunContext,
};

pub const exif_c = @cImport({
    @cInclude("libexif/exif-data.h");
});

extern "c" fn strerror(errcode: c_int) [*:0]const u8;

const RegexTagInferrer = struct {
    pub const Config = struct {
        // Regex text
        text: ?[]const u8 = null,

        // Outputs: either tag_scope or tag_on_match must be set
        tag_scope: ?[]const u8 = null,
        tag_on_match: ?[]const u8 = null,

        // which file inputs to use?
        use_full_path: bool = false,
        use_exif: bool = false,

        // Cast inputs to lowercase?
        cast_lowercase: bool = false,
    };

    pub const RunContext = struct {
        allocator: std.mem.Allocator,
        config: Config,
        regex_cstr: [:0]const u8,
        regex: libpcre.Regex,
    };

    pub fn consumeArguments(args_it: *std.process.ArgIterator) !TagInferrerConfig {
        var arg_state: enum { None, Text, TagScope, TagOnMatch } = .None;
        var config = TagInferrerConfig{
            .last_argument = undefined,
            .config = .{ .regex = .{} },
        };

        var arg: []const u8 = undefined;
        while (args_it.next()) |arg_from_loop| {
            arg = arg_from_loop;
            logger.debug("(regex tag inferrer) state: {} arg: {s}", .{ arg_state, arg });

            switch (arg_state) {
                .None => {},
                .Text => config.config.regex.text = arg,
                .TagScope => config.config.regex.tag_scope = arg,
                .TagOnMatch => config.config.regex.tag_on_match = arg,
            }

            // if we hit non-None states, we need to know if we're going
            // to have another configuration parameter or not
            //
            // and we do this by next()'ing into the next argument
            if (arg_state != .None) {
                arg = args_it.next() orelse break;
                arg_state = .None;
            }
            logger.debug("(regex tag inferrer, main loop) state: {} arg: {s}", .{ arg_state, arg });

            if (std.mem.eql(u8, arg, "--regex")) {
                arg_state = .Text;
            } else if (std.mem.eql(u8, arg, "--regex-text-scope")) {
                arg_state = .TagScope;
            } else if (std.mem.eql(u8, arg, "--regex-cast-lowercase")) {
                config.config.regex.cast_lowercase = true;
            } else if (std.mem.eql(u8, arg, "--regex-use-full-path")) {
                config.config.regex.use_full_path = true;
            } else if (std.mem.eql(u8, arg, "--regex-use-exif")) {
                config.config.regex.use_exif = true;
            } else if (std.mem.eql(u8, arg, "--regex-tag-on-match")) {
                arg_state = .TagOnMatch;
            } else {
                config.last_argument = arg;
                break;
            }
        }

        if (config.config.regex.text == null) return error.RegexArgumentRequired;
        return config;
    }

    pub fn init(config: TagInferrerConfig, allocator: std.mem.Allocator) !RunContext {
        const regex_config = config.config.regex;
        const regex_cstr = try allocator.dupeZ(u8, regex_config.text.?);
        return RunContext{
            .allocator = allocator,
            .config = regex_config,
            .regex_cstr = regex_cstr,
            .regex = try libpcre.Regex.compile(regex_cstr, .{}),
        };
    }

    pub fn deinit(self: *RunContext) void {
        self.allocator.free(self.regex_cstr);
    }

    pub fn run(
        self: *RunContext,
        file: *const Context.File,
        tags_to_add: *std.ArrayList([]const u8),
    ) !void {
        var input_text_list = std.ArrayList(u8).init(self.allocator);
        defer input_text_list.deinit();

        var input_text_writer = input_text_list.writer();
        _ = try input_text_writer.write(
            if (self.config.use_full_path) file.local_path else std.fs.path.basename(file.local_path),
        );

        if (self.config.use_exif) {
            const fd = try std.fs.openFileAbsolute(file.local_path, .{ .mode = .read_only });
            defer fd.close();

            const data = try fd.readToEndAlloc(self.allocator, std.math.maxInt(usize));
            defer self.allocator.free(data);

            const ed = exif_c.exif_data_new_from_data(data.ptr, @intCast(data.len));
            defer exif_c.exif_data_free(ed);
            if (ed == null) {
                const errstr = strerror(std.c._errno().*);
                std.debug.print("EXIF: error reading data ({s}): errno = {s}\n", .{ file.local_path, errstr });
                return error.NoExif;
            }

            const PARAMS_TO_GET = .{
                exif_c.EXIF_TAG_USER_COMMENT,
                exif_c.EXIF_TAG_IMAGE_DESCRIPTION,
                exif_c.EXIF_TAG_SOFTWARE,
            };

            inline for (PARAMS_TO_GET) |param| {
                const maybe_entry = exif_c.exif_content_get_entry(ed.*.ifd[exif_c.EXIF_IFD_EXIF], param);
                if (maybe_entry) |entry| {
                    var comment_buf: [8192]u8 = undefined;
                    _ = exif_c.exif_entry_get_value(entry, &comment_buf, comment_buf.len);
                    std.debug.print("fetched data from exif: {s}\n", .{comment_buf});
                    _ = try input_text_writer.write(" ");
                    _ = try input_text_writer.write(std.mem.span(@as([*c]u8, &comment_buf))); // why do i need [*c]u8 to compile what
                }
            }
        }

        const input_text = input_text_list.items;
        var offset: usize = 0;
        while (true) {
            logger.debug("regex input input: {s}", .{input_text});
            const maybe_captures = try self.regex.captures(self.allocator, input_text[offset..], .{});

            if (maybe_captures) |captures| {
                defer self.allocator.free(captures);

                const full_match = captures[0].?;
                logger.debug("captures array len={d} full_text={s}", .{ captures.len, input_text[offset + full_match.start ..] });

                // we got a match, add tag_on_match
                if (self.config.tag_on_match) |tag_on_match| {
                    try tags_to_add.append(try self.allocator.dupe(u8, tag_on_match));
                }

                for (captures[1..]) |capture| {
                    const tag_group = capture.?;

                    const raw_tag_text = input_text[offset + tag_group.start .. offset + tag_group.end];
                    var tag_text_list = std.ArrayList(u8).init(self.allocator);
                    defer tag_text_list.deinit();

                    var writer = tag_text_list.writer();
                    // if using tag_on_match, don't add autotags based on
                    // regex captures.
                    //
                    // i wonder if at this rate i should plug in some sort
                    // of scripting language for automated tagging...
                    if (self.config.tag_on_match == null) {
                        _ = try utilAddScope(self.config.tag_scope, &writer);
                        _ = try utilAddRawTag(self.config, raw_tag_text, &writer);
                    }

                    try tags_to_add.append(try tag_text_list.toOwnedSlice());
                }

                offset += full_match.end;
            } else {
                break;
            }
        }
    }
};

test "regex tag inferrer" {
    var ctx = try manage_main.makeTestContext();
    defer ctx.deinit();

    // setup regex inferrer

    const regex_config = RegexTagInferrer.Config{
        .text = "\\[(.*?)\\]",
    };

    const allocator = std.testing.allocator;

    var context = try RegexTagInferrer.init(
        .{ .last_argument = undefined, .config = .{ .regex = regex_config } },
        allocator,
    );
    defer RegexTagInferrer.deinit(&context);

    try TestUtil.runTestInferrerFile(
        allocator,
        "test_[tag3] file [tag1] [tag2][tag4]",
        "awooga",
        RegexTagInferrer,
        .{&context},
        &ctx,
        .{ "tag1", "tag2", "tag3", "tag4" },
    );
}

test "regex tag inferrer with exif" {
    var ctx = try manage_main.makeTestContext();
    defer ctx.deinit();

    // setup regex inferrer

    const regex_config = RegexTagInferrer.Config{
        .text = "Exif comment test!",
        .tag_on_match = "real_test_image",
        .use_exif = true,
    };

    const allocator = std.testing.allocator;

    var context = try RegexTagInferrer.init(
        .{ .last_argument = undefined, .config = .{ .regex = regex_config } },
        allocator,
    );
    defer RegexTagInferrer.deinit(&context);

    const test_file_bytes = @embedFile("test_vectors/sample-green-100x75.jpg");
    try TestUtil.runTestInferrerFile(
        allocator,
        "test_file.jpg",
        test_file_bytes,
        RegexTagInferrer,
        .{&context},
        &ctx,
        .{"real_test_image"},
    );
}

const AudioMetadataTagInferrer = struct {
    pub const Config = struct {
        tag_scope_album: ?[]const u8 = null,
        tag_scope_artist: ?[]const u8 = null,
        tag_scope_title: ?[]const u8 = null,
        cast_lowercase: bool = false,
    };

    pub const RunContext = struct {
        allocator: std.mem.Allocator,
        config: Config,
    };

    pub fn consumeArguments(args_it: *std.process.ArgIterator) !TagInferrerConfig {
        var arg_state: enum { None, AlbumTagScope, ArtistTagScope, TitleTagScope } = .None;
        var config: TagInferrerConfig = .{
            .last_argument = undefined,
            .config = .{ .audio = .{} },
        };
        var arg: []const u8 = undefined;
        while (args_it.next()) |arg_from_loop| {
            arg = arg_from_loop;
            logger.debug("(audio tag inferrer) state: {} arg: {s}", .{ arg_state, arg });

            switch (arg_state) {
                .None => {},
                .AlbumTagScope => config.config.audio.tag_scope_album = arg,
                .ArtistTagScope => config.config.audio.tag_scope_artist = arg,
                .TitleTagScope => config.config.audio.tag_scope_title = arg,
            }

            // if we hit non-None states, we need to know if we're going
            // to have another configuration parameter or not
            //
            // and we do this by next()'ing into the next argument
            if (arg_state != .None) {
                arg = args_it.next() orelse break;
                arg_state = .None;
            }
            logger.debug("(audio tag inferrer, main loop) state: {} arg: {s}", .{ arg_state, arg });

            if (std.mem.eql(u8, arg, "--artist-tag-scope")) {
                arg_state = .ArtistTagScope;
            } else if (std.mem.eql(u8, arg, "--album-tag-scope")) {
                arg_state = .AlbumTagScope;
            } else if (std.mem.eql(u8, arg, "--title-tag-scope")) {
                arg_state = .TitleTagScope;
            } else if (std.mem.eql(u8, arg, "--cast-lowercase")) {
                config.config.regex.cast_lowercase = true;
            } else {
                config.last_argument = arg;
                break;
            }
        }

        return config;
    }

    pub fn init(config: TagInferrerConfig, allocator: std.mem.Allocator) !RunContext {
        return RunContext{
            .allocator = allocator,
            .config = config.config.audio,
        };
    }

    pub fn deinit(self: *RunContext) void {
        _ = self;
    }

    pub fn run(
        self: *RunContext,
        file: *const Context.File,
        tags_to_add: *std.ArrayList([]const u8),
    ) !void {
        const extension = std.fs.path.extension(file.local_path);
        const is_mp3 = std.mem.eql(u8, extension, ".mp3");
        const is_flac = std.mem.eql(u8, extension, ".flac");
        if (!is_mp3 and !is_flac) {
            logger.err(
                "file {s} is not mp3 or flac (extension '{s}'), please exclude from paths",
                .{ file.local_path, extension },
            );
            return error.InvalidAudioFile;
        }

        var file_fd = try std.fs.cwd().openFile(file.local_path, .{ .mode = .read_only });
        defer file_fd.close();

        var buffered_reader = std.io.bufferedReader(file_fd.reader());

        var audio_meta = if (is_mp3)
            try tunez.resolveId3(buffered_reader.reader(), self.allocator)
        else if (is_flac)
            try tunez.resolveFlac(buffered_reader.reader(), self.allocator)
        else
            unreachable;
        defer audio_meta.deinit();

        try utilAddTag(
            self.allocator,
            self.config,
            audio_meta.maybe_track_album,
            self.config.tag_scope_album,
            tags_to_add,
        );

        try utilAddTag(
            self.allocator,
            self.config,
            audio_meta.maybe_track_title,
            self.config.tag_scope_title,
            tags_to_add,
        );

        if (audio_meta.maybe_track_artists) |artists| {
            for (artists) |artist_name| {
                try utilAddTag(
                    self.allocator,
                    self.config,
                    artist_name,
                    self.config.tag_scope_artist,
                    tags_to_add,
                );
            }
        }
    }
};

const AUDIO_TEST_VECTORS = .{
    "test_vectors/audio_test_vector.mp3",
};

test "audio tag inferrer" {
    var ctx = try manage_main.makeTestContext();
    defer ctx.deinit();

    inline for (AUDIO_TEST_VECTORS) |test_vector_path| {
        logger.warn("testing {s}", .{test_vector_path});
        const test_vector_bytes = @embedFile(test_vector_path);

        // setup audio inferrer

        const config = AudioMetadataTagInferrer.Config{
            .tag_scope_album = "album:",
            .tag_scope_artist = "artist:",
            .tag_scope_title = "title:",
        };
        const allocator = std.testing.allocator;

        var context = try AudioMetadataTagInferrer.init(
            .{ .last_argument = undefined, .config = .{ .audio = config } },
            allocator,
        );
        defer AudioMetadataTagInferrer.deinit(&context);

        // setup test file

        try TestUtil.runTestInferrerFile(
            allocator,
            "test.mp3",
            test_vector_bytes,
            AudioMetadataTagInferrer,
            .{&context},
            &ctx,
            .{ "artist:Test Artist", "album:Test Album", "title:Test Track" },
        );
    }
}

const MimeCookie = @import("libmagic.zig").MimeCookie;

const MimeTagInferrer = struct {
    pub const Config = struct {
        tag_scope_mimetype: ?[]const u8 = null,
        tag_for_all_images: ?[]const u8 = null,
        tag_for_all_audio: ?[]const u8 = null,
        tag_for_all_video: ?[]const u8 = null,
        cast_lowercase: bool = true,
    };

    pub const RunContext = struct {
        allocator: std.mem.Allocator,
        cookie: MimeCookie,
        config: Config,
    };

    pub fn consumeArguments(args_it: *std.process.ArgIterator) !TagInferrerConfig {
        var arg_state: enum { None, TagScopeMimetype, TagImage, TagAudio, TagVideo } = .None;
        var config: TagInferrerConfig = .{
            .last_argument = undefined,
            .config = .{ .mime = .{} },
        };
        var arg: []const u8 = undefined;
        while (args_it.next()) |arg_from_loop| {
            arg = arg_from_loop;
            logger.debug("(mime tag inferrer) state: {} arg: {s}", .{ arg_state, arg });

            switch (arg_state) {
                .None => {},
                .TagScopeMimetype => config.config.mime.tag_scope_mimetype = arg,
                .TagAudio => config.config.mime.tag_for_all_audio = arg,
                .TagVideo => config.config.mime.tag_for_all_video = arg,
                .TagImage => config.config.mime.tag_for_all_images = arg,
            }

            // if we hit non-None states, we need to know if we're going
            // to have another configuration parameter or not
            //
            // and we do this by next()'ing into the next argument
            if (arg_state != .None) {
                arg = args_it.next() orelse break;
                arg_state = .None;
            }
            logger.debug("(mime tag inferrer, main loop) state: {} arg: {s}", .{ arg_state, arg });

            if (std.mem.eql(u8, arg, "--mime-tag-scope")) {
                arg_state = .TagScopeMimetype;
            } else if (std.mem.eql(u8, arg, "--image-tag")) {
                arg_state = .TagImage;
            } else if (std.mem.eql(u8, arg, "--audio-tag")) {
                arg_state = .TagAudio;
            } else if (std.mem.eql(u8, arg, "--video-tag")) {
                arg_state = .TagVideo;
            } else {
                config.last_argument = arg;
                break;
            }
        }

        return config;
    }

    pub fn init(config: TagInferrerConfig, allocator: std.mem.Allocator) !RunContext {
        const self = RunContext{
            .allocator = allocator,
            .cookie = try MimeCookie.init(allocator, .{}),
            .config = config.config.mime,
        };

        // This is an absolute hack.
        //
        // When building in ReleaseSafe mode *without* this assert,
        // self.config.tag_for_all_video.?.ptr will be set to a different value,
        // a completely useless one, which leads to crashing as other pieces
        // of code attempt to use that value
        //
        // When this assert statement is added (or a log statement of
        // the value, which makes me call this a "Schrodinger's bug"), the
        // memory address becomes correct.
        //
        // This is a weird optimization bug that I have no idea about how to
        // solve it. It's not a libmagic bug, because if I set cookie to
        // `undefined`, not calling libmagic at all, the bug still happens.
        // I have attempted to run gdb (I can't watch -l on unions properly),
        // or lldb, or rr, or valgrind, and nothing here properly helps me.
        //
        // Only adding log statements made me even realize the error location
        if (config.config.mime.tag_for_all_video) |tag_for_all_video| {
            std.debug.assert(@intFromPtr(tag_for_all_video.ptr) ==
                @intFromPtr(self.config.tag_for_all_video.?.ptr));
        }

        return self;
    }

    pub fn deinit(self: *RunContext) void {
        self.cookie.deinit();
    }

    pub fn run(
        self: *RunContext,
        file: *const Context.File,
        tags_to_add: *std.ArrayList([]const u8),
    ) !void {
        const path_cstr = try self.allocator.dupeZ(u8, file.local_path);
        defer self.allocator.free(path_cstr);

        const mimetype = try self.cookie.inferFile(path_cstr);
        logger.debug("mime: {s}", .{mimetype});

        if (self.config.tag_scope_mimetype != null) {
            try utilAddTag(
                self.allocator,
                self.config,
                mimetype,
                self.config.tag_scope_mimetype,
                tags_to_add,
            );
        }

        if (std.mem.startsWith(u8, mimetype, "image/")) {
            try utilAddTag(
                self.allocator,
                self.config,
                self.config.tag_for_all_images,
                null,
                tags_to_add,
            );
        }

        if (std.mem.startsWith(u8, mimetype, "audio/")) {
            try utilAddTag(
                self.allocator,
                self.config,
                self.config.tag_for_all_audio,
                null,
                tags_to_add,
            );
        }

        if (std.mem.startsWith(u8, mimetype, "video/")) {
            try utilAddTag(
                self.allocator,
                self.config,
                self.config.tag_for_all_video,
                null,
                tags_to_add,
            );
        }
    }
};

test "mime tag inferrer" {
    var ctx = try manage_main.makeTestContext();
    defer ctx.deinit();

    const test_vector_bytes = @embedFile("./test_vectors/audio_test_vector.mp3");

    const config = MimeTagInferrer.Config{
        .tag_scope_mimetype = "mime:",
        .tag_for_all_audio = "funky",
    };
    const allocator = std.testing.allocator;

    var context = try MimeTagInferrer.init(
        .{ .last_argument = undefined, .config = .{ .mime = config } },
        allocator,
    );
    defer MimeTagInferrer.deinit(&context);

    try TestUtil.runTestInferrerFile(
        allocator,
        "test.mp3",
        test_vector_bytes,
        MimeTagInferrer,
        .{&context},
        &ctx,
        .{ "mime:audio/mpeg", "funky" },
    );
}

const StringList = std.ArrayList([]const u8);
const ConfigList = std.ArrayList(TagInferrerConfig);

pub const Args = struct {
    help: bool = false,
    version: bool = false,
    filter_indexed_files_only: bool = false,
    dry_run: bool = false,
    cli_v1: bool = true,
    tag_source: ?Context.File.Source = null,
    default_tags: StringList,
    wanted_inferrers: ConfigList,
    include_paths: StringList,
    pool: ?ID = null,
    strict: bool = false,
    use_file_timestamp: bool = false,

    pub fn deinit(self: *@This()) void {
        self.default_tags.deinit();
        self.wanted_inferrers.deinit();
        self.include_paths.deinit();
    }
};

fn addTagList(
    ctx: *Context,
    file: *Context.File,
    tags_to_add: std.ArrayList([]const u8),
) !void {
    for (tags_to_add.items) |named_tag_text| {
        logger.info("adding tag {s}", .{named_tag_text});
        const maybe_tag = try ctx.fetchNamedTag(named_tag_text, "en");
        if (maybe_tag) |tag| {
            try file.addTag(tag.core, .{});
        } else {
            const tag = try ctx.createNamedTag(named_tag_text, "en", null, .{});
            try file.addTag(tag.core, .{});
        }
    }
}

pub var current_log_level: std.log.Level = .info;

pub const std_options = struct {
    pub const log_level = .debug;
    pub const logFn = manage_main.log;
};

pub fn main() anyerror!void {
    const rc = sqlite.c.sqlite3_config(sqlite.c.SQLITE_CONFIG_LOG, manage_main.sqliteLog, @as(?*anyopaque, null));
    if (rc != sqlite.c.SQLITE_OK) {
        logger.err("failed to configure: {d} '{s}'", .{
            rc, sqlite.c.sqlite3_errstr(rc),
        });
        return error.ConfigFail;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var args_it = std.process.args();
    _ = args_it.skip();

    const ArgState = enum { None, FetchTag, InferMoreTags, FetchPool, FetchSource };

    var state: ArgState = .None;

    var given_args = Args{
        .default_tags = StringList.init(allocator),
        .wanted_inferrers = ConfigList.init(allocator),
        .include_paths = StringList.init(allocator),
    };
    defer given_args.deinit();

    var ctx = try manage_main.loadDatabase(allocator, .{});
    defer ctx.deinit();

    var arg: []const u8 = undefined;
    while (args_it.next()) |arg_from_loop| {
        arg = arg_from_loop;
        logger.debug("state: {} arg: {s}", .{ state, arg });
        switch (state) {
            .FetchTag => {
                try given_args.default_tags.append(arg);
                state = .None;
                continue;
            },
            .FetchPool => {
                given_args.pool = ID.fromString(arg);
                state = .None;
                continue;
            },
            .FetchSource => {
                const arg_as_int = try std.fmt.parseInt(i64, arg, 10);
                given_args.tag_source = (try ctx.fetchTagSource(.external, arg_as_int)) orelse return error.TagSourceNotFound;
                state = .None;
                continue;
            },
            .InferMoreTags => {
                const tag_inferrer = std.meta.stringToEnum(TagInferrer, arg) orelse return error.InvalidTagInferrer;
                const inferrer_config = switch (tag_inferrer) {
                    .regex => try RegexTagInferrer.consumeArguments(&args_it),
                    .audio => try AudioMetadataTagInferrer.consumeArguments(&args_it),
                    .mime => try MimeTagInferrer.consumeArguments(&args_it),
                };

                try given_args.wanted_inferrers.append(inferrer_config);

                arg = inferrer_config.last_argument;
                state = .None;
            },
            .None => {},
        }
        logger.debug("(possible transition) state: {} arg: {s}", .{ state, arg });

        if (std.mem.eql(u8, arg, "-h")) {
            given_args.help = true;
        } else if (std.mem.eql(u8, arg, "-v")) {
            current_log_level = .debug;
        } else if (std.mem.eql(u8, arg, "-V")) {
            given_args.version = true;
        } else if (std.mem.eql(u8, arg, "--filter-indexed-files-only")) {
            given_args.filter_indexed_files_only = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            given_args.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--use-file-timestamp")) {
            given_args.use_file_timestamp = true;
        } else if (std.mem.eql(u8, arg, "--v1")) {
            given_args.cli_v1 = true; // doesn't do anything yet
        } else if (std.mem.eql(u8, arg, "--tag") or std.mem.eql(u8, arg, "-t")) {
            state = .FetchTag;
            // tag inferrers require more than one arg, so we need to load
            // those args beforehand and then pass the arg state forward
        } else if (std.mem.eql(u8, arg, "--infer-tags")) {
            state = .InferMoreTags;
            // TODO check if this is supposed to be an argument or an
            // actual option by peeking over args_it. paths can have --
            // after all.
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pool")) {
            state = .FetchPool;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--source")) {
            state = .FetchSource;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            given_args.strict = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            logger.err("unknown argument '{s}'", .{arg});
            return error.InvalidArgument;
        } else {
            try given_args.include_paths.append(arg);
        }
    }

    if (given_args.help) {
        std.debug.print(HELPTEXT, .{});
        return;
    } else if (given_args.version) {
        std.debug.print("ainclude {s}\n", .{VERSION});
        return;
    }

    if (given_args.include_paths.items.len == 0) {
        logger.err("at least one include path needs to be given", .{});
        return error.MissingArgument;
    }

    if (given_args.dry_run) try ctx.turnIntoMemoryDb();

    logger.info("args: {}", .{given_args});

    // map tag names to their relevant cores in db
    var default_tag_cores = Context.HashList.init(allocator);
    defer default_tag_cores.deinit();
    var had_unknown_tags: bool = false;
    for (given_args.default_tags.items) |named_tag_text| {
        const maybe_tag = try ctx.fetchNamedTag(named_tag_text, "en");
        if (maybe_tag) |tag| {
            logger.debug(
                "tag '{s}' is core {s}",
                .{ named_tag_text, tag.core },
            );
            try default_tag_cores.append(tag.core);
        } else {
            had_unknown_tags = true;
            if (given_args.strict) {
                logger.err("strict mode is on. '{s}' is an unknown tag", .{named_tag_text});
            } else {
                // TODO support ISO 639-1 for language codes
                const new_tag = try ctx.createNamedTag(named_tag_text, "en", null, .{});
                logger.debug(
                    "(created!) tag '{s}' with core {s}",
                    .{ named_tag_text, new_tag.core },
                );
                try default_tag_cores.append(new_tag.core);
            }
        }
    }

    if (given_args.strict and had_unknown_tags) {
        logger.err("strict mode is on. had unknown tags. exiting", .{});
        return error.UnknownTag;
    }

    var maybe_pool: ?Context.Pool = null;
    if (given_args.pool) |pool_id| {
        maybe_pool = (try ctx.fetchPool(pool_id)) orelse return error.PoolNotFound;
    }
    defer if (maybe_pool) |pool| pool.deinit();

    var contexts = std.ArrayList(TagInferrerContext).init(allocator);
    defer contexts.deinit();
    for (given_args.wanted_inferrers.items) |inferrer_config| {
        switch (inferrer_config.config) {
            .regex => try contexts.append(.{ .regex = try RegexTagInferrer.init(inferrer_config, allocator) }),
            .audio => try contexts.append(.{ .audio = try AudioMetadataTagInferrer.init(inferrer_config, allocator) }),
            .mime => try contexts.append(.{ .mime = try MimeTagInferrer.init(inferrer_config, allocator) }),
        }
    }
    defer for (contexts.items) |*context| switch (context.*) {
        .regex => |*regex_ctx| RegexTagInferrer.deinit(regex_ctx),
        .audio => |*audio_ctx| AudioMetadataTagInferrer.deinit(audio_ctx),
        .mime => |*mime_ctx| MimeTagInferrer.deinit(mime_ctx),
    };

    var file_ids_for_tagtree = std.ArrayList(ID).init(allocator);
    defer file_ids_for_tagtree.deinit();

    for (given_args.include_paths.items) |path_to_include| {
        var dir: ?std.fs.Dir = std.fs.cwd().openDir(path_to_include, .{ .iterate = true }) catch |err| blk: {
            if (err == error.NotDir) {
                break :blk null;
            }
            logger.err("error while including path '{s}': {s}", .{ path_to_include, @errorName(err) });
            return err;
        };
        defer if (dir) |*unpacked_dir| unpacked_dir.close();

        if (dir == null) {
            if (given_args.filter_indexed_files_only) {
                @panic("TODO support filter_indexed_files_only on file paths");
            }
            var file = try ctx.createFileFromPath(path_to_include, .{
                .use_file_timestamp = given_args.use_file_timestamp,
            });
            try file_ids_for_tagtree.append(file.hash.id);
            defer file.deinit();
            logger.debug("adding file '{s}'", .{file.local_path});

            var savepoint = try ctx.db.savepoint("tags");
            errdefer savepoint.rollback();
            defer savepoint.commit();

            for (default_tag_cores.items) |tag_core| {
                try file.addTag(tag_core, .{ .source = given_args.tag_source });
            }

            var tags_to_add = std.ArrayList([]const u8).init(allocator);
            defer {
                for (tags_to_add.items) |tag| allocator.free(tag);
                tags_to_add.deinit();
            }

            for (given_args.wanted_inferrers.items, 0..) |inferrer_config, index| {
                logger.info("found config for  {}", .{inferrer_config});
                const inferrer_ctx = &contexts.items[index];
                switch (inferrer_ctx.*) {
                    .regex => |*regex_ctx| try RegexTagInferrer.run(regex_ctx, &file, &tags_to_add),
                    .audio => |*audio_ctx| try AudioMetadataTagInferrer.run(audio_ctx, &file, &tags_to_add),
                    .mime => |*mime_ctx| try MimeTagInferrer.run(mime_ctx, &file, &tags_to_add),
                }
            }

            try addTagList(&ctx, &file, tags_to_add);

            if (maybe_pool) |pool| try pool.addFile(file.hash.id);
        } else {
            var walker = try dir.?.walk(allocator);
            defer walker.deinit();

            while (try walker.next()) |entry| {
                switch (entry.kind) {
                    .file, .sym_link => {
                        const child_realpath = try entry.dir.realpathAlloc(ctx.allocator, entry.basename);
                        logger.debug(
                            "checking path '{s}'",
                            .{child_realpath},
                        );

                        defer ctx.allocator.free(child_realpath);

                        const maybe_existing_file = try ctx.fetchFileByPath(child_realpath);

                        // if we only want to reindex files already in
                        // the system, hash them first and try to fetch the file
                        // if it exists, move forward, if not, skip that file

                        // NOTE: shortcircuit is possible if we fetch by path first, ignore if it already exists
                        if (maybe_existing_file == null and given_args.filter_indexed_files_only) {
                            var fs_file = try entry.dir.openFile(
                                entry.basename,
                                .{ .mode = .read_only },
                            );
                            defer fs_file.close();

                            const hash = try ctx.calculateHash(fs_file, .{ .insert_new_hash = false });
                            logger.debug("hash is {s}", .{hash});
                            const maybe_file = try ctx.fetchFileByHash(hash.hash_data);

                            if (maybe_file) |file| {
                                file.deinit();
                            } else {
                                logger.debug("skipping due to selected filter", .{});
                                continue;
                            }
                        } else if (given_args.filter_indexed_files_only) {
                            logger.debug("already added!", .{});
                        }

                        var file = if (maybe_existing_file) |f|
                            f
                        else
                            try ctx.createFileFromDir(entry.dir, entry.basename, .{
                                .use_file_timestamp = given_args.use_file_timestamp,
                            });
                        try file_ids_for_tagtree.append(file.hash.id);
                        defer file.deinit();
                        {
                            var savepoint = try ctx.db.savepoint("tags");
                            errdefer savepoint.rollback();
                            defer savepoint.commit();

                            var tags_to_add = std.ArrayList([]const u8).init(allocator);
                            defer {
                                for (tags_to_add.items) |tag| allocator.free(tag);
                                tags_to_add.deinit();
                            }

                            for (default_tag_cores.items) |tag_core| {
                                try file.addTag(tag_core, .{ .source = given_args.tag_source });
                            }

                            for (given_args.wanted_inferrers.items, 0..) |inferrer_config, index| {
                                logger.info("found config for  {}", .{inferrer_config});
                                const inferrer_ctx = &contexts.items[index];
                                switch (inferrer_ctx.*) {
                                    .regex => |*regex_ctx| try RegexTagInferrer.run(regex_ctx, &file, &tags_to_add),
                                    .audio => |*audio_ctx| try AudioMetadataTagInferrer.run(audio_ctx, &file, &tags_to_add),
                                    .mime => |*mime_ctx| try MimeTagInferrer.run(mime_ctx, &file, &tags_to_add),
                                }
                            }

                            try addTagList(&ctx, &file, tags_to_add);
                            if (maybe_pool) |pool| try pool.addFile(file.hash.id);
                        }
                    },
                    else => {},
                }
            }
        }
    }

    try ctx.processTagTree(.{ .files = file_ids_for_tagtree.items });
}
