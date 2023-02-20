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
local MessagingService = game:GetService("MessagingService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

--= Dependencies =--
local DataUtils = require(script:WaitForChild("DataStreamUtils"))
local VersioningModule = require(script:WaitForChild("DataStreamVersioning"))

--= Object References =--
local PlayerData = nil;

--= Constants =--
local CONFIG = require(script:WaitForChild("DataStreamConfig"))
local DATASTORE = DataStoreService:GetDataStore(CONFIG.DATASTORE_NAME)

--= Variables =--
local InStudio = game:GetService("RunService"):IsStudio()
local RawWarn = warn
local RawPrint = print
local Initialized = false
local Saving = 0
local ExtantServers = {}

--= Internal Functions =--
local function warn(...)
	RawWarn("[DataStream]", ...)
end

local function print(...)
	RawPrint("[DataStream]", ...)
end

local function SaveData(userId : number, setLock : boolean, stream : any?)
	if not ((CONFIG.SAVE_IN_STUDIO and InStudio) or not InStudio) then print("Will not save data. (SAVE_IN_STUDIO = false)") return end

	if not stream and PlayerData[userId] then
		stream = PlayerData[userId]:Read()
	end
	
	if not stream then
		warn("No data was provided. Will not save")
		return
	end

	local data = stream:Read()

	local DataToSave = DataUtils:DeepCopy(data)
	local dataMetaData = getmetatable(stream)._dataStream

	Saving += 1
	DataUtils:InvokeOnNext(Enum.DataStoreRequestType.SetIncrementAsync, function()
		print("Saving data!")
		local dataStoreOptions = Instance.new("DataStoreOptions")
		dataStoreOptions:SetMetaData({Lock = setLock and game.JobId or nil})

		dataMetaData.LastSaveTick = tick()

		local success, err = pcall(function()
			return DATASTORE:SetAsync(DataUtils.ResolveIndex(userId), DataToSave, {userId}, dataStoreOptions)
		end)

		if not success then
			warn("Failed to save data | ".. err)
		end
		Saving -= 1
	end)
end

local function DoGetAsync(player)

	local success, data, keyMetaData = pcall(function()
		
		DataUtils:WaitForNext(Enum.DataStoreRequestType.GetAsync)
		local resultData, keyInfo = DATASTORE:GetAsync(DataUtils.ResolveIndex(player))

		local userIds = keyInfo:GetUserIds()
		if #userIds > 0 and not table.find(userIds, player.UserId) then
			warn("Player is not authorized to access this data, as it doesnt belong to them.")
			return nil, {}
		end

		return resultData, keyInfo:GetMetadata()
	end)

	if success then
		return data, keyMetaData
	else
		error("Get failed | ", data)
	end
end

local function GetAndApplyData(player, stream, _isRetry, _sentQuery)
	local metaData = getmetatable(stream)._dataStream

	if metaData.Loading and _isRetry == nil then
		print("Data is loading, will not retry yet")
		task.wait(0.2)
		return
	end
	--
	metaData.Loading = true
	--
	local success, data, keyMetaData = pcall(function()
		if CONFIG.LOAD_IN_STUDIO == true or not InStudio then
			return DoGetAsync(player)
		else
			print("Providing default data (LOAD_IN_STUDIO = false)")
			return stream:Read(), {}
		end
	end)
	if data == "" then
		print("btw nil data is empty string!!!!!!!") --//TODO: remove me
		data = nil
	end
	--- Main stuff
	if success and data then
		-- Update Version
		VersioningModule:UpdateVersion(data)
		--
		if (_isRetry or 0) >= 3 then
			warn("Data is locked for", player, "and has been retried 3 times. Will not retry again.")

			ExtantServers[keyMetaData.Lock] -= 1
			if ExtantServers[keyMetaData.Lock] < 0 then
				ExtantServers[keyMetaData.Lock] = nil
			end

			keyMetaData.Lock = nil
		end

		if not keyMetaData.Lock then
			task.spawn(function()
				SaveData(player.UserId, true)
				stream:Write(data)
				metaData.DataApplied = true
			end)
		else --//TODO: Figure out what to do if a server still obviously has someones data
			print("Data is locked for", player)

			-- Send a message to the server and see if they respond
			local sentQuery = _sentQuery or false
			if _isRetry and _isRetry == 2 then
				local sent, err = pcall(function()
					local lockAlphaJobId = string.gsub(keyMetaData.Lock, "-", "")
					MessagingService:PublishAsync(lockAlphaJobId, {
						FromJobId = game.JobId,
						Type = "Query"
					})
				end)

				if not sent then
					warn("Failed to send lock message | ", err)
				else
					sentQuery = true
				end
			end

			task.wait(4.25) --// GetAsync cache lasts 4 seconds

			if sentQuery then
				local foundIndex = table.find(ExtantServers, keyMetaData.Lock)
				if foundIndex then
					table.remove(ExtantServers, foundIndex)
					player:Kick("Data is still being processed in another server, please rejoin, or contact an admin if this persists.")
					return
				end
			end

			if PlayerData[player] then -- Making sure the data is still needed
				GetAndApplyData(player, stream, (_isRetry or 0) + 1, sentQuery)
			else
				print("Player left while data was still retrying.")
			end
		end
	elseif not success then
		warn("Datastore failed: "..data)
		print("Retrying data get...")

		if PlayerData[player] then -- Making sure the data is still needed
			GetAndApplyData(player, stream)
		else
			print("Player left while data was still loading.")
		end
	else
		metaData.DataApplied = true
	end
	metaData.Loading = false
end

local function TriggerAutosave(RemoveLock)
	for key, stream in pairs(PlayerData) do
		local metaData = getmetatable(stream)._dataStream
		if metaData then
			if metaData.DataApplied == true and tick() - (metaData.LastSaveTick or 0) > 6 then
				SaveData(tonumber(key), RemoveLock or false, stream)
			end
		end
	end
end

--= API Functions =--
function DataStream:ForceSave()
	TriggerAutosave(true)
	--self:WaitForSave()
end

function DataStream:IsDataLoaded(RawKey) : boolean | nil
	local targetStream = PlayerData[RawKey]
	if targetStream then
		local metaData = getmetatable(targetStream)._dataStream
		if metaData then
			return not metaData.DataApplied
		end
	end
end

function DataStream:WaitForLoad(RawKey)
	while not self:IsDataLoaded(RawKey) do
		task.wait()
	end
end


do -- Initializer
	PlayerData = CONFIG.STREAM_MODULE[CONFIG.STREAM_SCHEMA_NAME]

	if not PlayerData then
		error("No schema found!")
	end

	local function addPlayer(player, stream)
		local streamMetaData = getmetatable(stream)
		streamMetaData._dataStream = {
			DataApplied = false,
			Loading = false,
			RetryCount = 0,
			LastSaveTick = 0,
		}
		GetAndApplyData(player, stream)
	end

	for userId, stream in pairs(PlayerData) do
		local player = Players:GetPlayerByUserId(tonumber(userId))
		if player then
			addPlayer(player, stream)
		else
			warn("Couldn't find player to add to data stream!", userId, "is not a valid player.")
		end
	end

	CONFIG.STREAM_MODULE.PlayerStreamAdded:Connect(function(name, player, stream)
		if name == CONFIG.STREAM_SCHEMA_NAME then
			addPlayer(player, stream)
		end
	end)

	CONFIG.STREAM_MODULE.PlayerStreamRemoving:Connect(function(name, player, stream)
		if name == CONFIG.STREAM_SCHEMA_NAME then
			SaveData(player.UserId, false, stream)
		end

		local metaData = getmetatable(stream)._dataStream

		print(player.Name.." is leaving, attempting to save...")

		if metaData.DataApplied == true then
			print("Adding "..player.Name.." to save queue.")
			SaveData(player.UserId, false)
		else
			warn("Did not save data on remove for "..player.Name..".")
		end
	end)

	-- Autosaving
	if CONFIG.AUTO_SAVE_INTERVAL > 0 then
		task.spawn(function()
			while task.wait(CONFIG.AUTO_SAVE_INTERVAL) do
				print("Autosaving...")
				TriggerAutosave()
			end
		end)
	end

	-- Data validation
	local subscribed, err = pcall(function()
		local alphaJobId =  string.gsub(game.JobId, "-", "")
		print("AlphaJobId: "..alphaJobId)

		MessagingService:SubscribeAsync(alphaJobId, function(data)
			local fromAlphaJobId = string.gsub(data.FromJobId, "-", "")

			if data.Type == "Query" then
				MessagingService:PublishAsync(fromAlphaJobId, {Type = "Response", FromJobId = game.JobId})
			elseif data.Type == "Response" then
				table.insert(ExtantServers, data.FromJobId)
			end
		end)
	end)

	if not subscribed then
		warn("Failed to subscribe to messaging service, this will affect data locking functionality | ", err)
	end
end

return setmetatable({}, {
	__index = function(self, index)
		index = tonumber(index) or index

		if typeof(index) == "Instance" and index:IsA("Player") then
			return PlayerData[index.UserId]
		elseif type(index) == "number" then
			return PlayerData[index]
		elseif DataStream[index] then
			return DataStream[index]
		else
			error("DataStream does not have a member named "..index)
		end
	end,
	__newindex = function(self, index, value)
		if PlayerData[index] then
			PlayerData[index]:Write(value)
		else
			error("Cannot write to a nil value "..index)
		end
	end,
})