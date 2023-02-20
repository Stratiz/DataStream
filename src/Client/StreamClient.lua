--[[
	DataStreamClient.lua
	Stratiz
	Created on 09/06/2022 @ 22:58
	
	Description:
		Client side of DataStream
	
	Documentation:
		To read the auto-replicated player data, index the module with the name of the table.
		For example, DataStream by default has .Temp and .Stored tables.
		To read the Temp table, use DataStreamClient.Temp, same thing with .Stored and any other tables you add.

		Any modifications to the data will not be replicated to the server, and will be overwritten by the server's data.

		:GetChangedSignal(Path: string)
			Returns a signal object that fires when the data at the path changes.
			For example, if you want to know when the data at DataStreamClient.Temp changes, you would use DataStreamClient:GetChangedSignal("Temp"):Connect(handlerFunction)


--]]

--= Root =--
local DataStreamClient = { }

--= Roblox Services =--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--= Dependencies =--

--= Object References =--
local RemotesFolder = ReplicatedStorage:WaitForChild("_STREAM_REMOTES")
local DataUpdateEvent = RemotesFolder:WaitForChild("DataUpdateEvent")
local GetData = RemotesFolder:WaitForChild("GetData")

--= Constants =--

--= Variables =--
local Binds = {}
local RawWarn = warn
local RawPrint = print

--= Internal Functions =--
local function warn(...)
	RawWarn("[StreamClient]", ...)
end

local function print(...)
	RawPrint("[StreamClient]", ...)
end

local function MakeSignal()
	local bindableEvent = Instance.new("BindableEvent")
	local newSignal = {}
	function newSignal:Connect(toExecute : (any) -> ()) : RBXScriptConnection
		return bindableEvent.Event:Connect(toExecute)
	end

	function newSignal:Once(toExecute : (any) -> ()) : RBXScriptConnection
		return bindableEvent.Event:Once(toExecute)
	end

	function newSignal:Fire(... : any)
		bindableEvent:Fire(...)
	end

	function newSignal:Wait() : any
		return bindableEvent.Event:Wait()
	end

	return newSignal
end

--= API Functions =--
function DataStreamClient:GetChangedSignal(path: string)
	if not Binds[path] then
		local newSignal = MakeSignal()
		Binds[path] = {
			Signal = newSignal
		}
		return newSignal
	else
		return Binds[path].Signal
	end
end

--= Initializers =--
do
	--// Fetch stores from server
	for name, data in pairs(GetData:InvokeServer()) do
		DataStreamClient[name] = data
	end
	
	--// Listen for updates
	DataUpdateEvent.OnClientEvent:Connect(function(name : string, path : string, value : any?)
		if not DataStreamClient[name] then
			DataStreamClient[name] = {}
		end
		--print("DATA REPLICATED", Path)
		--print("Data updated: "..(Path or "ALL"))
		local Current = DataStreamClient[name]
		local OldValue
		local PathKeys = path and path:split(".") or {}
		if #PathKeys == 0 then
			Current = value
		end
		for Index,NextKey in pairs(PathKeys) do
			if type(Current) == "table" then
				NextKey = tonumber(NextKey) or NextKey
				if Index >= #PathKeys then
					OldValue = Current[NextKey]
					Current[NextKey] = value
				elseif Current[NextKey] then
					Current = Current[NextKey]
				else
					warn("Path error | "..path)
					warn("Data may be out of sync, re-syncing with server...")
					DataStreamClient[name] = GetData:InvokeServer(name)
				end
			else
				warn("Invalid path | "..path)
			end
		end
		if #PathKeys == 0 then
			DataStreamClient[name] = value
		end
		---
		--print(self.Data)
		-- Changed event
		local PathForBinds = name.."."..path
		for BindPath,Bind in pairs(Binds) do
			local StringStart, _ = string.find(PathForBinds or "",BindPath)
			if BindPath == PathForBinds or StringStart == 1 then
				Bind.ToFire:Fire(value, OldValue, PathForBinds)
			end
		end
	end)
end

--= Return Module =--
return DataStreamClient