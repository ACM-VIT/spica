const c = @import("../contract.zig");
pub const contract = c;

pub const Step = union(enum) {
    expect: struct { request: c.Request, receipt: c.Receipt },
    emit: c.Observation,
    barrier: []const u8,
    at: u64,
    // Simulated native action, not an app-issued effect or repeated tool observation.
    native_action: void,
};
pub const Config = struct {
    account: c.Account,
    selection: c.SelectionResult,
    discovery: c.Discovery = .{ .capabilities = defaultCapabilities(), .limits = .{} },
};
pub fn defaultCapabilities() [@typeInfo(c.Capability).@"enum".fields.len]c.CapabilityInfo {
    var result: [@typeInfo(c.Capability).@"enum".fields.len]c.CapabilityInfo = undefined;
    for (&result) |*entry| entry.* = .{ .status = .supported };
    // No coordinator registration or normalized usage accounting implemented here.
    result[@intFromEnum(c.Capability.coordinator_bridge)].status = .unsupported;
    result[@intFromEnum(c.Capability.usage)].status = .unsupported;
    // The built-in fake factory intentionally does not claim these newer
    // workflows. Scripted fixtures opt in explicitly after implementing them.
    result[@intFromEnum(c.Capability.followup_queue)].status = .unsupported;
    result[@intFromEnum(c.Capability.question)].status = .unsupported;
    result[@intFromEnum(c.Capability.attachment)].status = .unsupported;
    return result;
}
pub const Call = struct { request: c.Request, receipt: c.Receipt, at: u64 };

