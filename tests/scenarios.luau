--!nocheck
--[[
    End-to-end scenarios: DataStream's real server and client code running
    against each other on the Roblox stand-in in runtime.luau.

    After each network round every loaded client's copy of every stream must
    equal the server's, with no thread errors, no re-syncs, and (from an
    independent decode of the wire) no path id used before it was defined.

    Usage, from the repository root (Lune is pinned in aftman.toml):
        lune run tests/scenarios.luau                    every scenario, 40 fuzz seeds
        lune run tests/scenarios.luau seeds=200          more fuzzing
        lune run tests/scenarios.luau only=leaderboard   scenarios whose name contains the text
        lune run tests/scenarios.luau seed=7 [cap] [debug]
            one fuzz seed, repeated (Instance-key hash order varies per run);
            prints the last server operations on failure. cap: 8-id cap.
            debug: the client warns why it re-syncs.
        lune run tests/scenarios.luau mutate=staledefs   re-introduce a known bug;
            the suite should fail (see MUTATIONS)
        src=<path>                                       another copy of the package (default: src)
]]
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local Runtime = require("./runtime")

local OPTIONS = {}
for _, arg in process.args do
	local key, value = arg:match("^(%w+)=(.*)$")
	if key then
		OPTIONS[key] = value
	else
		OPTIONS[arg] = true
	end
end

local SRC = OPTIONS.src or "src"
local FUZZ_SEEDS = tonumber(OPTIONS.seeds) or 40

local WIRE_PATH = SRC .. "/Shared/DataStreamWire.lua"
local Wire = if fs.isFile(WIRE_PATH) then luau.load(fs.readFile(WIRE_PATH), { debugName = "Wire" })() else nil

-- Without the wire module (an older copy of the package), the wire checks are skipped.

------------------------------------------------------------------ framework

local results = { passed = 0, failed = 0 }

local function fail(message)
	error(message, 0)
end

local function check(condition, message)
	if not condition then fail(message) end
end

-- Independent decoder: tracks the ids a client should hold, from the wire alone.
local function attachTap(client)
	local tap = { Live = {}, Defines = 0, Frees = 0, UnknownRefs = {} }
	client.TapState = tap
	if not Wire then return end
	local function liveFor(name)
		tap.Live[name] = tap.Live[name] or {}
		return tap.Live[name]
	end
	client.Tap = function(message)
		if message.Kind == "result" then
			local requested = message.Request[1]
			local value = message.Values[1]
			if type(value) ~= "table" then return end
			local snapshots = if requested then { [requested] = value } else value
			for name, info in snapshots do
				local live = liveFor(name)
				for index = 1, #(info.Paths or {}), 2 do
					live[info.Paths[index]] = true
				end
			end
			return
		end
		local name = message.Remote:GetAttribute("StreamTarget")
		local header = message.Args[1]
		local live = liveFor(name)
		local cursor = 0
		while cursor < buffer.len(header) do
			local flags
			_, cursor = Wire.ReadVarint(header, cursor)
			flags, cursor = Wire.ReadU8(header, cursor)
			local mode = bit32.band(flags, Wire.PATH_MODE_MASK)
			if mode == Wire.PATH_BY_ID or mode == Wire.PATH_DEFINE then
				local id
				id, cursor = Wire.ReadVarint(header, cursor)
				if mode == Wire.PATH_DEFINE then
					live[id] = true
					tap.Defines += 1
				elseif not live[id] and client.Ready then
					table.insert(tap.UnknownRefs, id)
				end
			end
			if bit32.band(flags, Wire.OP_MASK) ~= 0 then
				_, cursor = Wire.ReadVarint(header, cursor)
			end
			if bit32.btest(flags, Wire.HAS_FREES) then
				local count
				count, cursor = Wire.ReadVarint(header, cursor)
				for _ = 1, count do
					local id
					id, cursor = Wire.ReadVarint(header, cursor)
					live[id] = nil
					tap.Frees += 1
				end
			end
			if bit32.btest(flags, Wire.CLEAR_PATHS) then
				table.clear(live)
			end
		end
	end
end

local function liveCount(client, name)
	local count = 0
	for _ in client.TapState.Live[name] or {} do count += 1 end
	return count
