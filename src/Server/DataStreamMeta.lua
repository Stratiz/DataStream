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

local Signal = require(script.Parent.Parent:WaitForChild("Packages"):WaitForChild("Signal"))
local DataStreamUtils = require(script.Parent.Parent.Shared:WaitForChild("DataStreamUtils"))
local DataStreamRemotes = require(script.Parent.Parent.Shared:WaitForChild("DataStreamRemotes"))
local DataStreamInstanceRefs = require(script.Parent.Parent.Shared:WaitForChild("DataStreamInstanceRefs"))
local DataStreamWire = require(script.Parent.Parent.Shared:WaitForChild("DataStreamWire"))
local DataStreamPathIds = require(script.Parent:WaitForChild("DataStreamPathIds"))

--= Object References =--

--= Constants =--

local METHODS = {
    ChildAdded = true,
    ChildRemoved = true,
    Read = true,
    Changed = true,
    Write = true
}

--= Types =--
type DataStreamMethodObject = {
    Read : (self : any) -> any,
    Write : (self : any, value : any) -> (),
    ChildAdded : (self : any, callback : (index : any, value : any) -> ()) -> RBXScriptConnection,
    ChildRemoved : (self : any, callback : (index : any, value : any) -> ()) -> RBXScriptConnection,
    Changed : (self : any, callback : (newValue : any, oldValue : any) -> ()) -> RBXScriptConnection,
}

type DataStreamObject = DataStreamMethodObject & {
    [any] : DataStreamObject,
}

--= Variables =--

local SignalCache = {}
local ReplicatingToPlayers = {}

--= Internal Functions =--

-- Removes now-empty signal tree nodes after a full disconnect. Without this,
-- every path ever listened to leaves its node chain behind — including nodes
-- keyed by Instances, which would pin destroyed instances in memory.
local function PruneSignalNodes(name, ownerId, pathTable)
    local ownerCache = SignalCache[name] and SignalCache[name][ownerId]
    if not ownerCache then
        return
    end

    local chain = {ownerCache}
    for depth, index in pathTable do
        local nextNode = chain[depth][index]
        if not nextNode then
            break
        end
        chain[depth + 1] = nextNode
    end

    for depth = #chain - 1, 1, -1 do
        local node = chain[depth + 1]
        if next(node) == nil and getmetatable(node) == nil then
            chain[depth][pathTable[depth]] = nil
        else
            break
        end
    end

    if next(ownerCache) == nil and getmetatable(ownerCache) == nil then
        SignalCache[name][ownerId] = nil
        if next(SignalCache[name]) == nil then
            SignalCache[name] = nil
        end
    end
end

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
                PruneSignalNodes(name, ownerId, pathTable)
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
    local metaTable = DataStreamUtils.CopyTable(oldMetaTable)

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

-- Reconstructs a frozen snapshot of the entire pre-write tree from the old value
-- at the written path. Cheap under copy-on-write: everything outside the written
-- branch is shared by reference, so this costs #path shallow clones — and it is
-- what lets Changed signals report an accurate oldValue at every depth.
local function BuildOldRootSnapshot(rawData, pathTable, oldLeafValue)
    if #pathTable == 0 then
        return oldLeafValue
    end

    local parents = {rawData}
    for index = 1, #pathTable - 1 do
        local nextNode = parents[index][pathTable[index]]
        if type(nextNode) ~= "table" then
            return nil
        end
        parents[index + 1] = nextNode
    end

    local oldNode = oldLeafValue
    for index = #pathTable, 1, -1 do
        local snapshot = table.clone(parents[index])
        snapshot[pathTable[index]] = oldNode
        table.freeze(snapshot)
        oldNode = snapshot
    end
    return oldNode
end

