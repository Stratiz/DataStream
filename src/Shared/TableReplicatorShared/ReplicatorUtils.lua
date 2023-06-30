--[[
    TableReplicatorUtils.lua
    Stratiz
    Created on 06/28/2023 @ 01:37
    
    Description:
        No description provided.
    
--]]

--= Root =--
local TableReplicatorUtils = { }

--= Roblox Services =--
local Players = game:GetService("Players")

--= Dependencies =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Internal Functions =--

--= Public Variables =--

--= API Functions =--

--= Initializers =--
function TableReplicatorUtils.CopyTable(target)
	local new = {}
	for key, value in pairs(target) do
		new[key] = value
	end
	return new
end

function TableReplicatorUtils:DeepCopyTable(target, _context)
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
return TableReplicatorUtils