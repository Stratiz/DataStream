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
local PlayerData = { }

--= Roblox Services =--
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local DataStoreService = game:GetService("DataStoreService")

--= Dependencies =--
local DataUtils = require(script:WaitForChild("PlayerDataUtils"))
local VersioningModule = require(script:WaitForChild("PlayerDataVersioning"))

--= Object References =--
local PlayerReplicators = nil;

--= Constants =--
local JOB_ID = (game.JobId == nil or game.JobId == "" ) and "STUDIO_"..HttpService:GenerateGUID(false) or game.JobId
local CONFIG = require(script:WaitForChild("PlayerDataConfig"))
local DATASTORE = DataStoreService:GetDataStore(CONFIG.DATASTORE_NAME)

--= Variables =--
local Players = game:GetService("Players")
local InStudio = game:GetService("RunService"):IsStudio()
local RawWarn = warn
local RawPrint = print
local Saving = 0
local ExtantServers = {}

--= Internal Functions =--
local function warn(...)
	RawWarn("[PlayerData]", ...)
end

local function print(...)
	RawPrint("[PlayerData]", ...)
end

local function SaveData(userId : number, setLock : boolean, replicator : any?)
	if not ((CONFIG.SAVE_IN_STUDIO and InStudio) or not InStudio) then print("Will not save data. (SAVE_IN_STUDIO = false)") return end

	if not replicator and PlayerReplicators[userId] then
		replicator = PlayerReplicators[userId]
	end
	
	if not replicator then
		warn("No data was provided. Will not save")
		return
	end

	local DataToSave = DataUtils:DeepCopy(replicator:Read())
	local dataMetaData = getmetatable(replicator)._PlayerData

	Saving += 1
	DataUtils:InvokeOnNext(Enum.DataStoreRequestType.SetIncrementAsync, function()
		print("Saving data!")
		local dataStoreOptions = Instance.new("DataStoreSetOptions")
		dataStoreOptions:SetMetadata({Lock = setLock and JOB_ID or nil})

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

		if keyInfo then
			local userIds = keyInfo:GetUserIds()
			if #userIds > 0 and not table.find(userIds, player.UserId) then
				warn("Player is not authorized to access this data, as it doesnt belong to them.")
				return nil, {}
			end
		end

		return resultData, keyInfo and keyInfo:GetMetadata() or {}
	end)

	if success then
		return data, keyMetaData
	else
		error("Get failed | "..data)
	end
end