function TriggerPathChanged(name : string, ownerId : number, path : {string}, value : any, oldValue : any, rawData)
    local targetCache = SignalCache[name] and SignalCache[name][ownerId]

    if targetCache then
        local currentParent = targetCache
        local currentPath = {}

        local oldRoot = BuildOldRootSnapshot(rawData, path, oldValue)
        local function getOldValue(atPath)
            if oldRoot == nil then
                return nil
            end
            return GetValueFromPathTable(oldRoot, atPath)
        end

        local function childRecurse(targetChild, childPath, check)
            if check then
                local childSignalData = getmetatable(targetChild)

                if childSignalData then
                    childSignalData.Signal:Fire("Changed", GetValueFromPathTable(rawData, childPath), getOldValue(childPath))
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
                signalData.Signal:Fire("Changed", GetValueFromPathTable(rawData, currentPath), getOldValue(currentPath))
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


--= API Functions =--

-- Rebuilds a value into a remote-safe transport table plus a repair list the
-- client applies after deserialization. Repair entries are positional arrays to
-- keep the wire lean:
--   [1] kind: "V" Instance value | "K" Instance key | "I" other non-string key
--   [2] path fragments (placeholders as shipped in the transport table)
--   [3] "V"/"K": ref id; "I": the original key value
--   [4] "V"/"K": the Instance (arrives nil on the client iff not replicated yet;
--       the ref id lets the client resolve it later)
-- Kinds:
--   "V" -> Instance value stripped from the transport table; the repair entry is
--          the source of truth
--   "K" -> Instance key moved to a unique placeholder ("\1" .. refId), so two
--          same-named instances can never collide
--   "I" -> non-string, non-Instance key moved to a unique placeholder ("\2" .. n)
-- Dense arrays keep their numeric keys as-is (the serializer handles them
-- faithfully), so they don't generate per-element repair entries — unless
-- stripping an Instance element would leave a hole (see below).
function DataMeta:PrepareValueForTransport(value : any) : ({{any}}, any)
    local repairs = {}
    local placeholderCounter = 0

    local function isDenseArray(targetValue : {[any] : any}) : boolean
        local arrayLength = #targetValue
        local keyCount = 0
        for index in pairs(targetValue) do
            keyCount += 1
            if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > arrayLength then
                return false
            end
        end
        if keyCount ~= arrayLength then
            return false
        end

        -- Instance elements are stripped to nil (their "V" repair restores
        -- them), so one followed by a non-Instance element would ship an array
        -- with a hole, which remotes don't carry intact. Such arrays take the
        -- keyed path below. Trailing Instances (or all-Instance arrays) are fine.
        local sawInstance = false
        for _, child in ipairs(targetValue) do
            if typeof(child) == "Instance" then
                sawInstance = true
            elseif sawInstance then
                return false
            end
        end
        return true
    end

    local function walk(targetValue, targetPathTable)
        if typeof(targetValue) == "Instance" then
            table.insert(repairs, {
                "V",
                table.clone(targetPathTable),
                DataStreamInstanceRefs:GetId(targetValue),
                targetValue,
            })
            return nil
        elseif type(targetValue) ~= "table" then
            return targetValue
        end

        local newTargetValue = {}

        if isDenseArray(targetValue) then
            for index, child in ipairs(targetValue) do
                local newPathTable = table.clone(targetPathTable)
                table.insert(newPathTable, index)
                newTargetValue[index] = walk(child, newPathTable)
            end
            return newTargetValue
        end

        for index, child in pairs(targetValue) do
            local newPathTable = table.clone(targetPathTable)

            if type(index) == "string" then
                table.insert(newPathTable, index)
                newTargetValue[index] = walk(child, newPathTable)
            elseif typeof(index) == "Instance" then
                local refId = DataStreamInstanceRefs:GetId(index)
                local placeholder = "\1" .. refId

                table.insert(newPathTable, placeholder)
                table.insert(repairs, {
                    "K",
                    newPathTable,
                    refId,
                    index,
                })
                newTargetValue[placeholder] = walk(child, newPathTable)
            else
                placeholderCounter += 1
                local placeholder = "\2" .. placeholderCounter

                table.insert(newPathTable, placeholder)
                table.insert(repairs, {
                    "I",
                    newPathTable,
                    index,
                })
                newTargetValue[placeholder] = walk(child, newPathTable)
            end
        end
        return newTargetValue
    end

    local newValue = walk(value, {})
    return repairs, newValue
