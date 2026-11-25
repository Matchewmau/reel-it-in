--!strict
-- Weighted random selection. The caller supplies the Random so that all
-- gameplay rolls stay on the server's RNG.

local Weighted = {}

-- Picks an index into `weights`, proportionally to each weight.
-- Prefer this when the entries are string-literal union types (Rarity etc.):
-- indexing the source array afterwards keeps the precise type.
function Weighted.PickIndex(rng: Random, weights: { number }): number
	local total = 0
	for _, weight in weights do
		total += math.max(weight, 0)
	end
	assert(#weights > 0 and total > 0, "Weighted.PickIndex needs at least one positive weight")

	local roll = rng:NextNumber() * total
	for index, weight in weights do
		roll -= math.max(weight, 0)
		if roll <= 0 then
			return index
		end
	end
	return #weights
end

function Weighted.Pick<T>(rng: Random, entries: { T }, weightOf: (T) -> number): T
	local weights: { number } = table.create(#entries)
	for index, entry in entries do
		weights[index] = weightOf(entry)
	end
	return entries[Weighted.PickIndex(rng, weights)]
end

return Weighted
