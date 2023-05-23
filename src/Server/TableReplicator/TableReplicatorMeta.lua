export type Signal = {
	Connect: (self : any, toExecute : (any) -> ()) -> RBXScriptConnection,
	Fire: (any),
	Wait: (self : any) -> any,
}

local Players = game:GetService("Players")
local DataMeta = {}
local SignalCache = {}

local TableReplicatorUtils = require(script.Parent:WaitForChild("TableReplicatorUtils")) ---@module TableReplicatorUtils

local DataUpdateEvent = TableReplicatorUtils.MakeRemote("Event", "DataUpdateEvent")

local function MakeSignal() : Signal
	local BindableEvent = Instance.new("BindableEvent")
	local Signal = {}
	function Signal:Connect(toExecute : (any) -> ()) : RBXScriptConnection
		return BindableEvent.Event:Connect(toExecute)
	end

	function Signal:Fire(... : any)
		BindableEvent:Fire(...)
	end

	function Signal:Wait() : any
		return BindableEvent.Event:Wait()
	end

    function Signal:Destroy()
        BindableEvent:Destroy()
    end

	return Signal
end

Players.PlayerRemoving:Connect(function(player)
    local TargetIndex = TableReplicatorUtils.ResolvePlayerSchemaIndex(player)
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

local function MakeCatcherObject(metaTable)
    local NewObject = newproxy(true)
    local ObjectMetaTable = getmetatable(NewObject)
    ObjectMetaTable.__tostring = function(dataObject)
        local CatcherMeta = getmetatable(dataObject)
        return "TableReplicatorObject ("..CatcherMeta.PathString..")"
    end
    for Index,Value in pairs(metaTable) do
        ObjectMetaTable[Index] = Value
    end
    return NewObject
end

function DataMeta:TriggerReplicate(owner, name, ...) 
    if owner then
        DataUpdateEvent:FireClient(owner, name, ...)
    else
        DataUpdateEvent:FireAllClients(name, ...)
    end
end

function DataMeta:MakeTableReplicatorObject(name : string, rawData : {[any] : any}, owner : Player?)
    local function ReplicateData(pathString, ...)
        --TODO: Finish converting to table based system instead of strings
        self:TriggerReplicate(owner, name, string.split(pathString, "."), ...)
    end

    local function SetValueFromPath(Path, Value)
        if Path == "" or Path == nil then
            local OldValue = TableReplicatorUtils:DeepCopyTable(rawData)

            table.clear(rawData)
            for key, newValue in Value do
                rawData[key] = newValue
            end 

            return OldValue
        else
            local PathTable = string.split(Path,".")
            local LastStep = rawData
            for Index, PathFragment in ipairs(PathTable or {}) do
                PathFragment = tonumber(PathFragment) or PathFragment
                if LastStep then
                    if Index == #PathTable then
                        local OldValue = LastStep[PathFragment]
                        LastStep[PathFragment] = Value
                        return OldValue
                    else
                        LastStep = LastStep[PathFragment]
                    end
                else
                    warn("Last step is nil", Path, PathFragment)
                    return Value
                end
            end
        end
    end

    --// Local helper functions
    local function TriggerChangedEvents(meta,old,new)
        local ownerId = TableReplicatorUtils.ResolvePlayerSchemaIndex(meta.Owner and meta.Owner.UserId or 0)

        if SignalCache[ownerId] and SignalCache[ownerId][name] then
            for path, data in pairs(SignalCache[ownerId][name]) do
                local StringStart, _ = string.find(meta.PathString, path)
                if StringStart == 1 or meta.PathString == path then
                    data.Signal:Fire(new, old, meta.PathString)
                end
            end
        end
    end

    local RootCatcherMeta
    RootCatcherMeta = {
        PathString = "",
        LastTable = rawData,
        LastIndex = nil,
        FinalIndex = nil,
        Owner = owner,
        --// Meta table made to catch and replicate changes
        __index = function(dataObject,NextIndex)
            local CatcherMeta = getmetatable(dataObject)
            if CatcherMeta.LastTable[NextIndex] ~= nil then
                local NextMetaTable = TableReplicatorUtils.CopyTable(CatcherMeta)
                if type(NextMetaTable.LastTable[NextIndex]) == "table" then
                    NextMetaTable.LastTable = NextMetaTable.LastTable[NextIndex]
                else
                    NextMetaTable.FinalIndex = NextIndex
                end
                NextMetaTable.PathString = NextMetaTable.PathString..(NextMetaTable.PathString ~= "" and "." or "")..NextIndex
                NextMetaTable.LastIndex = NextIndex
                return MakeCatcherObject(NextMetaTable)
            elseif NextIndex == "Read" or NextIndex == "Write" or NextIndex == "Insert" or NextIndex == "Remove" or NextIndex == "Changed" then
                local NextMetaTable = TableReplicatorUtils.CopyTable(CatcherMeta)
                NextMetaTable.LastIndex = NextIndex
                return MakeCatcherObject(NextMetaTable)
            else
                --warn("Invalid index")
            end
        end,
        __newindex = function(dataObject,NextIndex,Value)
            local CatcherMeta = getmetatable(dataObject)
            local NextMetaTable = TableReplicatorUtils.CopyTable(CatcherMeta)
            local OldValue = nil
            if NextMetaTable.FinalIndex then
                OldValue = NextMetaTable.LastTable[NextMetaTable.FinalIndex]
                NextMetaTable.LastTable[NextMetaTable.FinalIndex] = Value
            else
                NextMetaTable.PathString = NextMetaTable.PathString..(NextMetaTable.PathString ~= "" and "." or "")..NextIndex
                OldValue = SetValueFromPath(NextMetaTable.PathString, TableReplicatorUtils:DeepCopyTable(Value))
            end

            TriggerChangedEvents(NextMetaTable,OldValue,Value)

            ReplicateData(NextMetaTable.PathString,Value)
            return MakeCatcherObject(NextMetaTable)
        end,
        -- Support for +=, -=, *=, /=
        __add = function(dataObject, Value)
            local CatcherMeta = getmetatable(dataObject)
            if CatcherMeta.FinalIndex then
                return CatcherMeta.LastTable[CatcherMeta.FinalIndex] + Value
            else
                error("Attempted to perform '+' (Addition) on a table.",2)
            end
        end,
        __sub = function(dataObject, Value)
            local CatcherMeta = getmetatable(dataObject)
            if CatcherMeta.FinalIndex then
                return CatcherMeta.LastTable[CatcherMeta.FinalIndex] - Value
            else
                error("Attempted to perform '-' (Subtraction) on a table.",2)
            end
        end,
        __mul = function(dataObject, Value)
            local CatcherMeta = getmetatable(dataObject)
            if CatcherMeta.FinalIndex then
                return CatcherMeta.LastTable[CatcherMeta.FinalIndex] * Value
            else
                error("Attempted to perform '*' (Multiplication) on a table.",2)
            end
        end,
        __div = function(dataObject, Value)
            local CatcherMeta = getmetatable(dataObject)
            if CatcherMeta.FinalIndex then
                return CatcherMeta.LastTable[CatcherMeta.FinalIndex] / Value
            else
                error("Attempted to perform '/' (Division) on a table.",2)
            end
        end,
        __call = function(dataObject,self,...)
            local CatcherMeta = getmetatable(dataObject)
            if CatcherMeta.LastIndex == "Read" then
                local IsRaw = (...)
                if not self then
                    warn("You should be calling Read() with : instead of .")
                end
                if IsRaw then
                    if CatcherMeta.FinalIndex then
                        return dataObject
                    else
                        local RawTable = {} -- Maybe make a raw flag?
                        for Index, _ in CatcherMeta.LastTable do
                            RawTable[Index] = dataObject[Index]
                        end
                        return RawTable
                    end
                else

                    if CatcherMeta.FinalIndex then
                        return CatcherMeta.LastTable[CatcherMeta.FinalIndex]
                    else
                        return TableReplicatorUtils:DeepCopyTable(CatcherMeta.LastTable)
                    end
                end
            elseif CatcherMeta.LastIndex == "Write" then
                local value = table.pack(...)[1]

                local NextMetaTable = CatcherMeta
                local OldValue = nil
                if NextMetaTable.FinalIndex then
                    OldValue = NextMetaTable.LastTable[NextMetaTable.FinalIndex]
                    NextMetaTable.LastTable[NextMetaTable.FinalIndex] = value
                else
                    OldValue = SetValueFromPath(NextMetaTable.PathString, TableReplicatorUtils:DeepCopyTable(value))
                end

                TriggerChangedEvents(NextMetaTable, OldValue, value)

                ReplicateData(NextMetaTable.PathString, value)
            elseif CatcherMeta.LastIndex == "Insert" then
                if CatcherMeta.FinalIndex then
                    error("Attempted to insert a value into a non-table value.")
                else
                    local OldTable = TableReplicatorUtils:DeepCopyTable(CatcherMeta.LastTable)
                    table.insert(CatcherMeta.LastTable,...)
                    TriggerChangedEvents(CatcherMeta,OldTable,CatcherMeta.LastTable)
                    ReplicateData(CatcherMeta.PathString,CatcherMeta.LastTable)
                end
            elseif CatcherMeta.LastIndex == "Remove" then
                if CatcherMeta.FinalIndex then
                    error("Attempted to remove a value from a non-table value.")
                else
                    local OldTable = TableReplicatorUtils:DeepCopyTable(CatcherMeta.LastTable)
                    table.remove(CatcherMeta.LastTable,...)
                    TriggerChangedEvents(CatcherMeta,OldTable,CatcherMeta.LastTable)
                    ReplicateData(CatcherMeta.PathString,CatcherMeta.LastTable)
                end
            elseif CatcherMeta.LastIndex == "Changed" then
                local ownerId = TableReplicatorUtils.ResolvePlayerSchemaIndex(owner and owner.UserId or 0)
                if not SignalCache[ownerId] then
                    SignalCache[ownerId] = {}
                end
                if not SignalCache[ownerId][name] then
                    SignalCache[ownerId][name] = {}
                end

                local CurrentSignal = SignalCache[ownerId][name][CatcherMeta.PathString]
                if not CurrentSignal then
                    CurrentSignal = {Signal = MakeSignal(), Connections = {}}
                    SignalCache[ownerId][name][CatcherMeta.PathString] = CurrentSignal
                end
                local newConnection = CurrentSignal.Signal:Connect(...)
                table.insert(CurrentSignal.Connections, newConnection) --//TODO: BURN CONNECTION WHEN PLAYER IS CLEANED UP
                return newConnection
            else
                error("Attempted to call a non-function value.",2)
            end
        end,
    }
    return MakeCatcherObject(RootCatcherMeta)
end

return DataMeta
