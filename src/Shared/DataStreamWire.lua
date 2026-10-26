--[[
    DataStreamWire.lua
    Stratiz

    Description:
        Wire format for replication batches. The server sends one remote call per
        stream per flush: (header : buffer, items : {any}?).

        header is a packed run of entries, each:
            varint  sequence delta from the previous entry (the first is from 0)
            u8      flags (see below)
            varint  path id                  PATH_BY_ID / PATH_DEFINE
            varint  array op position        OP_INSERT / OP_REMOVE
            varint  freed id count, then     HAS_FREES
                    that many varint ids

        items holds everything that isn't a small integer, consumed in entry order:
            the path                         PATH_INLINE / PATH_DEFINE
            the repair list                  HAS_REPAIRS
            the value                        HAS_VALUE
        Values can be nil, so they get a flag instead of a slot: remote arrays
        don't survive nil holes.

        Path ids are per stream and never reused, so every define and free is
        safe to replay (clients replay them from updates a snapshot already
        contains). An id is defined by the first update that sends its path,
        and freed by the update that removes the data at that path.

--]]

--= Root =--
local DataStreamWire = { }

--= Constants =--

-- Flags, bits 0-1: how the entry's path is sent
DataStreamWire.PATH_MODE_MASK = 3
DataStreamWire.PATH_BY_ID = 0 -- known id
DataStreamWire.PATH_INLINE = 1 -- path in items, no id (Instance key, or the dictionary is full)
DataStreamWire.PATH_DEFINE = 2 -- path in items, defines the id that follows
DataStreamWire.PATH_ROOT = 3 -- the stream root

DataStreamWire.HAS_REPAIRS = 4
DataStreamWire.HAS_VALUE = 8

-- Flags, bits 4-5: array op
DataStreamWire.OP_MASK = 48
DataStreamWire.OP_INSERT = 16
DataStreamWire.OP_REMOVE = 32

-- Applied after the entry's update, in this order
DataStreamWire.HAS_FREES = 64
DataStreamWire.CLEAR_PATHS = 128

local INITIAL_WRITER_SIZE = 64
local MAX_VARINT = 2 ^ 53
local MAX_VARINT_BYTES = 8 -- ceil(53 / 7)

--= Types =--

export type Writer = {
    Buffer : buffer,
    Cursor : number,
}

--= Internal Functions =--

local function Reserve(writer : Writer, byteCount : number)
    local size = buffer.len(writer.Buffer)
    local needed = writer.Cursor + byteCount
    if needed > size then
        local grown = buffer.create(math.max(size * 2, needed))
        buffer.copy(grown, 0, writer.Buffer, 0, writer.Cursor)
        writer.Buffer = grown
    end
end

--= API Functions =--

function DataStreamWire.NewWriter() : Writer
    return {
        Buffer = buffer.create(INITIAL_WRITER_SIZE),
        Cursor = 0,
    }
end

function DataStreamWire.WriteU8(writer : Writer, value : number)
    Reserve(writer, 1)
    buffer.writeu8(writer.Buffer, writer.Cursor, value)
    writer.Cursor += 1
end

-- Unsigned LEB128: 7 bits per byte, high bit set on every byte but the last.
-- Values under 128 take one byte; exact up to 2^53, so sequences never wrap.
function DataStreamWire.WriteVarint(writer : Writer, value : number)
    if not (value >= 0 and value <= MAX_VARINT and value % 1 == 0) then
        error("WriteVarint expects a non-negative integer, got " .. tostring(value))
    end

    Reserve(writer, MAX_VARINT_BYTES)
    while value >= 128 do
        buffer.writeu8(writer.Buffer, writer.Cursor, value % 128 + 128)
        writer.Cursor += 1
        value = math.floor(value / 128)
    end
    buffer.writeu8(writer.Buffer, writer.Cursor, value)
    writer.Cursor += 1
end

-- Returns a buffer trimmed to what was written.
function DataStreamWire.Finish(writer : Writer) : buffer
    local result = buffer.create(writer.Cursor)
    buffer.copy(result, 0, writer.Buffer, 0, writer.Cursor)
    return result
end

function DataStreamWire.ReadU8(source : buffer, cursor : number) : (number, number)
    return buffer.readu8(source, cursor), cursor + 1
end

-- Returns (value, next cursor). Errors past the end of the buffer.
function DataStreamWire.ReadVarint(source : buffer, cursor : number) : (number, number)
    local value = 0
    local multiplier = 1
    while true do
        local byte = buffer.readu8(source, cursor)
        cursor += 1
        if byte < 128 then
            return value + byte * multiplier, cursor
        end
        value += (byte - 128) * multiplier
        multiplier *= 128
    end
end

--= Return Module =--
return DataStreamWire
