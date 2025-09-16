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
	local new = {}
	for key, value in pairs(target) do
		new[key] = value
	end
	return new
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

--= Return Module =--
return DataStreamUtils