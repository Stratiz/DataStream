--[[
	ReplicatedTables.lua
	Stratiz
	Created on 09/06/2022 @ 22:58
	
	Description:
		Client side of DataStream
	
	Documentation:
		To read the auto-replicated player data, index the module with the name of the table.
		For example, DataStream by default has .Temp and .Stored tables.
		To read the Temp table, use ReplicatedTables.Temp, same thing with .Stored and any other tables you add.

		Any modifications to the data will not be replicated to the server, and will be overwritten by the server's data.

		:GetChangedSignal(Path: string)
			Returns a signal object that fires when the data at the path changes.
			For example, if you want to know when the data at ReplicatedTables.Temp changes, you would use ReplicatedTables:GetChangedSignal("Temp"):Connect(handlerFunction)


--]]

--= Root =--
local ReplicatedTables = { }

--= Roblox Services =--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--= Dependencies =--
local ReplicatedTablesUtils = require(script:WaitForChild("ReplicatedTablesUtils"))
local ClientMeta = require(script:WaitForChild("ClientReplicatedTablesMeta"))

--= Object References =--
local RemotesFolder = ReplicatedStorage:WaitForChild("_TABLE_REPLICATION_REMOTES")
local DataUpdateEvent = RemotesFolder:WaitForChild("DataUpdateEvent")
local GetData = RemotesFolder:WaitForChild("GetData")

--= Constants =--

--= Variables =--
local RawWarn = warn
local RawPrint = print
local RealData = {}

--= Internal Functions =--
local function warn(...)
	RawWarn("[ReplicatedTables]", ...)
end

local function print(...)
	RawPrint("[ReplicatedTables]", ...)
end

local function UpdateRoot(rootName : string, data : any)
	table.clear(RealData[rootName])
	for i, v in data do
		RealData[rootName][i] = v
	end
end

--= API Functions =--

--= Initializers =--
do
	--// Fetch stores from server
	for name, data in pairs(GetData:InvokeServer()) do
		RealData[name] = data
	end
	
	--// Listen for updates
	DataUpdateEvent.OnClientEvent:Connect(function(name : string, path : {string}, value : any?)
		if not RealData[name] then
			RealData[name] = {}
		end
		--print("DATA REPLICATED", Path)
		--print("Data updated: "..(Path or "ALL"))
		local Current = RealData[name]
		local PathKeys = path or {}
		for Index,NextKey in pairs(PathKeys) do
			if type(Current) == "table" then
				NextKey = tonumber(NextKey) or NextKey
				if Index >= #PathKeys then
					Current[NextKey] = value
				elseif Current[NextKey] then
					Current = Current[NextKey]
				else
					warn("Path error | "..path)
					warn("Data may be out of sync, re-syncing with server...")
					UpdateRoot(name, GetData:InvokeServer(name))
				end
			else
				warn("Invalid path | "..path)
			end
		end
		if #PathKeys == 0 then
			UpdateRoot(name, value)
		end
		ClientMeta:PathChanged(name, path, value)
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