-- SymmetricalChatAndDamageMeter: positions the native Damage Meter (confirmed
-- real global, Blizzard_DamageMeter) as a mirror image of the chat window -
-- bottom-right instead of bottom-left, same size - split evenly into however
-- many windows the player has chosen (Interface Options -> AddOns, 1 to the
-- client's own max of 3). The primary (Damage Done by default) always fills
-- the leftmost column; any further windows are the player's own to switch to
-- any other metric (Healing Done, HPS, ...) via each window's own native
-- dropdown - confirmed real via Enum.DamageMeterType and the per-window
-- damageMeterTypeDropdown in DamageMeterSessionWindow.lua, not something this
-- addon sets itself.
--
-- DamageMeter itself (confirmed against its real XML) has no visible content
-- of its own - it's just a positioning wrapper. The actual panels are
-- DamageMeterSessionWindow instances, created/destroyed through the real
-- ShowNewSecondarySessionWindow/HideSessionWindow accessors (confirmed in
-- DamageMeterMixin) rather than created directly by this addon. The primary
-- window is Edit-Mode-managed and ignores a plain SetSize when resized
-- externally, but takes a real two-point SetPoint span cleanly - so every
-- window here, not just the primary, is laid out with two-point anchors
-- rather than SetPoint+SetSize, for the same reason.
--
-- The mirror math uses ChatFrame1's resolved on-screen rect (GetLeft/Right/
-- Top) for sizing. Position is flush to the screen's bottom-right corner
-- rather than mirroring chat's own margins - chat visually sits flush with
-- no gap on either edge, but mirroring its measured GetLeft()/GetBottom()
-- still left visible gaps here, so whatever chat's true margins are, they
-- aren't reproducing correctly through this panel's own border art.
--
-- One more internal resize quirk, confirmed by printing the actual values:
-- the window frame, its MinimizeContainer, and its Background texture all
-- correctly follow an external resize, but the ScrollBox inside (the part
-- that actually lays out the entry bars) stays pinned at whatever height it
-- had when first initialized and doesn't track later resizes on its own.
-- Re-applying its BOTTOMRIGHT anchor relative to the container (the same
-- anchor DamageMeterSessionWindowMixin:InitializeScrollBox sets up itself)
-- re-establishes that as a live two-point span instead of a stale one.

local ADDON_NAME = "SymmetricalChatAndDamageMeter"

SymmetricalChatAndDamageMeter = {}
local Addon = SymmetricalChatAndDamageMeter
Addon.name = ADDON_NAME

local DEFAULTS = {
	damageMeterWindowCount = 3,
	windowTypes = {}, -- [windowIndex] = Enum.DamageMeterType, this addon's own memory of each window's chosen metric
}
Addon.DEFAULTS = DEFAULTS

local function ApplyDefaults(db, defaults)
	for key, value in pairs(defaults) do
		if db[key] == nil then
			db[key] = value
		end
	end
end

local db -- SymmetricalChatAndDamageMeterDB, set on ADDON_LOADED

local function FixScrollBoxHeight(win)
	if not win or not win.GetScrollBox or not win.GetMinimizeContainer then
		return
	end
	local scrollBox = win:GetScrollBox()
	local container = win:GetMinimizeContainer()
	if not scrollBox or not container then
		return
	end
	scrollBox:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -1, 6)
end

-- Confirmed in-game: a secondary session window this addon creates (via the
-- real ShowNewSecondarySessionWindow accessor, not created directly) stays
-- permanently tainted by this addon from then on, not just during the one
-- deferred call that created it - any LATER native code touching that same
-- window object, including a routine combat-session-duration refresh that
-- has nothing to do with this addon, still throws "attempt to compare ...
-- a secret number value, while execution tainted by 'SymmetricalChatAndDamageMeter'"
-- in DamageMeterSessionWindowMixin:SetSessionDuration (confirmed real,
-- DamageMeterSessionWindow.lua:928 - it just compares durationSeconds ~= 0
-- to decide whether to show a "[MM:SS]" timer prefix). The C_Timer.After(0,
-- ...) defer below still matters for the window's own creation, but can't
-- un-taint it for its whole remaining lifetime, so this wraps the one
-- function that crashes in a pcall instead - worst case the timer prefix on
-- a secondary window just doesn't update for a tick, instead of a Lua error
-- popping up on every combat tick.
local originalSetSessionDuration = DamageMeterSessionWindowMixin.SetSessionDuration
DamageMeterSessionWindowMixin.SetSessionDuration = function(self, ...)
	local ok = pcall(originalSetSessionDuration, self, ...)
	if not ok then
		return
	end
