-- Stock Factory mod — makes the captain-command map UI tolerant of modded command
-- types.
--
-- This file name-clashes with the vanilla
--   data/scripts/player/map/mapcommands.lua
-- so Avorion appends this code to that file. The vanilla `MapCommands.initUI()`
-- sorts every command type using a *function-local* `commandSortIndex` table that
-- only contains the built-in command types. Any command added by a mod isn't in
-- that table, so the sort comparator would evaluate `nil < number` and raise an
-- error — which would break the entire captain-command UI.
--
-- We can't reach that function-local from here, so instead we make the sort itself
-- tolerant: while the original initUI() runs, we temporarily wrap table.sort so an
-- erroring comparator (caused by an unknown/modded key) doesn't crash. Unknown
-- command types are ordered consistently *after* the known ones, which keeps the
-- comparator a valid strict-weak-ordering (so table.sort won't complain either).
do
    local originalInitUI = MapCommands.initUI

    if type(originalInitUI) == "function" then
        MapCommands.initUI = function(...)
            local realSort = table.sort

            table.sort = function(t, cmp)
                if type(cmp) ~= "function" then
                    return realSort(t)
                end

                local sortsStockFactoryCommands = false
                for _, value in pairs(t) do
                    if value == CommandType.StockFactory then
                        sortsStockFactoryCommands = true
                        break
                    end
                end

                if not sortsStockFactoryCommands then
                    return realSort(t, cmp)
                end

                local safeCmp = function(a, b)
                    local ok, result = pcall(cmp, a, b)
                    if ok then return result end

                    -- The comparator errored: at least one operand is an unknown
                    -- (modded) key that produced nil. cmp(x, x) succeeds for known
                    -- keys and errors for unknown ones, so we can tell them apart
                    -- and keep a consistent ordering: known < unknown, and unknown
                    -- keys ordered deterministically among themselves.
                    local aKnown = pcall(cmp, a, a)
                    local bKnown = pcall(cmp, b, b)

                    if aKnown and not bKnown then return true end
                    if not aKnown and bKnown then return false end
                    return tostring(a) < tostring(b)
                end

                return realSort(t, safeCmp)
            end

            local ok, err = pcall(originalInitUI, ...)

            -- always restore the real table.sort, even if initUI errored
            table.sort = realSort

            if not ok then error(err) end
        end
    end
end
