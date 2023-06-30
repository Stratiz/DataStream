--[[
    ClientReplicatedTablesMeta.lua
    Stratiz
    Created on 06/28/2023 @ 01:52
    
    Description:
        No description provided.
    
--]]

--= Root =--
local ClientReplicatedTablesMeta = { }

--= Roblox Services =--

--= Dependencies =--

local CONFIG = require(script.Parent.ReplicatorClientConfig)
local ReplicatorUtils = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("ReplicatorUtils"))
local Signal = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("ReplicatorSignal"))

--= Object References =--

--= Constants =--

local METHODS = {
    ChildAdded = true,
    ChildRemoved = true,
    Read = true,
    Changed = true
}

--= Variables =--

local DataMeta = {}
local SignalCache = {}

--= Internal Functions =--

local function MakeCatcherObject(metaTable)
    local NewObject = newproxy(true)
    local ObjectMetaTable = getmetatable(NewObject)
    ObjectMetaTable.__tostring = function(dataObject)
        local CatcherMeta = getmetatable(dataObject)

        if CatcherMeta.MethodLocked == true then
            return "TableReplicatorObjectMethod (".. table.concat(CatcherMeta.PathTable, ".")..")"
        else
            return "TableReplicatorObject (".. table.concat(CatcherMeta.PathTable, ".")..")"
        end
    end
    for Index,Value in pairs(metaTable) do
        ObjectMetaTable[Index] = Value
    end
    return NewObject
end

local function GetValueFromPathTable(rootTable, pathTable) : any?
    local currentTarget = rootTable
    for _, index in pathTable do
        currentTarget = currentTarget[index]
        if type(currentTarget) ~= "table" then
            break
        end
    end
    return currentTarget
end

local function BindChanged(name, pathTable, callback)
    if not SignalCache[name] then
        SignalCache[name] = {}
    end

    local currentCache = SignalCache[name]
    for _, index in pathTable do
        if not currentCache[index] then
            currentCache[index] = {}
        end
        currentCache = currentCache[index]
    end

    local currentSignalData = getmetatable(currentCache)

    if not currentSignalData then
        currentSignalData = {
            Signal = Signal.new(),
            ConnectionCount = 0
        }
        setmetatable(currentCache, currentSignalData)
    end

    local newConnection = currentSignalData.Signal:Connect(callback)
    local rbxSignalProxy = setmetatable({
        Disconnect = function()
            newConnection:Disconnect()
            currentSignalData.ConnectionCount -= 1
            if currentSignalData.ConnectionCount <= 0 then
                currentSignalData.Signal:Destroy()
                setmetatable(currentCache, nil)
            end
        end},
        {__index = newConnection}
    )
    currentSignalData.ConnectionCount += 1
    return rbxSignalProxy :: RBXScriptConnection
end

--= API Functions =--

function DataMeta:PathChanged(name : string, path : {string}, value : any, oldValue : any)
    local targetCache = SignalCache[name]

    if targetCache then
        local currentParent = targetCache

        for _, index in path do
            local signalData = getmetatable(currentParent)

            if signalData then
                signalData.Signal:Fire("Changed", value, oldValue)
            end

            local nextParent = currentParent[index]
            if nextParent then
                local nextSignalData = getmetatable(nextParent)
                if nextSignalData then
                    if value == nil then
                        nextSignalData.Signal:Fire("ChildRemoved", index)
                    elseif oldValue == nil then
                        nextSignalData.Signal:Fire("ChildAdded", index)
                    end
                end
                currentParent = nextParent
            else
                break
            end
        end
    end
end

function DataMeta:MakeTableReplicatorObject(name : string, rawData : {[string | number] : any})

    local RootCatcherMeta
    RootCatcherMeta = {
        PathTable = {},
        LastTable = rawData,
        LastIndex = nil,
        MethodLocked = false,
        --// Meta table made to catch and replicate changes
        __index = function(dataObject, NextIndex)
            local CatcherMeta = getmetatable(dataObject)

            if CatcherMeta.MethodLocked then
                error("Attempted to index a method.", 2)
            end

            local previousValue = GetValueFromPathTable(rawData, CatcherMeta.PathTable)
            local isPreviousTable = type(previousValue) == "table"

            if not METHODS[NextIndex] then
                if previousValue == nil then
                    error("Attempted to index a nil value.", 2)
                elseif not isPreviousTable then
                    error("Attempted to index a non-table value.", 2)
                end
            end

            local NextMetaTable = ReplicatorUtils.CopyTable(CatcherMeta)
            NextMetaTable.PathTable = table.clone(CatcherMeta.PathTable)

            table.insert(NextMetaTable.PathTable, NextIndex)

            if (previousValue == nil or not isPreviousTable) and METHODS[NextIndex] then
                NextMetaTable.MethodLocked = true
            end
            NextMetaTable.LastIndex = NextIndex
            return MakeCatcherObject(NextMetaTable)
            
        end,
        __newindex = function()
            error("Attempted to write to a read-only table.", 2)
            return nil
        end,
        __call = function(dataObject, self, ...)


            local CatcherMeta = getmetatable(dataObject)
            local truePathTable = table.clone(CatcherMeta.PathTable)
            table.remove(truePathTable, #truePathTable)

            if CatcherMeta.LastIndex == "Read" then
                if not self then
                    warn("You should be calling Read() with : instead of .")
                end

                return ReplicatorUtils:DeepCopyTable(GetValueFromPathTable(rawData, truePathTable))
            elseif CatcherMeta.LastIndex == "Changed" then
                local callback = table.pack(...)[1]

                return BindChanged(name, truePathTable, function(_, newValue, oldValue)
                    callback(newValue, oldValue)
                end)
            elseif CatcherMeta.LastIndex == "ChildAdded" or CatcherMeta.LastIndex == "ChildRemoved" then
                local callback = table.pack(...)[1]

                return BindChanged(name, truePathTable, function(method, index)
                    if method == CatcherMeta.LastIndex then
                        callback(index)
                    end
                end)
            else
                error("Attempted to call a non-function value.", 2)
            end
        end,
    }
    return MakeCatcherObject(RootCatcherMeta)
end

--= Return Module =--

return DataMeta