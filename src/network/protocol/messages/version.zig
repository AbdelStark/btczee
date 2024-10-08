const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();
const protocol = @import("../lib.zig");

const NetworkAddress = protocol.NetworkAddress;
const ServiceFlags = protocol.ServiceFlags;
const IpV6Address = protocol.IpV6Address;
const Message = protocol.message.Message;

const Endian = std.builtin.Endian;

const CompactSizeUint = @import("bitcoin-primitives").types.CompatSizeUint;

/// VersionMessage represents the "version" message
///
/// https://developer.bitcoin.org/reference/p2p_networking.html#version
pub const VersionMessage = struct {
    version: i32,
    services: u64,
    timestamp: i64,
    addr_recv: NetworkAddress,
    addr_trans: NetworkAddress,
    nonce: u64,
    user_agent: ?[]const u8,
    start_height: i32,
    relay: ?bool,

    /// Will free the user_agent if present in the message
    pub fn deinit(self: VersionMessage, allocator: std.mem.Allocator) void {
        if (self.user_agent) |ua| {
            allocator.free(ua);
        }
    }

    /// Serialize a message to bytes
    ///
    /// The caller is responsible for freeing the returned value.
    pub fn serializeTo(self: VersionMessage, buffer: []u8) void {
        const user_agent_len: usize = if (self.user_agent) |ua|
            ua.len
        else
            0;
        const compact_user_agent_len = CompactSizeUint.new(user_agent_len);
        const compact_user_agent_len_len = compact_user_agent_len.hint_encoded_len();

        copyWithEndian(buffer[0..4], std.mem.asBytes(&self.version), .little);
        copyWithEndian(buffer[4..12], std.mem.asBytes(&self.services), .little);
        copyWithEndian(buffer[12..20], std.mem.asBytes(&self.timestamp), .little);
        copyWithEndian(buffer[20..28], std.mem.asBytes(&self.addr_recv.services), .little);
        @memcpy(buffer[28..44], std.mem.asBytes(&self.addr_recv.address.ip)); // ip is already repr as big endian
        copyWithEndian(buffer[44..46], std.mem.asBytes(&self.addr_recv.address.port), .big);
        copyWithEndian(buffer[46..54], std.mem.asBytes(&self.addr_trans.services), .little);
        @memcpy(buffer[54..70], std.mem.asBytes(&self.addr_trans.address.ip)); // ip is already repr as big endian
        copyWithEndian(buffer[70..72], std.mem.asBytes(&self.addr_trans.address.port), .big);
        copyWithEndian(buffer[72..80], std.mem.asBytes(&self.nonce), .little);
        compact_user_agent_len.encode_to(buffer[80..]);
        if (user_agent_len != 0) {
            @memcpy(buffer[80 + compact_user_agent_len_len .. 80 + compact_user_agent_len_len + user_agent_len], self.user_agent.?);
        }
        copyWithEndian(buffer[80 + compact_user_agent_len_len + user_agent_len .. 80 + compact_user_agent_len_len + user_agent_len + 4], std.mem.asBytes(&self.start_height), .little);
        if (self.relay) |relay| {
            copyWithEndian(buffer[80 + compact_user_agent_len_len + user_agent_len + 4 .. 80 + compact_user_agent_len_len + user_agent_len + 4 + 1], std.mem.asBytes(&relay), .little);
        }
    }

    /// Serialize a message to bytes
    ///
    /// The caller is responsible for freeing the returned value.
    pub fn serialize(self: VersionMessage, allocator: std.mem.Allocator) ![]u8 {
        const serialized_len = self.hintSerializedLen();

        const res = try allocator.alloc(u8, serialized_len);

        self.serializeTo(res);

        return res;
    }

    pub const DeserializeError = error{
        InputTooShort,
    };

    /// Deserialize bytes into a `VersionMessage`
    ///
    /// The caller is responsible for freeing the allocated memory in field `user_agent` by calling `VersionMessage.deinit();`
    pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !VersionMessage {
        var vm: VersionMessage = undefined;

        // No Version can be shorter than this
        if (bytes.len < 85) {
            return error.InputTooShort;
        }
        const compact_user_agent_len = try CompactSizeUint.decode(bytes[80..]);
        const user_agent_len = compact_user_agent_len.value();
        const compact_user_agent_len_len = compact_user_agent_len.hint_encoded_len();

        copyWithEndian(std.mem.asBytes(&vm.version), bytes[0..4], .little);
        copyWithEndian(std.mem.asBytes(&vm.services), bytes[4..12], .little);
        copyWithEndian(std.mem.asBytes(&vm.timestamp), bytes[12..20], .little);
        copyWithEndian(std.mem.asBytes(&vm.addr_recv.services), bytes[20..28], .little);
        @memcpy(std.mem.asBytes(&vm.addr_recv.address.ip), bytes[28..44]); // ip already in big endian
        copyWithEndian(std.mem.asBytes(&vm.addr_recv.address.port), bytes[44..46], .big);
        copyWithEndian(std.mem.asBytes(&vm.addr_trans.services), bytes[46..54], .little);
        @memcpy(std.mem.asBytes(&vm.addr_trans.address.ip), bytes[54..70]); // ip already in big endian
        copyWithEndian(std.mem.asBytes(&vm.addr_trans.address.port), bytes[70..72], .big);
        copyWithEndian(std.mem.asBytes(&vm.nonce), bytes[72..80], .little);
        if (user_agent_len != 0) {
            const user_agent = try allocator.alloc(u8, user_agent_len);
            @memcpy(user_agent, bytes[80 + compact_user_agent_len_len .. 80 + compact_user_agent_len_len + user_agent_len]);
            vm.user_agent = user_agent;
        } else {
            vm.user_agent = null;
        }
        copyWithEndian(std.mem.asBytes(&vm.start_height), bytes[80 + compact_user_agent_len_len + user_agent_len .. 80 + compact_user_agent_len_len + user_agent_len + 4], .little);
        if (bytes.len == 80 + compact_user_agent_len_len + user_agent_len + 4 + 1) {
            copyWithEndian(std.mem.asBytes(&vm.relay.?), bytes[80 + compact_user_agent_len_len + user_agent_len + 4 .. 80 + compact_user_agent_len_len + user_agent_len + 4 + 1], .little);
        } else {
            vm.relay = null;
        }

        return vm;
    }

    pub fn hintSerializedLen(self: VersionMessage) usize {
        // 4 + 8 + 8 + (2 * (8 + 16 + 2) + 8 + 4)
        const fixed_length = 84;
        const user_agent_len: usize = if (self.user_agent) |ua|
            ua.len
        else
            0;
        const compact_user_agent_len = CompactSizeUint.new(user_agent_len);
        const compact_user_agent_len_len = compact_user_agent_len.hint_encoded_len();
        const relay_len: usize = if (self.relay != null) 1 else 0;
        const variable_length = compact_user_agent_len_len + user_agent_len + relay_len;
        return fixed_length + variable_length;
    }
};

