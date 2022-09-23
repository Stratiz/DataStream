-- Stratiz 2021
-- My take on datastores

--[[
This system was developed for personal use, it features a very unique way of interacting with data and replicating data accordingly. 

Player data is indexed via:

PlayerData.Data[Player].Currency.Souls:Read() -- Reads data
PlayerData.Data[Player].Currency.Souls = 10 -- Sets data

Why? Because this allows for automatic replication of data to clients, triggering of artificial events such as changed and more without the need to call a function like:
OtherDataSystem:Set(Player,"Currency.Souls",Value)

-- That type of function doesnt suck, but it creates a slightly slower workflow.

Only downside is you have to do :Read() when getting data.

--]]

--[[
	init.lua
	Stratiz
	Created on 09/07/2022 @ 01:30
	
	Description:
		No description provided.
	
	Documentation:
		No documentation provided.
--]]

--= Root =--
local DataStream = { }

--= Roblox Services =--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

--= Dependencies =--
local DataUtils = require(script:WaitForChild("DataStreamUtils"))
local DataStreamMeta = require(script:WaitForChild("DataStreamMeta"))
local VersioningModule = require(script:WaitForChild("DataStreamVersioning"))

--= Object References =--
local InitDataGet = DataUtils:MakeRemote("Function","DataGetFunction")
local StoredDataCache = {}
DataStream.Stored = DataStreamMeta.new("Stored",StoredDataCache)
local TempDataCache = {}
DataStream.Temp = DataStreamMeta.new("Temp",TempDataCache)

--= Constants =--
local MAIN_DS = DataStoreService:GetDataStore("BETA_1")
local AUTO_SAVE_INTERVAL = 5*60 -- 0 = off
local SAVE_IN_STUDIO = false
local LOAD_IN_STUDIO = false

--= Variables =--
local InStudio = game:GetService("RunService"):IsStudio()
local RawWarn = warn
local RawPrint = print
local Initialized = false

--= Internal Functions =--
local function warn(...)
	RawWarn("[DataStream]", ...)
end

local function print(...)
	RawPrint("[DataStream]", ...)
end

local function SaveData(key : string, data : any)
	
	if not ((SAVE_IN_STUDIO and InStudio) or not InStudio) then print("Will not save data. (SAVE_IN_STUDIO = false)") return end
	
	if not data and StoredDataCache[key] then
		data = StoredDataCache[key]
	elseif not data then
		warn("No data was provided. Will not save")
		return
	end
	local DataToSave = DataUtils:DeepCopy(data)
	DataUtils:InvokeOnNext(Enum.DataStoreRequestType.SetIncrementAsync, function()
		print("Saving data!")
		local OK,Data = pcall(function()
			if TempDataCache[key] then
				TempDataCache[key]._LastSaveTick = tick()
			end
			
			return MAIN_DS:SetAsync(key, DataToSave)
		end)
		if not OK then
			warn("Failed to save data | ".. Data)
		end
	end)
end

--= API Functions =--

--= Initializers =--
function DataStream:Init()
	
end

--= Return Module =--
return DataStream

local DefaultData = {}





local function TriggerAutosave(RemoveLock)
	for Key,Data in pairs(StoredDataCache) do
		if TempDataCache[Key] then
			if TempDataCache[Key]._IsPlaceholder == false and tick() - (TempDataCache[Key]._LastSaveTick or 0) > 6 then
				if RemoveLock then
					Data._LOCK = nil
				end
				SaveData(Key,Data)
			end
		end
	end
end


function PlayerData:Init()
	for _, Schema in pairs(script.Schemas:GetChildren()) do
		DefaultData[Schema.Name] = require(Schema)
	end

	local function BindPlayer(Player)
		self:InitData(Player.UserId)
	end
	Players.PlayerAdded:Connect(BindPlayer)
	for _,Player in pairs(Players:GetPlayers()) do
		BindPlayer(Player)
	end
	
	Players.PlayerRemoving:Connect(function(Player)
		print(Player.Name.." is leaving, attempting to save...")
		local Key = DataUtils.ResolveIndex(Player.UserId)
		if StoredDataCache[Key] and TempDataCache[Key] and not StoredDataCache[Key]._IsPlaceholder then
			local DataToSave = TableUtils.deepCopy(StoredDataCache[Key])
			StoredDataCache[Key] = nil
			--TempDataCache[Key] = nil
			DataToSave._LOCK = nil
			print("Adding "..Player.Name.." to save queue.")
			SaveData(Key,DataToSave)
		else
			warn("Did not save data on remove for "..Player.Name..".")
		end
	end)

	-- Autosaving
	if AUTO_SAVE_INTERVAL > 0 then
		task.spawn(function()
			while task.wait(AUTO_SAVE_INTERVAL) do
				print("Autosaving...")
				TriggerAutosave()
			end
		end)
	end
end

