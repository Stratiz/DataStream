--[[
    Stream.lua
    Stratiz
    Created on 11/30/2022 @ 03:13
    
    Description:
        No description provided.
    
    Documentation:
        No documentation provided.
--]]

--= Root =--
local Stream = { }

--= Roblox Services =--
local Players = game:GetService("Players")

--= Dependencies =--
local StreamMeta = require(script:WaitForChild("StreamMeta"))
local StreamUtils = require(script:WaitForChild("StreamUtils"))

--= Object References =--

--= Constants =--

--= Variables =--
local GetData = StreamUtils.MakeRemote("Function", "GetData")
local Streams = {
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

local function deepCopy(target, _context)
	_context = _context or  {}
	if _context[target] then
		return _context[target]
	end

	if type(target) == "table" then
		local new = {}
		_context[target] = new
		for index, value in pairs(target) do
			new[deepCopy(index, _context)] = deepCopy(value, _context)
		end
		return setmetatable(new, deepCopy(getmetatable(target), _context))
	else
		return target
	end
end

local function validateStreamName(name : string)
    if Streams.Global[name] or Streams.Player[name] then
        error("Schema already exists with name: " .. name)
    end
    if Stream[name] then
        error("Schema cannot have the same name as a module method: " .. name)
    end
end

--= API Functions =--
Stream.PlayerStreamAdded = MakeSignal()
Stream.PlayerStreamRemoving = MakeSignal()

function Stream:AddPlayerStreamTemplate(name : string, schema : {[any] : any})
    validateStreamName(name)

    Streams.Player[name] = setmetatable({}, {
        __newindex = function(Table,Index,Value)
            --warn("Overwriting entire player data table! Are you really sure you should be doing this?")

            local targetIndex = StreamUtils.ResolvePlayerSchemaIndex(Index)
            local targetPlayer = Players:GetPlayerByUserId(targetIndex)
            if targetPlayer then
                rawset(Streams.Player[name], targetIndex, Value)
                StreamMeta:TriggerReplicate(targetPlayer,name,"",Value)
            else
                warn("Player not found for index: " .. targetIndex)
            end
            return Table
        end
    })
    Players.PlayerAdded:Connect(function(player)
        self:MakePlayerStream(name, player, deepCopy(schema))
    end)

    Players.PlayerRemoving:Connect(function(player)
        self:RemovePlayerStream(name, player)
    end)
end

function Stream:MakePlayerStream(name : string, player : Player, schema : {[any] : any})
    if not Streams.Player[name] then
        Streams.Player[name] = {}
    end

    local playerIndex = StreamUtils.ResolvePlayerSchemaIndex(player)
    local newStream = StreamMeta:MakeStreamObject(schema, player)
    Streams.Player[name][playerIndex] = newStream

    Stream.PlayerStreamAdded:Fire(name, player, newStream)
    return newStream
end

function Stream:RemovePlayerStream(name : string, player : Player)
    local playerIndex = StreamUtils.ResolvePlayerSchemaIndex(player)

    Stream.PlayerStreamRemoving:Fire(name, player, Streams.Player[name][playerIndex])

    Streams.Player[name][playerIndex] = nil
end

function Stream:MakeGlobalStream(name : string, schema : {[any] : any})
    validateStreamName(name)

    Streams.Global[name] = StreamMeta:MakeStreamObject(schema)
end

--= Initializers =--
do
    for _, playerSchema in script.Schemas.Player:GetChildren() do
        if playerSchema:IsA("ModuleScript") then
            Stream:AddPlayerStreamTemplate(playerSchema.Name, require(playerSchema))
        end
    end
    for _, globalSchema in script.Schemas.Global:GetChildren() do
        if globalSchema:IsA("ModuleScript") then
            Stream:MakeGlobalStream(globalSchema.Name, require(globalSchema))
        end
    end

    GetData.OnServerInvoke = function(player, schemaName)
        if not schemaName then
            local toReturn = {}
            local playerIndex = StreamUtils.ResolvePlayerSchemaIndex(player)

            for name, schema in pairs(Streams.Player) do
                if schema[playerIndex] then
                    toReturn[name] = schema[playerIndex]:Read()
                end
            end

            for name, schema in pairs(Streams.Global) do
                toReturn[name] = schema:Read()
            end

            return toReturn
        else
            if Streams.Player[schemaName] then
                local playerIndex = StreamUtils.ResolvePlayerSchemaIndex(player)
                if Streams.Player[schemaName][playerIndex] then
                    return Streams.Player[schemaName][playerIndex]:Read()
                else
                    return nil
                end
            else
                return Streams.Global[schemaName]:Read()
            end
        end
    end
end

--= Return Module =--
return setmetatable(Stream, {
    __index = function(self, index)
        local streamTarget = Streams.Global[index] or Streams.Player[index]
        if streamTarget then
            return streamTarget
        else
            error("Attempt to index non-existent schema '"..tostring(index).."'")
        end
    end
})