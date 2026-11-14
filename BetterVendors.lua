local addonName = ...

local COLUMNS, ROWS = 4, 6
local PER_PAGE = COLUMNS * ROWS
local CELL_W, CELL_H, GAP = 190, 46, 10
local PANEL_PAD_X, PANEL_PAD_TOP = 12, 12
local GRID_H = ROWS * CELL_H + (ROWS - 1) * GAP
local TOOLBAR_H = 38
local TAB_H, PANEL_H = 30, PANEL_PAD_TOP + TOOLBAR_H + GRID_H + 10
local FRAME_W = COLUMNS * CELL_W + (COLUMNS - 1) * GAP + 2 * PANEL_PAD_X + 20
local FRAME_H = 80 + TAB_H + PANEL_H + 50

-- Same bronze palette as SharedForeverUI2 tables and tabs.
local ROW = { 0.12, 0.077, 0.043, 0.68 }
local HOVER = { 0.31, 0.21, 0.105, 0.96 }
local HEADER = { 0.25, 0.16, 0.075, 0.94 }
local BRONZE = { 0.39, 0.27, 0.14, 0.65 }
local GOLD = { 0.73, 0.49, 0.21, 0.85 }
local TEXT = { 0.86, 0.72, 0.49 }

local state = { tab = "all", page = 1, merchantOpen = false, search = "", slot = "all" }
local slotButton, slotPicker
local db
local searchBox, searchHint, host
local window, tabs, cells, pageText, prevButton, nextButton, goldText, repairButton, repairText

local function Paint(tex, c)
	tex:SetColorTexture(c[1], c[2], c[3], c[4])
end

-- This client has no GetMerchantItemInfo/GetCoinTextureString globals.
local function MerchantInfo(index)
	if GetMerchantItemInfo then
		return GetMerchantItemInfo(index)
	end
	local info = C_MerchantFrame.GetItemInfo(index)
	if not info then
		return nil
	end
	return info.name, info.texture, info.price, info.stackCount, info.numAvailable,
		info.isPurchasable, info.isUsable, info.hasExtendedCost
end

local function GetCoinTextureString(copper)
	if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
		return C_CurrencyInfo.GetCoinTextureString(copper or 0)
	end
	return _G.GetCoinTextureString(copper or 0)
end

local MAX_COSTS = MAX_ITEM_COST or 3
local RED = "|cffff5050"

-- Extra (non-gold) costs of a merchant slot: currencies and/or items.
local function ReadCosts(index)
	local costs
	for i = 1, MAX_COSTS do
		local texture, value, link, currencyName = GetMerchantItemCostItem(index, i)
		if texture and value and value > 0 then
			costs = costs or {}
			costs[#costs + 1] = {
				texture = texture, value = value, link = link, isCurrency = currencyName ~= nil,
			}
		end
	end
	return costs
end

-- How many of a cost's currency/item the player has; nil when unknown.
local function Owned(cost)
	if not cost.link then
		return nil
	end
	if cost.isCurrency then
		local info = C_CurrencyInfo.GetCurrencyInfoFromLink(cost.link)
		return info and info.quantity
	end
	return C_Item.GetItemCount(cost.link, false, false, true)
end