end

-- Path fragments can themselves be Instance keys (a write nested under an
-- instance-keyed entry). Encode those as {refId, instance} so the client can
-- resolve them by ref id instead of receiving a bare nil for unreplicated
-- instances. Real path fragments are never tables, so a table fragment is
-- unambiguously an encoded ref.
local function EncodePathForTransport(pathTable : {any}) : {any}
    local encoded = table.clone(pathTable)
    for index, fragment in encoded do
        if typeof(fragment) == "Instance" then
            encoded[index] = {DataStreamInstanceRefs:GetId(fragment), fragment}
        end
    end
    return encoded
end

function DataMeta:EnableReplicationForPlayer(player : Player)
    ReplicatingToPlayers[player] = true
end

--// Replication queue --------------------------------------------------------
-- Writes are coalesced per resumption cycle instead of firing a remote each:
-- a plain set supersedes any queued write at the same or a descendant path,
-- back to the last array op above it (its frozen snapshot already contains
-- that state), so rapid-fire writes to one path ship once. What's left goes
-- out as one batch per stream per flush
-- (see DataStreamWire). Every update carries a per-stream sequence number, and
-- GetData snapshots report the sequence they contain — that lets clients drop
-- updates already baked into a snapshot, which matters because array ops (see
-- Insert/Remove) are not idempotent the way set-writes are.

local ReplicationQueue = {}
local FlushScheduled = false
-- Both keyed by stream key, so they outlive the stream object: a player stream
-- removed and re-made keeps counting where it left off, and clients never see
-- a sequence number or path id reused.
local SequenceCounters = {}
local PathDictionaries = {}

local function GetStreamKey(name : string, owner : Player?) : string
    return name .. "\0" .. (if owner then tostring(owner.UserId) else "")
end

local function GetPathDictionary(streamKey : string) : DataStreamPathIds.Dictionary
    local dictionary = PathDictionaries[streamKey]
    if not dictionary then
        dictionary = DataStreamPathIds.new()
        PathDictionaries[streamKey] = dictionary
    end
    return dictionary
end

local function IsPathPrefixOf(prefix : {any}, pathTable : {any}) : boolean
    if #prefix > #pathTable then
        return false
    end
    for index, fragment in prefix do
        if pathTable[index] ~= fragment then
            return false
        end
    end
    return true
end

function DataMeta:GetSequence(name : string, owner : Player?) : number
    return SequenceCounters[GetStreamKey(name, owner)] or 0
end

-- The stream's live path ids, for GetData snapshots. Clients that join (or
-- re-sync) after an id was defined learn it from here.
function DataMeta:GetPathSnapshot(name : string, owner : Player?) : {any}
    return DataStreamPathIds.Snapshot(GetPathDictionary(GetStreamKey(name, owner)))
end