// Copy to dest and apply the specified endianness
//
// dest and src should not overlap
// dest.len should be == to src.len
fn copyWithEndian(dest: []u8, src: []const u8, endian: Endian) void {
    @memcpy(dest, src);
    if (native_endian != endian) {
        std.mem.reverse(u8, dest[0..src.len]);
    }
}

// TESTS

fn compareVersionMessage(lhs: VersionMessage, rhs: VersionMessage) bool {
    // Normal fields
    if (lhs.version != rhs.version //
    or lhs.services != rhs.services //
    or lhs.timestamp != rhs.timestamp //
    or lhs.addr_recv.services != rhs.addr_recv.services //
    or !std.mem.eql(u16, &lhs.addr_recv.address.ip, &rhs.addr_recv.address.ip) //
    or lhs.addr_recv.address.port != rhs.addr_recv.address.port //
    or lhs.addr_trans.services != rhs.addr_trans.services //
    or !std.mem.eql(u16, &lhs.addr_trans.address.ip, &rhs.addr_trans.address.ip) //
    or lhs.addr_trans.address.port != rhs.addr_trans.address.port //
    or lhs.nonce != rhs.nonce) {
        return false;
    }

    // user_agent
    if (lhs.user_agent) |lua| {
        if (rhs.user_agent) |rua| {
            if (!std.mem.eql(u8, lua, rua)) {
                return false;
            }
        } else {
            return false;
        }
    } else {
        if (rhs.user_agent) |_| {
            return false;
        }
    }

    // relay
    if (lhs.relay) |ln| {
        if (rhs.relay) |rn| {
            if (ln != rn) {
                return false;
            }
        } else {
            return false;
        }
    } else {
        if (rhs.relay) |_| {
            return false;
        }
    }

    return true;
}

