--[[
    DataStreamPathIds.lua
    Stratiz

    Description:
        Per-stream dictionary of path ids, so replication batches can send a small
        number instead of a full path (see DataStreamWire). It mirrors what the
        stream's clients know: an id is defined the first time its path is sent,
        and freed when the data at that path goes away (a nil write, a parent
        replaced without that key, an array shrinking). The dictionary follows
        live data, so keys that come and go (UserIds, item ids) don't fill it up.

        Ids are never reused within a stream: NextId only counts up.

        Only paths made of string and number keys get ids. Paths through an
        Instance key are sent inline: holding them here would pin destroyed
        instances, and clients resolve those keys by ref id anyway.

--]]

--= Root =--
local DataStreamPathIds = { }

--= Constants =--

-- Safety rail, not a working limit: frees keep the live count near the number
-- of distinct written paths in live data. Past it, new paths are sent inline.
local MAX_LIVE_IDS = 65536

--= Types =--

type Node = {
    Id : number?,
    Children : {[any] : Node}?,
}

export type Dictionary = {
    Root : Node,
    NextId : number,
    LiveCount : number,
}

--= Internal Functions =--

local function IsInternable(pathTable : {any}) : boolean
    for _, fragment in pathTable do
        local fragmentType = type(fragment)
        if fragmentType ~= "string" and fragmentType ~= "number" then
            return false
        end
    end
    return true
end

local function FindNode(dictionary : Dictionary, pathTable : {any}) : Node?
    local node = dictionary.Root
    for _, fragment in pathTable do
        local children = node.Children
        local child = children and children[fragment]
        if not child then
            return nil
        end
        node = child
    end
    return node
end

local function CollectIds(dictionary : Dictionary, node : Node, frees : {number})
    if node.Id then
        table.insert(frees, node.Id)
        dictionary.LiveCount -= 1
    end
    if node.Children then
        for _, child in node.Children do
            CollectIds(dictionary, child, frees)
        end
    end
end

-- Drops every child of node whose key is gone from value, recursively.
-- Returns whether node is left empty (no id, no children).
local function PruneAgainst(dictionary : Dictionary, node : Node, value : any, frees : {number}) : boolean
    local children = node.Children
    if children then
        for key, child in children do
            -- rawget: compare against the keys that actually replicate.
            local childValue = if type(value) == "table" then rawget(value, key) else nil
            if childValue == nil then
                CollectIds(dictionary, child, frees)
                children[key] = nil
            elseif PruneAgainst(dictionary, child, childValue, frees) then
                children[key] = nil
            end
        end
        if next(children) == nil then
            node.Children = nil
        end
    end
    return node.Id == nil and node.Children == nil
end

--= API Functions =--

function DataStreamPathIds.new() : Dictionary
    return {
        Root = {},
        NextId = 0,
        LiveCount = 0,
    }
end

-- Returns the id for a non-empty path if it has one, without assigning.
function DataStreamPathIds.Lookup(dictionary : Dictionary, pathTable : {any}) : number?
    local node = FindNode(dictionary, pathTable)
    return node and node.Id
end

-- Returns (id, isNew) for a non-empty path, assigning an id on first use.
-- Returns nil when the path can't get one; the caller sends it inline.
function DataStreamPathIds.Intern(dictionary : Dictionary, pathTable : {any}) : (number?, boolean)
    local existing = FindNode(dictionary, pathTable)
    if existing and existing.Id then
        return existing.Id, false
    end

    if dictionary.LiveCount >= MAX_LIVE_IDS or not IsInternable(pathTable) then
        return nil, false
    end

    local node = dictionary.Root
    for _, fragment in pathTable do
        local children = node.Children
        if not children then
            children = {}
            node.Children = children
        end

        local child = children[fragment]
        if not child then
            child = {}
            children[fragment] = child
        end
        node = child
    end

    dictionary.NextId += 1
    dictionary.LiveCount += 1
    node.Id = dictionary.NextId
    return node.Id, true
end

-- Frees every id at or below pathTable whose data is gone now that value was
-- written there (all of them when value is nil). Returns the freed ids, or nil.
-- Cost is the number of interned paths under pathTable: one lookup for a leaf.
function DataStreamPathIds.FreeStale(dictionary : Dictionary, pathTable : {any}, value : any) : {number}?
    local chain = {dictionary.Root}
    for depth, fragment in pathTable do
        local children = chain[depth].Children
        local child = children and children[fragment]
        if not child then
            -- Nothing at or below an uninterned path can have an id.
            return nil
        end
        chain[depth + 1] = child
    end

    local depth = #pathTable
    local target = chain[depth + 1]
    if value ~= nil and target.Children == nil then
        -- The common leaf write: nothing below it to free.
        return nil
    end

    local frees = {}
    local isTargetEmpty
    if value == nil then
        CollectIds(dictionary, target, frees)
        isTargetEmpty = true
    else
        isTargetEmpty = PruneAgainst(dictionary, target, value, frees)
    end

    -- Unlink the emptied target, then any ancestors it leaves empty. The root
    -- itself is never unlinked.
    if isTargetEmpty then
        for index = depth, 1, -1 do
            local parent = chain[index]
            parent.Children[pathTable[index]] = nil
            if next(parent.Children) == nil then
                parent.Children = nil
            end

            if index == 1 or parent.Id ~= nil or parent.Children ~= nil then
                break
            end
        end
    end

    return if #frees > 0 then frees else nil
end

-- Frees ids under the indexes past length, after an array at pathTable shrank.
-- Returns the freed ids, or nil.
function DataStreamPathIds.FreeArrayTail(dictionary : Dictionary, pathTable : {any}, length : number) : {number}?
    local node = FindNode(dictionary, pathTable)
    local children = node and node.Children
    if not children then
        return nil
    end

    local frees = {}
    for key, child in children do
        if type(key) == "number" and key > length then
            CollectIds(dictionary, child, frees)
            children[key] = nil
        end
    end
    if next(children) == nil then
        node.Children = nil
    end

    return if #frees > 0 then frees else nil
end

-- Drops every id at once (the stream root was removed). NextId keeps counting.
function DataStreamPathIds.Reset(dictionary : Dictionary)
    dictionary.Root = {}
    dictionary.LiveCount = 0
end

-- Flat {id, path, id, path, ...} list of every live id, for GetData snapshots.
function DataStreamPathIds.Snapshot(dictionary : Dictionary) : {any}
    local flat = {}

    local function walk(node : Node, pathTable : {any})
        if node.Id then
            table.insert(flat, node.Id)
            table.insert(flat, table.clone(pathTable))
        end
        if node.Children then
            for key, child in node.Children do
                table.insert(pathTable, key)
                walk(child, pathTable)
                table.remove(pathTable)
            end
        end
    end

    walk(dictionary.Root, {})
    return flat
end

--= Return Module =--
return DataStreamPathIds
