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

--= Constants =--

local ID_ATTRIBUTE = "_DS_RefId"
local TAG = "_DataStreamRef"

--= Variables =--

local IsServer = RunService:IsServer()

--= API Functions =--

DataStreamInstanceRefs.ID_ATTRIBUTE = ID_ATTRIBUTE

if IsServer then
    local ID_CHARS = "0123456789abcdefghijklmnopqrstuvwxyz"

    local NextIdNumber = 0
    -- Weak values: entries disappear with their instances, and holding a strong
    -- reference here would keep dead instances alive forever.
    local IdToInstance = setmetatable({}, {__mode = "v"})

    -- Ids only need to be unique within one server session (attributes don't
    -- persist and every server re-stamps), so a base36 counter keeps them a few
    -- characters instead of a 36-character GUID on every wire payload.
    local function EncodeId(number : number) : string
        local encoded = ""
        repeat
            local remainder = number % 36
            encoded = string.sub(ID_CHARS, remainder + 1, remainder + 1) .. encoded
            number = math.floor(number / 36)
        until number == 0
        return encoded
    end

    -- Returns the ref id for an instance, assigning one on first use.
    function DataStreamInstanceRefs:GetId(instance : Instance) : string
        local id = instance:GetAttribute(ID_ATTRIBUTE)
        if type(id) == "string" and IdToInstance[id] == instance then
            return id
        end

        -- Either unstamped, or a Clone() carrying the attribute copied from its
        -- source instance — both need an id of their own.
        NextIdNumber += 1
        local newId = EncodeId(NextIdNumber)
        instance:SetAttribute(ID_ATTRIBUTE, newId)
        -- Registry before tag: the tag-added sanitizer below must see this
        -- instance as legitimate even if the signal fires synchronously.
        IdToInstance[newId] = instance
        CollectionService:AddTag(instance, TAG)
        return newId
    end

    -- Clone() copies attributes and tags, so a clone of a stamped instance that
    -- gets parented into the world carries a duplicate id. Strip the stamp from
    -- any tagged instance the registry doesn't recognize — the removal
    -- replicates, so clients never see the duplicate at all. (Clients also keep
    -- a first-registration-wins guard for client-side clones, which the server
    -- can't intercept.)
    local function SanitizeInstance(instance : Instance)
        local id = instance:GetAttribute(ID_ATTRIBUTE)
        if type(id) ~= "string" or IdToInstance[id] ~= instance then
            CollectionService:RemoveTag(instance, TAG)
            instance:SetAttribute(ID_ATTRIBUTE, nil)
        end
    end

    CollectionService:GetInstanceAddedSignal(TAG):Connect(SanitizeInstance)
    -- Stale stamps can also be baked into the place file (e.g. saved after a
    -- Studio test session); sweep whatever is already tagged at startup.
    for _, instance in CollectionService:GetTagged(TAG) do
        SanitizeInstance(instance)
    end
else
    local IdToInstance : {[string] : Instance} = {}
    local Listeners : {[string] : {[{}] : (Instance) -> ()}} = {}

    local function registerInstance(instance : Instance)
        -- The server sanitizer strips the stamp from unrecognized clones; when
        -- that removal replicates, the attribute-changed wait below re-enters
        -- here — bail instead of re-arming a wait that can never resolve.
        if not CollectionService:HasTag(instance, TAG) then
            return
        end

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

        local existing = IdToInstance[id]
        if existing ~= nil and existing ~= instance then
            -- Duplicate id, e.g. a Clone() of a stamped instance replicated before
            -- the server re-stamped it (or one never used in a stream). First
            -- registration wins.
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
