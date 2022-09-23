local Players = game:GetService("Players")
local DataMeta = {}

local TableUtils = _G.require("Table")
local DataUtils = require(script.Parent.DataStreamUtils)
local GetRemoteEvent = _G.require("GetRemoteEvent")
local Signal = _G.require("Signal")

local DataUpdateEvent = GetRemoteEvent("DataUpdateEvent")

local function ReplicateData(UserID,...)
	local Player = Players:GetPlayerByUserId(UserID)
	if Player then
		DataUpdateEvent:FireClient(Player,...)
	end
end

local SignalCache = {}

Players.PlayerRemoving:Connect(function(player)
    local TargetIndex,_ = DataUtils.ResolveIndex(player)
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
        return "DataStreamObject ("..CatcherMeta.PathString..")"
    end
    for Index,Value in pairs(metaTable) do
        ObjectMetaTable[Index] = Value
    end
    return NewObject
end

function DataMeta.new(name : string, DataCache : {})

    local function SetValueFromPath(UserId,Path,Value)
        local TargetIndex = "DATA_"..UserId
        if DataCache[TargetIndex] then
            if Path == "" or Path == nil then
                local OldValue = DataCache[TargetIndex]
                DataCache[TargetIndex] = Value
                return OldValue
            else
                local PathTable = string.split(Path,".")
                local LastStep = DataCache[TargetIndex]
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
    end

    local PlayerDataMeta = {
        __index = function(_,Index)
            local TargetIndex,UserId = DataUtils.ResolveIndex(Index)
            if DataCache[TargetIndex] then
                --// Local helper functions
                local function TriggerChangedEvents(meta,old,new)
                    if SignalCache[TargetIndex] then
                        for FocusedPath, Signal in pairs(SignalCache[TargetIndex]) do
                            local StringStart,_ = string.find(meta.PathString, FocusedPath)
                            if StringStart == 1 or meta.PathString == FocusedPath then
                                Signal:Fire(new, old, meta.PathString)
                            end
                        end
                    end 
                end

                local RootCatcherMeta
                RootCatcherMeta = {
                    PathString = "",
                    LastTable = DataCache[TargetIndex],
                    LastIndex = TargetIndex,
                    FinalIndex = nil,
                    --// Meta table made to catch and replicate changes
                    __index = function(dataObject,NextIndex)
                        local CatcherMeta = getmetatable(dataObject)
                        if CatcherMeta.LastTable[NextIndex] ~= nil then
                            local NextMetaTable = TableUtils.copy(CatcherMeta)
                            if type(NextMetaTable.LastTable[NextIndex]) == "table" then
                                NextMetaTable.LastTable = NextMetaTable.LastTable[NextIndex]
                            else
                                NextMetaTable.FinalIndex = NextIndex
                            end
                            NextMetaTable.PathString = NextMetaTable.PathString..(NextMetaTable.PathString ~= "" and "." or "")..NextIndex
                            NextMetaTable.LastIndex = NextIndex
                            return MakeCatcherObject(NextMetaTable)
                        elseif NextIndex == "Read" or NextIndex == "Write" or NextIndex == "Insert" or NextIndex == "Remove" or NextIndex == "Changed" then
                            local NextMetaTable = TableUtils.copy(CatcherMeta)
                            NextMetaTable.LastIndex = NextIndex
                            return MakeCatcherObject(NextMetaTable)
                        else
                            --warn("Invalid index")
                        end
                    end,
                    __newindex = function(dataObject,NextIndex,Value)
                        local CatcherMeta = getmetatable(dataObject)
                        local NextMetaTable = TableUtils.copy(CatcherMeta)
                        local OldValue = nil
                        if NextMetaTable.FinalIndex then
                            OldValue = NextMetaTable.LastTable[NextMetaTable.FinalIndex]
                            NextMetaTable.LastTable[NextMetaTable.FinalIndex] = Value
                        else
                            NextMetaTable.PathString = NextMetaTable.PathString..(NextMetaTable.PathString ~= "" and "." or "")..NextIndex
                            OldValue = SetValueFromPath(UserId,NextMetaTable.PathString,TableUtils.deepCopy(Value))
                        end

                        TriggerChangedEvents(NextMetaTable,OldValue,Value)

                        ReplicateData(UserId,name,NextMetaTable.PathString,Value)
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
                                    return TableUtils.deepCopy(CatcherMeta.LastTable)
                                end
                            end
                        elseif CatcherMeta.LastIndex == "Write" then
                            -- TODO: Write for when the object is a varible and new index wont get triggered
                        elseif CatcherMeta.LastIndex == "Insert" then
                            if CatcherMeta.FinalIndex then
                                error("Attempted to insert a value into a non-table value.")
                            else
                                local OldTable = TableUtils.deepCopy(CatcherMeta.LastTable)
                                table.insert(CatcherMeta.LastTable,...)
                                TriggerChangedEvents(CatcherMeta,OldTable,CatcherMeta.LastTable)
                                ReplicateData(UserId,name,CatcherMeta.PathString,CatcherMeta.LastTable)
                            end
                        elseif CatcherMeta.LastIndex == "Remove" then
                            if CatcherMeta.FinalIndex then
                                error("Attempted to remove a value from a non-table value.")
                            else
                                local OldTable = TableUtils.deepCopy(CatcherMeta.LastTable)
                                table.remove(CatcherMeta.LastTable,...)
                                TriggerChangedEvents(CatcherMeta,OldTable,CatcherMeta.LastTable)
                                ReplicateData(UserId,name,CatcherMeta.PathString,CatcherMeta.LastTable)
                            end
                        elseif CatcherMeta.LastIndex == "Changed" then
                            if not SignalCache[TargetIndex] then
                                SignalCache[TargetIndex] = {}
                            end
                            local CurrentSignal = SignalCache[TargetIndex][CatcherMeta.PathString]
                            if not CurrentSignal then
                                CurrentSignal = Signal.new()
                                SignalCache[TargetIndex][CatcherMeta.PathString] = CurrentSignal
                            end
                            return CurrentSignal:Connect(...)
                        else
                            error("Attempted to call a non-function value.",2)
                        end
                    end,
                }
                return MakeCatcherObject(RootCatcherMeta)
            end
        end,
        __newindex = function(Table,Index,Value)
            warn("Overwriting entire player data table! Are you really sure you should be doing this?")
            
            local TargetIndex,UserId = DataUtils.ResolveIndex(Index)
            if DataCache[TargetIndex] then
                --PlayerData:WaitForLoad(UserId)
                DataCache[TargetIndex] = Value
                ReplicateData(UserId,name,"",Value)
            end
            return Table
        end
    }
    return MakeCatcherObject(PlayerDataMeta)

end

return DataMeta