test "ok_full_flow_VersionMessage" {
    const allocator = std.testing.allocator;

    // No optional
    {
        const vm = VersionMessage{
            .version = 42,
            .services = ServiceFlags.NODE_NETWORK,
            .timestamp = 43,
            .addr_recv = NetworkAddress{
                .services = ServiceFlags.NODE_WITNESS,
                .address = IpV6Address{
                    .ip = [_]u16{13} ** 8,
                    .port = 17,
                },
            },
            .addr_trans = NetworkAddress{
                .services = ServiceFlags.NODE_BLOOM,
                .address = IpV6Address{
                    .ip = [_]u16{13} ** 8,
                    .port = 19,
                },
            },
            .nonce = 31,
            .user_agent = null,
            .start_height = 1000,
            .relay = null,
        };

        const payload = try vm.serialize(allocator);
        defer allocator.free(payload);
        const deserialized_vm = try VersionMessage.deserialize(allocator, payload);
        defer deserialized_vm.deinit(allocator);

        try std.testing.expect(compareVersionMessage(vm, deserialized_vm));
    }

    // With relay
    {
        const vm = VersionMessage{
            .version = 42,
            .services = ServiceFlags.NODE_NETWORK,
            .timestamp = 43,
            .addr_recv = NetworkAddress{
                .services = ServiceFlags.NODE_WITNESS,
                .address = IpV6Address{
                    .ip = [_]u16{13} ** 8,
                    .port = 17,
                },
            },
            .addr_trans = NetworkAddress{
                .services = ServiceFlags.NODE_BLOOM,
                .address = IpV6Address{
                    .ip = [_]u16{13} ** 8,
                    .port = 19,
                },
            },
            .nonce = 31,
            .user_agent = null,
            .start_height = 1000,
            .relay = true,
        };

        const payload = try vm.serialize(allocator);
        defer allocator.free(payload);
        const deserialized_vm = try VersionMessage.deserialize(allocator, payload);
        defer deserialized_vm.deinit(allocator);

        try std.testing.expect(compareVersionMessage(vm, deserialized_vm));
    }

    // With relay and user agent
    {
        const user_agent = [_]u8{0} ** 2046;
        const vm = VersionMessage{
            .version = 42,
            .services = ServiceFlags.NODE_NETWORK,
            .timestamp = 43,
            .addr_recv = NetworkAddress{
                .services = ServiceFlags.NODE_WITNESS,
                .address = IpV6Address{
                    .ip = [_]u16{13} ** 8,
                    .port = 17,
                },
            },
            .addr_trans = NetworkAddress{
                .services = ServiceFlags.NODE_BLOOM,
                .address = IpV6Address{
                    .ip = [_]u16{13} ** 8,
                    .port = 19,
                },
            },
            .nonce = 31,
            .user_agent = &user_agent,
            .start_height = 1000,
            .relay = false,
        };

        const payload = try vm.serialize(allocator);
        defer allocator.free(payload);
        const deserialized_vm = try VersionMessage.deserialize(allocator, payload);
        defer deserialized_vm.deinit(allocator);

        try std.testing.expect(compareVersionMessage(vm, deserialized_vm));
    }
}
