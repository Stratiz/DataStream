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

local DataStreamMeta = require(script:WaitForChild("DataStreamMeta"))
local Signal = require(script.Parent:WaitForChild("Packages"):WaitForChild("Signal"))
local DataStreamUtils = require(script.Parent.Shared:WaitForChild("DataStreamUtils"))
local StreamRemotes = require(script.Parent.Shared:WaitForChild("DataStreamRemotes"))

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

--= Constants =--

local SCHEMA_WAIT_WARN_SECONDS = 5

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
                -- MakeDataStreamObject deep-copies the schema, so the template can be passed directly.
                DataStream:MakeStreamForPlayer(name, targetPlayer, SchemaCache[name])
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

-- Yields until the schema is registered, WaitForChild-style (warns if it takes
-- suspiciously long, e.g. a typo'd name, but keeps waiting). Use this when
-- another script registers the schema and load order isn't guaranteed —
-- metamethods cannot yield, so plain DataStream[name] access errors instead of
-- waiting when the schema doesn't exist yet.
function DataStream:WaitForSchema(name : string)
    local replicatorTarget = Replicating.Global[name] or Replicating.Player[name]

    local startTime = os.clock()
    local warned = false
    while not replicatorTarget do
        task.wait()
        replicatorTarget = Replicating.Global[name] or Replicating.Player[name]

        if not replicatorTarget and not warned and os.clock() - startTime >= SCHEMA_WAIT_WARN_SECONDS then
            warned = true
            warn("Infinite yield possible waiting for schema '" .. tostring(name)
                .. "'. Register it with MakeGlobalStream or AddPlayerStreamTemplate on a server script without yielding.")
        end
    end

    return replicatorTarget
end

-- Adds a new schema to be a default replicator which is unique to each player
function DataStream:AddPlayerStreamTemplate(name : string, schema : {[any] : any})
    ValidateStreamName(name)

    Replicating.Player[name] = CreatePlayerStreamCatcher(name)

    SchemaCache[name] = schema

    Players.PlayerAdded:Connect(function(player)
        self:MakeStreamForPlayer(name, player, schema)
    end)

    -- Cover players who joined before this template was registered.
    for _, player in Players:GetPlayers() do
        self:MakeStreamForPlayer(name, player, schema)
    end

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

    -- If this player's client already fetched (stream created after join, e.g. lazy
    -- or late registration), push the root as a baseline. Gated internally on the
    -- client having called GetData, so this is a no-op during normal boot.
    DataStreamMeta:TriggerReplicate(player, name, {}, newDataStream:Read())

    DataStream.PlayerStreamAdded:Fire(name, player)

    return newDataStream
end

-- Removes a schema from a specific player
function DataStream:RemoveStreamForPlayer(name : string, player : Player)
    DataStream.PlayerStreamRemoving:Fire(name, player)

    if RegisteredPlayers[player] then
        RegisteredPlayers[player][name] = nil
        -- Prune the per-player table once empty: it's keyed by the Player
        -- instance and would otherwise pin departed players in memory when
        -- streams are managed manually (without AddPlayerStreamTemplate).
        if next(RegisteredPlayers[player]) == nil then
            RegisteredPlayers[player] = nil
        end
    end

    -- Capture the exact stream we're removing. If the same UserId rejoins before this deferred
    -- cleanup runs, MakeStreamForPlayer will have already replaced this cache entry with a fresh
    -- stream. Clearing it anyway would leave the rejoining player with no schema (GetData returns
    -- nothing for it and the client errors indexing the nil root), so only clear the cache when it
    -- still holds the stream we set out to remove.
    local target = Replicating.Player[name]
    local playerIndex = DataStreamUtils.ResolvePlayerSchemaIndex(player)
    local removingStream = if target and playerIndex then getmetatable(target)._playerStreamCache[playerIndex] else nil

    task.defer(function()
        if removingStream and getmetatable(target)._playerStreamCache[playerIndex] == removingStream then
            SetStreamObjectToPlayer(name, player, nil)
        end
    end)
end

-- Adds a schema whose data all players share.
function DataStream:MakeGlobalStream(name : string, schema : {[any] : any})
    ValidateStreamName(name)

    Replicating.Global[name] = DataStreamMeta:MakeDataStreamObject(name, schema)

    -- Baseline for clients that fetched before this stream was registered.
    -- Clients that haven't fetched yet queue this root update and apply it after
    -- their fetch, so it is never lost and never applied out of order.
    DataStreamMeta:TriggerReplicate(nil, name, {}, Replicating.Global[name]:Read())
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
    GetDataFunction.OnServerInvoke = function(player, schemaName)
        DataStreamMeta:EnableReplicationForPlayer(player)
        -- Seq marks which updates this snapshot already contains, so the client
        -- can drop queued/in-flight updates that are already baked in.
        local function makeReturnDataFromSchema(schema, name, ownerPlayer)
            local repairs, valueForTransport = DataStreamMeta:PrepareValueForTransport(schema:Read())

            return {
                Data = valueForTransport,
                Repairs = repairs,
                Seq = DataStreamMeta:GetSequence(name, ownerPlayer)
            }
        end

        if not schemaName then
            local toReturn = {}
            local playerIndex = DataStreamUtils.ResolvePlayerSchemaIndex(player)

            for name, schema in pairs(Replicating.Player) do
                if schema[playerIndex] then
                    toReturn[name] = makeReturnDataFromSchema(schema[playerIndex], name, player)
                end
            end

            for name, schema in pairs(Replicating.Global) do
                toReturn[name] = makeReturnDataFromSchema(schema, name, nil)
            end

            return toReturn
        else
            if Replicating.Player[schemaName] then
                local playerIndex = DataStreamUtils.ResolvePlayerSchemaIndex(player)
                if Replicating.Player[schemaName][playerIndex] then
                    return makeReturnDataFromSchema(Replicating.Player[schemaName][playerIndex], schemaName, player)
                else
                    return nil
                end
            else
                return makeReturnDataFromSchema(Replicating.Global[schemaName], schemaName, nil)
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
            error("Attempt to index non-existent schema '"..tostring(index).."'. If it registers later, use DataStream:WaitForSchema().")
        end
    end,
    __newindex = function(self, index, value)
        local replicatorTarget = Replicating.Global[index]
        if replicatorTarget then
            replicatorTarget:Write(value)
        elseif Replicating.Player[index] then
            error("Attempt to write to the root of player schema '"..tostring(index).."'. Index a player first.")
        else
            error("Attempt to index non-existent schema '"..tostring(index).."'. If it registers later, use DataStream:WaitForSchema().")
        end

        return self
    end
})
