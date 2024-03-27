--[[
    DataStreamMeta.lua
    Stratiz
    Created on 06/28/2023 @ 02:29
    
    Description:
        Proxy system for data caching and replication.
    
--]]

--= Root =--
local DataMeta = { }

--= Roblox Services =--
local Players = game:GetService("Players")

--= Dependencies =--

local CONFIG = require(script.Parent.DataStreamServerConfig)
local Signal = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("DataStreamSignal"))
local DataStreamUtils = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("DataStreamUtils"))
local DataStreamRemotes = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("DataStreamRemotes"))

--= Object References =--

local DataUpdateEvent = DataStreamRemotes:Get("Event", "DataUpdate")

--= Constants =--

local METHODS = {
    ChildAdded = true,
    ChildRemoved = true,
    Read = true,
    Changed = true,
    Write = true
}

--= Variables =--

local SignalCache = {}

--= Internal Functions =--

local function BindChanged(name, ownerId, pathTable, callback)
    if not SignalCache[name] then
        SignalCache[name] = {}
    end

    if not SignalCache[name][ownerId] then
        SignalCache[name][ownerId] = {}
    end

    local currentCache = SignalCache[name][ownerId]
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

    local proxyMeta = {
        Disconnect = function()
            newConnection:Disconnect()
            currentSignalData.ConnectionCount -= 1
            if currentSignalData.ConnectionCount <= 0 then
                currentSignalData.Signal:Destroy()
                setmetatable(currentCache, nil)
            end
        end
    }
    proxyMeta.Destroy = proxyMeta.Disconnect

    local rbxSignalProxy = setmetatable(proxyMeta ,
        {__index = newConnection}
    )
    currentSignalData.ConnectionCount += 1
    return rbxSignalProxy :: RBXScriptConnection
end

local function MakeCatcherObject(oldMetaTable)
    local metaTable = DataStreamUtils:DeepCopyTable(oldMetaTable)
    metaTable.LastTable = oldMetaTable.LastTable

    local NewObject = newproxy(true)
    local ObjectMetaTable = getmetatable(NewObject)
    ObjectMetaTable.__tostring = function(dataObject)
        local CatcherMeta = getmetatable(dataObject)

        if CatcherMeta.MethodLocked == true then
            return "DataStreamObjectMethod (".. DataStreamUtils.StringifyPathTable(CatcherMeta.PathTable) ..")"
        else
            return "DataStreamObject (".. DataStreamUtils.StringifyPathTable(CatcherMeta.PathTable) ..")"
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

