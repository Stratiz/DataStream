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
local RemotesFolder = ReplicatedStorage:WaitForChild("_DATASTREAM_REMOTES")
local DataUpdateEvent = RemotesFolder:WaitForChild("DataUpdateEvent")
local InitDataGet = RemotesFolder:WaitForChild("DataGetFunction")

--= Constants =--

--= Variables =--
local Binds = {}
local RawWarn = warn
local RawPrint = print
local Initialized = false

--= Internal Functions =--
local function warn(...)
	RawWarn("[DataStreamClient]", ...)
end

local function print(...)
	RawPrint("[DataStreamClient]", ...)
end

local function MakeSignal() : {[any] : any}
	local NewSignal = {}

	NewSignal._Connections = {}
	NewSignal._Bindable = Instance.new("BindableEvent")
	
	function NewSignal:Fire(... : any) : nil
		self._Bindable:Fire(...)
	end

	function NewSignal:Connect(handler : (any) -> (any)) : RBXScriptConnection
		local NewConnection = self._Bindable.Event:Connect(handler)
		table.insert(self._Connections, NewConnection)
		return NewConnection
	end

	function NewSignal:Disconnect() : nil
		for _,Connection in self._Connections do
			Connection:Disconnect()
		end
		self._Bindable:Destroy()
	end

	return NewSignal
end

--= API Functions =--
function DataStreamClient:GetChangedSignal(Path: string)
	if not Binds[Path] then
		local NewSignal = MakeSignal()
		NewSignal._Disconnect = NewSignal.Disconnect
		function NewSignal:Disconnect()
			Binds[Path].InUseBy -= 1
			if Binds[Path].InUseBy <= 0 then
				Binds[Path] = nil
				self:_Disconnect()
			end
		end
		Binds[Path] = {
			ToFire = NewSignal,
			InUseBy = 1
		}
		return NewSignal
	else
		Binds[Path].InUseBy += 1
		return Binds[Path].ToFire
	end
end

--= Initializers =--
function DataStreamClient:Init()
	if Initialized then return end
	Initialized = true

	--// Fetch stores from server
	for Name, Data in pairs(InitDataGet:InvokeServer()) do
		DataStreamClient[Name] = Data
	end	
	
	--// Listen for updates
	DataUpdateEvent.OnClientEvent:Connect(function(Name,Path,Value)
		if not self[Name] then
			self[Name] = {}
		end
		--print("DATA REPLICATED", Path)
		--print("Data updated: "..(Path or "ALL"))
		local Current = self[Name]
		local OldValue
		local PathKeys = Path and Path:split(".") or {}
		if #PathKeys == 0 then
			Current = Value
		end
		for Index,NextKey in pairs(PathKeys) do
			if type(Current) == "table" then
				NextKey = tonumber(NextKey) or NextKey
				if Index >= #PathKeys then
					OldValue = Current[NextKey]
					Current[NextKey] = Value
				elseif Current[NextKey] then
					Current = Current[NextKey]
				else
					warn("Path error | "..Path)
					warn("Data may be out of sync, re-syncing with server...")
					self[Name] = InitDataGet:InvokeServer()
				end
			else
				warn("Invalid path | "..Path)
			end
		end
		if #PathKeys == 0 then
			self[Name] = Value
		end
		---
		--print(self.Data)
		-- Changed event
		local PathForBinds = Name.."."..Path
		for BindPath,Bind in pairs(Binds) do
			local StringStart,_ = string.find(PathForBinds or "",BindPath)
			if BindPath == PathForBinds or StringStart == 1 then
				Bind.ToFire:Fire(Value,OldValue,PathForBinds)
			end
		end
	end)
end

DataStreamClient:Init() -- DELETE ME IF YOU HAVE A BETTER WAY TO INITIALIZE

--= Return Module =--
return DataStreamClient