--[[
	ClientDataStream.lua
	Stratiz
	Created on 09/06/2022 @ 22:58

	Description:
		Client side of DataStream

	Documentation:
		To read the auto-replicated player data, index the module with the name of the table.
		For example, DataStream by default has .Temp and .Stored schemas.
		To read the Temp table, use ClientDataStream.Temp, same thing with .Stored and any other tables you add.

		Data tables are frozen: reading is zero-copy, and any attempt to modify data
		errors instead of silently desyncing from the server. table.clone what you :Read()
		if you need a mutable copy.

--]]

--= Root =--
local ClientDataStream = { }

--= Dependencies =--

local ClientMeta = require(script:WaitForChild("ClientDataStreamMeta"))
local DataStreamRemotes = require(script.Parent.Shared:WaitForChild("DataStreamRemotes"))
local DataStreamUtils = require(script.Parent.Shared:WaitForChild("DataStreamUtils"))
local DataStreamInstanceRefs = require(script.Parent.Shared:WaitForChild("DataStreamInstanceRefs"))

--= Object References =--

local GetDataFunction = DataStreamRemotes:Get("Function", "GetData")

--= Constants =--

local PENDING_REF_WARN_SECONDS = 30
local SCHEMA_WAIT_WARN_SECONDS = 5
local UNRESOLVED = {} -- Sentinel for placeholder keys whose instance hasn't replicated yet

--= Variables =--

local RawWarn = warn
local RealData = {}
local DidFetch = false
local UpdateCache = {}
local PendingRefs = {} -- [schemaName][entryKey] = pending instance ref entry

--= Internal Functions =--

local function warn(...)
	RawWarn("[ClientDataStream]", ...)
end

local function UpdateRoot(rootName : string, data : any)
	if type(data) ~= "table" then
		warn("Something tried to set data to a non-table for", rootName, data)
		return
	end

	table.clear(RealData[rootName])
	for i, v in data do
		RealData[rootName][i] = v
	end
end

--// Deferred instance resolution ---------------------------------------------
-- Entries stay registered after they first resolve so instances that stream out
-- and back in (arriving as new client-side objects with the same ref id) get
-- re-patched into the data.

local function RemovePendingEntry(entry)
	local nameCache = PendingRefs[entry.Name]
	if nameCache and nameCache[entry.Key] == entry then
		nameCache[entry.Key] = nil
	end
	if entry.Cancel then
		entry.Cancel()
	end
end

-- Moves the value under a stale instance key (a previous incarnation of the same
-- ref id) onto the freshly resolved key. Returns the moved value.
local function MoveInstanceKey(root, parentPath, staleKey, newKey)
	if #parentPath == 0 then
		root[newKey] = root[staleKey]
		root[staleKey] = nil
		return root[newKey]
	end

	local parent = DataStreamUtils.GetValueAtPath(root, parentPath)
	if type(parent) ~= "table" then
		return nil
	end

	local newParent = table.clone(parent)
	newParent[newKey] = newParent[staleKey]
	newParent[staleKey] = nil
	table.freeze(newParent)
	DataStreamUtils.SetValueAtPath(root, parentPath, newParent)
	return newParent[newKey]
end

local function ApplyResolvedInstance(entry, instance : Instance)
	local root = RealData[entry.Name]
	if not root then
		return
	end

	local slotPath, newValue, oldValue

	if entry.IsKey then
		-- entry.Path is the path of the PARENT table; the resolved instance is the key.
		local parent = if #entry.Path == 0 then root else DataStreamUtils.GetValueAtPath(root, entry.Path)
		if type(parent) ~= "table" then
			-- The parent subtree was replaced by newer data; this ref is obsolete.
			RemovePendingEntry(entry)
			return
		end

		if parent[instance] ~= nil then
			entry.Applied = true
			return
		end

		local staleKey = nil
		for key in pairs(parent) do
			if typeof(key) == "Instance" and key ~= instance
				and key:GetAttribute(DataStreamInstanceRefs.ID_ATTRIBUTE) == entry.Id then
				staleKey = key
				break
			end
		end

		slotPath = table.clone(entry.Path)
		table.insert(slotPath, instance)

		if staleKey ~= nil then
			newValue = MoveInstanceKey(root, entry.Path, staleKey, instance)
			oldValue = nil
		elseif not entry.Applied and entry.Value ~= nil then
			DataStreamUtils.SetValueAtPath(root, slotPath, entry.Value)
			newValue = entry.Value
			oldValue = nil
		else
			return
		end
	else
		-- entry.Path is the path of the value slot itself.
		local currentValue = DataStreamUtils.GetValueAtPath(root, entry.Path)
		if currentValue == instance then
			entry.Applied = true
			return
		end

		local isStaleInstance = typeof(currentValue) == "Instance"
			and currentValue:GetAttribute(DataStreamInstanceRefs.ID_ATTRIBUTE) == entry.Id
		if currentValue ~= nil and not isStaleInstance then
			-- The slot was overwritten by newer data; this ref is obsolete.
			RemovePendingEntry(entry)
			return
		end

		local didSet = DataStreamUtils.SetValueAtPath(root, entry.Path, instance)
		if not didSet then
			RemovePendingEntry(entry)
			return
		end

		slotPath = entry.Path
		newValue = instance
		oldValue = currentValue
	end

	entry.Applied = true
	ClientMeta:PathChanged(entry.Name, slotPath, newValue, oldValue, RealData[entry.Name])
