--!nocheck
--[[
    Runs one fixed workload (10 players, per-frame player-stream and
    UserId-keyed leaderboard writes, inventory inserts, join/leave churn) and
    prints what one long-lived client received. Point it at two copies of the
    package to compare them, e.g. a checkout of main:
        lune run tests/compare.luau                     (src)
        lune run tests/compare.luau src=../main/src
    Remote call counts are exact; byte counts are rough estimates (see
    runtime.luau), useful only for comparing versions.
]]
local process = require("@lune/process")
local Runtime = require("./runtime")

local SRC = "src"
for _, arg in process.args do
	SRC = arg:match("^src=(.+)$") or SRC
end
local FRAMES = 300

local rt = Runtime.new(SRC)
rt.DataStream:MakeGlobalStream("Leaderboard", {})
rt.DataStream:AddPlayerStreamTemplate("PlayerData", {
	Coins = 0,
	Stats = { Level = 1, XP = 0 },
	Inventory = {},
})

local leaderboard = rt.DataStream.Leaderboard
local playerData = rt.DataStream.PlayerData

local function join()
	local client = rt.AddClient()
	leaderboard[tostring(client.UserId)] = { Score = 0, Kills = 0, Name = "Player" .. client.UserId }
	return client
end

local active = {}
for _ = 1, 10 do table.insert(active, join()) end
local observer = active[1]
rt.Settle()
for _, client in rt.Clients do
	client.Stats.EventCalls, client.Stats.EventBytes = 0, 0
end

for frame = 1, FRAMES do
	for _, client in active do
		local data = playerData[client.Player]
		data.Coins = data.Coins + 1
		data.Stats.XP = data.Stats.XP + 3
		leaderboard[tostring(client.UserId)].Score = frame
		if frame % 10 == 0 then
			data.Inventory:Insert({ Id = frame, Durability = 100 })
		end
		if frame % 5 == 0 and #data.Inventory:Read() > 0 then
			data.Inventory[1].Durability = data.Inventory[1].Durability - 1
		end
	end
	if frame % 60 == 0 then
		local leaving = table.remove(active, 2) -- never the observer
		leaderboard[tostring(leaving.UserId)] = nil
		rt.RemoveClient(leaving)
		table.insert(active, join())
	end
	rt.Frame()
end
rt.Settle()

local late = rt.AddClient()
rt.Settle()

local errors = #rt.Errors
local resyncs = 0
for _, warning in rt.Warnings do
	if warning.Message:find("re%-syncing") then resyncs += 1 end
end

print(string.format("observer: %d remote calls, ~%d bytes over %d frames (~%.0f bytes/frame)",
	observer.Stats.EventCalls, observer.Stats.EventBytes, FRAMES, observer.Stats.EventBytes / FRAMES))
print(string.format("late joiner GetData reply: ~%d bytes", late.Stats.InvokeBytes))
print(string.format("errors: %d, re-syncs: %d", errors, resyncs))
process.exit(0)
