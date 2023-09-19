--[[
	ReplicatedTables.lua
	Stratiz
	Created on 09/06/2022 @ 22:58
	
	Description:
		Client side of DataStream
	
	Documentation:
		To read the auto-replicated player data, index the module with the name of the table.
		For example, DataStream by default has .Temp and .Stored schemas.
		To read the Temp table, use ReplicatedTables.Temp, same thing with .Stored and any other tables you add.

		Any modifications to the data will not be replicated to the server, and will be overwritten by the server's data.

--]]

--= Root =--
local ReplicatedTables = { }

--= Dependencies =--

local ClientMeta = require(script:WaitForChild("ClientReplicatedTablesMeta"))
local CONFIG = require(script.ReplicatorClientConfig)
local ReplicatorRemotes = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("ReplicatorRemotes"))

--= Object References =--

local GetDataFunction = ReplicatorRemotes:Get("Function", "GetData")
local DataUpdateEvent = ReplicatorRemotes:Get("Event", "DataUpdate")

--= Constants =--

--= Variables =--
local RawWarn = warn
local RawPrint = print
local RealData = {}

--= Internal Functions =--

local function warn(...)
	RawWarn("[ReplicatedTables]", ...)
end

local function UpdateRoot(rootName : string, data : any)
	table.clear(RealData[rootName])
	for i, v in data do
		RealData[rootName][i] = v
	end
end

--= Initializers =--
do
	--// Fetch stores from server
	for name, data in pairs(GetDataFunction:InvokeServer()) do
		RealData[name] = data
	end
	
	--// Listen for updates
	DataUpdateEvent.OnClientEvent:Connect(function(name : string, path : {string}, value : any?)
		if not RealData[name] then
			RealData[name] = {}
		end

		local oldValue = nil
		local Current = RealData[name]
		local PathKeys = path or {}
		for Index,NextKey in pairs(PathKeys) do
			if type(Current) == "table" then
				NextKey = tonumber(NextKey) or NextKey
				if Index >= #PathKeys then
					oldValue = Current[NextKey]
					Current[NextKey] = value
				elseif Current[NextKey] then
					Current = Current[NextKey]
				else
					warn("Path error | " .. table.concat(path, "."))
					warn("Data may be out of sync, re-syncing with server...")
					UpdateRoot(name, GetDataFunction:InvokeServer(name))
				end
			else
				warn("Invalid path | " .. table.concat(path, "."))
			end
		end
		if #PathKeys == 0 then
			UpdateRoot(name, value)
		end
		ClientMeta:PathChanged(name, path, value, oldValue, RealData[name])
	end)
end

--= Return Module =--
return setmetatable(ReplicatedTables, {
	__index = function(self, index)
		if RealData[index] then
			return ClientMeta:MakeTableReplicatorObject(index, RealData[index])
		else
			return nil
		end
	end,
})