local function GetAndApplyData(player, replicator, _isRetry, _sentQuery)
	local metaData = getmetatable(replicator)._PlayerData

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
			return replicator:Read(), {}
		end
	end)

	--- Main stuff
	if success and data then
		-- Update Version
		VersioningModule:UpdateVersion(data)
		--
		if (_isRetry or 0) >= 3 then
			warn("Data is locked for", player, "and has been retried 3 times. Will not retry again.")

			keyMetaData.Lock = nil
		end

		if not keyMetaData.Lock then
			task.spawn(function()
				SaveData(player.UserId, true)
				replicator:Write(data)
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
						FromJobId = JOB_ID,
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

			if PlayerReplicators[player] then -- Making sure the data is still needed
				GetAndApplyData(player, replicator, (_isRetry or 0) + 1, sentQuery)
			else
				print("Player left while data was still retrying.")
			end
		end
	elseif not success then
		warn("Datastore failed: "..data)
		task.wait(2)
		print("Retrying data get...")

		if PlayerReplicators[player] then -- Making sure the data is still needed
			GetAndApplyData(player, replicator, 0) -- Retry to 0 because DATA IS IMPORTANT
		else
			print("Player left while data was still loading.")
		end
	else
		metaData.DataApplied = true
	end
	metaData.Loading = false
end

local function TriggerAutosave(RemoveLock)
	for _, player in pairs(CONFIG.TABLE_REPLICATOR_MODULE:GetPlayersWithSchema(CONFIG.SCHEMA_NAME)) do
		local replicator = PlayerReplicators[player]
		if replicator then
			local metaData = getmetatable(replicator)._PlayerData
			if metaData then
				if metaData.DataApplied == true and tick() - (metaData.LastSaveTick or 0) > 6 then
					print("Autosaving data for", player)
					SaveData(player.UserId, RemoveLock or false, replicator)
				end
			end
		end
	end
end

--= API Functions =--
function PlayerData:ForceSave()
	TriggerAutosave(true)
	--self:WaitForSave()
end

function PlayerData:IsDataLoaded(RawKey) : boolean | nil
	local targetreplicator = PlayerReplicators[RawKey]
	if targetreplicator then
		local metaData = getmetatable(targetreplicator)._PlayerData
		if metaData then
			return metaData.DataApplied == true and metaData.Loading == false
		end
	end
end

function PlayerData:WaitForLoad(RawKey) : boolean
	local _, userId = DataUtils.ResolveIndex(RawKey)
	local targetPlayer = Players:GetPlayerByUserId(tonumber(userId))
	local isLoaded = self:IsDataLoaded(RawKey)
	
	while not isLoaded and targetPlayer and targetPlayer.Parent do
		task.wait()
		isLoaded = self:IsDataLoaded(RawKey)
	end

	return isLoaded
end

do -- Initializer
	PlayerReplicators = CONFIG.TABLE_REPLICATOR_MODULE[CONFIG.SCHEMA_NAME]

	if not PlayerReplicators then
		error("No schema found!")
	end

	local function addPlayer(player, replicator)
		local replicatorMetaData = getmetatable(replicator)
		replicatorMetaData._PlayerData = {
			DataApplied = false,
			Loading = false,
			RetryCount = 0,
			LastSaveTick = 0,
		}
		GetAndApplyData(player, replicator)
	end

	for _, player in pairs(CONFIG.TABLE_REPLICATOR_MODULE:GetPlayersWithSchema(CONFIG.SCHEMA_NAME)) do
		addPlayer(player, PlayerReplicators[player])
	end

	CONFIG.TABLE_REPLICATOR_MODULE.PlayerReplicatorAdded:Connect(function(name, player)
		if name == CONFIG.SCHEMA_NAME then
			addPlayer(player, PlayerReplicators[player])
		end
	end)

	CONFIG.TABLE_REPLICATOR_MODULE.PlayerReplicatorRemoving:Connect(function(name, player)
		if name == CONFIG.SCHEMA_NAME then
			local replicator = PlayerReplicators[player]
			local metaData = getmetatable(replicator)._PlayerData

			print(player.Name.." is leaving, attempting to save...")

			if metaData.DataApplied == true then
				print("Adding "..player.Name.." to save queue.")
				SaveData(player.UserId, false, replicator)
			else
				warn("Did not save data on remove for "..player.Name..".")
			end
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

	-- Bind to close
	game:BindToClose(function()
		print("Game is closing, attempting to save...")
		PlayerData:ForceSave()
		repeat
			task.wait()
		until Saving <= 0
	end)

	-- Data validation
	local subscribed, err = pcall(function()
		local alphaJobId = string.gsub(JOB_ID, "-", "")

		MessagingService:SubscribeAsync(alphaJobId, function(data)
			local fromAlphaJobId = string.gsub(data.FromJobId, "-", "")

			if data.Type == "Query" then
				MessagingService:PublishAsync(fromAlphaJobId, {Type = "Response", FromJobId = JOB_ID})
			elseif data.Type == "Response" then
				table.insert(ExtantServers, data.FromJobId)
			end
		end)
	end)

	if not subscribed then
		warn("Failed to subscribe to messaging service, this will affect data locking functionality |", err)
	end
end

return setmetatable({}, {
	__index = function(self, index)
		index = tonumber(index) or index

		if type(index) == "string" then
			return PlayerData[index]
		elseif typeof(index) == "Instance" and index:IsA("Player") then
			return PlayerReplicators[index.UserId]
		elseif type(index) == "number" then
			return PlayerReplicators[index]
		else
			error("PlayerData does not have a member named "..index)
		end
	end,
	__newindex = function(self, index, value)
		if PlayerReplicators[index] then
			PlayerReplicators[index]:Write(value)
		else
			error("Cannot write to a nil value "..index)
		end
	end,
})