function TriggerPathChanged(name : string, ownerId : number, path : {string}, value : any, oldValue : any, rawData)
    local targetCache = SignalCache[name] and SignalCache[name][ownerId]

    if targetCache then
        local currentParent = targetCache
        local currentPath = {}

        local function childRecurse(targetChild, childPath, check)
            if check then
                local childSignalData = getmetatable(targetChild)

                if childSignalData then
                    childSignalData.Signal:Fire("Changed", GetValueFromPathTable(rawData, childPath))
                end
            end

            for index, child in targetChild do
                local newTable = table.clone(childPath)
                table.insert(newTable, index)

                childRecurse(child, newTable, true)
            end
        end

        local function checkAndTrigger()
            local signalData = getmetatable(currentParent)

            if signalData then
                signalData.Signal:Fire("Changed", GetValueFromPathTable(rawData, currentPath))
            end
        end

        -- Check if root changed
        checkAndTrigger()

        if #path == 0 then
            childRecurse(currentParent, currentPath, false)
            return
        end
        
        for depth, index in path do
            --// Handles the case when changed signals belong to children of the changed path
            table.insert(currentPath, index)

            -- Check for child added and removed
            local parentSignalData = getmetatable(currentParent)
            if parentSignalData and depth == #path then
                if value == nil then
                    parentSignalData.Signal:Fire("ChildRemoved", path[#path])
                elseif oldValue == nil then
                    parentSignalData.Signal:Fire("ChildAdded", path[#path])
                end
            end

            -- Check for changed
            local nextParent = currentParent[index]
            if nextParent then
                currentParent = nextParent
                
                if depth == #path then
                    childRecurse(currentParent, currentPath)
                end
                checkAndTrigger()
            else
                break
            end
        end
    end
end


--= API Functions =--

function DataMeta:GetNonStringIndexesFromValue(value : any) : {{Path : {string}, IndexValue : any}}
    local nonStringIndexes = {} -- Keep track of non-string indexes to fix them later after remote event encoding
    
    local function checkNonStringIndex(targetValue, targetPathTable)
        if type(targetValue) == "table" then
            local newTargetValue = {}
            for index, child in pairs(targetValue) do
                local newPathTable = table.clone(targetPathTable)
                if type(index) ~= "string" then
                    local indexAsString = tostring(index)

                    while targetValue[indexAsString] do
                        indexAsString ..= "_"
                    end

                    table.insert(newPathTable, indexAsString)
                    table.insert(nonStringIndexes, {
                        Path = newPathTable,
                        IndexValue = index
                    })

                    newTargetValue[indexAsString] = checkNonStringIndex(child, newPathTable)
                else
                    table.insert(newPathTable, index)
                    newTargetValue[index] = checkNonStringIndex(child, newPathTable)
                end
            end
            return newTargetValue
        end
        return targetValue
    end

    local newValue = checkNonStringIndex(value, {})
    return nonStringIndexes, newValue
end

function DataMeta:TriggerReplicate(owner, name, pathTable, value)
    local nonStringIndexes, valueForTransport = self:GetNonStringIndexesFromValue(DataStreamUtils:DeepCopyTable(value))

    if owner then
        DataUpdateEvent:FireClient(owner, name, pathTable, valueForTransport, nonStringIndexes)
    else
        DataUpdateEvent:FireAllClients(name, pathTable, valueForTransport, nonStringIndexes)
    end
end

function DataMeta:MakeDataStreamObject(name : string, rawData : {[any] : any}, owner : Player?)
    local function ReplicateData(pathTable : { string }, value : any)
        self:TriggerReplicate(owner, name, pathTable, value)
    end

    local function SetValueFromPath(pathTable : {string}, Value)
        if pathTable == nil or #pathTable <= 0 then
            local OldValue = DataStreamUtils:DeepCopyTable(rawData)

            table.clear(rawData)
            for key, newValue in Value do
                rawData[key] = newValue
            end 

            return OldValue
        else
            local LastStep = rawData
            for Index, PathFragment in ipairs(pathTable or {}) do
                if LastStep then
                    if Index == #pathTable then
                        local OldValue = LastStep[PathFragment]
                        LastStep[PathFragment] = Value
                        return OldValue
                    else
                        LastStep = LastStep[PathFragment]
                    end
                else
                    warn("Last step is nil", pathTable, PathFragment)
                    return Value
                end
            end
        end
    end

    --// Local helper functions
    local function internalChangedTrigger(meta, old, new, fromMethod : boolean)
        local ownerId = DataStreamUtils.ResolvePlayerSchemaIndex(meta.Owner and meta.Owner.UserId or 0)

        local pathTable = table.clone(meta.PathTable)
        if fromMethod then
            table.remove(pathTable, #pathTable)
        end

        TriggerPathChanged(name, ownerId, pathTable, new, old, rawData)
    end

    local RootCatcherMeta
    RootCatcherMeta = {
        PathTable = {},
        LastTable = rawData,
        LastIndex = nil,
        ValueType = type(rawData),
        MethodLocked = false,
        Owner = owner,
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

            local NextMetaTable = DataStreamUtils.CopyTable(CatcherMeta)
            NextMetaTable.PathTable = table.clone(CatcherMeta.PathTable)

            table.insert(NextMetaTable.PathTable, NextIndex)

            if (previousValue == nil or not isPreviousTable) and METHODS[NextIndex] then
                NextMetaTable.MethodLocked = true
            end

            if isPreviousTable then
                NextMetaTable.ValueType = type(previousValue[NextIndex])
            end

            NextMetaTable.LastIndex = NextIndex
            if not NextMetaTable.MethodLocked then
                NextMetaTable.LastTable = previousValue
            end

            return MakeCatcherObject(NextMetaTable)
        end,
        __newindex = function(dataObject,NextIndex,Value)

            local CatcherMeta = getmetatable(dataObject)
            local NextMetaTable = DataStreamUtils.CopyTable(CatcherMeta)
            NextMetaTable.PathTable = table.clone(CatcherMeta.PathTable)

            local OldValue = nil
            if NextMetaTable.FinalIndex then
                OldValue = NextMetaTable.LastTable[NextMetaTable.FinalIndex]
                NextMetaTable.LastTable[NextMetaTable.FinalIndex] = Value
            else
                table.insert(NextMetaTable.PathTable, NextIndex)
                OldValue = SetValueFromPath(NextMetaTable.PathTable, DataStreamUtils:DeepCopyTable(Value))
            end

            internalChangedTrigger(NextMetaTable,OldValue,Value, false)

            ReplicateData(NextMetaTable.PathTable, Value)
            return MakeCatcherObject(NextMetaTable)
        end,
        -- Support for +=, -=, *=, /=
        __add = function(dataObject, Value)
            local catcherMeta = getmetatable(dataObject)
            if catcherMeta.ValueType == "number" then
                return catcherMeta.LastTable[catcherMeta.LastIndex] + Value
            else
                error("Attempted to perform '+' (Addition) on " .. catcherMeta.ValueType, 2)
            end
        end,
        __sub = function(dataObject, Value)
            local catcherMeta = getmetatable(dataObject)
            if catcherMeta.ValueType == "number" then
                return catcherMeta.LastTable[catcherMeta.LastIndex] - Value
            else
                error("Attempted to perform '-' (Subtraction) on " .. catcherMeta.ValueType, 2)
            end
        end,
        __mul = function(dataObject, Value)
            local catcherMeta = getmetatable(dataObject)
            if catcherMeta.ValueType == "number" then
                return catcherMeta.LastTable[catcherMeta.LastIndex] * Value
            else
                error("Attempted to perform '*' (Multiplication) on " .. catcherMeta.ValueType, 2)
            end
        end,
        __div = function(dataObject, Value)
            local catcherMeta = getmetatable(dataObject)
            if catcherMeta.ValueType == "number" then
                return catcherMeta.LastTable[catcherMeta.LastIndex] / Value
            else
                error("Attempted to perform '/' (Division) on " .. catcherMeta.ValueType, 2)
            end
        end,
        __call = function(dataObject,self,...)
            local CatcherMeta = getmetatable(dataObject)
            local ownerId = DataStreamUtils.ResolvePlayerSchemaIndex(owner and owner.UserId or 0)
            local truePathTable = table.clone(CatcherMeta.PathTable)
            table.remove(truePathTable, #truePathTable)

            if CatcherMeta.LastIndex == "Read" then
                if not self then
                    warn("You should be calling Read() with : instead of .")
                end

                return DataStreamUtils:DeepCopyTable(GetValueFromPathTable(rawData, truePathTable))
            elseif CatcherMeta.LastIndex == "Write" then
                local value = table.pack(...)[1]

                local NextMetaTable = CatcherMeta
                local OldValue = nil
                if NextMetaTable.FinalIndex then
                    OldValue = NextMetaTable.LastTable[NextMetaTable.FinalIndex]
                    NextMetaTable.LastTable[NextMetaTable.FinalIndex] = value
                else
                    OldValue = SetValueFromPath(truePathTable, DataStreamUtils:DeepCopyTable(value))
                end

                internalChangedTrigger(NextMetaTable, OldValue, value, true)

                ReplicateData(truePathTable, value)
            elseif CatcherMeta.LastIndex == "Insert" then
                if CatcherMeta.FinalIndex then
                    error("Attempted to insert a value into a non-table value.")
                else
                    local OldTable = DataStreamUtils:DeepCopyTable(CatcherMeta.LastTable)
                    table.insert(CatcherMeta.LastTable, ...)
                    internalChangedTrigger(CatcherMeta, OldTable, CatcherMeta.LastTable, true)
                    ReplicateData(truePathTable, CatcherMeta.LastTable)
                end
            elseif CatcherMeta.LastIndex == "Remove" then
                if CatcherMeta.FinalIndex then
                    error("Attempted to remove a value from a non-table value.")
                else
                    local OldTable = DataStreamUtils:DeepCopyTable(CatcherMeta.LastTable)
                    table.remove(CatcherMeta.LastTable, ...)
                    internalChangedTrigger(CatcherMeta, OldTable, CatcherMeta.LastTable, true)
                    ReplicateData(truePathTable, CatcherMeta.LastTable)
                end
            elseif CatcherMeta.LastIndex == "Changed" then
                local callback = table.pack(...)[1]

                return BindChanged(name, ownerId, truePathTable, function(method, newValue, oldValue)
                    if method == CatcherMeta.LastIndex then
                        callback(newValue, oldValue)
                    end
                end)
            elseif CatcherMeta.LastIndex == "ChildAdded" or CatcherMeta.LastIndex == "ChildRemoved" then
                local callback = table.pack(...)[1]

                return BindChanged(name, ownerId, truePathTable, function(method, index)
                    if method == CatcherMeta.LastIndex then
                        callback(index)
                    end
                end)
            else
                error("Attempted to call a non-function value.",2)
            end
        end,
    }
    return MakeCatcherObject(RootCatcherMeta)
end

--= Initializers =--

do
    Players.PlayerRemoving:Connect(function(player)
        local TargetIndex = tostring(player.UserId)
        if TargetIndex and SignalCache[TargetIndex] then
            for _, pathSignalData in pairs(SignalCache[TargetIndex]) do
                for _, data in pairs(pathSignalData) do
                    data.Signal:Destroy()
                    for _, connection in pairs(data.Connections) do
                        connection:Disconnect()
                    end
                end
            end
            SignalCache[TargetIndex] = nil
        end
    end)
end

--= Return Module =--

return DataMeta