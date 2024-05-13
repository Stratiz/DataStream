--[[
    ClientDataStreamMeta.lua
    Stratiz
    Created on 06/28/2023 @ 01:52
    
    Description:
        Provides functionality for the data proxy on the client for consistency.
    
--]]

--= Root =--

local ClientDataStreamMeta = { }

--= Roblox Services =--

--= Dependencies =--

local CONFIG = require(script.Parent.ClientDataStreamConfig)
local DataStreamUtils = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("DataStreamUtils"))
local Signal = require(CONFIG.SHARED_MODULES_LOCATION:WaitForChild("DataStreamSignal"))

--= Object References =--

--= Constants =--

local METHODS = {
    ChildAdded = true,
    ChildRemoved = true,
    Read = true,
    Changed = true
}

--= Variables =--

local SignalCache = {}

--= Internal Functions =--

local function MakeCatcherObject(metaTable)
    local NewObject = newproxy(true)
    local ObjectMetaTable = getmetatable(NewObject)
    ObjectMetaTable.__tostring = function(dataObject)
        local CatcherMeta = getmetatable(dataObject)

        if CatcherMeta.MethodLocked == true then
            return "DataStreamObjectMethod (".. DataStreamUtils.StringifyPathTable(CatcherMeta.PathTable)..")"
        else
            return "DataStreamObject (".. DataStreamUtils.StringifyPathTable(CatcherMeta.PathTable)..")"
        end
    end
    for Index,Value in pairs(metaTable) do
        ObjectMetaTable[Index] = Value
    end
    return NewObject
end

local function GetValueFromPathTable(rootTable, pathTable) : any?
    if type(rootTable) ~= "table" then
        return rootTable
    end
    
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

--= API Functions =--

function ClientDataStreamMeta:PathChanged(name : string, path : {string}, value : any, oldValue : any, rawData: {})
    local targetCache = SignalCache[name]

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
                    parentSignalData.Signal:Fire("ChildRemoved", path[#path], oldValue)
                elseif oldValue == nil then
                    parentSignalData.Signal:Fire("ChildAdded", path[#path], value)
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

function ClientDataStreamMeta:MakeDataStreamObject(name : string, rawData : {[string | number] : any})

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

            local NextMetaTable = DataStreamUtils.CopyTable(CatcherMeta)
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

                return DataStreamUtils:DeepCopyTable(GetValueFromPathTable(rawData, truePathTable))
            elseif CatcherMeta.LastIndex == "Changed" then
                local callback = table.pack(...)[1]

                return BindChanged(name, truePathTable, function(method, newValue)
                    if method == CatcherMeta.LastIndex then
                        callback(newValue)
                    end
                end)
            elseif CatcherMeta.LastIndex == "ChildAdded" or CatcherMeta.LastIndex == "ChildRemoved" then
                local callback = table.pack(...)[1]

                return BindChanged(name, truePathTable, function(method, index, value)
                    if method == CatcherMeta.LastIndex then
                        callback(index, value)
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

return ClientDataStreamMeta