end

-- ChatFrame1EditBox (the "Say:" draft box) default-anchors its TOPLEFT to
-- ChatFrame1's BOTTOMLEFT (confirmed in the real XML), which is why it sits
-- below the chat text. Moved inside the chat window instead, flush at the
-- top (its own TOPLEFT to ChatFrame1's TOPLEFT) - sits right under the tab
-- row rather than outside the frame entirely, overlaying the top of the
-- message area when shown. Hidden (alpha 0) except while actively focused
-- for typing, via the real OnEditFocusGained/OnEditFocusLost scripts
-- (hooked, not replaced, so Blizzard's own handling still runs).
local function MoveEditBoxAboveChat()
	local editBox = _G["ChatFrame1EditBox"]
	if not editBox or not ChatFrame1 then
		return
	end
	editBox:ClearAllPoints()
	editBox:SetPoint("TOPLEFT", ChatFrame1, "TOPLEFT", -5, -2)
	editBox:SetPoint("RIGHT", ChatFrame1, "RIGHT", 8, 0)

	editBox:SetAlpha(editBox:HasFocus() and 1 or 0)
	editBox:HookScript("OnEditFocusGained", function(self)
		self:SetAlpha(1)
	end)
	editBox:HookScript("OnEditFocusLost", function(self)
		self:SetAlpha(0)
	end)
end

-- Permanently hides the chat frame's side buttons (channel, voice mute/
-- deafen, menu, text-to-speech) by reparenting them to a hidden holder frame
-- - the same technique Leatrix_Plus's own "Hide chat buttons" option uses
-- (confirmed in its installed source), chosen over plain :Hide() because
-- Blizzard's own code can re-show a frame that's just hidden, but a frame
-- parented to something permanently hidden stays hidden regardless.
local hiddenHolder
local function HideChatSideButtons()
	hiddenHolder = hiddenHolder or CreateFrame("Frame")
	hiddenHolder:Hide()

	for _, name in ipairs({
		"ChatFrameChannelButton",
		"ChatFrameToggleVoiceDeafenButton",
		"ChatFrameToggleVoiceMuteButton",
		"ChatFrameMenuButton",
		"TextToSpeechButton",
		-- The "Social (O)" toast button with the online-friend-count badge -
		-- confirmed real name QuickJoinToastButton (roleset="chat", and
		-- FloatingChatFrame.lua itself reparents it alongside chat's own side
		-- buttons), not QueueStatusButton (that one is the Group Finder eye
		-- icon anchored to MicroMenu, which the player wants kept visible).
		"QuickJoinToastButton",
		-- The container the side buttons sat in (ChatFrame1ButtonFrame,
		-- parentKey "buttonFrame") inherits FloatingBorderedFrame - confirmed
		-- in the real XML, it has its own visible border/backdrop.
		-- Reparenting only the buttons left that empty bordered box on
		-- screen, so the container itself is hidden too.
		"ChatFrame1ButtonFrame",
	}) do
		local button = _G[name]
		if button then
			button:SetParent(hiddenHolder)
		end
	end
end

-- Forces chat's bottom-left corner flush to the screen's actual bottom-left
-- corner, the same "flush beats mirrored-margin" fix used for the Damage
-- Meter's own position. Captures the current size first since ClearAllPoints
-- drops whatever anchors were providing it.
--
-- ChatFrame1 inherits EditModeChatFrameSystemTemplate (confirmed in its real
-- XML), which overrides its own SetPoint/ClearAllPoints (confirmed in
-- EditModeSystemMixin:OnSystemLoad) - the override still moves the frame
-- immediately, but Edit Mode's saved anchorInfo for it is never updated, so
-- the next time Edit Mode re-applies its layout (ApplySystemAnchor, e.g. on
-- a later login or layout switch) it snaps straight back, making this look
-- like it never moved at all. The real fix is the same call Blizzard's own
-- drag-to-move code makes right after a drag finishes
-- (EditModeSystemMixin:OnDragStop calls self:OnSystemPositionChange()) -
-- that tells Edit Mode to read the frame's current point back out and adopt
-- it as the new saved anchor, instead of us fighting the override.
--
-- Still wasn't reaching the true corner even so, and confirmed in-game that
-- dragging it there by hand in Edit Mode isn't possible either - because
-- ChatFrame1 is ClampedToScreen with nonzero clamp rect insets (Edit Mode's
-- own EditModeSystemMixin:UpdateClampOffsets sets these from its Selection
-- overlay's padding), and the engine enforces that clamp on every anchor
-- change, SetPoint calls included, not just mouse drags. Leatrix_Plus's own
-- real "Unclamp chat frame" option (confirmed in its installed source) is
-- exactly this: SetClampedToScreen(false) plus zeroing the insets, so the
-- same two calls go here instead of relying on LTP.
local function FlushChatToCorner()
	if not ChatFrame1 then
		return
	end
	ChatFrame1:SetClampedToScreen(false)
	ChatFrame1:SetClampRectInsets(0, 0, 0, 0)
	local w, h = ChatFrame1:GetWidth(), ChatFrame1:GetHeight()
	ChatFrame1:ClearAllPoints()
	ChatFrame1:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
	ChatFrame1:SetSize(w, h)
	if ChatFrame1.OnSystemPositionChange then
		ChatFrame1:OnSystemPositionChange()
	end
end

local function GetDesiredWindowCount()
	local maxCount = (DamageMeter and DamageMeter.GetMaxSessionWindowCount and DamageMeter:GetMaxSessionWindowCount()) or 3
	local desired = (db and db.damageMeterWindowCount) or DEFAULTS.damageMeterWindowCount
	if desired < 1 then
		desired = 1
	elseif desired > maxCount then
		desired = maxCount
	end
	return desired
end

-- Confirmed in-game: the window reset to Damage Done on every login despite
-- Blizzard's own per-character persistence existing for this
-- (DamageMeterPerCharacterSettings, confirmed real in DamageMeter.lua,
-- restored via LoadSavedWindowDataList at the Damage Meter's own OnLoad,
-- well before this addon runs) - something about that restoration not
-- surviving this addon's own window-count management isn't fully
-- understood, so rather than keep chasing a native mechanism this addon
-- doesn't control, it just remembers each window's chosen type itself.
-- hooksecurefunc on the real SetSessionWindowDamageMeterType (confirmed
-- real, what the native per-window dropdown calls) captures a change the
-- instant the player makes it, by window index (confirmed real accessor,
-- DamageMeterSessionWindowMixin:GetSessionWindowIndex) - including this
-- addon's own calls to it below, which is harmless, re-saving the same
-- value.
hooksecurefunc(DamageMeter, "SetSessionWindowDamageMeterType", function(_, sessionWindow, damageMeterType)
	if db and sessionWindow and sessionWindow.GetSessionWindowIndex then
		db.windowTypes[sessionWindow:GetSessionWindowIndex()] = damageMeterType
	end
end)

-- Re-applies this addon's own remembered type for every currently-shown
-- window, skipping any that's already showing the right one (SetSession-
-- WindowDamageMeterType isn't a no-op query, so this avoids calling it
-- needlessly on every login for a window that was already correct).
local function RestoreWindowTypes()
	if not db then
		return
	end
	local maxCount = DamageMeter.GetMaxSessionWindowCount and DamageMeter:GetMaxSessionWindowCount() or 3
	for index = 1, maxCount do
		local savedType = db.windowTypes[index]
		local win = savedType and DamageMeter:GetSessionWindow(index)
		if win and win:IsShown() and DamageMeter:GetSessionWindowDamageMeterType(win) ~= savedType then
			DamageMeter:SetSessionWindowDamageMeterType(win, savedType)
		end
	end
end

-- Grows or shrinks the number of shown session windows to match the desired
-- count, via the real accessors (ShowNewSecondarySessionWindow/
-- HideSessionWindow/CanHideSessionWindow) rather than creating or destroying
-- frames directly.
local function ApplyWindowCount(desiredCount)
	if not DamageMeter then
		return
	end

	while DamageMeter:GetCurrentSessionWindowCount() < desiredCount and DamageMeter:CanShowNewSecondarySessionWindow() do
		DamageMeter:ShowNewSecondarySessionWindow()
	end

	local maxCount = DamageMeter.GetMaxSessionWindowCount and DamageMeter:GetMaxSessionWindowCount() or 3
	for index = maxCount, 1, -1 do
		if DamageMeter:GetCurrentSessionWindowCount() <= desiredCount then
			break
		end
		local win = DamageMeter:GetSessionWindow(index)
		if win and win:IsShown() and DamageMeter:CanHideSessionWindow(win) then
			DamageMeter:HideSessionWindow(win)
		end
	end

	RestoreWindowTypes()
end

-- Lays out every currently-shown session window as an equal-width column
-- spanning DamageMeter, left to right by window index (primary first). Each
-- window gets a real two-point anchor (TOPLEFT + BOTTOMRIGHT, both expressed
-- as offsets from DamageMeter's own TOPLEFT) rather than SetPoint+SetSize -
-- confirmed necessary for the primary window, which ignores a plain SetSize
-- when it's set externally, so every window uses the same technique rather
-- than special-casing the primary.
local function LayoutSessionWindows()
	if not DamageMeter then
		return
	end

	local maxCount = DamageMeter.GetMaxSessionWindowCount and DamageMeter:GetMaxSessionWindowCount() or 3
	local windows = {}
	for index = 1, maxCount do
		local win = DamageMeter:GetSessionWindow(index)
		if win and win:IsShown() then
			table.insert(windows, win)
		end
	end

	local count = #windows
	if count == 0 then
		return
	end

	local totalWidth = DamageMeter:GetWidth()
	local height = DamageMeter:GetHeight()
	local colWidth = totalWidth / count

	for i, win in ipairs(windows) do
		win:ClearAllPoints()
		win:SetPoint("TOPLEFT", DamageMeter, "TOPLEFT", (i - 1) * colWidth, 0)
		win:SetPoint("BOTTOMRIGHT", DamageMeter, "TOPLEFT", i * colWidth, -height)
		FixScrollBoxHeight(win)
	end
end

local function MirrorToChat()
	if not DamageMeter or not ChatFrame1 then
		return
	end

	local chatRight = ChatFrame1:GetRight()
	local chatLeft = ChatFrame1:GetLeft()
	local chatBottom = ChatFrame1:GetBottom()
	local chatTop = ChatFrame1:GetTop()
	if not (chatLeft and chatRight and chatBottom and chatTop) then
		return
	end

	local width = chatRight - chatLeft
	local height = chatTop - chatBottom

	-- Anchored flush to the screen corner directly, rather than mirroring
	-- chat's own margins - chat visually sits flush with no gap on either
	-- edge, but mirroring its measured GetLeft()/GetBottom() still left
	-- visible gaps here, so whatever chat's true margins are, they aren't
	-- reproducing correctly through this panel's own border art.
	DamageMeter:ClearAllPoints()
	DamageMeter:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)
	DamageMeter:SetSize(width, height)
	DamageMeter:SetAlpha(1)

	-- DamageMeter:Show() (and ShowNewSecondarySessionWindow/HideSessionWindow
	-- inside ApplyWindowCount) can trigger a session window's own OnShow
	-- chain synchronously - confirmed in-game via the real error: Blizzard's
	-- own DamageMeterSessionWindow.lua:SetSessionDuration compares a live
	-- combat session's duration, which is a "secret" number while a session
	-- is active (the same anti-automation secret-value system that also
	-- guards combat log aura data on this client), and that comparison
	-- throws once the call stack is "tainted" by this addon having called
	-- Show()/etc directly. Deferring one frame via C_Timer.After(0, ...) runs
	-- that chain in a fresh, untainted call stack instead - the standard way
	-- to hand a call back to a clean execution context on this client.
	C_Timer.After(0, function()
		DamageMeter:Show()
		ApplyWindowCount(GetDesiredWindowCount())
		LayoutSessionWindows()
	end)
end
Addon.MirrorToChat = MirrorToChat

local function ReapplyPositioning()
	FlushChatToCorner()
	MirrorToChat()
end
Addon.ReapplyPositioning = ReapplyPositioning

-- Chasing the specific event that resets chat's position (Edit Mode's own
-- layout-apply flow, confirmed to run on EDIT_MODE_LAYOUTS_UPDATED and on
-- ExitEditMode) kept losing races against exactly when Edit Mode decided to
-- re-assert its saved anchor - confirmed in-game, chat still wasn't flush
-- even after hooking both. Also confirmed in-game: dragging chat all the way
-- into the corner by hand in Edit Mode isn't possible either (its own
-- drag-clamp, UpdateClampOffsets/SetClampRectInsets, keeps a margin based on
-- the Selection overlay's own padding) - so there's no "correct" anchor to
-- coax Edit Mode into saving here, only a position this addon has to keep
-- re-asserting against it.
--
-- So instead of reacting to specific events, this polls on a timer and
-- re-flushes whenever chat has actually drifted off the corner - the same
-- "poll instead of chasing events" approach already used in
-- HiddenMicroMenuBagBar for a similar native-frame fight. Cheap: two GetLeft/
-- GetBottom reads and an early-out when nothing's drifted, a few times a
-- second.
--
-- Only needed to win the race against Edit Mode's own delayed reset right
-- after login though - left running forever, it fights the player the moment
-- they try to drag chat somewhere else on purpose, snapping it straight back
-- before they can let go of the mouse. So it only runs for a short window
-- after PLAYER_ENTERING_WORLD, then stops itself for the rest of the
-- session - the player can freely move chat (or the Damage Meter mirror
-- won't re-sync to it, but that's expected once they've moved chat by hand).
local POSITION_POLL_INTERVAL = 0.5
local POSITION_POLL_DURATION = 15
local positionElapsed = 0
local pollElapsedTotal = 0

local function IsChatFlush()
	if not ChatFrame1 then
		return true
	end
	local left, bottom = ChatFrame1:GetLeft(), ChatFrame1:GetBottom()
	return left and bottom and math.abs(left) < 0.5 and math.abs(bottom) < 0.5
end

local initialized = false

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			SymmetricalChatAndDamageMeterDB = SymmetricalChatAndDamageMeterDB or {}
			ApplyDefaults(SymmetricalChatAndDamageMeterDB, DEFAULTS)
			db = SymmetricalChatAndDamageMeterDB
			Addon.db = db
			if Addon.Options then
				Addon.Options:Init()
			end
		end
		return
	end

	-- PLAYER_ENTERING_WORLD
	if initialized then
		return
	end
	initialized = true

	-- This addon only has a Damage Meter to mirror once the native one is
	-- enabled - confirmed real CVar name "damageMeterEnabled" (DamageMeter.lua
	-- itself names it DAMAGE_METER_ENABLED_CVAR, and it's what Interface
	-- Options -> Advanced Options' own "Enable Damage Meter" checkbox and
	-- Edit Mode's shouldEnableCVarName for the Damage Meter system are both
	-- wired to). Off by default on a fresh character (confirmed in-game),
	-- which left this addon with nothing to show or resize at all.
	if not GetCVarBool("damageMeterEnabled") then
		SetCVar("damageMeterEnabled", "1")
	end

	ReapplyPositioning()
	HideChatSideButtons()
	MoveEditBoxAboveChat()

	frame:SetScript("OnUpdate", function(self, delta)
		pollElapsedTotal = pollElapsedTotal + delta
		if pollElapsedTotal >= POSITION_POLL_DURATION then
			self:SetScript("OnUpdate", nil)
			return
		end

		positionElapsed = positionElapsed + delta
		if positionElapsed < POSITION_POLL_INTERVAL then
			return
		end
		positionElapsed = 0
		if not IsChatFlush() then
			ReapplyPositioning()
		end
	end)
end)