end

local DEBUG_PATCH = if OPTIONS.debug then require("./debug_patch") else nil

-- Re-introduce one known bug, to prove the suite catches it.
local MUTATIONS = {
	nocoalescefix = { "Server/DataStreamMeta.lua",
		"if entry.Op and #entry.PathTable < #pathTable and IsPathPrefixOf(entry.PathTable, pathTable) then",
		"if false then" },
	staledefs = { "Client/init.lua",
		"if pathMode == DataStreamWire.PATH_DEFINE then",
		"if pathMode == DataStreamWire.PATH_DEFINE and (LastSequence[name] == nil or entry.Sequence > LastSequence[name]) then" },
	nofrees = { "Server/DataStreamPathIds.lua",
		"function DataStreamPathIds.FreeStale(dictionary : Dictionary, pathTable : {any}, value : any) : {number}?\n",
		"function DataStreamPathIds.FreeStale(dictionary : Dictionary, pathTable : {any}, value : any) : {number}?\n    do return nil end\n" },
	noholefix = { "Server/DataStreamMeta.lua",
		"elseif sawInstance then\n                return false",
		"elseif sawInstance then" },
}
local MUTATION = if OPTIONS.mutate then assert(MUTATIONS[OPTIONS.mutate], "unknown mutation " .. OPTIONS.mutate) else nil

-- Cuts the path id cap to 8 so the inline-path fallback gets exercised.
local CAP_PATCH = {
	Patch = function(path, source)
		if path:match("DataStreamPathIds%.lua$") then
			local patched, count = source:gsub("local MAX_LIVE_IDS = 65536", "local MAX_LIVE_IDS = 8")
			assert(count == 1, "cap constant not found")
			return patched
		end
		return source
	end,
}

