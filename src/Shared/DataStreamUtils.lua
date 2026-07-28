--[[
    DataStreamUtils.lua
    Stratiz
    Created on 06/28/2023 @ 01:37
    
    Description:
        Data stream utility functions.
    
--]]

--= Root =--

local DataStreamUtils = { }

--= API Functions =--

function DataStreamUtils.ResolvePlayerSchemaIndex(index : number | Player) : string
    if typeof(index) == "Instance" and index:IsA("Player") then
        return tostring(index.UserId)
    elseif type(index) == "number" or type(index) == "string" and tonumber(index) then
        return tostring(index)
    else
        error("Invalid index type. Expected Player or userid, got " .. typeof(index))
    end
end

-- Remade concat since default concat only accepts string tables
function DataStreamUtils.StringifyPathTable(pathTable : { any }) : string
    local pathString = ""

    for i, value in pathTable do
        pathString ..= (if i == 1 then "" else ".").. tostring(value)
    end

    return pathString
end

function DataStreamUtils.CopyTable(target)
	return table.clone(target)
end

function DataStreamUtils:DeepCopyTable(target, _context)
    _context = _context or  {}
    if _context[target] then
        return _context[target]
    end

    if type(target) == "table" then
        local new = {}
        _context[target] = new
        for index, value in pairs(target) do
            new[self:DeepCopyTable(index, _context)] = self:DeepCopyTable(value, _context)
        end
        return setmetatable(new, self:DeepCopyTable(getmetatable(target), _context))
    else
        return target
    end
end

-- Recursively freezes target and every descendant table. Cycle-safe. Returns target.
function DataStreamUtils.DeepFreeze(target : any, _seen : {[any] : boolean}?) : any
    if type(target) ~= "table" then
        return target
    end

    local seen = _seen or {}
    if seen[target] then
        return target
    end
    seen[target] = true

    for index, value in pairs(target) do
        DataStreamUtils.DeepFreeze(index, seen)
        DataStreamUtils.DeepFreeze(value, seen)
    end

    if not table.isfrozen(target) then
        table.freeze(target)
    end

    return target
end

-- Deep-freezes every child of target, but leaves target itself unfrozen.
-- Used for stream roots, whose table identity is load-bearing and which are
-- mutated in place while everything below them is immutable.
function DataStreamUtils.FreezeChildren(target : {[any] : any}) : {[any] : any}
    for _, value in pairs(target) do
        DataStreamUtils.DeepFreeze(value)
    end

    return target
end

-- Cycle-safe deep copy where every produced table is frozen. Ingestion primitive
-- for developer-supplied values: the caller keeps their mutable table, the stream
-- stores an immutable copy.
function DataStreamUtils.DeepCopyAndFreeze(target : any, _context : {[any] : any}?) : any
    local context = _context or {}
    if context[target] ~= nil then
        return context[target]
    end

    if type(target) == "table" then
        local new = {}
        context[target] = new
        for index, value in pairs(target) do
            new[DataStreamUtils.DeepCopyAndFreeze(index, context)] = DataStreamUtils.DeepCopyAndFreeze(value, context)
        end

        local metatable = getmetatable(target)
        if metatable ~= nil then
            setmetatable(new, DataStreamUtils.DeepCopyAndFreeze(metatable, context))
        end

        table.freeze(new)
        return new
    else
        return target
    end
end

-- Copy-on-write path write for a tree whose root is unfrozen and whose descendant
-- tables are frozen. Clones each frozen table along pathTable (clones of frozen
-- tables are unfrozen), sets the leaf, re-freezes bottom-up, and mutates only the
-- root in place — so previously handed-out references keep their old contents.
-- Does not create missing intermediate tables: returns false so callers can
-- warn/re-sync. If value is a table it must already be frozen.
function DataStreamUtils.SetValueAtPath(root : {[any] : any}, pathTable : {any}, value : any) : (boolean, any)
    local pathLength = #pathTable
    if pathLength == 0 then
        error("SetValueAtPath requires a non-empty path. Handle root replacement at the call site.")
    end

    local parents = table.create(pathLength)
    parents[1] = root
    for index = 1, pathLength - 1 do
        local nextTable = parents[index][pathTable[index]]
        if type(nextTable) ~= "table" then
            return false, nil
        end
        parents[index + 1] = nextTable
    end

    local oldValue = parents[pathLength][pathTable[pathLength]]

    local newChild = value
    for index = pathLength, 2, -1 do
        local clone = table.clone(parents[index])
        clone[pathTable[index]] = newChild
        table.freeze(clone)
        newChild = clone
    end
    root[pathTable[1]] = newChild

    return true, oldValue
end

-- Read a value at a path without erroring on missing/non-table intermediates.
function DataStreamUtils.GetValueAtPath(root : any, pathTable : {any}) : any
    local currentTarget = root
    for _, index in pathTable do
        if type(currentTarget) ~= "table" then
            return nil
        end
        currentTarget = currentTarget[index]
    end
    return currentTarget
end

--= Return Module =--
return DataStreamUtils