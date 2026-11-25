--!strict
-- Display formatting helpers (client UI + server notifications).

local Format = {}

local SUFFIXES = { "K", "M", "B", "T", "Qa" }

local function withCommas(n: number): string
	local text = tostring(math.floor(n))
	local formatted = text
	while true do
		local replaced, count = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
		formatted = replaced
		if count == 0 then
			break
		end
	end
	return formatted
end

-- 950 -> "950", 24500 -> "24,500", 1250000 -> "1.25M"
function Format.Number(n: number): string
	if n < 1_000_000 then
		return withCommas(n)
	end
	local index = 0
	local value = n
	while value >= 1000 and index < #SUFFIXES do
		value /= 1000
		index += 1
	end
	return string.format("%.2f%s", value, SUFFIXES[index])
end

function Format.Rate(goldPerSec: number): string
	if goldPerSec < 10 then
		return string.format("+%.1f/s", goldPerSec)
	end
	return "+" .. Format.Number(goldPerSec) .. "/s"
end

function Format.Weight(kg: number): string
	if kg < 10 then
		return string.format("%.2fkg", kg)
	elseif kg < 1000 then
		return string.format("%.1fkg", kg)
	end
	return withCommas(kg) .. "kg"
end

function Format.Duration(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	if s >= 3600 then
		return string.format("%dh %dm", s // 3600, (s % 3600) // 60)
	end
	return string.format("%d:%02d", s // 60, s % 60)
end

function Format.Percent(fraction: number): string
	local pct = fraction * 100
	if pct < 1 then
		return string.format("%.2f%%", pct)
	end
	return string.format("%.1f%%", pct)
end

return Format
