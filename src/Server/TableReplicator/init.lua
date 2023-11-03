--[[
    TableReplicator.lua
    Stratiz
    Created on 11/30/2022 @ 03:13
    
    Description:
        Allows for easy real-time replication of tables to the client.
    
    Usage:

        TableReplicator[<SchemaName>].Some.Kind.Of.Table.Path = 100
        TableReplicator[<SchemaName>].Some.Kind.Of.Table.Path:Read() -- Returns 100
        TableReplicator[<SchemaName>].Some.Kind.Of.Table.Path:Changed(function(newValue, oldValue)
            print(newValue)
        end)

--]]

--= Root =--

local TableReplicator = { }

--= Roblox Services =--

local Players = game:GetService("Players")

--= Dependencies =--

local CONFIG = require(script.ReplicatorServerConfig)
local TableReplicatorMeta = require(script:WaitForChild("TableReplicatorMeta"))
local Signal = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("ReplicatorSignal"))
local ReplicatorUtils = require(script.TableReplicatorUtils)
local ReplicatorRemotes = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("ReplicatorRemotes"))

--= Object References =--

--= Constants =--

--= Variables =--

local GetDataFunction =  ReplicatorRemotes:Get("Function", "GetData")
local Replicating = {
    Player = {},
    Global = {}
}
local RegisteredPlayers = {}
local SchemaCache = {}

--= Internal Functions =--

local function ValidateReplicatorName(name : string)
    if Replicating.Global[name] or Replicating.Player[name] then
        error("Schema already exists with name: " .. name)
    end
    if TableReplicator[name] then
        error("Schema cannot have the same name as a module method: " .. name)
    end
end

local function CreatePlayerReplicatorCatcher(name)
    local playerTableReplicatorCache = {}
    local proxy = newproxy(true)
    local metatable = getmetatable(proxy)
    
    local function checkForRegister(index)
        local targetIndex = ReplicatorUtils.ResolvePlayerSchemaIndex(index)
        local targetPlayer = Players:GetPlayerByUserId(targetIndex)

        if targetPlayer then
            if not RegisteredPlayers[targetPlayer] or RegisteredPlayers[targetPlayer][name] == nil then
                TableReplicator:MakeReplicatorForPlayer(name, targetPlayer, ReplicatorUtils:DeepCopyTable(SchemaCache[name]))
            end
        end
    end

    metatable.__newindex = function(self,Index,Value)
        local targetIndex = ReplicatorUtils.ResolvePlayerSchemaIndex(Index)
        local targetPlayer = Players:GetPlayerByUserId(targetIndex)
        checkForRegister(Index)

        if targetPlayer then
            playerTableReplicatorCache[targetIndex] = Value
            if Value == nil then
                TableReplicatorMeta:TriggerReplicate(targetPlayer, name, {}, Value)
            end
        else
            warn("Player not found for index: " .. targetIndex)
        end
        return self
    end
    
    metatable.__index = function(self, Index)
        local targetIndex = ReplicatorUtils.ResolvePlayerSchemaIndex(Index)
        checkForRegister(Index)


        return playerTableReplicatorCache[targetIndex]
    end

    metatable.__tostring = function()
        return `PlayerReplicatorIndexCatcher ({name})`
    end

    metatable._playerReplicatorCache = playerTableReplicatorCache

    return proxy
end

--= API Functions =--
TableReplicator.PlayerReplicatorAdded = Signal.new()
TableReplicator.PlayerReplicatorRemoving = Signal.new()

-- Adds a new schema to be a default replicator which is unique to each player
function TableReplicator:AddPlayerReplicatorTemplate(name : string, schema : {[any] : any})
    ValidateReplicatorName(name)

    Replicating.Player[name] = CreatePlayerReplicatorCatcher(name)

    SchemaCache[name] = schema

    Players.PlayerAdded:Connect(function(player)
        self:MakeReplicatorForPlayer(name, player, ReplicatorUtils:DeepCopyTable(schema))
    end)

    Players.PlayerRemoving:Connect(function(player)
        RegisteredPlayers[player] = nil
        self:RemoveReplicatorForPlayer(name, player)
    end)
end