local function CostText(entry, bundles)
	bundles = bundles or 1
	local parts = {}
	local gold = (entry.price or 0) * bundles
	if gold > 0 then
		local text = GetCoinTextureString(gold)
		parts[#parts + 1] = GetMoney() < gold and (RED .. text .. "|r") or text
	end
	for _, cost in ipairs(entry.costs or {}) do
		local need = cost.value * bundles
		local have = Owned(cost)
		local text = need .. " |T" .. cost.texture .. ":14|t"
		parts[#parts + 1] = (have and have < need) and (RED .. text .. "|r") or text
	end
	return #parts > 0 and table.concat(parts, "  ") or "Free"
end

local function CanAfford(entry, bundles)
	if GetMoney() < (entry.price or 0) * bundles then
		return false
	end
	for _, cost in ipairs(entry.costs or {}) do
		local have = Owned(cost)
		if have and have < cost.value * bundles then
			return false
		end
	end
	return true
end

-- Currencies/items this vendor asks for, with how many the player holds.
local function VendorCurrencySummary()
	local seen, parts = {}, {}
	for i = 1, GetMerchantNumItems() do
		for _, cost in ipairs(ReadCosts(i) or {}) do
			local key = cost.link or cost.texture
			if not seen[key] then
				seen[key] = true
				parts[#parts + 1] = string.format("|T%s:14|t %s", cost.texture, BreakUpLargeNumbers(Owned(cost) or 0))
			end
		end
	end
	return table.concat(parts, "   ")
end

local function MatchesSearch(name)
	return state.search == "" or name:lower():find(state.search, 1, true) ~= nil
end

-- Known recipes, pets, toys and so on carry an "Already known" tooltip line,
-- and recipes list their product's equip slot as a tooltip line too. Both are
-- read from the merchant tooltip once per vendor visit and cached.
local scanCache = {}
local NO_SCAN = {}

local SLOT_OF_EQUIPLOC = {
	INVTYPE_HEAD = "head", INVTYPE_NECK = "neck", INVTYPE_SHOULDER = "shoulder",
	INVTYPE_CLOAK = "back", INVTYPE_CHEST = "chest", INVTYPE_ROBE = "chest",
	INVTYPE_WRIST = "wrist", INVTYPE_HAND = "hands", INVTYPE_WAIST = "waist",
	INVTYPE_LEGS = "legs", INVTYPE_FEET = "feet", INVTYPE_FINGER = "finger",
	INVTYPE_TRINKET = "trinket", INVTYPE_WEAPON = "weapon",
	INVTYPE_WEAPONMAINHAND = "weapon", INVTYPE_2HWEAPON = "weapon",
	INVTYPE_SHIELD = "offhand", INVTYPE_WEAPONOFFHAND = "offhand",
	INVTYPE_HOLDABLE = "offhand", INVTYPE_RANGED = "weapon",
	INVTYPE_RANGEDRIGHT = "weapon", INVTYPE_THROWN = "weapon",
}

-- Localized slot label -> slot, for matching tooltip lines.
local SLOT_OF_TEXT, SLOT_LABEL = {}, {}
for equipLoc, slot in pairs(SLOT_OF_EQUIPLOC) do
	local text = _G[equipLoc]
	if text then
		SLOT_OF_TEXT[text] = SLOT_OF_TEXT[text] or slot
	end
end
for slot, equipLoc in pairs({
	head = "INVTYPE_HEAD", neck = "INVTYPE_NECK", shoulder = "INVTYPE_SHOULDER",
	back = "INVTYPE_CLOAK", chest = "INVTYPE_CHEST", wrist = "INVTYPE_WRIST",
	hands = "INVTYPE_HAND", waist = "INVTYPE_WAIST", legs = "INVTYPE_LEGS",
	feet = "INVTYPE_FEET", finger = "INVTYPE_FINGER", trinket = "INVTYPE_TRINKET",
	offhand = "INVTYPE_WEAPONOFFHAND",
}) do
	SLOT_LABEL[slot] = _G[equipLoc] or slot
end
-- One-hand, two-hand and ranged weapons share one "Weapons" entry.
SLOT_LABEL.weapon = WEAPONS or "Weapons"

local SLOT_CHOICES = { "all", "head", "neck", "shoulder", "back", "chest", "wrist", "hands",
	"waist", "legs", "feet", "finger", "trinket", "weapon", "offhand" }

local function Scan(index)
	local cached = scanCache[index]
	if cached then
		return cached
	end
	local data = C_TooltipInfo and C_TooltipInfo.GetMerchantItem and C_TooltipInfo.GetMerchantItem(index)
	if not (data and data.lines) then
		return NO_SCAN
	end
	local result = {}
	local link = GetMerchantItemLink(index)
	local equipLoc = link and select(4, C_Item.GetItemInfoInstant(link))
	result.slot = equipLoc and SLOT_OF_EQUIPLOC[equipLoc]
	for _, line in ipairs(data.lines) do
		if line.leftText == nil and TooltipUtil and TooltipUtil.SurfaceArgs then
			pcall(TooltipUtil.SurfaceArgs, line)
		end
		local text = line.leftText
		if text == ITEM_SPELL_KNOWN then
			result.known = true
		elseif not result.slot and text then
			result.slot = SLOT_OF_TEXT[text]
		end
	end
	scanCache[index] = result
	return result
end

local function BuildEntries()
	local list = {}
	local onlyUsable = state.tab == "usable" or (db and db.onlyUsable)
	local hideKnown = db and db.hideKnown
	if state.tab == "buyback" then
		for i = 1, GetNumBuybackItems() do
			local name, texture, price, quantity = GetBuybackItemInfo(i)
			if name and MatchesSearch(name) then
				list[#list + 1] = {
					index = i, buyback = true, name = name, texture = texture,
					price = price, quantity = quantity, link = GetBuybackItemLink(i),
				}
			end
		end
	else
		for i = 1, GetMerchantNumItems() do
			local name, texture, price, quantity, avail, _, isUsable = MerchantInfo(i)
			if name and (isUsable or not onlyUsable) and MatchesSearch(name)
				and not (hideKnown and Scan(i).known)
				and (state.slot == "all" or Scan(i).slot == state.slot) then
				list[#list + 1] = {
					index = i, name = name, texture = texture, avail = avail,
					costs = ReadCosts(i), usable = isUsable,
					price = price, quantity = quantity, link = GetMerchantItemLink(i),
				}
			end
		end
	end
	return list
end

local function QualityColor(link)
	local quality = link and select(3, C_Item.GetItemInfo(link))
	local c = quality and ITEM_QUALITY_COLORS[quality]
	if c then
		return c.r, c.g, c.b
	end
	return TEXT[1], TEXT[2], TEXT[3]
end

local function UpdateCell(cell, e)
	cell.entry = e
	if not e then
		cell:Hide()
		return
	end
	cell.icon:SetTexture(e.texture)
	cell.name:SetText(e.name)
	cell.name:SetTextColor(QualityColor(e.link))
	cell.price:SetText(CostText(e))
	-- Items the character can't use get a red tinted icon and a red note.
	local unusable = e.usable == false
	cell.unusable:SetShown(unusable)
	if unusable then
		cell.icon:SetVertexColor(1, 0.35, 0.35)
	else
		cell.icon:SetVertexColor(1, 1, 1)
	end
	cell.price:ClearAllPoints()
	cell.price:SetPoint("BOTTOMLEFT", cell.icon, "BOTTOMRIGHT", 8, 0)
	if unusable then
		cell.price:SetPoint("BOTTOMRIGHT", cell.unusable, "BOTTOMLEFT", -4, 0)
	else
		cell.price:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -6, 6)
	end
	cell.count:SetText((e.quantity and e.quantity > 1) and e.quantity or "")
	cell:Show()
end

local function DoRefresh()
	if not window or not window:IsShown() then
		return
	end

	local entries = BuildEntries()
	local pages = math.max(1, math.ceil(#entries / PER_PAGE))
	state.page = math.min(math.max(state.page, 1), pages)

	local first = (state.page - 1) * PER_PAGE
	for i, cell in ipairs(cells) do
		UpdateCell(cell, entries[first + i])
	end

	pageText:SetText(string.format("Page %d / %d", state.page, pages))
	prevButton:SetEnabled(state.page > 1)
	nextButton:SetEnabled(state.page < pages)

	window:SetWindowTitle(UnitName("npc") or "Vendor")
	local summary = VendorCurrencySummary()
	goldText:SetText(GetCoinTextureString(GetMoney()) .. (summary ~= "" and ("   " .. summary) or ""))

	local cost, canRepair = GetRepairAllCost()
	local show = CanMerchantRepair()
	repairButton:SetShown(show)
	repairText:SetShown(show)
	repairButton:SetEnabled(canRepair and cost > 0)
	repairText:SetText(cost > 0 and GetCoinTextureString(cost) or "")
end

local function Refresh()
	local ok, err = pcall(DoRefresh)
	if not ok then
		print("|cffff5555BetterVendors error:|r " .. tostring(err))
	end
end

-- Out-of-range pages are clamped by DoRefresh.
local function ChangePage(step)
	state.page = state.page + step
	Refresh()
end

local function SlotLabel(slot)
	return slot == "all" and (ALL or "All") or SLOT_LABEL[slot]
end

local function SelectSlot(slot, refresh)
	state.slot = slot
	if slotButton then
		slotButton:SetText("Slot: " .. SlotLabel(slot))
	end
	if slotPicker then
		slotPicker:Hide()
	end
	if refresh then
		state.page = 1
		Refresh()
	end
end

local OpenBuyDialog

local function OnCellClick(self, button)
	local e = self.entry
	if not e or button ~= "RightButton" then
		return
	end
	if e.buyback then
		BuybackItem(e.index)
	elseif IsShiftKeyDown() then
		OpenBuyDialog(e)
	else
		BuyMerchantItem(e.index, 1)
	end
end

local function OnCellEnter(self)
	Paint(self.bg, HOVER)
	local e = self.entry
	if not e then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if e.buyback then
		GameTooltip:SetBuybackItem(e.index)
	else
		GameTooltip:SetMerchantItem(e.index)
	end
	GameTooltip:Show()
end

local function Rule(owner, a, b, vertical, color)
	local t = owner:CreateTexture(nil, "BORDER")
	t:SetPoint(a, owner, a)
	t:SetPoint(b, owner, b)
	if vertical then t:SetWidth(1) else t:SetHeight(1) end
	Paint(t, color)
	return t
end

local function CreateCell(parent, i)
	local col = (i - 1) % COLUMNS
	local row = math.floor((i - 1) / COLUMNS)

	local b = CreateFrame("Button", nil, parent)
	b:SetSize(CELL_W, CELL_H)
	b:SetPoint("TOPLEFT", parent, "TOPLEFT", col * (CELL_W + GAP), -row * (CELL_H + GAP))
	b:RegisterForClicks("RightButtonUp")

	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	Paint(b.bg, ROW)
	Rule(b, "TOPLEFT", "TOPRIGHT", false, GOLD)
	Rule(b, "BOTTOMLEFT", "BOTTOMRIGHT", false, BRONZE)
	Rule(b, "TOPLEFT", "BOTTOMLEFT", true, BRONZE)
	Rule(b, "TOPRIGHT", "BOTTOMRIGHT", true, BRONZE)

	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetSize(34, 34)
	b.icon:SetPoint("LEFT", 6, 0)
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	local frameLine = b:CreateTexture(nil, "OVERLAY")
	frameLine:SetPoint("TOPLEFT", b.icon, -1, 1)
	frameLine:SetPoint("BOTTOMRIGHT", b.icon, 1, -1)
	frameLine:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.9)
	frameLine:SetDrawLayer("BACKGROUND", 2)

	b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.count:SetPoint("BOTTOMRIGHT", b.icon, "BOTTOMRIGHT", -1, 2)

	b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.name:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 8, -2)
	b.name:SetPoint("RIGHT", b, "RIGHT", -6, 0)
	b.name:SetJustifyH("LEFT")
	b.name:SetWordWrap(false)

	b.price = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.price:SetPoint("BOTTOMLEFT", b.icon, "BOTTOMRIGHT", 8, 0)
	b.price:SetJustifyH("LEFT")
	b.price:SetWordWrap(false)

	b.unusable = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.unusable:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -6, 6)
	b.unusable:SetTextColor(1, 0.31, 0.31)
	b.unusable:SetText("Can't use")
	b.unusable:Hide()

	b:SetScript("OnClick", OnCellClick)
	b:SetScript("OnEnter", OnCellEnter)
	b:SetScript("OnLeave", function(self)
		Paint(self.bg, ROW)
		GameTooltip:Hide()
	end)
	b:Hide()
	return b
end

local buyDialog, buyTicker

local function CancelPurchase()
	if buyTicker then
		buyTicker:Cancel()
		buyTicker = nil
	end
end

local function Bundle(entry)
	return math.max(1, entry.quantity or 1)
end

-- Most purchases (bundles) affordable with the gold and every currency/item
-- cost, also limited by the vendor's stock (which is counted in purchases).
local function MaxAffordable(entry)
	local bundles = math.huge
	local price = entry.price or 0
	if price > 0 then
		bundles = math.floor(GetMoney() / price)
	end
	for _, cost in ipairs(entry.costs or {}) do
		local have = Owned(cost)
		if have then
			bundles = math.min(bundles, math.floor(have / cost.value))
		end
	end
	if entry.avail and entry.avail >= 0 then
		bundles = math.min(bundles, entry.avail)
	end
	if bundles == math.huge then
		bundles = 9999
	end
	return math.max(1, math.min(bundles, 9999))
end

-- BuyMerchantItem takes an item count (whole bundles) and is capped at one
-- stack per call, so large orders are split into stack-sized purchases spaced
-- out to avoid server throttling.
local function StartPurchase(entry, bundles)
	CancelPurchase()
	local bundle = Bundle(entry)
	local chunkSize = math.max(bundle, math.floor(GetMerchantItemMaxStack(entry.index) / bundle) * bundle)
	local remaining = bundles * bundle
	buyTicker = C_Timer.NewTicker(0.2, function()
		if not state.merchantOpen or GetMerchantItemLink(entry.index) ~= entry.link then
			CancelPurchase()
			return
		end
		local chunk = math.min(remaining, chunkSize)
		BuyMerchantItem(entry.index, chunk)
		remaining = remaining - chunk
		if remaining <= 0 then
			CancelPurchase()
		end
	end)
end

local function CreateBuyDialog(UI)
	local d = CreateFrame("Frame", nil, window)
	d:SetSize(340, 236)
	d:SetPoint("CENTER", window, "CENTER")
	d:SetFrameStrata("DIALOG")
	d:EnableMouse(true)
	d:Hide()

	local bg = d:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.08, 0.05, 0.03, 0.98)
	Rule(d, "TOPLEFT", "TOPRIGHT", false, GOLD)
	Rule(d, "BOTTOMLEFT", "BOTTOMRIGHT", false, BRONZE)
	Rule(d, "TOPLEFT", "BOTTOMLEFT", true, BRONZE)
	Rule(d, "TOPRIGHT", "BOTTOMRIGHT", true, BRONZE)

	d.icon = d:CreateTexture(nil, "ARTWORK")
	d.icon:SetSize(34, 34)
	d.icon:SetPoint("TOPLEFT", 16, -16)
	d.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	d.name = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	d.name:SetPoint("LEFT", d.icon, "RIGHT", 10, 0)
	d.name:SetPoint("RIGHT", d, "RIGHT", -16, 0)
	d.name:SetJustifyH("LEFT")
	d.name:SetWordWrap(false)

	d.input = UI:CreateNumberInput(d, { min = 1, max = 9999, step = 1, value = 1, width = 200,
		onChanged = function() d:Update() end })
	d.input:SetPoint("TOP", d, "TOP", 0, -66)

	local stackButton = UI:CreateActionButton(d, { text = "Stack", width = 80, height = 28,
		onClick = function()
			local entry = d.entry
			local perStack = math.floor(GetMerchantItemMaxStack(entry.index) / Bundle(entry))
			d.input:SetValue(math.max(1, perStack), true)
			d:Update()
		end })
	stackButton:SetPoint("TOPLEFT", d.input, "BOTTOMLEFT", 0, -8)
	local maxButton = UI:CreateActionButton(d, { text = "Max", width = 80, height = 28,
		onClick = function()
			d.input:SetValue(MaxAffordable(d.entry), true)
			d:Update()
		end })
	maxButton:SetPoint("TOPRIGHT", d.input, "BOTTOMRIGHT", 0, -8)

	d.total = d:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	d.total:SetPoint("TOP", d.input, "BOTTOM", 0, -50)
	d.receive = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	d.receive:SetPoint("TOP", d.total, "BOTTOM", 0, -4)
	d.receive:SetTextColor(TEXT[1], TEXT[2], TEXT[3])

	d.buy = UI:CreateActionButton(d, { text = "Buy", width = 110, height = 30,
		onClick = function()
			d.input.editBox:ClearFocus()
			local bundles = d.input:GetValue()
			if CanAfford(d.entry, bundles) then
				StartPurchase(d.entry, bundles)
				d:Hide()
			end
		end })
	d.buy:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 40, 16)
	local cancel = UI:CreateActionButton(d, { text = "Cancel", width = 110, height = 30,
		onClick = function() d:Hide() end })
	cancel:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -40, 16)

	-- The number is a count of purchases; a purchase may hold several items
	-- (for example 200 bullets), so the items received are shown separately.
	function d:Update()
		local bundles = self.input:GetValue()
		local bundle = Bundle(self.entry)
		self.total:SetText("Total: " .. CostText(self.entry, bundles))
		self.total:SetTextColor(1, 1, 1)
		if bundle > 1 then
			self.receive:SetText(string.format("You get %d items (%d per purchase)", bundles * bundle, bundle))
		else
			self.receive:SetText("")
		end
		self.buy:SetEnabled(CanAfford(self.entry, bundles))
	end

	d.input.editBox:HookScript("OnEnterPressed", function() d:Update() end)
	d:SetScript("OnHide", function() d.input.editBox:ClearFocus() end)
	return d
