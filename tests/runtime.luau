--!nocheck
--[[
    Minimal Roblox stand-in for running DataStream's server and client code
    against each other under Lune.

    - Instances are userdata (newproxy) so type() and typeof() behave like Roblox.
    - One server world, one world per client; each world loads its own copy of
      the package (module-level state is per world, as on Roblox).
    - Runtime-created instances under the server's ReplicatedStorage replicate
      to every client world (remotes), with attributes.
    - Network: per-client ordered inbound channel. Remote events are delivered in
      order; events fired before a handler connects are queued, as on Roblox.
      InvokeServer replies travel the same ordered channel.
    - Remote arguments are deep-copied with Roblox's rules, but strictly: any
      table Roblox would silently mangle (mixed keys, non-string keys outside a
      dense array, holes, cycles) raises an error instead.
    - Byte counts are estimates from community measurements (call header ~9,
      number ~9, string ~len+2, table ~2+contents, buffer ~len+3); relative only.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local task = require("@lune/task")

local Runtime = {}

local SIGNAL_SOURCE = [[
local Signal = {}
Signal.__index = Signal
function Signal.new()
	return setmetatable({ _connections = {} }, Signal)
end
function Signal:Connect(fn)
	local connections = self._connections
	local connection = { Connected = true, _fn = fn }
	function connection:Disconnect()
		if not connection.Connected then return end
		connection.Connected = false
		local index = table.find(connections, connection)
		if index then table.remove(connections, index) end
	end
	table.insert(connections, connection)
	return connection
end
function Signal:Fire(...)
	for _, connection in table.clone(self._connections) do
		if connection.Connected then
			task.spawn(connection._fn, ...)
		end
	end
end
function Signal:Destroy()
	for _, connection in table.clone(self._connections) do
		connection:Disconnect()
	end
end
return Signal
]]

local CLEANER_SOURCE = [[
local Cleaner = {}
Cleaner.__index = Cleaner
function Cleaner.new()
	return setmetatable({ _items = {} }, Cleaner)
end
function Cleaner:Add(item)
	table.insert(self._items, item)
	return item
end
function Cleaner:Destroy()
	for _, item in self._items do
		if type(item) == "function" then
			item()
		elseif type(item) == "thread" then
			pcall(task.cancel, item)
		elseif type(item) == "table" and item.Disconnect then
			item:Disconnect()
		elseif type(item) == "table" and item.Destroy then
			item:Destroy()
		end
	end
	table.clear(self._items)
end
return Cleaner
]]

function Runtime.new(srcRoot : string, options : {[string] : any}?)
	options = options or {}
	local rt = {
		Errors = {},
		Warnings = {}, -- {World, Message}
		Clients = {},
		ServerInbound = {},
	}

	local InstanceState = {}
	local Replicas = {} -- [serverInstance][client] = client counterpart

	------------------------------------------------------------------ errors

	local function recordError(where, message)
		table.insert(rt.Errors, where .. ": " .. tostring(message))
	end

	local function guard(fn, where)
		if type(fn) ~= "function" then
			return fn
		end
		return function(...)
			local result = table.pack(xpcall(fn, debug.traceback, ...))
			if not result[1] then
				recordError(where or "thread", result[2])
				return
			end
			return table.unpack(result, 2, result.n)
		end
	end

	local WrappedTask = {
		spawn = function(fn, ...) return task.spawn(guard(fn), ...) end,
		defer = function(fn, ...) return task.defer(guard(fn), ...) end,
		delay = function(seconds, fn, ...) return task.delay(seconds, guard(fn), ...) end,
		wait = task.wait,
		cancel = task.cancel,
	}

	------------------------------------------------------------------ signals

	local Signal = {}
	Signal.__index = Signal
	function Signal.new(onFirstConnect)
		return setmetatable({ Connections = {}, OnFirstConnect = onFirstConnect }, Signal)
	end
	function Signal:Connect(fn)
		local connections = self.Connections
		local connection = { Connected = true, Fn = fn }
		function connection:Disconnect()
			connection.Connected = false
			local index = table.find(connections, connection)
			if index then table.remove(connections, index) end
		end
		table.insert(connections, connection)
		if #connections == 1 and self.OnFirstConnect then
			self.OnFirstConnect()
		end
		return connection
	end
	function Signal:Fire(...)
		for _, connection in table.clone(self.Connections) do
			if connection.Connected then
				WrappedTask.spawn(connection.Fn, ...)
			end
		end
	end

	------------------------------------------------------------------ instances

	local Methods = {}

	local function newInstance(className, name, world)
		local proxy = newproxy(true)
		local state = {
			ClassName = className,
			Name = name or className,
			Parent = nil,
			Children = {},
			Attributes = {},
			AttributeSignals = {},
			Props = {},
			World = world,
			ChildAdded = Signal.new(),
			ChildRemoved = Signal.new(),
		}
		InstanceState[proxy] = state

		local meta = getmetatable(proxy)
		meta.__index = function(self, key)
			local method = Methods[key]
			if method then return method end
			if key == "Name" then return state.Name end
			if key == "ClassName" then return state.ClassName end
			if key == "Parent" then return state.Parent end
			if key == "ChildAdded" then return state.ChildAdded end
			if key == "ChildRemoved" then return state.ChildRemoved end
			local prop = state.Props[key]
			if prop ~= nil then return prop end
			for _, child in state.Children do
				if InstanceState[child].Name == key then return child end
			end
			error(tostring(key) .. " is not a valid member of " .. state.ClassName .. " \"" .. state.Name .. "\"", 2)
		end
		meta.__newindex = function(self, key, value)
			if key == "Name" then
				state.Name = value
			elseif key == "Parent" then
				rt.SetParent(self, value)
			else
				state.Props[key] = value
			end
		end
		meta.__tostring = function()
			return state.Name
		end
		return proxy, state
	end
	rt.NewInstance = newInstance
	rt.InstanceState = InstanceState

	function rt.SetParent(instance, newParent)
		local state = InstanceState[instance]
		local old = state.Parent
		if old == newParent then return end
		if old then
			local oldState = InstanceState[old]
			local index = table.find(oldState.Children, instance)
			if index then table.remove(oldState.Children, index) end
			state.Parent = nil
			oldState.ChildRemoved:Fire(instance)
		end
		state.Parent = newParent
		if newParent then
			table.insert(InstanceState[newParent].Children, instance)
			InstanceState[newParent].ChildAdded:Fire(instance)
			rt.OnParented(instance)
		end
	end

	function Methods.FindFirstChild(self, name)
		for _, child in InstanceState[self].Children do
			if InstanceState[child].Name == name then return child end
		end
		return nil
	end
	function Methods.WaitForChild(self, name)
		local started = os.clock()
		while true do
			local child = Methods.FindFirstChild(self, name)
			if child then return child end
			if os.clock() - started > 5 then
				error("WaitForChild timed out: " .. tostring(name), 2)
			end
			task.wait()
		end
	end
	function Methods.GetChildren(self)
		return table.clone(InstanceState[self].Children)
	end
	function Methods.IsA(self, className)
		local own = InstanceState[self].ClassName
		return className == own or className == "Instance"
	end
	function Methods.GetAttribute(self, name)
		return InstanceState[self].Attributes[name]
	end
	function Methods.SetAttribute(self, name, value)
		local state = InstanceState[self]
		state.Attributes[name] = value
		local signal = state.AttributeSignals[name]
		if signal then signal:Fire() end
	end
	function Methods.GetAttributeChangedSignal(self, name)
		local state = InstanceState[self]
		local signal = state.AttributeSignals[name]
		if not signal then
			signal = Signal.new()
			state.AttributeSignals[name] = signal
		end
		return signal
	end
	function Methods.Destroy(self)
		rt.SetParent(self, nil)
	end

	local function fakeTypeof(value)
		if InstanceState[value] then return "Instance" end
		return typeof(value)
	end

	------------------------------------------------------------------ transfer

	local function describe(value, depth)
		depth = depth or 0
		if type(value) ~= "table" then return tostring(value) end
		if depth > 3 then return "{...}" end
		local parts = {}
		for key, child in pairs(value) do
			table.insert(parts, "[" .. tostring(key) .. "]=" .. describe(child, depth + 1))
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	rt.Describe = describe

	-- Deep copy with Roblox remote rules (strict). Returns copy, estimated bytes.
	local function transfer(value, seen)
		local valueType = type(value)
		if value == nil then return nil, 1 end
		if valueType == "boolean" then return value, 2 end
		if valueType == "number" then return value, 9 end
		if valueType == "string" then return value, 2 + #value end
		if valueType == "buffer" then
			local copy = buffer.create(buffer.len(value))
			buffer.copy(copy, 0, value, 0, buffer.len(value))
			return copy, 3 + buffer.len(value)
		end
		if valueType == "userdata" and InstanceState[value] then
			return value, 9
		end
		if valueType ~= "table" then
			error("cannot send a " .. valueType .. " over a remote")
		end

		seen = seen or {}
		if seen[value] then error("cyclic table sent over a remote") end
		seen[value] = true

		local length = rawlen(value)
		local count, isArray, allStrings = 0, true, true
		for key in pairs(value) do
			count += 1
			if type(key) ~= "string" then allStrings = false end
			if not (type(key) == "number" and key % 1 == 0 and key >= 1 and key <= length) then
				isArray = false
			end
		end
		if count ~= length then isArray = false end

		local copy, bytes = {}, 2
		if count == 0 then
			-- empty
		elseif isArray then
			for index = 1, length do
				local child, childBytes = transfer(value[index], seen)
				copy[index] = child
				bytes += childBytes
			end
		elseif allStrings then
			for key, child in pairs(value) do
				local childCopy, childBytes = transfer(child, seen)
				copy[key] = childCopy
				bytes += 2 + #key + childBytes
			end
		else
			local keys = {}
			for key in pairs(value) do table.insert(keys, tostring(key) .. ":" .. type(key)) end
			error("unsendable table (mixed/non-string keys or holes): {" .. table.concat(keys, ", ") .. "}")
		end
		seen[value] = nil
		return copy, bytes
	end

	local function transferArgs(packed)
		local copy, bytes = { n = packed.n }, 0
		for index = 1, packed.n do
			local ok, child, childBytes = pcall(transfer, packed[index])
			if not ok then
				error(tostring(child) .. "\n      in argument " .. index .. ": " .. describe(packed[index]), 0)
			end
			copy[index] = child
			bytes += childBytes
		end
		return copy, bytes
	end
	rt.Transfer = transfer

	------------------------------------------------------------------ worlds

	local function readSource(path)
		local source = fs.readFile(path)
		if options.Patch then
			source = options.Patch(path, source)
		end
		return source
	end

	-- Rojo-style: a directory with init.lua(u) is a ModuleScript, else a Folder.
	-- Read from disk once: Lune's fs calls yield, and a yield inside AddClient
	-- would let the server's deferred flush run before the client's GetData.
	local function readTemplate(path, name)
		local template = { Name = name, Children = {} }
		for _, candidate in { "init.luau", "init.lua" } do
			if fs.isFile(path .. "/" .. candidate) then
				template.Source = readSource(path .. "/" .. candidate)
				template.DebugName = path .. "/" .. candidate
			end
		end
		local entries = fs.readDir(path)
		table.sort(entries)
		for _, entry in entries do
			local full = path .. "/" .. entry
			if fs.isDir(full) then
				table.insert(template.Children, readTemplate(full, entry))
			elseif (entry:match("%.luau$") or entry:match("%.lua$")) and not entry:match("^init%.") then
				table.insert(template.Children, {
					Name = (entry:gsub("%.luau?$", "")),
					Source = readSource(full),
					DebugName = full,
					Children = {},
				})
			end
		end
		return template
	end
	local packageTemplate = readTemplate(srcRoot, "DataStream")

	local function buildTree(world, template)
		local node, state = newInstance(if template.Source then "ModuleScript" else "Folder", template.Name, world)
		state.Source = template.Source
		state.DebugName = template.DebugName
		for _, child in template.Children do
			rt.SetParent(buildTree(world, child), node)
		end
		return node
	end

	local function newWorld(isServer, label)
		local world = { IsServer = isServer, Label = label, ModuleCache = {} }

		local game = newInstance("DataModel", "game", world)
		local services = {}
		local function service(className, props)
			local instance, state = newInstance(className, className, world)
			for key, value in props or {} do state.Props[key] = value end
			rt.SetParent(instance, game)
			services[className] = instance
			return instance, state
		end

		service("RunService", {
			IsServer = function() return isServer end,
			IsClient = function() return not isServer end,
		})
		local replicatedStorage = service("ReplicatedStorage")
		world.ReplicatedStorage = replicatedStorage

		local players, playersState = service("Players", {
			PlayerAdded = Signal.new(),
			PlayerRemoving = Signal.new(),
		})
		local playersProps = playersState.Props
		playersProps.GetPlayers = function()
			local list = {}
			for _, child in InstanceState[players].Children do
				if InstanceState[child].ClassName == "Player" then table.insert(list, child) end
			end
			return list
		end
		playersProps.GetPlayerByUserId = function(_, userId)
			userId = tonumber(userId)
			for _, child in InstanceState[players].Children do
				if InstanceState[child].Props.UserId == userId then return child end
			end
			return nil
		end
		world.Players = players

		local tags, added, removed = {}, {}, {}
		local function tagSignal(map, tag)
			if not map[tag] then map[tag] = Signal.new() end
			return map[tag]
		end
		service("CollectionService", {
			AddTag = function(_, instance, tag)
				tags[tag] = tags[tag] or {}
				if not tags[tag][instance] then
					tags[tag][instance] = true
					tagSignal(added, tag):Fire(instance)
				end
			end,
			RemoveTag = function(_, instance, tag)
				if tags[tag] and tags[tag][instance] then
					tags[tag][instance] = nil
					tagSignal(removed, tag):Fire(instance)
				end
			end,
			HasTag = function(_, instance, tag)
				return tags[tag] ~= nil and tags[tag][instance] == true
			end,
			GetTagged = function(_, tag)
				local list = {}
				for instance in tags[tag] or {} do table.insert(list, instance) end
				return list
			end,
			GetInstanceAddedSignal = function(_, tag) return tagSignal(added, tag) end,
			GetInstanceRemovedSignal = function(_, tag) return tagSignal(removed, tag) end,
		})

		InstanceState[game].Props.GetService = function(_, name)
			return services[name] or error("no service " .. tostring(name))
		end
		world.Game = game

		-- Package layout: ReplicatedStorage.Packages.DataStream (+ nested Packages)
		local packages = newInstance("Folder", "Packages", world)
		rt.SetParent(packages, replicatedStorage)
		local dataStream = buildTree(world, packageTemplate)
		rt.SetParent(dataStream, packages)
		local nested = newInstance("Folder", "Packages", world)
		rt.SetParent(nested, dataStream)
		for name, source in { Signal = SIGNAL_SOURCE, Cleaner = CLEANER_SOURCE } do
			local module, state = newInstance("ModuleScript", name, world)
			state.Source = source
			state.DebugName = "stub:" .. name
			rt.SetParent(module, nested)
		end
		world.Package = dataStream

		function world.Warn(...)
			local parts = {}
			for index = 1, select("#", ...) do parts[index] = tostring((select(index, ...))) end
			table.insert(rt.Warnings, { World = label, Message = table.concat(parts, " ") })
		end

		function world.NewInstance(className)
			local instance, state = newInstance(className, className, world)
			state.RuntimeCreated = true
			if className == "RemoteEvent" then
				state.Props.FireClient = function(self, player, ...)
					rt.FireClient(self, player, table.pack(...))
				end
				state.Props.FireAllClients = function(self, ...)
					local packed = table.pack(...)
					for _, client in table.clone(rt.Clients) do
						rt.FireClient(self, client.Player, packed)
					end
				end
				state.Props.OnServerEvent = Signal.new()
			end
			return instance
		end

		function world.Require(module)
			local cached = world.ModuleCache[module]
			if cached ~= nil then return cached.Value end
			local state = InstanceState[module]
			assert(state and state.ClassName == "ModuleScript", "require expects a ModuleScript")
			local env = {
				script = module,
				game = game,
				require = world.Require,
				task = WrappedTask,
				typeof = fakeTypeof,
				warn = world.Warn,
				print = function(...) end,
				Instance = { new = world.NewInstance },
			}
			local chunk = luau.load(state.Source, { debugName = state.DebugName, environment = env })
			local value = chunk()
			world.ModuleCache[module] = { Value = value }
			return value
		end

		return world
	end

	------------------------------------------------------------------ replication

	local function replicateTo(serverInstance, client)
		local state = InstanceState[serverInstance]
		local parent = state.Parent
		local clientParent
		if parent == rt.Server.ReplicatedStorage then
			clientParent = client.World.ReplicatedStorage
		else
			clientParent = Replicas[parent] and Replicas[parent][client]
		end
		if not clientParent then return end

		Replicas[serverInstance] = Replicas[serverInstance] or {}
		if Replicas[serverInstance][client] then return end

		local counterpart, counterState = newInstance(state.ClassName, state.Name, client.World)
		for key, value in state.Attributes do counterState.Attributes[key] = value end
		if state.ClassName == "RemoteEvent" then
			local pending = {}
			local event
			local function flush()
				while #pending > 0 and #event.Connections > 0 do
					local args = table.remove(pending, 1)
					event:Fire(table.unpack(args, 1, args.n))
				end
			end
			event = Signal.new(function() WrappedTask.defer(flush) end)
			counterState.Props.OnClientEvent = event
			counterState.Deliver = function(args)
				table.insert(pending, args)
				flush()
			end
		elseif state.ClassName == "RemoteFunction" then
			counterState.Props.InvokeServer = function(_, ...)
				return rt.InvokeServer(client, serverInstance, table.pack(...))
			end
		end
		Replicas[serverInstance][client] = counterpart
		rt.SetParent(counterpart, clientParent)

		for _, child in state.Children do
			replicateTo(child, client)
		end
	end

	function rt.OnParented(instance)
		local state = InstanceState[instance]
		if not state.RuntimeCreated or not state.World.IsServer then return end
		-- only things under the server's ReplicatedStorage replicate
		local cursor = state.Parent
		while cursor and cursor ~= rt.Server.ReplicatedStorage do
			cursor = InstanceState[cursor].Parent
		end
		if not cursor then return end
		for _, client in rt.Clients do
			replicateTo(instance, client)
		end
	end

	------------------------------------------------------------------ network

	function rt.FireClient(serverRemote, player, packed)
		local client = nil
		for _, candidate in rt.Clients do
			if candidate.Player == player then client = candidate end
		end
		if not client then return end
		local args, bytes = transferArgs(packed)
		client.Stats.EventCalls += 1
		client.Stats.EventBytes += 9 + bytes
		table.insert(client.Inbound, { Kind = "event", Remote = serverRemote, Args = args })
	end

	function rt.InvokeServer(client, serverRemote, packed)
		local thread = coroutine.running()
		local args = transferArgs(packed)
		table.insert(rt.ServerInbound, { Client = client, Remote = serverRemote, Args = args, Thread = thread })
		return coroutine.yield()
	end

	function rt.ProcessServerInbound()
		local inbound = rt.ServerInbound
		rt.ServerInbound = {}
		for _, request in inbound do
			if request.Client.Gone then continue end
			local handler = InstanceState[request.Remote].Props.OnServerInvoke
			local results = table.pack(xpcall(handler, debug.traceback, request.Client.Player,
				table.unpack(request.Args, 1, request.Args.n)))
			if not results[1] then
				recordError("OnServerInvoke", results[2])
				results = { true, n = 1 }
			end
			local values, bytes = transferArgs(table.pack(table.unpack(results, 2, results.n)))
			request.Client.Stats.InvokeBytes += 9 + bytes
			table.insert(request.Client.Inbound, {
				Kind = "result", Thread = request.Thread, Values = values, Request = request.Args,
			})
		end
	end

	function rt.Deliver()
		for _, client in table.clone(rt.Clients) do
			local inbound = client.Inbound
			client.Inbound = {}
			for _, message in inbound do
				if client.Tap then client.Tap(message) end
				if message.Kind == "event" then
					local counterpart = Replicas[message.Remote][client]
					InstanceState[counterpart].Deliver(message.Args)
				else
					task.spawn(message.Thread, table.unpack(message.Values, 1, message.Values.n))
				end
			end
		end
	end

	-- One network round. invokesFirst: serve pending InvokeServer calls before
	-- the server's deferred flush runs (a snapshot taken between a write and
	-- its flush).
	function rt.Frame(invokesFirst)
		if invokesFirst then rt.ProcessServerInbound() end
		task.wait()
		rt.ProcessServerInbound()
		task.wait()
		rt.Deliver()
		task.wait()
	end

	function rt.Settle(rounds)
		for _ = 1, rounds or 4 do rt.Frame(false) end
	end

	------------------------------------------------------------------ setup

	rt.Server = newWorld(true, "server")
	rt.DataStream = rt.Server.Require(rt.Server.Package).Server

	local nextPlayerId = 1000
	function rt.AddClient(userId)
		if not userId then
			nextPlayerId += 1
			userId = nextPlayerId
		end
		local player, playerState = newInstance("Player", "Player" .. userId, rt.Server)
		playerState.Props.UserId = userId

		local client = {
			Player = player,
			UserId = userId,
			Inbound = {},
			Stats = { EventCalls = 0, EventBytes = 0, InvokeBytes = 0 },
		}
		client.World = newWorld(false, "client" .. userId)
		table.insert(rt.Clients, client)

		-- replicate existing runtime instances (remote folder and remotes)
		local function walk(instance)
			for _, child in InstanceState[instance].Children do
				if InstanceState[child].RuntimeCreated then
					replicateTo(child, client)
				end
				walk(child)
			end
		end
		walk(rt.Server.ReplicatedStorage)

		rt.SetParent(player, rt.Server.Players)
		InstanceState[rt.Server.Players].Props.PlayerAdded:Fire(player)

		WrappedTask.spawn(function()
			client.DataStream = client.World.Require(client.World.Package).Client
			client.Ready = true
		end)
		return client
	end

	function rt.RemoveClient(client)
		local index = table.find(rt.Clients, client)
		if index then table.remove(rt.Clients, index) end
		client.Gone = true
		InstanceState[rt.Server.Players].Props.PlayerRemoving:Fire(client.Player)
		rt.SetParent(client.Player, nil)
	end

	-- Shared "replicated" instance (same object in every world), for Instance
	-- keys and values in data.
	function rt.NewPart(name)
		return (newInstance("Part", name, rt.Server))
	end

	return rt
end

------------------------------------------------------------------ helpers

function Runtime.DeepEqual(a, b, path)
	path = path or "root"
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false, path .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")"
	end
	for key, value in pairs(a) do
		local ok, where = Runtime.DeepEqual(value, b[key], path .. "." .. tostring(key))
		if not ok then return false, where end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false, path .. "." .. tostring(key) .. " (only on client)"
		end
	end
	return true
end

return Runtime
