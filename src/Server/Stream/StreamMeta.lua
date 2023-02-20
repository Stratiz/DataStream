export type Signal = {
	Connect: (self : any, toExecute : (any) -> ()) -> RBXScriptConnection,
	Fire: (any),
	Wait: (self : any) -> any,
}

local Players = game:GetService("Players")
local DataMeta = {}
local SignalCache = {}

local StreamUtils = require(script.Parent:WaitForChild("StreamUtils")) ---@module StreamUtils

local DataUpdateEvent = StreamUtils.MakeRemote("Event", "DataUpdateEvent")

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

	return Signal
end

Players.PlayerRemoving:Connect(function(player)
    local TargetIndex,_ = StreamUtils.ResolvePlayerSchemaIndex(player)
    if TargetIndex then
        for _,Signal in pairs(SignalCache[TargetIndex]) do
            Signal:Destroy()
        end
        SignalCache[TargetIndex] = nil
    end
end)

local function MakeCatcherObject(metaTable)
    local NewObject = newproxy(true)
    local ObjectMetaTable = getmetatable(NewObject)
    ObjectMetaTable.__tostring = function(dataObject)
        local CatcherMeta = getmetatable(dataObject)
        return "StreamObject ("..CatcherMeta.PathString..")"
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

function DataMeta:MakeStreamObject(name : string, rawData : {[any] : any}, owner : Player?)
    local function ReplicateData(...)
        self:TriggerReplicate(owner, name, ...)
    end

    local function SetValueFromPath(UserId, Path, Value)
        if Path == "" or Path == nil then
            local OldValue = rawData
            rawData = Value
            return OldValue
        else
            local PathTable = string.split(Path,".")
            local LastStep = rawData
            for Index,PathFragment in ipairs(PathTable or {}) do
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
                    warn("Last step is nil",Path,PathFragment)
                    return Value
                end
            end
        end
    end

    --// Local helper functions
    local function TriggerChangedEvents(meta,old,new)
        local ownerId = StreamUtils.ResolvePlayerSchemaIndex(meta.Owner and meta.Owner.UserId or 0)
        if SignalCache[ownerId] then
            for FocusedPath, signalData in pairs(SignalCache[ownerId]) do --//TODO: check this with one on client, might be flipped client is correct
                local StringStart, _ = string.find(meta.PathString, FocusedPath)
                if StringStart == 1 or meta.PathString == FocusedPath then
                    signalData.Signal:Fire(new, old, meta.PathString)
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
        --// Meta table made to catch and replicate changes
        __index = function(dataObject,NextIndex)
            local CatcherMeta = getmetatable(dataObject)
            if CatcherMeta.LastTable[NextIndex] ~= nil then
                local NextMetaTable = StreamUtils.CopyTable(CatcherMeta)
                if type(NextMetaTable.ListTable[NextIndex]) == "table" then
                    NextMetaTable.LastTable = NextMetaTable.LastTable[NextIndex]
                else
                    NextMetaTable.FinalIndex = NextIndex
                end
                NextMetaTable.PathString = NextMetaTable.PathString..(NextMetaTable.PathString ~= "" and "." or "")..NextIndex
                NextMetaTable.LastIndex = NextIndex
                return MakeCatcherObject(NextMetaTable)
            elseif NextIndex == "Read" or NextIndex == "Write" or NextIndex == "Insert" or NextIndex == "Remove" or NextIndex == "Changed" then
                local NextMetaTable = StreamUtils.CopyTable(CatcherMeta)
                NextMetaTable.LastIndex = NextIndex
                return MakeCatcherObject(NextMetaTable)
            else
                --warn("Invalid index")
            end
        end,
        __newindex = function(dataObject,NextIndex,Value)
            local CatcherMeta = getmetatable(dataObject)
            local NextMetaTable = StreamUtils.CopyTable(CatcherMeta)
            local OldValue = nil
            if NextMetaTable.FinalIndex then
                OldValue = NextMetaTable.LastTable[NextMetaTable.FinalIndex]
                NextMetaTable.LastTable[NextMetaTable.FinalIndex] = Value
            else
                NextMetaTable.PathString = NextMetaTable.PathString..(NextMetaTable.PathString ~= "" and "." or "")..NextIndex
                OldValue = SetValueFromPath(NextMetaTable.PathString, StreamUtils:DeepCopyTable(Value))
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
                        return StreamUtils:DeepCopyTable(CatcherMeta.LastTable)
                    end
                end
            elseif CatcherMeta.LastIndex == "Write" then
                -- TODO: Write for when the object is a varible and new index wont get triggered
            elseif CatcherMeta.LastIndex == "Insert" then
                if CatcherMeta.FinalIndex then
                    error("Attempted to insert a value into a non-table value.")
                else
                    local OldTable = StreamUtils:DeepCopyTable(CatcherMeta.LastTable)
                    table.insert(CatcherMeta.LastTable,...)
                    TriggerChangedEvents(CatcherMeta,OldTable,CatcherMeta.LastTable)
                    ReplicateData(CatcherMeta.PathString,CatcherMeta.LastTable)
                end
            elseif CatcherMeta.LastIndex == "Remove" then
                if CatcherMeta.FinalIndex then
                    error("Attempted to remove a value from a non-table value.")
                else
                    local OldTable = StreamUtils:DeepCopyTable(CatcherMeta.LastTable)
                    table.remove(CatcherMeta.LastTable,...)
                    TriggerChangedEvents(CatcherMeta,OldTable,CatcherMeta.LastTable)
                    ReplicateData(CatcherMeta.PathString,CatcherMeta.LastTable)
                end
            elseif CatcherMeta.LastIndex == "Changed" then
                local ownerId = StreamUtils.ResolvePlayerSchemaIndex(owner and owner.UserId or 0)
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