end

function OpenBuyDialog(entry)
	buyDialog.entry = entry
	buyDialog.icon:SetTexture(entry.texture)
	buyDialog.name:SetText(entry.name)
	buyDialog.name:SetTextColor(QualityColor(entry.link))
	buyDialog.input:SetValue(1, false)
	buyDialog:Update()
	buyDialog:Show()
end

local function Build(UI, ctx)
	-- Compact multi-column slot chooser; the library's single-column popup is
	-- taller than this window with this many choices.
	local function CreateSlotPicker()
		local COLS, BW, BH, PAD = 3, 112, 26, 8
		local rows = math.ceil(#SLOT_CHOICES / COLS)

		-- Transparent catcher: a click anywhere outside the picker closes it.
		local cover = CreateFrame("Button", nil, host)
		cover:SetAllPoints(host)
		cover:SetFrameLevel(host:GetFrameLevel() + 40)
		cover:SetScript("OnClick", function(self) self:Hide() end)
		cover:Hide()

		local panel = CreateFrame("Frame", nil, cover)
		panel:SetSize(COLS * BW + (COLS + 1) * PAD, rows * BH + (rows + 1) * PAD)
		panel:SetFrameLevel(cover:GetFrameLevel() + 5)
		panel:EnableMouse(true)
		panel:SetPoint("TOPLEFT", slotButton, "BOTTOMLEFT", 0, -4)
		local bg = panel:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.08, 0.05, 0.03, 0.98)
		Rule(panel, "TOPLEFT", "TOPRIGHT", false, GOLD)
		Rule(panel, "BOTTOMLEFT", "BOTTOMRIGHT", false, BRONZE)
		Rule(panel, "TOPLEFT", "BOTTOMLEFT", true, BRONZE)
		Rule(panel, "TOPRIGHT", "BOTTOMRIGHT", true, BRONZE)

		local buttons = {}
		local function Restyle()
			for slot, b in pairs(buttons) do
				local active = slot == state.slot
				Paint(b.bg, active and HEADER or ROW)
				if active then
					b.label:SetTextColor(1, 0.82, 0.16)
				else
					b.label:SetTextColor(TEXT[1], TEXT[2], TEXT[3])
				end
			end
		end
		for i, slot in ipairs(SLOT_CHOICES) do
			local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
			local b = CreateFrame("Button", nil, panel)
			b:SetSize(BW, BH)
			b:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + col * (BW + PAD), -(PAD + row * (BH + PAD)))
			b.bg = b:CreateTexture(nil, "BACKGROUND")
			b.bg:SetAllPoints()
			b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			b.label:SetPoint("CENTER")
			b.label:SetText(SlotLabel(slot))
			b:SetScript("OnEnter", function(self) Paint(self.bg, HOVER) end)
			b:SetScript("OnLeave", Restyle)
			b:SetScript("OnClick", function() SelectSlot(slot, true) end)
			buttons[slot] = b
		end
		cover:SetScript("OnShow", Restyle)
		return cover
	end

	local w, reason = ctx:CreateWindow({
		windowId = "Vendor",
		title = "Vendor",
		icon = "Interface\\Icons\\INV_Misc_Coin_01",
		width = FRAME_W,
		height = FRAME_H,
		sidebarWidth = 0,
		resizable = false,
		savePosition = false,
	})
	if not w then
		UI:Report(reason)
		return false
	end
	window = w
	window:ClearAllPoints()
	window:SetPoint("CENTER")
	window:SetFrameStrata("HIGH")
	buyDialog = CreateBuyDialog(UI)

	-- The library window reserves a navigation sidebar and content pane; this
	-- addon draws straight onto the interior instead.
	window.navigation:Hide()
	window.content:Hide()
	host = CreateFrame("Frame", nil, window.interior)
	host:SetPoint("TOPLEFT", window.interior, "TOPLEFT", 0, -2)
	host:SetPoint("BOTTOMRIGHT", window.interior, "BOTTOMRIGHT", 0, 0)
	host:SetFrameLevel(window.interior:GetFrameLevel() + 5)

	tabs = UI:CreateTabs(host, {
		tabs = {
			{ id = "all", text = "All Items" },
			{ id = "usable", text = "Usable" },
			{ id = "buyback", text = "Buy Back" },
		},
		selectedId = "all",
		width = FRAME_W - 34,
		tabWidth = 130,
		height = TAB_H,
		contentHeight = PANEL_H,
		onChanged = function(id)
			state.tab = id
			state.page = 1
			Refresh()
		end,
	})
	if not tabs then
		UI:Report("BetterVendors: could not create tabs")
		return false
	end
	tabs:SetPoint("TOPLEFT", host, "TOPLEFT", 10, -10)

	local toolbar = CreateFrame("Frame", nil, tabs.content)
	toolbar:SetPoint("TOPLEFT", tabs.content, "TOPLEFT", 0, 0)
	toolbar:SetPoint("TOPRIGHT", tabs.content, "TOPRIGHT", 0, 0)
	toolbar:SetHeight(TOOLBAR_H - 8)

	searchBox = UI:CreateEditBox(toolbar, {
		width = 170,
		height = 28,
		maxLetters = 60,
		onChanged = function(text)
			state.search = (text or ""):lower()
			state.page = 1
			Refresh()
		end,
	})
	if not searchBox then
		UI:Report("BetterVendors: could not create search box")
		return false
	end
	searchBox:SetPoint("LEFT", toolbar, "LEFT", 0, 0)

	searchHint = toolbar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	searchHint:SetPoint("LEFT", searchBox, "LEFT", 8, 0)
	searchHint:SetText("Search items...")
	searchBox:HookScript("OnTextChanged", function(self)
		searchHint:SetShown(self:GetText() == "")
	end)
	searchBox:HookScript("OnEscapePressed", function(self) self:ClearFocus() end)

	slotButton = UI:CreateActionButton(toolbar, {
		text = "Slot: " .. SlotLabel("all"), width = 130, height = 28,
		onClick = function()
			slotPicker:SetShown(not slotPicker:IsShown())
		end,
	})
	slotButton:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)
	slotPicker = CreateSlotPicker()

	local usableToggle = ctx:CreateToggle(toolbar, {
		label = "Only usable",
		width = 210,
		trackWidth = 68,
		checked = db.onlyUsable == true,
		onChanged = function(checked)
			db.onlyUsable = checked
			state.page = 1
			Refresh()
		end,
	})
	local knownToggle = ctx:CreateToggle(toolbar, {
		label = "Hide known",
		width = 210,
		trackWidth = 68,
		checked = db.hideKnown == true,
		onChanged = function(checked)
			db.hideKnown = checked
			state.page = 1
			Refresh()
		end,
	})
	if usableToggle and knownToggle then
		usableToggle:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)
		knownToggle:SetPoint("RIGHT", usableToggle, "LEFT", -8, 0)
	end

	-- Scrolling anywhere in the window flips pages (wheel up = previous page).
	host:EnableMouseWheel(true)
	host:SetScript("OnMouseWheel", function(_, delta)
		ChangePage(delta > 0 and -1 or 1)
	end)

	local grid = CreateFrame("Frame", nil, tabs.content)
	grid:SetPoint("TOPLEFT", tabs.content, "TOPLEFT", 0, -TOOLBAR_H)
	grid:SetSize(COLUMNS * CELL_W + (COLUMNS - 1) * GAP, GRID_H)

	cells = {}
	for i = 1, PER_PAGE do
		cells[i] = CreateCell(grid, i)
	end

	local footer = CreateFrame("Frame", nil, host)
	footer:SetPoint("TOPLEFT", tabs, "BOTTOMLEFT", 0, -8)
	footer:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -10, 6)

	goldText = footer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	goldText:SetPoint("LEFT", footer, "LEFT", 4, 0)

	prevButton = UI:CreateActionButton(footer, {
		text = "Prev", width = 90, height = 28,
		onClick = function()
			state.page = state.page - 1
			Refresh()
		end,
	})
	prevButton:SetPoint("CENTER", footer, "CENTER", -80, 0)
	goldText:SetPoint("RIGHT", prevButton, "LEFT", -12, 0)
	goldText:SetJustifyH("LEFT")

	pageText = footer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	pageText:SetPoint("CENTER", footer, "CENTER", 0, 0)
	pageText:SetTextColor(TEXT[1], TEXT[2], TEXT[3])

	nextButton = UI:CreateActionButton(footer, {
		text = "Next", width = 90, height = 28,
		onClick = function()
			state.page = state.page + 1
			Refresh()
		end,
	})
	nextButton:SetPoint("CENTER", footer, "CENTER", 80, 0)

	repairButton = UI:CreateActionButton(footer, {
		text = "Repair All", width = 110, height = 28,
		onClick = function() RepairAllItems() end,
	})
	repairButton:SetPoint("RIGHT", footer, "RIGHT", 0, 0)

	repairText = footer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	repairText:SetPoint("RIGHT", repairButton, "LEFT", -8, 0)

	-- Closing our window (X or ESC) must also end the vendor session.
	window:HookScript("OnHide", function()
		buyDialog:Hide()
		if state.merchantOpen then
			state.merchantOpen = false
			CloseMerchant()
		end
	end)
	return true
