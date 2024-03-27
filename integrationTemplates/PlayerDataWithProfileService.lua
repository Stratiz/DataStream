--[[
    PlayerData.lua
    Stratiz
    Created on 10/15/2022 @ 01:58
    
    Description:
        Handles player data with ProfileService and DataStream

    Usage:

        To read:

            PlayerData[PlayerObject or UserId].Currency.Coins:Read()
            
        To write (2 options):

            PlayerData[PlayerObject or UserId].Currency.Coins:Write(100)
            PlayerData[PlayerObject or UserId].Currency.Coins = 100
            PlayerData[PlayerObject or UserId].Currency.Coins *= 100
            PlayerData[PlayerObject or UserId].Currency.Coins /= 100
            etc...

        To listen for changes:

            PlayerData[PlayerObject or UserId].Currency.Coins:Changed(function(newValue, oldValue)
                print(newValue)
            end)
--]]

--= Root =--

local PlayerData = {
    Priority = 100
}

--= Roblox Services =--

local Players = game:GetService("Players")

--= Dependencies =--

--// FILL THESE IN!
local DataStream = require(DATA_STREAM) -- src/Server/DataStream
local ProfileService = require(PROFILE_SERVICE) -- ProfileService: https://github.com/MadStudioRoblox/ProfileService
local ProfileSchema = require(STORED_SCHEMA) -- src/Server/DataStream/Schemas/Player/Stored
local Signal = require(SIGNAL_MODULE) -- Signal module: https://github.com/Quenty/NevermoreEngine/blob/main/src/signal/src/Shared/Signal.lua

--= Object References =--

local LoadedCallbackSignal = Signal.new()

--= Constants =--

local LOAD_PLAYER_DATA = true

--= Variables =--

local GameProfileStore = ProfileService.GetProfileStore("PlayerData" .. tostring(game.PlaceId), ProfileSchema)
local Profiles = {}
local PlayerCleanupTasks = {}

--= Internal Functions =--

--= API Functions =--

function PlayerData:IsDataReadyForPlayer(player : Player)
    return Profiles[player] ~= nil
end

function PlayerData:OnDataReady(player : Player, callback : () -> ())
    if self:IsDataReadyForPlayer(player) then
        callback()
        return
    end
    local connection; connection = LoadedCallbackSignal:Connect(function(readyPlayer, success)
        if readyPlayer == player then
            connection:Disconnect()
            if success then
                callback()
            end
        end
    end)
    
    return connection
end

-- Function to execute before the data is saved on player leave.
function PlayerData:OnDataReleasing(player : Player, callback : () -> ())
    self:OnDataReady(player, function()
        local profile = Profiles[player]
        if profile ~= nil then
            if not PlayerCleanupTasks[player] then
                PlayerCleanupTasks[player] = {}
            end

            table.insert(PlayerCleanupTasks[player], callback)
        end
    end)
end

--= Initializers =--

function PlayerData:Init() -- This function will be called when the module is initialized.
    local function PlayerAdded(player)
        local profile = GameProfileStore:LoadProfileAsync("Player_" .. player.UserId)
        if profile ~= nil then
            profile:AddUserId(player.UserId) -- GDPR compliance
            profile:Reconcile() -- Fill in missing variables from ProfileTemplate (optional)
            profile:ListenToRelease(function()
                Profiles[player] = nil
                PlayerCleanupTasks[player] = nil
                -- The profile could've been loaded on another Roblox server:
                player:Kick()
            end)
            
            if Players:FindFirstChild(player.Name) then
                if LOAD_PLAYER_DATA then
                    DataStream.Stored[player]:Write(profile.Data)
                end
                DataStream.Stored[player]:Changed(function()
                    profile.Data = DataStream.Stored[player]:Read()
                end)

                Profiles[player] = profile
                -- A profile has been successfully loaded:

                LoadedCallbackSignal:Fire(player, true)
                DataStream.Session[player].IsLoaded:Write(true)
            else
                -- Player left before the profile loaded:
                profile:Release()
            end
        else
            -- The profile couldn't be loaded possibly due to other
            --   Roblox servers trying to load this profile at the same time:
            player:Kick()
        end

        LoadedCallbackSignal:Fire(player, false)
    end
    
    -- In case Players have joined the server earlier than this script ran:
    for _, player in ipairs(Players:GetPlayers()) do
        task.spawn(PlayerAdded, player)
    end
    
    Players.PlayerAdded:Connect(PlayerAdded)

    Players.PlayerRemoving:Connect(function(player)
        local profile = Profiles[player]
        if profile ~= nil then
            if PlayerCleanupTasks[player] then
                for _, task in PlayerCleanupTasks[player] do
                    task()
                end
            end

            profile:Release()
        end
    end)
end

setmetatable(PlayerData, {
    __index = function(self, index)
        return DataStream.Stored[index]
    end,
    __newindex = function(self, index, value)
        DataStream.Stored[index] = value
    end
})

--= Return Module =--
return PlayerData