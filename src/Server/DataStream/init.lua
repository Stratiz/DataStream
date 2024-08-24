--[[
    DataStream.lua
    Stratiz
    Created on 11/30/2022 @ 03:13
    
    Description:
        Allows for easy real-time replication of tables to the client.
    
    Usage:

        DataStream[<SchemaName>].Some.Kind.Of.Table.Path = 100
        DataStream[<SchemaName>].Some.Kind.Of.Table.Path:Read() -- Returns 100
        DataStream[<SchemaName>].Some.Kind.Of.Table.Path:Changed(function(newValue, oldValue)
            print(newValue)
        end)

--]]

--= Root =--

local DataStream = { }

--= Roblox Services =--

local Players = game:GetService("Players")

--= Dependencies =--

local CONFIG = require(script.ServerDataStreamConfig)
local DataStreamMeta = require(script:WaitForChild("DataStreamMeta"))
local Signal = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("DataStreamSignal"))
local DataStreamUtils = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("DataStreamUtils"))
local StreamRemotes = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("DataStreamRemotes"))

--= Object References =--

--= Constants =--

--= Variables =--

local GetDataFunction =  StreamRemotes:Get("Function", "GetData")
local Replicating = {
    Player = {},
    Global = {}
}
local RegisteredPlayers = {}
local SchemaCache = {}

--= Internal Functions =--

local function ValidateStreamName(name : string)
    if Replicating.Global[name] or Replicating.Player[name] then
        error("Schema already exists with name: " .. name)
    end
    if rawget(DataStream, name) then
        error("Schema cannot have the same name as a module method: " .. name)
    end
end

local function CreatePlayerStreamCatcher(name)
    local playerDataStreamCache = {}
    local proxy = newproxy(true)
    local metatable = getmetatable(proxy)
    
    local function checkForRegister(index)
        local targetIndex = DataStreamUtils.ResolvePlayerSchemaIndex(index)
        local targetPlayer = Players:GetPlayerByUserId(targetIndex)

        if targetPlayer then
            if not RegisteredPlayers[targetPlayer] or RegisteredPlayers[targetPlayer][name] == nil then
                DataStream:MakeStreamForPlayer(name, targetPlayer, DataStreamUtils:DeepCopyTable(SchemaCache[name]))
            end
        end
    end

    metatable.__newindex = function(self, index, value)
        local targetIndex = DataStreamUtils.ResolvePlayerSchemaIndex(index)
        checkForRegister(index)

        if playerDataStreamCache[targetIndex] then
            playerDataStreamCache[targetIndex]:Write(value)
        else
            error("Player does not have schema '"..name.."'")
        end
        
        return self
    end
    
    metatable.__index = function(self, Index)
        local targetIndex = DataStreamUtils.ResolvePlayerSchemaIndex(Index)
        checkForRegister(Index)


        return playerDataStreamCache[targetIndex]
    end

    metatable.__tostring = function()
        return `PlayerStreamIndexCatcher ({name})`
    end

    metatable._playerStreamCache = playerDataStreamCache

    return proxy
end

local function SetStreamObjectToPlayer(schemaName, player, value)
    local playerIndex = DataStreamUtils.ResolvePlayerSchemaIndex(player)
    local target = Replicating.Player[schemaName]
    if target and playerIndex then
        local targetMeta = getmetatable(target)

        targetMeta._playerStreamCache[playerIndex] = value
        if value == nil then
            DataStreamMeta:TriggerReplicate(player, schemaName, {}, value)
        end
    end
end

--= API Functions =--
DataStream.PlayerStreamAdded = Signal.new()
DataStream.PlayerStreamRemoving = Signal.new()

-- Adds a new schema to be a default replicator which is unique to each player
function DataStream:AddPlayerStreamTemplate(name : string, schema : {[any] : any})
    ValidateStreamName(name)

    Replicating.Player[name] = CreatePlayerStreamCatcher(name)

    SchemaCache[name] = schema

    Players.PlayerAdded:Connect(function(player)
        self:MakeStreamForPlayer(name, player, DataStreamUtils:DeepCopyTable(schema))
    end)

    Players.ChildRemoved:Connect(function(player)
        if player:IsA("Player") then
            RegisteredPlayers[player] = nil
            self:RemoveStreamForPlayer(name, player)
        end
    end)
