-- SymmetricalChatAndDamageMeter: settings panel. Just one dropdown (how many
-- Damage Meter windows to mirror), so the native
-- Settings.RegisterVerticalLayoutCategory API is enough here - no need for a
-- hand-built canvas panel.

local Addon = SymmetricalChatAndDamageMeter

local Options = {}
Addon.Options = Options

local category

-- Dropdown contract on this client: the options argument passed to
-- Settings.CreateDropdown is called as optionsFunc() internally, so it must
-- be a function returning the entry list, never the list itself. Each entry
-- needs controlType = Settings.ControlType.Radio.
local function DropdownOptions(entries)
	local container = Settings.CreateControlTextContainer()
	for i = 1, #entries do
		container:Add(entries[i].value, entries[i].label, entries[i].tooltip, Settings.ControlType.Radio)
	end
	return container:GetData()
end

-- The real max (DamageMeter:GetMaxSessionWindowCount(), confirmed 3 on this
-- client) isn't known for certain until DamageMeter itself exists, so this
-- falls back to 3 if asked before it's loaded.
local function GetMaxWindowCount()
	return (DamageMeter and DamageMeter.GetMaxSessionWindowCount and DamageMeter:GetMaxSessionWindowCount()) or 3
end

local function BuildCountEntries()
	local entries = {}
	for i = 1, GetMaxWindowCount() do
		entries[i] = {
			value = i,
			label = (i == 1) and "1 window" or (i .. " windows"),
			tooltip = "Mirror the Damage Meter as " .. i .. (i == 1 and " window." or " equal-width windows side by side."),
		}
	end
	return entries
end

function Options:Init()
	if category then
		return
	end
	local db = Addon.db

	category = Settings.RegisterVerticalLayoutCategory(Addon.name)
	Settings.RegisterAddOnCategory(category)

	local setting = Settings.RegisterProxySetting(category, "damageMeterWindowCount", Settings.VarType.Number,
		"Damage Meter window count", db.damageMeterWindowCount,
		function() return db.damageMeterWindowCount end,
		function(value)
			db.damageMeterWindowCount = value
			if Addon.MirrorToChat then
				Addon.MirrorToChat()
			end
		end)
	local function GetOptions()
		return DropdownOptions(BuildCountEntries())
	end
	Settings.CreateDropdown(category, setting, GetOptions, "How many Damage Meter windows to mirror in the bottom-right corner, split evenly.")
end

function Options:Open()
	if not category then
		return
	end
	-- OpenToCategory's argument has shifted between client builds; try the
	-- category object first and its numeric id as a fallback.
	if not pcall(Settings.OpenToCategory, category) then
		pcall(Settings.OpenToCategory, category.GetID and category:GetID() or nil)
	end
end
