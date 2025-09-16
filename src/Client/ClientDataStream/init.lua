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

		Any modifications to the data will not be replicated to the server, and will be overwritten by the server's data.

--]]

--= Root =--
local ClientDataStream = { }

--= Dependencies =--

local ClientMeta = require(script:WaitForChild("ClientDataStreamMeta"))
local CONFIG = require(script.ClientDataStreamConfig)
local DataStreamRemotes = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("DataStreamRemotes"))
local DataStreamUtils = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("DataStreamUtils"))

--= Object References =--

local GetDataFunction = DataStreamRemotes:Get("Function", "GetData")

--= Constants =--

--= Variables =--

local RawWarn = warn
local RawPrint = print
local RealData = {}
local DidFetch = false
local UpdateCache = {}

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

local function FixValueIndexes(value : any, nonStringIndexesInValue : {{ Path : {string}, IndexValue : any }})
	if type(value) ~= "table" then
		return
	end

	local toClear = {}
	for _, nonStringIndex in nonStringIndexesInValue do
		local pathKeys = nonStringIndex.Path
		local current = value
		for index, nextKey in pairs(pathKeys) do
			if type(current) == "table" then
				if index >= #pathKeys then
					if nonStringIndex.IndexValue == nil then
						warn("Fix path is nil | " .. DataStreamUtils.StringifyPathTable(pathKeys))
						continue
					end
					current[nonStringIndex.IndexValue] = current[nextKey]
					table.insert(toClear, {current, nextKey})
				elseif current[nextKey] then
					current = current[nextKey]
				else
					warn("Fix Path error | " .. DataStreamUtils.StringifyPathTable(pathKeys))
				end
			else
				warn("Invalid Fix path | " .. DataStreamUtils.StringifyPathTable(pathKeys))
			end
		end
	end

	for _, clear in pairs(toClear) do
		local current, nextKey = clear[1], clear[2]
		if current[nextKey] then
			current[nextKey] = nil
		else
			warn("Tried to clear a non-existing key |", nextKey)
		end
	end
end

local function UpdateData(name : string, path : {string}, value : any, nonStringIndexesInValue : {{ Path : {string}, IndexValue : any }})
	FixValueIndexes(value, nonStringIndexesInValue)

	if not RealData[name] then
		RealData[name] = {}
	end

	local oldValue = nil
	local Current = RealData[name]
	local PathKeys = path or {}
	for Index,NextKey in pairs(PathKeys) do
		if type(Current) == "table" then
			if Index >= #PathKeys then
				oldValue = DataStreamUtils:DeepCopyTable(Current[NextKey])
				Current[NextKey] = value
			elseif Current[NextKey] then
				Current = Current[NextKey]
			else
				warn("Path error | " .. DataStreamUtils.StringifyPathTable(path))
				warn("Data may be out of sync, re-syncing with server...")
				local schemaInfo = GetDataFunction:InvokeServer(name)

				if schemaInfo then
					FixValueIndexes(schemaInfo.Data, schemaInfo.NonStringIndexes)
					UpdateRoot(name, schemaInfo.Data)
				else
					UpdateRoot(name, {})
				end
			end
		else
			warn("Invalid path | " .. DataStreamUtils.StringifyPathTable(path))
		end
	end
	if #PathKeys == 0 then
		UpdateRoot(name, value)
		oldValue = DataStreamUtils:DeepCopyTable(RealData[name])
	end

	ClientMeta:PathChanged(name, path, value, oldValue, RealData[name])
end

--= Initializers =--
do
	--// Listen for updates
	DataStreamRemotes:OnDataUpdateEventAdded(function(name : string, event : RemoteEvent)
		event.OnClientEvent:Connect(function(...)
			if not DidFetch then
				table.insert(UpdateCache, {name, ...})
			else
				UpdateData(name, ...)
			end
		end)
	end)

	--// Fetch stores from server
	for name, schemaInfo in pairs(GetDataFunction:InvokeServer()) do
		FixValueIndexes(schemaInfo.Data, schemaInfo.NonStringIndexes)
		RealData[name] = schemaInfo.Data
	end
	DidFetch = true

	--// Update data from cache after fetch
	for _, update in ipairs(UpdateCache) do
		UpdateData(unpack(update))
	end
	UpdateCache = {}
end

--= Return Module =--
return setmetatable(ClientDataStream, {
	__index = function(_, index)
		if RealData[index] then
			return ClientMeta:MakeDataStreamObject(index, RealData[index])
		else
			return nil
		end
	end,
})