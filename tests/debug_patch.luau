--!nocheck
-- Harness-only source patch: makes the client say why it re-syncs.
local function replaceOnce(source, old, new, label)
	local start, finish = string.find(source, old, 1, true)
	assert(start, "debug patch anchor not found: " .. label)
	return string.sub(source, 1, start - 1) .. new .. string.sub(source, finish + 1)
end

return function(path, source)
	if not path:match("Client/init%.lua$") then
		return source
	end
	source = replaceOnce(source,
		"\t\t\tif not path or not ApplyUpdate(",
		"\t\t\tif not path then warn(\"DEBUG no path\", pathMode, entry.PathId, entry.Path and DataStreamUtils.StringifyPathTable(entry.Path)) end\n"
			.. "\t\t\tif not path or not ApplyUpdate(",
		"apply")
	source = replaceOnce(source,
		"\t\tif type(currentArray) ~= \"table\" then\n\t\t\treturn false",
		"\t\tif type(currentArray) ~= \"table\" then\n\t\t\twarn(\"DEBUG op target not a table\", DataStreamUtils.StringifyPathTable(path), opKind, position)\n\t\t\treturn false",
		"op target")
	source = replaceOnce(source,
		"\t\t\tif position < 1 or position > #newArray + 1 then\n\t\t\t\treturn false",
		"\t\t\tif position < 1 or position > #newArray + 1 then\n\t\t\t\tlocal keys = {} for k in pairs(newArray) do table.insert(keys, tostring(k)) end warn(\"DEBUG insert position\", DataStreamUtils.StringifyPathTable(path), position, #newArray, \"client keys\", table.concat(keys, \",\"))\n\t\t\t\treturn false",
		"insert")
	source = replaceOnce(source,
		"\t\t\tif position < 1 or position > #newArray then\n\t\t\t\treturn false",
		"\t\t\tif position < 1 or position > #newArray then\n\t\t\t\twarn(\"DEBUG remove position\", DataStreamUtils.StringifyPathTable(path), position, #newArray)\n\t\t\t\treturn false",
		"remove")
	return source
end