local function newRuntime(options)
	options = table.clone(options or {})
	if MUTATION then
		local inner = options.Patch
		options.Patch = function(path, source)
			if inner then source = inner(path, source) end
			if path:sub(-#MUTATION[1]) == MUTATION[1] then
				local start, finish = source:find(MUTATION[2], 1, true)
				assert(start, "mutation anchor not found")
				source = source:sub(1, start - 1) .. MUTATION[3] .. source:sub(finish + 1)
			end
			return source
		end
	end
	if DEBUG_PATCH then
		local inner = options.Patch
		options.Patch = function(path, source)
			if inner then source = inner(path, source) end
			return DEBUG_PATCH(path, source)
		end
	end
	local rt = Runtime.new(SRC, options)
	local addClient = rt.AddClient
	rt.AddClient = function(...)
		local client = addClient(...)
		attachTap(client)
		return client
	end
	return rt
end

-- Every ready client's view of every stream must equal the server's, with no
-- re-syncs, errors, or unknown path ids along the way.
local function verify(rt, streams, label)
	for _, err in rt.Errors do
		fail((label or "") .. " error: " .. err)
	end
	for index, warning in rt.Warnings do
		local message = warning.Message
		if message:find("re%-syncing") or message:find("Path error") or message:find("Malformed")
			or message:find("Invalid repair") or message:find("Last step is nil") then
			local context = {}
			for back = math.max(1, index - 4), index - 1 do
				if rt.Warnings[back].World == warning.World then
					table.insert(context, "\n        before: " .. rt.Warnings[back].Message)
				end
			end
			fail((label or "") .. " warning in " .. warning.World .. ": " .. message .. table.concat(context))
		end
	end
	for _, client in rt.Clients do
		if not client.Ready then continue end
		check(#client.TapState.UnknownRefs == 0,
			(label or "") .. " client referenced unknown id " .. tostring(client.TapState.UnknownRefs[1]))
		for _, stream in streams do
			local serverValue, clientValue
			if stream.Player then
				local owned = rt.DataStream[stream.Name][client.Player]
				serverValue = owned and owned:Read()
			else
				serverValue = rt.DataStream[stream.Name]:Read()
			end
			local clientStream = client.DataStream[stream.Name]
			clientValue = clientStream and clientStream:Read()
			local same, where = Runtime.DeepEqual(serverValue, clientValue)
			check(same, (label or "") .. " " .. stream.Name .. " differs for client "
				.. client.UserId .. " at " .. tostring(where))
		end
	end
end

local ONLY_SEED = tonumber(OPTIONS.seed)

local function test(name, fn)
	if ONLY_SEED then return end
	if OPTIONS.only and not name:find(OPTIONS.only, 1, true) then return end
	local ok, err = pcall(fn)
	if ok then
		results.passed += 1
		print("PASS  " .. name)
	else
		results.failed += 1
		print("FAIL  " .. name .. "\n      " .. tostring(err))
	end
end

-- Server-side navigation helper: returns the catcher object at path.
local function at(stream, path)
	local node = stream
	for _, key in path do
		node = node[key]
	end
	return node
end

------------------------------------------------------------------ scenarios

test("nested writes, nil writes and Changed values reach clients", function()
	local rt = newRuntime()
	rt.DataStream:MakeGlobalStream("Game", { Round = { Number = 1, Teams = { Red = { Score = 0 } } } })
	local client = rt.AddClient()
	rt.Settle()
	check(client.Ready, "client never finished loading")

	local seen = {}
	client.DataStream.Game.Round.Teams.Red.Score:Changed(function(new, old)
		table.insert(seen, { new, old })
	end)

	local game = rt.DataStream.Game
	game.Round.Teams.Red.Score = 5
	rt.Frame()
	game.Round.Teams.Red.Score = 7
	game.Round.Teams.Blue = { Score = 3 }
	rt.Frame()
	game.Round.Teams.Blue = nil
	game.Round.Number = 2
	rt.Frame()
	game.Round.Teams = { Red = { Score = 1 } }
	rt.Settle()

	verify(rt, { { Name = "Game" } })
	check(#seen == 3, "expected 3 Changed calls, got " .. #seen)
	check(seen[1][1] == 5 and seen[1][2] == 0, "first Changed should be 5 (old 0)")
	check(seen[2][1] == 7 and seen[2][2] == 5, "second Changed should be 7 (old 5)")
	check(seen[3][1] == 1 and seen[3][2] == 7, "third Changed should be 1 (old 7)")
end)

test("repeat writes to one path send its id, not the path", function()
	local rt = newRuntime()
	rt.DataStream:MakeGlobalStream("Stats", { Server = { Uptime = 0 } })
	local client = rt.AddClient()
	rt.Settle()

	local defines = client.TapState.Defines
	for tick = 1, 20 do
		rt.DataStream.Stats.Server.Uptime = tick
		rt.Frame()
	end
	rt.Settle()
	verify(rt, { { Name = "Stats" } })
	check(client.TapState.Defines - defines == 1,
		"Uptime should be defined once, got " .. (client.TapState.Defines - defines))
end)

test("array ops and writes in the same frame (coalescing across ops)", function()
	local rt = newRuntime()
	rt.DataStream:MakeGlobalStream("Lists", { Arr = { "a", "b", "c", "d" }, Nested = { { V = 1 }, { V = 2 } } })
	rt.AddClient()
	rt.Settle()

	local lists = rt.DataStream.Lists
	-- write Arr[3], Remove(1) shifts it to Arr[2], write Arr[3] again
	lists.Arr[3] = "C1"
	lists.Arr:Remove(1)
	lists.Arr[3] = "D1"
	rt.Frame()
	-- a write that an Insert position depends on, then a write to the same path
	lists.Arr[4] = "E"
	lists.Arr:Insert(5, "F")
	lists.Arr[4] = "E2"
	rt.Frame()
	-- nested element tables shifting under interned paths
	lists.Nested[2].V = 20
	lists.Nested:Insert(1, { V = 0 })
	lists.Nested[2].V = 10
	lists.Nested:Remove(3)
	lists.Nested:Insert({ V = 99 })
	rt.Settle()
	verify(rt, { { Name = "Lists" } })
end)

test("snapshot taken between a write and its flush", function()
	local rt = newRuntime()
	rt.DataStream:MakeGlobalStream("Live", { Counter = 0, Items = {} })
	local early = rt.AddClient()
	rt.Settle()

	for round = 1, 30 do
		local live = rt.DataStream.Live
		live.Counter = round
		live.Items["item" .. round] = { Level = round }
		if round > 2 then
			live.Items["item" .. (round - 2)] = nil
		end
		if round % 3 == 0 then
			rt.AddClient()
		end
		-- serve GetData before the deferred flush: the snapshot contains writes
		-- whose ids are defined only by the batch that follows it
		rt.Frame(true)
	end
	rt.Settle()
	verify(rt, { { Name = "Live" } })
	check(early.Ready, "early client not ready")
end)

test("UserId-keyed leaderboard: ids are freed as players leave", function()
	local rt = newRuntime()
	rt.DataStream:MakeGlobalStream("Leaderboard", {})
	local observer = rt.AddClient()
	rt.Settle()

	local board = rt.DataStream.Leaderboard
	local active = {}
	for cycle = 1, 150 do
		local client = rt.AddClient()
		local key = tostring(client.UserId)
		board[key] = { Score = 0, Kills = 0, Name = "P" .. key }
		table.insert(active, client)
		for _, other in active do
			board[tostring(other.UserId)].Score = cycle
			board[tostring(other.UserId)].Kills = cycle % 7
		end
		if #active > 6 then
			local leaving = table.remove(active, 1)
			board[tostring(leaving.UserId)] = nil
			rt.RemoveClient(leaving)
		end
		rt.Frame(cycle % 2 == 0)
	end
	rt.Settle()
	verify(rt, { { Name = "Leaderboard" } })

	-- 6 entries x (entry + Score + Kills) = 18 live ids; anything near the
	-- 450 ever defined would mean frees aren't happening.
	local live = liveCount(observer, "Leaderboard")
	check(live <= 18, "observer holds " .. live .. " live ids, expected <= 18")
	check(observer.TapState.Defines > 300, "expected many defines over the churn")
	local newest = rt.Clients[#rt.Clients]
	check(liveCount(newest, "Leaderboard") == live,
		"newest client's snapshot ids (" .. liveCount(newest, "Leaderboard") .. ") should match observer (" .. live .. ")")
end)

test("player streams: per-player data, stream removed and re-made", function()
	local rt = newRuntime()
	rt.DataStream:AddPlayerStreamTemplate("PlayerData", { Coins = 0, Stats = { Level = 1, XP = 0 }, Inventory = {} })
	local a = rt.AddClient()
	local b = rt.AddClient()
	rt.Settle()
	check(a.Ready and b.Ready, "clients not ready")

	local data = rt.DataStream.PlayerData
	for tick = 1, 10 do
		data[a.Player].Coins = tick * 10
		data[a.Player].Stats.XP = tick
		data[b.Player].Stats.Level = tick
		data[b.Player].Inventory:Insert({ Id = tick, Durability = 100 })
		rt.Frame()
	end
	data[b.Player].Inventory[2].Durability = 50
	data[b.Player].Inventory:Remove(1)
	rt.Frame()
	verify(rt, { { Name = "PlayerData", Player = true } })

	-- remove and re-make a's stream: ids clear, then get re-defined
	rt.DataStream:RemoveStreamForPlayer("PlayerData", a.Player)
	rt.Settle()
	check(liveCount(a, "PlayerData") == 0, "ids should clear when the stream is removed, have " .. liveCount(a, "PlayerData"))
	rt.DataStream:MakeStreamForPlayer("PlayerData", a.Player, { Coins = 5, Stats = { Level = 2, XP = 0 }, Inventory = {} })
	rt.Settle()
	data[a.Player].Coins = 6
	data[a.Player].Stats.XP = 1
	rt.Settle()
	verify(rt, { { Name = "PlayerData", Player = true } })
end)

test("Instance keys and values (inline paths, repairs)", function()
	local rt = newRuntime()
	local partA, partB = rt.NewPart("A"), rt.NewPart("B")
	rt.DataStream:MakeGlobalStream("World", { Owners = {}, Focus = false })
	rt.AddClient()
	rt.Settle()

	local world = rt.DataStream.World
	world.Owners = { [partA] = { Health = 100 }, [partB] = { Health = 50 } }
	rt.Frame()
	world.Owners[partA].Health = 90 -- path through an Instance key: sent inline
	world.Focus = partB
	rt.Frame()
	world.Owners[partB] = nil
	world.Owners[partA].Health = 80
	rt.Settle()
	verify(rt, { { Name = "World" } })
end)

test("arrays with an Instance before other elements", function()
	local rt = newRuntime()
	local part = rt.NewPart("Sword")
	rt.DataStream:MakeGlobalStream("Loadout", { Slots = {} })
	rt.AddClient()
	rt.Settle()

	rt.DataStream.Loadout.Slots = { part, "Shield", { Name = "Bow" } }
	rt.Frame()
	rt.DataStream.Loadout.Mixed = { "a", part, "b", part }
	rt.Settle()
	verify(rt, { { Name = "Loadout" } })

	-- and in a snapshot for a client that joins afterwards
	rt.AddClient()
	rt.Settle()
	verify(rt, { { Name = "Loadout" } })
end)

test("global root write frees ids for dropped keys", function()
	local rt = newRuntime()
	rt.DataStream:MakeGlobalStream("Config", { A = { X = 1 }, B = { Y = 2 } })
	local client = rt.AddClient()
	rt.Settle()

	rt.DataStream.Config.A.X = 2
	rt.DataStream.Config.B.Y = 3
	rt.Frame()
	check(liveCount(client, "Config") == 2, "expected 2 live ids, got " .. liveCount(client, "Config"))
	rt.DataStream.Config = { A = { X = 5 } }
	rt.Settle()
	verify(rt, { { Name = "Config" } })
	check(liveCount(client, "Config") == 1, "B.Y's id should be freed, live = " .. liveCount(client, "Config"))
end)

------------------------------------------------------------------ fuzz

local KEYS = { "a", "b", "c", 1, 2, 3, 101, 102 }

local function randomTree(rng, depth, parts)
	if depth == 0 or rng:NextNumber() < 0.3 then
		if parts and rng:NextNumber() < 0.05 then
			return parts[rng:NextInteger(1, #parts)]
		end
		return rng:NextInteger(0, 9)
	end
	local tree = {}
	for _ = 1, rng:NextInteger(0, 3) do
		tree[KEYS[rng:NextInteger(1, #KEYS)]] = randomTree(rng, depth - 1, parts)
	end
	return tree
end

local function tablePaths(value, path, out)
	table.insert(out, path)
	for key, child in pairs(value) do
		if type(child) == "table" and #path < 3 then
			local childPath = table.clone(path)
			table.insert(childPath, key)
			tablePaths(child, childPath, out)
		end
	end
	return out
end

-- True sequences only (keys exactly 1..n): # is ambiguous on anything else,
-- and Insert/Remove on a non-sequence is undefined in Lua itself.
local function isArray(value)
	local count = 0
	for key in pairs(value) do
		count += 1
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return false end
	end
	for index = 1, count do
		if value[index] == nil then return false end
	end
	return true
end

local function valueAt(root, path)
	local node = root
	for _, key in path do node = node[key] end
	return node
end

local Rng = {}
Rng.__index = Rng
function Rng.new(seed)
	return setmetatable({ state = seed * 2654435761 % 4294967296 + 1 }, Rng)
end
function Rng:NextNumber()
	self.state = (self.state * 1103515245 + 12345) % 2147483648
	return self.state / 2147483648
end
function Rng:NextInteger(low, high)
	return low + math.floor(self:NextNumber() * (high - low + 1))
end

-- Server operation log, kept only for seed= runs.
local fuzzLog = nil
local function log(...)
	if fuzzLog then
		local parts = {}
		for index = 1, select("#", ...) do parts[index] = tostring((select(index, ...))) end
		table.insert(fuzzLog, table.concat(parts, " "))
	end
end

local function pathString(path)
	local parts = {}
	for _, key in path do table.insert(parts, tostring(key) .. ":" .. typeof(key)) end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function keyList(value)
	local keys = {}
	for key in pairs(value) do table.insert(keys, tostring(key)) end
	return table.concat(keys, ",")
end

local function fuzz(seed, options)
	local rng = Rng.new(seed)
	local rt = newRuntime(options)
	local parts = { rt.NewPart("P1"), rt.NewPart("P2") }
	rt.DataStream:MakeGlobalStream("Fuzz", { arr = {} })
	rt.AddClient()
	rt.Settle(2)

	for frame = 1, 60 do
		for _ = 1, rng:NextInteger(0, 6) do
			local root = rt.DataStream.Fuzz:Read()
			local roll = rng:NextNumber()
			if roll < 0.02 then
				log("frame", frame, "ROOT write")
				rt.DataStream.Fuzz = { arr = {}, x = randomTree(rng, 2, parts) }
				continue
			end
			local tables = tablePaths(root, {}, {})
			local arrays = {}
			for _, path in tables do
				if isArray(valueAt(root, path)) and #path > 0 then table.insert(arrays, path) end
			end
			if roll < 0.25 and #arrays > 0 then
				local path = arrays[rng:NextInteger(1, #arrays)]
				local array = valueAt(root, path)
				if #array > 0 and rng:NextNumber() < 0.45 then
					local position = rng:NextInteger(1, #array)
					log("frame", frame, "Remove", pathString(path), position, "len", #array)
					at(rt.DataStream.Fuzz, path):Remove(position)
				else
					local position = rng:NextInteger(1, #array + 1)
					local element = randomTree(rng, 2, parts)
					log("frame", frame, "Insert", pathString(path), position, "len", #array, "keys", keyList(array))
					at(rt.DataStream.Fuzz, path):Insert(position, element)
				end
				continue
			end
			local parentPath = tables[rng:NextInteger(1, #tables)]
			local parent = valueAt(root, parentPath)
			local key = KEYS[rng:NextInteger(1, #KEYS)]
			if roll < 0.3 then
				key = parts[rng:NextInteger(1, #parts)] -- Instance key
			end
			local node = at(rt.DataStream.Fuzz, parentPath)
			if roll < 0.45 and parent[key] ~= nil then
				log("frame", frame, "nil", pathString(parentPath), tostring(key) .. ":" .. typeof(key), "parent keys", keyList(parent))
				node[key] = nil
			else
				local value = randomTree(rng, 2, parts)
				log("frame", frame, "set", pathString(parentPath), tostring(key) .. ":" .. typeof(key), "=", type(value) == "table" and rt.Describe(value) or tostring(value))
				node[key] = value
			end
		end
		if rng:NextNumber() < 0.1 then
			local joined = rt.AddClient()
			log("frame", frame, "JOIN", joined.UserId)
		end
		if #rt.Clients > 1 and rng:NextNumber() < 0.05 then
			rt.RemoveClient(rt.Clients[rng:NextInteger(1, #rt.Clients)])
		end
		local invokesFirst = rng:NextNumber() < 0.5
		log("frame", frame, "flush; invokesFirst", invokesFirst)
		rt.Frame(invokesFirst)
		verify(rt, { { Name = "Fuzz" } }, "seed " .. seed .. " frame " .. frame)
	end
	rt.Settle()
	verify(rt, { { Name = "Fuzz" } }, "seed " .. seed .. " final")
	return #rt.Clients
end

test("fuzz: random writes, array ops, Instance keys, joins and leaves", function()
	for seed = 1, FUZZ_SEEDS do
		fuzz(seed)
	end
end)

test("fuzz with an 8-id cap (inline fallback)", function()
	for seed = 1, math.max(1, FUZZ_SEEDS // 4) do
		fuzz(1000 + seed, CAP_PATCH)
	end
end)

if ONLY_SEED then
	-- Instance keys hash by address, so the same seed can take different paths
	-- from run to run: repeat it.
	for attempt = 1, 30 do
		fuzzLog = {}
		local ok, err = pcall(fuzz, ONLY_SEED, if OPTIONS.cap then CAP_PATCH else nil)
		if not ok then
			print("attempt " .. attempt .. " failed: " .. tostring(err))
			for index = math.max(1, #fuzzLog - 30), #fuzzLog do print("  " .. fuzzLog[index]) end
			process.exit(1)
		end
	end
	print("seed " .. ONLY_SEED .. " passed 30 attempts")
	process.exit(0)
end

print(string.format("\n%d passed, %d failed", results.passed, results.failed))
process.exit(if results.failed == 0 then 0 else 1)