-- Adds a schema to a specific player
function TableReplicator:MakeReplicatorForPlayer(name : string, player : Player, schema : {[any] : any})
    
    if not Replicating.Player[name] then
        ValidateReplicatorName(name)
        Replicating.Player[name] = CreatePlayerReplicatorCatcher(name)
    end

    if not RegisteredPlayers[player] then
        RegisteredPlayers[player] = {}
    end
    RegisteredPlayers[player][name] = true

    local playerIndex = ReplicatorUtils.ResolvePlayerSchemaIndex(player)
    local newTableReplicator = TableReplicatorMeta:MakeTableReplicatorObject(name, schema, player)
    Replicating.Player[name][playerIndex] = newTableReplicator

    TableReplicator.PlayerReplicatorAdded:Fire(name, player)

    return newTableReplicator
end

-- Removes a schema from a specific player
function TableReplicator:RemoveReplicatorForPlayer(name : string, player : Player)
    local playerIndex = ReplicatorUtils.ResolvePlayerSchemaIndex(player)

    TableReplicator.PlayerReplicatorRemoving:Fire(name, player)

    if RegisteredPlayers[player] then
        RegisteredPlayers[player][name] = nil
    end

    task.defer(function()
        Replicating.Player[name][playerIndex] = nil
    end)
end

-- Adds a schema whose data all players share.
function TableReplicator:MakeGlobalReplicator(name : string, schema : {[any] : any})
    ValidateReplicatorName(name)

    Replicating.Global[name] = TableReplicatorMeta:MakeTableReplicatorObject(name, schema)
end

--= Initializers =--
do
    for _, playerSchema in script.Schemas.Player:GetChildren() do
        if playerSchema:IsA("ModuleScript") then
            TableReplicator:AddPlayerReplicatorTemplate(playerSchema.Name, require(playerSchema))
        end
    end
    for _, globalSchema in script.Schemas.Global:GetChildren() do
        if globalSchema:IsA("ModuleScript") then
            TableReplicator:MakeGlobalReplicator(globalSchema.Name, require(globalSchema))
        end
    end

    GetDataFunction.OnServerInvoke = function(player, schemaName)

        local function makeReturnDataFromSchema(schema)
            local currentData = schema:Read()

            return {
                Data = currentData,
                NonStringIndexes = TableReplicatorMeta:GetNonStringIndexesFromValue(currentData)
            }
        end

        if not schemaName then
            local toReturn = {}
            local playerIndex = ReplicatorUtils.ResolvePlayerSchemaIndex(player)

            for name, schema in pairs(Replicating.Player) do
                if schema[playerIndex] then
                    toReturn[name] = makeReturnDataFromSchema(schema[playerIndex])
                end
            end

            for name, schema in pairs(Replicating.Global) do
                toReturn[name] = makeReturnDataFromSchema(schema)
            end

            return toReturn
        else
            if Replicating.Player[schemaName] then
                local playerIndex = ReplicatorUtils.ResolvePlayerSchemaIndex(player)
                if Replicating.Player[schemaName][playerIndex] then
                    return makeReturnDataFromSchema(Replicating.Player[schemaName][playerIndex])
                else
                    return nil
                end
            else
                return makeReturnDataFromSchema(Replicating.Global[schemaName])
            end
        end
    end
end

function TableReplicator:GetPlayersWithSchema(name : string) : {Player}
    local globalReplicator = Replicating.Global[name]
    if globalReplicator then
        return Players:GetPlayers()
    end

    local playerReplicator = Replicating.Player[name]
    if not playerReplicator then
        error("Attempt to get players in non-existent schema '"..tostring(name).."'")
    end

    local metatable = getmetatable(playerReplicator)

    local toReturn = {}
    for playerIndex, _ in pairs(metatable._playerReplicatorCache) do
        local player = Players:GetPlayerByUserId(playerIndex)
        if player then
            table.insert(toReturn, player)
        end
    end
    return toReturn
end

--= Return Module =--
return setmetatable(TableReplicator, {
    __index = function(self, index)
        local replicatorTarget = Replicating.Global[index] or Replicating.Player[index]
        if replicatorTarget then
            return replicatorTarget
        else
            error("Attempt to index non-existent schema '"..tostring(index).."'")
        end
    end
})