end

-- Adds a schema to a specific player
function DataStream:MakeStreamForPlayer(name : string, player : Player, schema : {[any] : any})
    if RegisteredPlayers[player] and RegisteredPlayers[player][name] then
        return
    end

    if not Replicating.Player[name] then
        ValidateStreamName(name)
        Replicating.Player[name] = CreatePlayerStreamCatcher(name)
    end

    if not RegisteredPlayers[player] then
        RegisteredPlayers[player] = {}
    end
    RegisteredPlayers[player][name] = true

    local newDataStream = DataStreamMeta:MakeDataStreamObject(name, schema, player)
    SetStreamObjectToPlayer(name, player, newDataStream)

    DataStream.PlayerStreamAdded:Fire(name, player)

    return newDataStream
end

-- Removes a schema from a specific player
function DataStream:RemoveStreamForPlayer(name : string, player : Player)
    DataStream.PlayerStreamRemoving:Fire(name, player)

    if RegisteredPlayers[player] then
        RegisteredPlayers[player][name] = nil
    end

    --TODO: new deffered signals might make this a race condition.
    task.defer(function()
        SetStreamObjectToPlayer(name, player, nil)
    end)
end

-- Adds a schema whose data all players share.
function DataStream:MakeGlobalStream(name : string, schema : {[any] : any})
    ValidateStreamName(name)

    Replicating.Global[name] = DataStreamMeta:MakeDataStreamObject(name, schema)
end

function DataStream:GetPlayersWithSchema(name : string) : {Player}
    local globalStream = Replicating.Global[name]
    if globalStream then
        return Players:GetPlayers()
    end

    local playerStream = Replicating.Player[name]
    if not playerStream then
        error("Attempt to get players in non-existent schema '"..tostring(name).."'")
    end

    local metatable = getmetatable(playerStream)

    local toReturn = {}
    for playerIndex, _ in pairs(metatable._playerStreamCache) do
        local player = Players:GetPlayerByUserId(playerIndex)
        if player then
            table.insert(toReturn, player)
        end
    end
    return toReturn
end

--= Initializers =--
do
    for _, playerSchema in script.Schemas.Player:GetChildren() do
        if playerSchema:IsA("ModuleScript") then
            DataStream:AddPlayerStreamTemplate(playerSchema.Name, require(playerSchema))
        end
    end
    for _, globalSchema in script.Schemas.Global:GetChildren() do
        if globalSchema:IsA("ModuleScript") then
            DataStream:MakeGlobalStream(globalSchema.Name, require(globalSchema))
        end
    end

    GetDataFunction.OnServerInvoke = function(player, schemaName)
        DataStreamMeta:EnableReplicationForPlayer(player)
        local function makeReturnDataFromSchema(schema)
            local nonStringIndexes, valueForTransport = DataStreamMeta:GetNonStringIndexesFromValue(schema:Read())

            return {
                Data = valueForTransport,
                NonStringIndexes = nonStringIndexes
            }
        end

        if not schemaName then
            local toReturn = {}
            local playerIndex = DataStreamUtils.ResolvePlayerSchemaIndex(player)

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
                local playerIndex = DataStreamUtils.ResolvePlayerSchemaIndex(player)
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

--= Return Module =--
return setmetatable(DataStream, {
    __index = function(self, index)
        local replicatorTarget = Replicating.Global[index] or Replicating.Player[index]
        if replicatorTarget then
            return replicatorTarget
        else
            error("Attempt to index non-existent schema '"..tostring(index).."'")
        end
    end,
    __newindex = function(self, index, value)
        local replicatorTarget = Replicating.Global[index]
        if replicatorTarget then
            replicatorTarget:Write(value)
        else
            error("Attempt to index non-existent schema '"..tostring(index).."'")
        end

        return self
    end
})