-- Packs one stream's queued entries into a batch (layout in DataStreamWire).
-- Ids are assigned and freed here, at send time, never at write time:
-- coalescing can drop a queued entry, and a define riding on it would be lost.
local function EncodeBatch(pathIds : DataStreamPathIds.Dictionary, entries) : (buffer, {any}?)
    local writer = DataStreamWire.NewWriter()
    local items = {}
    local previousSeq = 0

    for _, entry in entries do
        local pathTable, value, op = entry.PathTable, entry.Value, entry.Op
        local isRoot = #pathTable == 0
        local flags
        local pathId = nil

        if isRoot then
            flags = DataStreamWire.PATH_ROOT
        else
            local isNew = false
            if op == nil and value == nil then
                -- A removal never defines: the id would be freed right after.
                pathId = DataStreamPathIds.Lookup(pathIds, pathTable)
            else
                pathId, isNew = DataStreamPathIds.Intern(pathIds, pathTable)
            end

            if pathId == nil then
                flags = DataStreamWire.PATH_INLINE
                table.insert(items, EncodePathForTransport(pathTable))
            elseif isNew then
                -- Interned paths hold only string/number keys; no encoding needed.
                flags = DataStreamWire.PATH_DEFINE
                table.insert(items, pathTable)
            else
                flags = DataStreamWire.PATH_BY_ID
            end
        end

        local repairs, valueForTransport = DataMeta:PrepareValueForTransport(value)
        if #repairs > 0 then
            flags += DataStreamWire.HAS_REPAIRS
            table.insert(items, repairs)
        end
        if valueForTransport ~= nil then
            flags += DataStreamWire.HAS_VALUE
            table.insert(items, valueForTransport)
        end

        if op then
            flags += if op[1] == "i" then DataStreamWire.OP_INSERT else DataStreamWire.OP_REMOVE
        end

        -- Free what this entry removed. Clients apply frees after the update,
        -- so the entry can still use its own id.
        local frees = nil
        if op == nil then
            if isRoot and type(value) ~= "table" then
                DataStreamPathIds.Reset(pathIds)
                flags += DataStreamWire.CLEAR_PATHS
            else
                frees = DataStreamPathIds.FreeStale(pathIds, pathTable, value)
            end
        elseif op[1] == "r" then
            frees = DataStreamPathIds.FreeArrayTail(pathIds, pathTable, op[3])
        end
        if frees then
            flags += DataStreamWire.HAS_FREES
        end

        DataStreamWire.WriteVarint(writer, entry.Seq - previousSeq)
        previousSeq = entry.Seq
        DataStreamWire.WriteU8(writer, flags)
        if pathId then
            DataStreamWire.WriteVarint(writer, pathId)
        end
        if op then
            DataStreamWire.WriteVarint(writer, op[2])
        end
        if frees then
            DataStreamWire.WriteVarint(writer, #frees)
            for _, id in frees do
                DataStreamWire.WriteVarint(writer, id)
            end
        end
    end

    return DataStreamWire.Finish(writer), if #items > 0 then items else nil
end

-- entries all belong to one stream, in queue order.
local function SendBatch(streamKey : string, entries)
    local name, owner = entries[1].Name, entries[1].Owner

    if owner and not ReplicatingToPlayers[owner] then
        -- Nothing reaches a player before their first GetData, so their
        -- dictionary stays empty until then, matching the snapshot they fetch.
        return
    end

    local header, items = EncodeBatch(GetPathDictionary(streamKey), entries)

    local targetEvent = DataStreamRemotes:Get("Event", name)
    if owner then
        targetEvent:FireClient(owner, header, items)
    else
        targetEvent:FireAllClients(header, items)
    end
end

local function FlushReplicationQueue()
    FlushScheduled = false
    local queue = ReplicationQueue
    ReplicationQueue = {}

    -- Group by stream, keeping queue order within each stream. Streams are
    -- independent (own remote, own sequence), so batches go out in order of
    -- each stream's first queued write.
    local batches = {}
    local streamOrder = {}
    for _, entry in queue do
        local streamKey = GetStreamKey(entry.Name, entry.Owner)
        local batch = batches[streamKey]
        if not batch then
            batch = {}
            batches[streamKey] = batch
            table.insert(streamOrder, streamKey)
        end
        table.insert(batch, entry)
    end

    for _, streamKey in streamOrder do
        SendBatch(streamKey, batches[streamKey])
    end
end

-- op is nil for a plain set, or {"i", position} / {"r", position, newLength}
-- for array ops (value = the inserted element for "i", nil for "r").
function DataMeta:TriggerReplicate(owner, name, pathTable, value, op)
    -- Ops are deltas, not snapshots — they never supersede anything.
    if not op then
        for index = #ReplicationQueue, 1, -1 do
            local entry = ReplicationQueue[index]
            if entry.Owner == owner and entry.Name == name then
                if entry.Op and #entry.PathTable < #pathTable and IsPathPrefixOf(entry.PathTable, pathTable) then
                    -- An array op above this path shifted positions, and may rely
                    -- on writes queued before it: write Arr[3], Arr:Remove(1), write
                    -- Arr[3] — the second write is a different element. Nothing
                    -- queued before the op is superseded.
                    break
                elseif IsPathPrefixOf(pathTable, entry.PathTable) then
                    table.remove(ReplicationQueue, index)
                end
            end
        end
    end

    -- Sequence is assigned at write time (not send time) so a GetData snapshot
    -- taken now already accounts for everything queued; coalesced-away entries
    -- just leave gaps, which the client's monotonic check doesn't mind.
    local streamKey = GetStreamKey(name, owner)
    local sequence = (SequenceCounters[streamKey] or 0) + 1
    SequenceCounters[streamKey] = sequence

    table.insert(ReplicationQueue, {
        Owner = owner,
        Name = name,
        PathTable = pathTable,
        Value = value,
        Op = op,
        Seq = sequence,
    })

    if not FlushScheduled then
        FlushScheduled = true
        task.defer(FlushReplicationQueue)
    end
end

function DataMeta:MakeDataStreamObject(name : string, schema : {[any] : any}, owner : Player?) : DataStreamObject
    -- The stream owns an immutable copy of the schema: the root table stays
    -- unfrozen (its identity is captured in the closures below), everything
    -- beneath it is frozen and replaced copy-on-write.
    local rawData = DataStreamUtils.FreezeChildren(DataStreamUtils:DeepCopyTable(schema))

    -- Create remote event for replication
    DataStreamRemotes:Get("Event", name)

    local function ReplicateData(pathTable : { string }, value : any, op : {any}?)
        self:TriggerReplicate(owner, name, pathTable, value, op)
    end

    -- Value must already be frozen (ingested) if it is a table.
    local function SetValueFromPath(pathTable : {string}, Value)
        if pathTable == nil or #pathTable <= 0 then
            local OldValue = table.freeze(table.clone(rawData))

            table.clear(rawData)
            for key, newValue in Value do
                rawData[key] = newValue
            end

            return OldValue
        else
            local didSet, OldValue = DataStreamUtils.SetValueAtPath(rawData, pathTable, Value)
            if not didSet then
                warn("Last step is nil", pathTable)
                return nil
            end
            return OldValue
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

            return MakeCatcherObject(NextMetaTable)
        end,
        __newindex = function(dataObject,NextIndex,Value)

            local CatcherMeta = getmetatable(dataObject)
            local NextMetaTable = DataStreamUtils.CopyTable(CatcherMeta)
            NextMetaTable.PathTable = table.clone(CatcherMeta.PathTable)

            table.insert(NextMetaTable.PathTable, NextIndex)
            local frozenValue = DataStreamUtils.DeepCopyAndFreeze(Value)
            local OldValue = SetValueFromPath(NextMetaTable.PathTable, frozenValue)

            internalChangedTrigger(NextMetaTable, OldValue, frozenValue, false)

            ReplicateData(NextMetaTable.PathTable, frozenValue)
            return MakeCatcherObject(NextMetaTable)
        end,
        -- Support for +=, -=, *=, /=
        __add = function(dataObject, Value)
            local catcherMeta = getmetatable(dataObject)
            if catcherMeta.ValueType == "number" then
                return GetValueFromPathTable(rawData, catcherMeta.PathTable) + Value
            else
                error("Attempted to perform '+' (Addition) on " .. catcherMeta.ValueType, 2)
            end
        end,
        __sub = function(dataObject, Value)
            local catcherMeta = getmetatable(dataObject)
            if catcherMeta.ValueType == "number" then
                return GetValueFromPathTable(rawData, catcherMeta.PathTable) - Value
            else
                error("Attempted to perform '-' (Subtraction) on " .. catcherMeta.ValueType, 2)
            end
        end,
        __mul = function(dataObject, Value)
            local catcherMeta = getmetatable(dataObject)
            if catcherMeta.ValueType == "number" then
                return GetValueFromPathTable(rawData, catcherMeta.PathTable) * Value
            else
                error("Attempted to perform '*' (Multiplication) on " .. catcherMeta.ValueType, 2)
            end
        end,
        __div = function(dataObject, Value)
            local catcherMeta = getmetatable(dataObject)
            if catcherMeta.ValueType == "number" then
                return GetValueFromPathTable(rawData, catcherMeta.PathTable) / Value
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

                if #truePathTable == 0 then
                    -- The root is unfrozen (children are frozen), so hand out a frozen shallow clone.
                    return table.freeze(table.clone(rawData))
                end
                return GetValueFromPathTable(rawData, truePathTable)
            elseif CatcherMeta.LastIndex == "Write" then
                local value = table.pack(...)[1]

                local frozenValue = DataStreamUtils.DeepCopyAndFreeze(value)
                local OldValue = SetValueFromPath(truePathTable, frozenValue)

                internalChangedTrigger(CatcherMeta, OldValue, frozenValue, true)

                ReplicateData(truePathTable, frozenValue)
            elseif CatcherMeta.LastIndex == "Insert" or CatcherMeta.LastIndex == "Remove" then
                local currentTable = if #truePathTable == 0 then rawData else GetValueFromPathTable(rawData, truePathTable)
                if type(currentTable) ~= "table" then
                    error("Attempted to " .. CatcherMeta.LastIndex:lower() .. " a value on a non-table value.")
                end

                -- Replicated as a delta ({"i"/"r", position}) rather than
                -- re-shipping the whole array on every call.
                local newTable = table.clone(currentTable)
                local opForTransport, elementForTransport
                if CatcherMeta.LastIndex == "Insert" then
                    local packedArgs = table.pack(...)
                    local position
                    if packedArgs.n >= 2 then
                        position = packedArgs[1]
                        elementForTransport = DataStreamUtils.DeepCopyAndFreeze(packedArgs[2])
                        table.insert(newTable, position, elementForTransport)
                        -- table.insert accepted it, so it's numeric; send the
                        -- whole-number position it actually used.
                        position = math.floor(tonumber(position))
                    else
                        elementForTransport = DataStreamUtils.DeepCopyAndFreeze(packedArgs[1])
                        table.insert(newTable, elementForTransport)
                        position = #newTable
                    end
                    opForTransport = {"i", position}
                else
                    local position = table.pack(...)[1] or #newTable
                    table.remove(newTable, position)
                    -- The new length is server-only: it says which index ids to free.
                    opForTransport = {"r", math.floor(tonumber(position)), #newTable}
                end
                table.freeze(newTable)

                local OldTable = SetValueFromPath(truePathTable, newTable)
                internalChangedTrigger(CatcherMeta, OldTable, newTable, true)
                ReplicateData(truePathTable, elementForTransport, opForTransport)
            elseif CatcherMeta.LastIndex == "Changed" then
                local callback = table.pack(...)[1]

                return BindChanged(name, ownerId, truePathTable, function(method, newValue, oldValue)
                    if method == CatcherMeta.LastIndex then
                        callback(newValue, oldValue)
                    end
                end)
            elseif CatcherMeta.LastIndex == "ChildAdded" or CatcherMeta.LastIndex == "ChildRemoved" then
                local callback = table.pack(...)[1]

                return BindChanged(name, ownerId, truePathTable, function(method, index, value)
                    if method == CatcherMeta.LastIndex then
                        callback(index, value)
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
        ReplicatingToPlayers[player] = nil

        local streamKeySuffix = "\0" .. tostring(player.UserId)
        for key in pairs(SequenceCounters) do
            if string.sub(key, -#streamKeySuffix) == streamKeySuffix then
                SequenceCounters[key] = nil
            end
        end
        for key in pairs(PathDictionaries) do
            if string.sub(key, -#streamKeySuffix) == streamKeySuffix then
                PathDictionaries[key] = nil
            end
        end

        for name, owners in pairs(SignalCache) do
            local targetOwner = tostring(player.UserId)
            if owners[targetOwner] then
                local function recurse(signalTable : {[string] : {}})
                    local metaData = getmetatable(signalTable)
                    if metaData and metaData.Signal then
                        metaData.Signal:Destroy()
                    end
                    for _, child in pairs(signalTable) do
                        recurse(child)
                    end
                end
                recurse(owners[targetOwner])
                owners[targetOwner] = nil
                if next(owners) == nil then
                    SignalCache[name] = nil
                end
            end
        end
    end)
end

--= Return Module =--

return DataMeta