end

local function DoOpenVendor()
	state.merchantOpen = true
	wipe(scanCache)
	if window:IsShown() then
		return
	end
	state.page = 1
	state.tab = "all"
	tabs:SetSelection("all", false)
	state.search = ""
	SelectSlot("all", false)
	searchBox:SetText("")
	window:Show()
	Refresh()
end

local function OpenVendor()
	local ok, err = pcall(DoOpenVendor)
	if not ok then
		print("|cffff5555BetterVendors error:|r " .. tostring(err))
	end
end

local function HideDefaultMerchant()
	local function Conceal(self)
		self:SetAlpha(0)
		self:EnableMouse(false)
	end
	Conceal(MerchantFrame)
	-- Blizzard's panel manager keeps room for the default vendor frame and pushes
	-- other panels (Character, Bags...) aside. Our window is not a panel, so make
	-- the hidden frame reserve no space.
	MerchantFrame:SetAttribute("UIPanelLayout-width", 0)
	if UIPanelWindows and UIPanelWindows.MerchantFrame then
		UIPanelWindows.MerchantFrame.width = 0
	end
	-- Other code (fades, skins) may restore the alpha, so pin it at 0.
	hooksecurefunc(MerchantFrame, "SetAlpha", function(self, alpha)
		if alpha ~= 0 then
			self:SetAlpha(0)
		end
	end)
	-- The default frame shows before MERCHANT_SHOW reaches us; open ours at the
	-- same moment so there is no visible gap.
	MerchantFrame:HookScript("OnShow", function(self)
		Conceal(self)
		OpenVendor()
	end)
