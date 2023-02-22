--[[
    TableReplicator.lua
    Stratiz
    Created on 11/30/2022 @ 03:13
    
    Description:
        No description provided.
    
    Documentation:
        No documentation provided.
--]]

--= Root =--
local TableReplicator = { }

--= Roblox Services =--
local Players = game:GetService("Players")

--= Dependencies =--
local TableReplicatorMeta = require(script:WaitForChild("TableReplicatorMeta"))
local TableReplicatorUtils = require(script:WaitForChild("TableReplicatorUtils"))

--= Object References =--

--= Constants =--

--= Variables =--
local GetData = TableReplicatorUtils.MakeRemote("Function", "GetData")
local Replicating = {
    Player = {},
    Global = {}
}

--= Internal Functions =--
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
    
    metatable.__newindex = function(self,Index,Value)
        local targetIndex = TableReplicatorUtils.ResolvePlayerSchemaIndex(Index)
        local targetPlayer = Players:GetPlayerByUserId(targetIndex)

        if targetPlayer then
            playerTableReplicatorCache[targetIndex] = Value
            if Value == nil then
                TableReplicatorMeta:TriggerReplicate(targetPlayer, name, "", Value)
            end
        else
            warn("Player not found for index: " .. targetIndex)
        end
        return self
    end
    
    metatable.__index = function(self, Index)
        local targetIndex = TableReplicatorUtils.ResolvePlayerSchemaIndex(Index)
        return playerTableReplicatorCache[targetIndex]
    end

    metatable.__tostring = function()
        return `PlayerReplicatorIndexCatcher ({name})`
    end

    metatable._playerReplicatorCache = playerTableReplicatorCache

    return proxy
end

--= API Functions =--
TableReplicator.PlayerReplicatorAdded = MakeSignal()
TableReplicator.PlayerReplicatorRemoving = MakeSignal()

function TableReplicator:AddPlayerReplicatorTemplate(name : string, schema : {[any] : any})
    ValidateReplicatorName(name)

    Replicating.Player[name] = CreatePlayerReplicatorCatcher(name)

    Players.PlayerAdded:Connect(function(player)
        self:MakeReplicatorForPlayer(name, player, TableReplicatorUtils:DeepCopyTable(schema))
    end)

    Players.PlayerRemoving:Connect(function(player)
        self:RemoveReplicatorForPlayer(name, player)
    end)
end

function TableReplicator:MakeReplicatorForPlayer(name : string, player : Player, schema : {[any] : any})

    if not Replicating.Player[name] then
        ValidateReplicatorName(name)
        Replicating.Player[name] = CreatePlayerReplicatorCatcher(name)
    end

    local playerIndex = TableReplicatorUtils.ResolvePlayerSchemaIndex(player)
    local newTableReplicator = TableReplicatorMeta:MakeTableReplicatorObject(name, schema, player)
    Replicating.Player[name][playerIndex] = newTableReplicator

    TableReplicator.PlayerReplicatorAdded:Fire(name, player)
    return newTableReplicator
end

function TableReplicator:RemoveReplicatorForPlayer(name : string, player : Player)
    local playerIndex = TableReplicatorUtils.ResolvePlayerSchemaIndex(player)

    TableReplicator.PlayerReplicatorRemoving:Fire(name, player)

    task.defer(function()
        Replicating.Player[name][playerIndex] = nil
    end)
end

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

    GetData.OnServerInvoke = function(player, schemaName)
        if not schemaName then
            local toReturn = {}
            local playerIndex = TableReplicatorUtils.ResolvePlayerSchemaIndex(player)

            for name, schema in pairs(Replicating.Player) do
                if schema[playerIndex] then
                    toReturn[name] = schema[playerIndex]:Read()
                end
            end

            for name, schema in pairs(Replicating.Global) do
                toReturn[name] = schema:Read()
            end

            return toReturn
        else
            if Replicating.Player[schemaName] then
                local playerIndex = TableReplicatorUtils.ResolvePlayerSchemaIndex(player)
                if Replicating.Player[schemaName][playerIndex] then
                    return Replicating.Player[schemaName][playerIndex]:Read()
                else
                    return nil
                end
            else
                return Replicating.Global[schemaName]:Read()
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