local function DoGetAsync(dataStore,key)
	
	local OK,Data = pcall(function()
		if (LOAD_IN_STUDIO and InStudio) or not InStudio then
			AsyncServiceHelper:WaitForNextAvailableCall("DataStoreService", {DataStore = MainData, Key = key, RequestType = Enum.DataStoreRequestType.SetIncrementAsync})
			return dataStore:GetAsync(key)
		else
			print("Providing default data (LOAD_IN_STUDIO = false)")
			return TableUtils.deepCopy(DefaultData["Stored"])
		end
	end)

	if OK then
		return Data
	else
		error("Get failed | ", Data)
	end
end

local function GetData(RawKey,_isRetry)
	--print("Getting data")
	
	local Key = DataUtils.ResolveIndex(RawKey) 
	if StoredDataCache[Key] and TempDataCache[Key] and TempDataCache[Key]._IsLoading and _isRetry == nil then
		print("Data is loading, will not retry yet")
		task.wait(0.2)
		return
	end
	--
	StoredDataCache[Key] = TableUtils.deepCopy(DefaultData["Stored"])
	TempDataCache[Key] = TableUtils.deepCopy(DefaultData["Temp"])
	TempDataCache[Key]._IsPlaceholder = true
	TempDataCache[Key]._GetCount = 0
	TempDataCache[Key]._IsLoading = true
	--
	local OK,Data = pcall(function()
		return DoGetAsync(MainData,Key)
	end)
	if Data == "" then
		Data = nil
	end
	--- Main stuff
	if OK and Data then
		StoredDataCache[Key] = Data
		-- Update Version
		VersioningModule:UpdateVersion(StoredDataCache[Key])
		--

		TempDataCache[Key]._IsPlaceholder = false
		if _isRetry then -- If its a successful retry then replicate data to the client
			--ReplicateData(RawKey,nil,Data)
			PlayerData.Stored[RawKey] = Data
			--PlayerData.Temp[RawKey] = Data
		end
		--
		if not StoredDataCache[Key]._LOCK or (_isRetry or 0) >= 3 then -- If not lock file or lockfile timeout
			StoredDataCache[Key]._LOCK = game.JobId
			task.spawn(function()
				SaveData(Key)
			end)
		else
			TempDataCache[Key]._IsPlaceholder = true
			print("Data is locked for "..Key)
			if StoredDataCache[Key] then -- Making sure the data is still needed
				GetData(RawKey,(_isRetry or 1) + 1)
			end
		end
	else
		if not OK then
			warn("Datastore failed: "..Data)
			print("Retrying data get...")
			GetData(RawKey)
		else
			TempDataCache[Key]._IsPlaceholder = false
		end		
	end
	TempDataCache[Key]._IsLoading = false
end

--[[function PlayerData:WaitForSave()
	repeat task.wait(0.1) until #SaveQueue == 0
end]]

function PlayerData:ForceSave()
	TriggerAutosave(true)
	--self:WaitForSave()
end

function PlayerData:IsDataLoaded(RawKey)
	return StoredDataCache[DataUtils.ResolveIndex(RawKey)] and true or false
end

function PlayerData:InitData(RawKey)
	local Key = DataUtils.ResolveIndex(RawKey)
	if StoredDataCache[Key] then
		if TempDataCache[Key]._IsLoading then
			self:WaitForLoad(RawKey)
		end
	else
		GetData(RawKey)
	end
end

function PlayerData:WaitForLoad(RawKey)
	local Key = DataUtils.ResolveIndex(RawKey)
	if Key then
		while not StoredDataCache[Key] or TempDataCache[Key]._IsLoading == true do
			task.wait()
		end
		return {Stored = StoredDataCache[Key], Temp = TempDataCache[Key]}
	end
end

InitDataGet.OnServerInvoke = function(Player)
	return PlayerData:WaitForLoad(Player)
end

function PlayerData:MakeIterator(path : string) : ()
	local PathFragments = string.split(path,".")
	local Indexes = Players:GetPlayers()
	local CurrentIndex = 1
	local TargetDataTable = PathFragments[1] == "Temp" and TempDataCache or PathFragments[1] == "Stored" and StoredDataCache
	if not TargetDataTable then
		error("Invalid path: "..path)
	end
	return function()
		if CurrentIndex > #Indexes then
			return nil
		end

		local TargetValue = nil
		for i=CurrentIndex, #Indexes do
			local Key = DataUtils.ResolveIndex(Indexes[CurrentIndex])
			if TargetDataTable[Key] then
				local Current = TargetDataTable[Key]
				local Success = true
				for _,NextKey in pairs(PathFragments) do
					if type(Current) == "table" then
						Current = Current[NextKey]
					else
						Success = false
						break
					end
				end
				if Success then
					CurrentIndex = i + 1
					TargetValue = Current
					return Indexes[i], TargetValue
				end
			end
		end
	end
end

return PlayerData