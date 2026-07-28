--[[
    DataStreamInstanceRefs.lua
    Stratiz

    Description:
        Tracks Instances referenced inside stream data so clients can resolve them
        even when they haven't replicated yet (deferred resolution, StreamingEnabled).

        The server stamps each referenced Instance with a persistent GUID attribute
        and a CollectionService tag. Both replicate with the Instance itself, so the
        client can build an id -> Instance map and notify listeners as instances
        appear, disappear, and stream back in.

--]]

--= Root =--
local DataStreamInstanceRefs = { }

--= Roblox Services =--
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

--= Constants =--

local ID_ATTRIBUTE = "_DS_RefId"
local TAG = "_DataStreamRef"

--= Variables =--

local IsServer = RunService:IsServer()

--= API Functions =--

DataStreamInstanceRefs.ID_ATTRIBUTE = ID_ATTRIBUTE

if IsServer then
    -- Returns the persistent ref id for an instance, assigning one on first use.
    function DataStreamInstanceRefs:GetId(instance : Instance) : string
        local id = instance:GetAttribute(ID_ATTRIBUTE)
        if type(id) ~= "string" then
            id = HttpService:GenerateGUID(false)
            instance:SetAttribute(ID_ATTRIBUTE, id)
            CollectionService:AddTag(instance, TAG)
        end
        return id :: string
    end
else
    local IdToInstance : {[string] : Instance} = {}
    local Listeners : {[string] : {[{}] : (Instance) -> ()}} = {}

    local function registerInstance(instance : Instance)
        local id = instance:GetAttribute(ID_ATTRIBUTE)
        if type(id) ~= "string" then
            -- The tag can replicate before the attribute; wait for it once.
            local connection
            connection = instance:GetAttributeChangedSignal(ID_ATTRIBUTE):Connect(function()
                connection:Disconnect()
                registerInstance(instance)
            end)
            return
        end

        IdToInstance[id] = instance

        local listeners = Listeners[id]
        if listeners then
            for _, callback in pairs(table.clone(listeners)) do
                task.spawn(callback, instance)
            end
        end
    end

    CollectionService:GetInstanceAddedSignal(TAG):Connect(registerInstance)
    CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(instance : Instance)
        local id = instance:GetAttribute(ID_ATTRIBUTE)
        if type(id) == "string" and IdToInstance[id] == instance then
            IdToInstance[id] = nil
        end
    end)
    for _, instance in CollectionService:GetTagged(TAG) do
        registerInstance(instance)
    end

    function DataStreamInstanceRefs:Resolve(id : string) : Instance?
        return IdToInstance[id]
    end

    -- Registers a persistent listener for an id. Fires immediately if the instance
    -- is already resolved, and again every time it (re)appears — instances that
    -- stream out and back in arrive as new client-side objects with the same id.
    -- Returns a cancel function.
    function DataStreamInstanceRefs:OnResolved(id : string, callback : (Instance) -> ()) : () -> ()
        local listeners = Listeners[id]
        if not listeners then
            listeners = {}
            Listeners[id] = listeners
        end

        local key = {}
        listeners[key] = callback

        local current = IdToInstance[id]
        if current then
            -- Deferred so a listener registered while an update is being applied
            -- runs after that update has fully landed in the data tree.
            task.defer(callback, current)
        end

        return function()
            local currentListeners = Listeners[id]
            if currentListeners then
                currentListeners[key] = nil
                if next(currentListeners) == nil then
                    Listeners[id] = nil
                end
            end
        end
    end
end

--= Return Module =--
return DataStreamInstanceRefs