end

local function RegisterPendingInstance(name : string, id : string, path : {any}, isKey : boolean, parkedValue : any)
	local entryKey = (if isKey then "K|" else "V|") .. id .. "|" .. DataStreamUtils.StringifyPathTable(path)

	local nameCache = PendingRefs[name]
	if not nameCache then
		nameCache = {}
		PendingRefs[name] = nameCache
	end

	local existingEntry = nameCache[entryKey]
	if existingEntry then
		if isKey then
			existingEntry.Value = parkedValue
		end
		return
	end

	local entry = {
		Name = name,
		Id = id,
		Key = entryKey,
		Path = path,
		IsKey = isKey,
		Value = parkedValue,
		Applied = false,
	}
	nameCache[entryKey] = entry

	entry.Cancel = DataStreamInstanceRefs:OnResolved(id, function(instance)
		ApplyResolvedInstance(entry, instance)
	end)

	task.delay(PENDING_REF_WARN_SECONDS, function()
		if nameCache[entryKey] == entry and not entry.Applied then
			warn("Instance reference still unresolved after " .. PENDING_REF_WARN_SECONDS .. "s |",
				name, "|", DataStreamUtils.StringifyPathTable(path), "| id:", id)
		end
	end)
end

--// Transport repairs --------------------------------------------------------
-- The server rewrites non-string keys into unique string placeholders and strips
-- Instance values, shipping a repair list alongside the payload (see
-- DataStreamMeta:PrepareValueForTransport). This applies those repairs to the
-- fresh, still-mutable payload and parks anything whose instance hasn't
-- replicated yet. Returns the repaired value (the value itself can be replaced
-- when it is a bare instance slot).
local function ApplyTransportRepairs(name : string, basePath : {any}, value : any, repairs)
	if not repairs or #repairs == 0 then
		return value
	end

	local keyMap = {} -- placeholder -> real key (or UNRESOLVED)
	local toClear = {}
	local parkedKeys = {}

	local function mapFragment(fragment)
		local mapped = keyMap[fragment]
		if mapped ~= nil then
			return mapped
		end
		return fragment
	end

	-- Builds the absolute RealData path for a repair, translating placeholder
	-- fragments to their real keys. Returns nil when the repair sits under a key
	-- whose instance is itself unresolved — the slot then lives inside that
	-- parked subtree instead of being registered independently.
	local function makeAbsolutePath(repairPath, dropLast) : {any}?
		local absolutePath = table.clone(basePath)
		local fragmentCount = #repairPath - (if dropLast then 1 else 0)
		for index = 1, fragmentCount do
			local realFragment = mapFragment(repairPath[index])
			if realFragment == UNRESOLVED then
				return nil
			end
			table.insert(absolutePath, realFragment)
		end
		return absolutePath
	end

	for _, repair in ipairs(repairs) do
		local pathKeys = repair.Path

		if #pathKeys == 0 then
			-- The transported value itself is an instance slot.
			if repair.Kind == "InstanceValue" then
				if repair.Instance then
					value = repair.Instance
				else
					value = nil
					if #basePath > 0 then
						RegisterPendingInstance(name, repair.Id, table.clone(basePath), false, nil)
					else
						warn("Cannot defer an unreplicated instance at a stream root")
					end
				end
			end
			continue
		end

		local current = value
		for index = 1, #pathKeys - 1 do
			current = if type(current) == "table" then current[pathKeys[index]] else nil
		end
		local lastKey = pathKeys[#pathKeys]

		if type(current) ~= "table" then
			warn("Invalid repair path | " .. DataStreamUtils.StringifyPathTable(pathKeys))
		elseif repair.Kind == "Index" then
			current[repair.IndexValue] = current[lastKey]
			keyMap[lastKey] = repair.IndexValue
			table.insert(toClear, {current, lastKey})
		elseif repair.Kind == "InstanceKey" then
			if repair.Instance then
				current[repair.Instance] = current[lastKey]
				keyMap[lastKey] = repair.Instance
				table.insert(toClear, {current, lastKey})
			else
				keyMap[lastKey] = UNRESOLVED
				table.insert(parkedKeys, {Parent = current, Placeholder = lastKey, Repair = repair})
			end
		elseif repair.Kind == "InstanceValue" then
			if repair.Instance then
				-- The slot key may itself be a placeholder that an earlier repair
				-- already moved; write to the real key so the value isn't lost
				-- when placeholders are cleared.
				local realKey = mapFragment(lastKey)
				current[if realKey == UNRESOLVED then lastKey else realKey] = repair.Instance
			else
				local absolutePath = makeAbsolutePath(pathKeys, false)
				if absolutePath then
					RegisterPendingInstance(name, repair.Id, absolutePath, false, nil)
				end
			end
		end
	end

	-- Placeholder aliases are only cleared after every repair has run, because
	-- nested repair paths traverse the transport table as-shipped.
	for _, clear in ipairs(toClear) do
		local parent, key = clear[1], clear[2]
		if parent[key] ~= nil then
			parent[key] = nil
		end
	end

	-- Extract parked instance-keyed entries, deepest first so an inner
	-- placeholder is removed before the outer parked subtree is frozen.
	for index = #parkedKeys, 1, -1 do
		local parked = parkedKeys[index]
		local parkedValue = parked.Parent[parked.Placeholder]
		parked.Parent[parked.Placeholder] = nil

		local parentAbsolutePath = makeAbsolutePath(parked.Repair.Path, true)
		if parentAbsolutePath then
			RegisterPendingInstance(name, parked.Repair.Id, parentAbsolutePath, true, DataStreamUtils.DeepFreeze(parkedValue))
		else
			warn("Dropping instance-keyed entry nested under another unresolved instance key |",
				DataStreamUtils.StringifyPathTable(parked.Repair.Path))
		end
	end

	return value
end

--// Update handling ----------------------------------------------------------

-- Path fragments can be encoded instance refs (see EncodePathForTransport on the
-- server). Returns nil when a fragment's instance can't be resolved — the caller
-- falls back to a full re-sync.
local function DecodePath(pathTable) : {any}?
	local decoded = table.clone(pathTable or {})
	for index, fragment in decoded do
		if type(fragment) == "table" and fragment.__dsRefId then
			local instance = fragment.Instance or DataStreamInstanceRefs:Resolve(fragment.__dsRefId)
			if not instance then
				return nil
			end
			decoded[index] = instance
		end
	end
	return decoded
end

local function Resync(name : string)
	warn("Data may be out of sync, re-syncing with server...")

	if not RealData[name] then
		RealData[name] = {}
	end
	local oldRoot = table.freeze(table.clone(RealData[name]))

	local schemaInfo = GetDataFunction:InvokeServer(name)
	if schemaInfo then
		local data = ApplyTransportRepairs(name, {}, schemaInfo.Data, schemaInfo.Repairs)
		UpdateRoot(name, if type(data) == "table" then DataStreamUtils.FreezeChildren(data) else data)
	else
		UpdateRoot(name, {})
	end

	ClientMeta:PathChanged(name, {}, RealData[name], oldRoot, RealData[name])
end

local function UpdateData(name : string, path : {any}, value : any, repairs)
	local decodedPath = DecodePath(path)
	if not decodedPath then
		Resync(name)
		return
	end

	value = ApplyTransportRepairs(name, decodedPath, value, repairs)
	value = DataStreamUtils.DeepFreeze(value)

	if not RealData[name] then
		RealData[name] = {}
	end

	local oldValue = nil
	if #decodedPath == 0 then
		oldValue = table.freeze(table.clone(RealData[name]))
		UpdateRoot(name, value)
	else
		local didSet
		didSet, oldValue = DataStreamUtils.SetValueAtPath(RealData[name], decodedPath, value)
		if not didSet then
			warn("Path error | " .. DataStreamUtils.StringifyPathTable(decodedPath))
			Resync(name)
			return
		end
	end

	ClientMeta:PathChanged(name, decodedPath, value, oldValue, RealData[name])
end

--= Initializers =--
do
	--// Listen for updates
	DataStreamRemotes:OnDataUpdateEventAdded(function(name : string, event : RemoteEvent)
		event.OnClientEvent:Connect(function(...)
			if not DidFetch then
				table.insert(UpdateCache, {Name = name, Args = table.pack(...)})
			else
				UpdateData(name, ...)
			end
		end)
	end)

	--// Fetch stores from server
	for name, schemaInfo in pairs(GetDataFunction:InvokeServer()) do
		local data = ApplyTransportRepairs(name, {}, schemaInfo.Data, schemaInfo.Repairs)
		if type(data) == "table" then
			RealData[name] = DataStreamUtils.FreezeChildren(data)
		else
			warn("Received a non-table root for", name, data)
			RealData[name] = {}
		end
	end
	DidFetch = true

	--// Update data from cache after fetch
	for _, update in ipairs(UpdateCache) do
		UpdateData(update.Name, table.unpack(update.Args, 1, update.Args.n))
	end
	UpdateCache = {}
end

--= Return Module =--
return setmetatable(ClientDataStream, {
	__index = function(_, index)
		-- Schemas registered on the server after this client's initial fetch arrive
		-- as a root update pushed at registration time, so an unknown schema yields
		-- until its data lands instead of returning nil.
		local startTime = os.clock()
		local warned = false
		while RealData[index] == nil do
			task.wait()

			if not warned and os.clock() - startTime >= SCHEMA_WAIT_WARN_SECONDS then
				warned = true
				warn("Infinite yield possible waiting for schema '" .. tostring(index)
					.. "'. Is it registered on the server, and does this player have it?")
			end
		end

		return ClientMeta:MakeDataStreamObject(index, RealData[index])
	end,
})