/// Storage is entirely inline. Script/config strings must remain immutable/alive
/// until this instance and all returned views are discarded. Request inputs need
/// live only for dispatch: accepted call records borrow the byte-equal script.
pub fn Runtime(comptime queue_capacity: usize, comptime call_capacity: usize) type {
    return struct {
        const Self = @This();
        config: Config,
        script: []const Step,
        position: usize = 0,
        now: u64 = 0,
        counters: c.Counters = .{},
        observations: [queue_capacity]c.Observation = undefined,
        observation_head: usize = 0,
        observation_count: usize = 0,
        observation_bytes: usize = 0,
        questions: [queue_capacity]?c.Question = [_]?c.Question{null} ** queue_capacity,
        question_count: usize = 0,
        calls: [call_capacity]Call = undefined,
        call_head: usize = 0,
        call_count: usize = 0,

        pub fn init(config: Config, script: []const Step) c.Error!Self {
            const l = config.discovery.limits;
            if (l.queue_frames == 0 or l.queue_frames > queue_capacity or
                l.call_frames == 0 or l.call_frames > call_capacity or
                l.frame_bytes == 0 or l.chunk_bytes == 0 or l.chunk_bytes > l.frame_bytes or
                l.queue_bytes == 0 or l.pending_requests != 1) return error.InvalidLimits;
            if (l.followup_count == 0 or l.question_choices == 0 or l.attachment_count == 0 or
                l.followup_bytes == 0 or l.question_answer_bytes == 0 or l.attachment_bytes == 0 or
                l.attachment_metadata_bytes == 0) return error.InvalidLimits;
            if (config.discovery.capabilities[@intFromEnum(c.Capability.usage)].status == .supported or
                config.discovery.capabilities[@intFromEnum(c.Capability.coordinator_bridge)].status == .supported)
                return error.CapabilityUnavailable;
            return .{ .config = config, .script = script };
        }
        pub fn discover(self: *const Self) c.Discovery {
            return self.config.discovery;
        }
        pub fn accountStatus(self: *const Self, reference: []const u8) c.Account {
            if (c.equal(reference, self.config.account.reference)) return self.config.account;
            return .{ .reference = reference, .readiness = .unavailable };
        }
        pub fn resolveSelection(self: *const Self, requested: c.Selection) c.Error!c.SelectionResult {
            try self.require(.selection);
            try self.require(.workspace);
            if (self.accountStatus(requested.account_ref).readiness != .ready) return error.AccountUnavailable;
            if (!c.equal(requested, self.config.selection.requested)) return error.SelectionUnavailable;
            return self.config.selection;
        }
        fn require(self: *const Self, capability: c.Capability) c.Error!void {
            if (self.config.discovery.capabilities[@intFromEnum(capability)].status != .supported)
                return error.CapabilityUnavailable;
        }
        pub fn openSession(self: *Self, request: c.Open) c.Error!c.Receipt {
            return self.dispatch(.{ .open = request });
        }
        pub fn start(self: *Self, request: @FieldType(c.Request, "start")) c.Error!c.Receipt {
            return self.dispatch(.{ .start = request });
        }
        pub fn respondApproval(self: *Self, request: @FieldType(c.Request, "respond_approval")) c.Error!c.Receipt {
            return self.dispatch(.{ .respond_approval = request });
        }
        pub fn cancel(self: *Self, request: @FieldType(c.Request, "cancel")) c.Error!c.Receipt {
            return self.dispatch(.{ .cancel = request });
        }
        pub fn message(self: *Self, request: @FieldType(c.Request, "message")) c.Error!c.Receipt {
            return self.dispatch(.{ .message = request });
        }
        pub fn answerQuestion(self: *Self, request: @FieldType(c.Request, "answer_question")) c.Error!c.Receipt {
            return self.dispatch(.{ .answer_question = request });
        }
        pub fn inspect(self: *Self, request: @FieldType(c.Request, "inspect")) c.Error!c.Receipt {
            return self.dispatch(.{ .inspect = request });
        }
        pub fn attach(self: *Self, request: @FieldType(c.Request, "attach")) c.Error!c.Receipt {
            return self.dispatch(.{ .attach = request });
        }
        pub fn dispatch(self: *Self, request: c.Request) c.Error!c.Receipt {
            if (c.frameBytes(request) > self.config.discovery.limits.frame_bytes) return error.FrameTooLarge;
            switch (request) {
                .open => |open| switch (open) {
                    .create => |create| {
                        try self.require(.create);
                        const selection = try self.resolveSelection(create.selection);
                        if (selection.readiness != .ready or selection.effective == null) return error.SelectionUnavailable;
                    },
                    .existing => |r| {
                        try self.require(.attach);
                        if (r.after != null) try self.require(.replay);
                    },
                },
                .start => |r| {
                    try self.require(.start);
                    try validate(r.correlation, false);
                    if (r.attachments.len != 0) {
                        try self.require(.attachment);
                        try c.validateAttachments(r.attachments, self.config.discovery.limits);
                    }
                },
                .respond_approval => |r| {
                    try self.require(.approval);
                    try validate(r.correlation, true);
                },
                .cancel => |r| {
                    try self.require(.cancel);
                    try validate(r.correlation, false);
                },
                .message => |r| {
                    try self.require(.message);
                    try validate(r.correlation, false);
                    try c.validateAttachments(r.attachments, self.config.discovery.limits);
                    if (r.followup) |followup| {
                        try self.require(.followup_queue);
                        try c.validateFollowup(followup, self.config.discovery.limits);
                    }
                    if (r.attachments.len != 0) try self.require(.attachment);
                },
                .answer_question => |r| {
                    try self.require(.question);
                    try validate(r.correlation, false);
                    if (r.question.value.len == 0 or r.correlation.question == null or
                        !c.equal(r.question, r.correlation.question.?)) return error.InvalidQuestion;
                    try c.validateQuestionAnswer(r.answer, self.config.discovery.limits);
                    var matched: ?usize = null;
                    for (self.questions[0..self.question_count], 0..) |question, index| {
                        if (question) |pending| if (c.equal(pending.id, r.question)) {
                            if (!c.equal(pending.correlation.session, r.correlation.session) or
                                !c.equal(pending.correlation.run, r.correlation.run)) return error.InvalidQuestion;
                            if (pending.expires_at) |expires| if (self.now >= expires) return error.QuestionExpired;
                            if (r.answer.choice_ids.len == 0 and r.answer.text.len == 0) return error.InvalidQuestion;
                            if (!pending.allow_multiple and r.answer.choice_ids.len > 1) return error.InvalidQuestion;
                            if (r.answer.text.len != 0 and !pending.allow_freeform) return error.InvalidQuestion;
                            for (r.answer.choice_ids) |choice| {
                                var known = false;
                                for (pending.choices) |option| {
                                    if (c.equal(option.id, choice)) known = true;
                                }
                                if (!known) return error.InvalidQuestion;
                            }
                            matched = index;
                            break;
                        };
                    }
                    if (matched == null) return error.InvalidQuestion;
                    var shift = matched.?;
                    while (shift + 1 < self.question_count) : (shift += 1) self.questions[shift] = self.questions[shift + 1];
                    self.questions[self.question_count - 1] = null;
                    self.question_count -= 1;
                },
                .inspect => try self.require(.inspect),
                .attach => |r| {
                    try self.require(.attach);
                    if (r.after != null) try self.require(.replay);
                },
            }
            if (self.call_count == self.config.discovery.limits.call_frames) return error.CallLogFull;
            if (self.position == self.script.len) return error.ScriptFinished;
            const expected = switch (self.script[self.position]) {
                .expect => |e| e,
                else => return error.UnexpectedRequest,
            };
            if (!c.equal(request, expected.request)) return error.UnexpectedRequest;
            // Counting begins at dispatch, including rejected/ambiguous upstream receipts.
            switch (request) {
                .open => |o| switch (o) {
                    .create => self.counters.O += 1,
                    .existing => self.counters.T += 1,
                },
                .start => self.counters.S += 1,
                .respond_approval => self.counters.A += 1,
                .cancel => self.counters.C += 1,
                .message => |sent_message| {
                    self.counters.D += 1;
                    if (sent_message.followup != null) self.counters.F += 1;
                    if (sent_message.attachments.len != 0) self.counters.H += 1;
                },
                .answer_question => self.counters.Q += 1,
                .inspect => self.counters.I += 1,
                .attach => self.counters.T += 1,
            }
            self.calls[(self.call_head + self.call_count) % call_capacity] = .{
                .request = expected.request,
                .receipt = expected.receipt,
                .at = self.now,
            };
            self.call_count += 1;
            self.position += 1;
            return expected.receipt;
        }
        fn validate(correlation: c.Correlation, approval: bool) c.Error!void {
            if (correlation.effect == null or correlation.run == null or
                (approval and (correlation.tool == null or correlation.approval == null)))
                return error.InvalidCorrelation;
        }
        /// Explicit pumping: dispatch never emits/retries behind the caller's back.
        /// QueueFull is backpressure, leaves the current script step unconsumed.
        pub fn pump(self: *Self) c.Error!void {
            while (self.position < self.script.len) {
                switch (self.script[self.position]) {
                    .expect, .barrier => return,
                    .at => |deadline| if (self.now < deadline) return,
                    .native_action => self.counters.X += 1,
                    .emit => |observation| {
                        const capability: ?c.Capability = switch (observation.body) {
                            .chunk => .stream,
                            .tool_started, .tool_completed => .tools,
                            .approval => .approval,
                            .question => .question,
                            .selection => .selection,
                            .cancelled => .cancel,
                            else => null,
                        };
                        if (capability) |required| try self.require(required);
                        const bytes = c.frameBytes(observation);
                        const limits = self.config.discovery.limits;
                        if (bytes > limits.frame_bytes) return error.FrameTooLarge;
                        switch (observation.body) {
                            .chunk => |chunk| if (chunk.text.len > limits.chunk_bytes) return error.ChunkTooLarge,
                            .question => |question| {
                                try c.validateQuestion(question, limits);
                                if (self.question_count == queue_capacity) return error.QueueFull;
                                self.questions[self.question_count] = question;
                                self.question_count += 1;
                            },
                            else => {},
                        }
                        if (self.observation_count == limits.queue_frames or bytes > limits.queue_bytes - self.observation_bytes)
                            return error.QueueFull;
                        self.observations[(self.observation_head + self.observation_count) % queue_capacity] = observation;
                        self.observation_count += 1;
                        self.observation_bytes += bytes;
                    },
                }
                self.position += 1;
            }
        }
        pub fn poll(self: *Self) ?c.Observation {
            if (self.observation_count == 0) return null;
            const result = self.observations[self.observation_head];
            self.observation_head = (self.observation_head + 1) % queue_capacity;
            self.observation_count -= 1;
            self.observation_bytes -= c.frameBytes(result);
            return result;
        }
        pub fn takeCall(self: *Self) ?Call {
            if (self.call_count == 0) return null;
            const result = self.calls[self.call_head];
            self.call_head = (self.call_head + 1) % call_capacity;
            self.call_count -= 1;
            return result;
        }
        pub fn release(self: *Self, name: []const u8) c.Error!void {
            if (self.position == self.script.len) return error.BarrierMismatch;
            switch (self.script[self.position]) {
                .barrier => |expected| if (!c.equal(name, expected)) return error.BarrierMismatch,
                else => return error.BarrierMismatch,
            }
            self.position += 1;
        }
        pub fn advance(self: *Self, time: u64) c.Error!void {
            if (time < self.now) return error.ClockReversed;
            self.now = time;
        }
        pub fn finished(self: *const Self) bool {
            return self.position == self.script.len;
        }
    };
}