end

local function Setup()
	local UI = _G.SharedForeverUI2
	if not UI then
		print("|cffff5555BetterVendors:|r SharedForeverUI2 is required.")
		return
	end

	BetterVendorsDB = BetterVendorsDB or {}
	db = BetterVendorsDB
	db.ui = type(db.ui) == "table" and db.ui or {}

	local ctx, err = UI:CreateAddonContext({
		id = "BetterVendors",
		getStorage = function() return db.ui end,
		getLanguage = function() return db.language or "auto" end,
		setLanguage = function(lang) db.language = lang end,
		translations = { en = {} },
	})
	if not ctx then
		UI:Report(err)
		return
	end
	if not Build(UI, ctx) then
		return
	end

	HideDefaultMerchant()

	local ev = CreateFrame("Frame")
	ev:RegisterEvent("MERCHANT_SHOW")
	ev:RegisterEvent("MERCHANT_CLOSED")
	ev:RegisterEvent("MERCHANT_UPDATE")
	ev:RegisterEvent("PLAYER_MONEY")
	ev:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
	ev:RegisterEvent("BAG_UPDATE_DELAYED")
	ev:SetScript("OnEvent", function(_, event)
		if event == "MERCHANT_SHOW" then
			OpenVendor()
		elseif event == "MERCHANT_CLOSED" then
			state.merchantOpen = false
			CancelPurchase()
			window:Hide()
		else
			if event == "MERCHANT_UPDATE" then
				wipe(scanCache)
			end
			Refresh()
			if buyDialog:IsShown() then
				buyDialog:Update()
			end
		end
	end)
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, loaded)
	if loaded ~= addonName then
		return
	end
	self:UnregisterAllEvents()
	local ok, err = pcall(Setup)
	if not ok then
		print("|cffff5555BetterVendors failed to load:|r " .. tostring(err))
	end
end)
