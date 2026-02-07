--!strict
-- StarterPlayerScripts/SimulationClient.client.lua
-- FINAL: slot inventory UI (Hotbar 12 + Bag 36) + Shop + TopBar + Tile farming click actions
-- No Instance.new (UI must be manual)

----------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

----------------------------------------------------------------
-- REMOTES
----------------------------------------------------------------
local Assets = ReplicatedStorage:WaitForChild("Assets")
local Remotes = Assets:WaitForChild("Remotes")

local RF_RequestSnapshot = Remotes:WaitForChild("RequestSnapshot") :: RemoteFunction
local RE_DataSnapshot = Remotes:WaitForChild("DataSnapshot") :: RemoteEvent
local RE_DataDelta = Remotes:WaitForChild("DataDelta") :: RemoteEvent

local RF_BuySeed = Remotes:WaitForChild("BuySeed") :: RemoteFunction
local RF_SellItem = Remotes:WaitForChild("SellItem") :: RemoteFunction

local RF_HoeTile = Remotes:WaitForChild("HoeTile") :: RemoteFunction
local RF_PlantTile = Remotes:WaitForChild("PlantTile") :: RemoteFunction
local RF_WaterTile = Remotes:WaitForChild("WaterTile") :: RemoteFunction
local RF_HarvestTile = Remotes:WaitForChild("HarvestTile") :: RemoteFunction

local RF_InvEquip = Remotes:WaitForChild("Inventory_Equip") :: RemoteFunction

----------------------------------------------------------------
-- EXTERNAL DEPS
----------------------------------------------------------------
local NumberFormat = require(ReplicatedStorage.Assets.Shared:WaitForChild("NumberFormat"))
local ShopConfig = require(ReplicatedStorage.Assets.Config:WaitForChild("ShopConfig"))

----------------------------------------------------------------
-- UTIL
----------------------------------------------------------------
local warned: {[string]: boolean} = {}

local function warnOnce(key: string, msg: string)
	if warned[key] then return end
	warned[key] = true
	warn(msg)
end

local function clampInt(x: any): number
	return math.max(0, math.floor(tonumber(x) or 0))
end

local function deepMerge(dest: any, src: any)
	if type(dest) ~= "table" or type(src) ~= "table" then return end
	for k, v in pairs(src) do
		if v == false then
			dest[k] = nil -- deletion sentinel
		elseif type(v) == "table" and type(dest[k]) == "table" then
			deepMerge(dest[k], v)
		else
			dest[k] = v
		end
	end
end

local function fmtLayers(L: {number}): string
	if type(L) ~= "table" then return "0" end
	return NumberFormat.FromLayers(L)
end

local function isSeedId(id: string): boolean
	return string.sub(id, 1, 5) == "Seed_"
end

local function isCropId(id: string): boolean
	return string.sub(id, 1, 5) == "Crop_"
end

----------------------------------------------------------------
-- STATE (minimal)
----------------------------------------------------------------
type CatalogIndex = {
	SeedsById: {[string]: any},
	CropsById: {[string]: any},
	QualityById: {[string]: any},
	SeedsSorted: {any},
}

local state = {
	Data = nil :: any,
	Derived = nil :: any,
	Catalog = nil :: any,
	Index = nil :: CatalogIndex?,
	serverNowAtApply = 0,
	clientNowAtApply = 0,
}

local function approxServerNow(): number
	if state.serverNowAtApply <= 0 then return os.time() end
	local dt = os.time() - state.clientNowAtApply
	return state.serverNowAtApply + dt
end

local function buildIndex(catalog: any): CatalogIndex
	local idx: CatalogIndex = {
		SeedsById = {},
		CropsById = {},
		QualityById = {},
		SeedsSorted = {},
	}
	if type(catalog) ~= "table" then return idx end

	local seeds = catalog.Seeds
	if type(seeds) == "table" then
		for _, s in ipairs(seeds) do
			if type(s) == "table" then
				local id = tostring(s.Id or "")
				if id ~= "" then
					idx.SeedsById[id] = s
					table.insert(idx.SeedsSorted, s)
				end
			end
		end
		table.sort(idx.SeedsSorted, function(a: any, b: any)
			local ao = tonumber(a.SortOrder) or 0
			local bo = tonumber(b.SortOrder) or 0
			if ao ~= bo then return ao < bo end
			return tostring(a.Id) < tostring(b.Id)
		end)
	end

	local crops = catalog.Crops
	if type(crops) == "table" then
		for _, c in ipairs(crops) do
			if type(c) == "table" then
				local id = tostring(c.Id or "")
				if id ~= "" then idx.CropsById[id] = c end
			end
		end
	end

	local q = catalog.Quality
	if type(q) == "table" then
		for _, d in ipairs(q) do
			if type(d) == "table" then
				local id = tostring(d.Id or "")
				if id ~= "" then idx.QualityById[id] = d end
			end
		end
	end

	return idx
end

local function applySnapshot(payload: any)
	if type(payload) ~= "table" then return end
	state.Data = payload.Data
	state.Derived = payload.Derived
	state.Catalog = payload.Catalog
	state.Index = buildIndex(state.Catalog)

	state.serverNowAtApply = clampInt(payload.ServerNow)
	state.clientNowAtApply = os.time()
end

local function extractDelta(payload: any): any
	if type(payload) ~= "table" then return nil end
	local d = payload.Delta
	if type(d) == "table" and d.Delta ~= nil then
		d = d.Delta
	end
	return d
end

local function applyDelta(payload: any)
	if type(state.Data) ~= "table" then return end
	local d = extractDelta(payload)
	if type(d) ~= "table" then return end

	if payload.ServerNow ~= nil then
		state.serverNowAtApply = clampInt(payload.ServerNow)
		state.clientNowAtApply = os.time()
	end

	-- Coins
	if d.Coins ~= nil then
		state.Data.Coins = state.Data.Coins or { L = {0} }
		state.Data.Coins.L = d.Coins
		d.Coins = nil
	end

	-- Inventory (slot-packed from server)
	if d.Inventory ~= nil then
		state.Data.Inventory = d.Inventory
		d.Inventory = nil
	end

	if type(d.Derived) == "table" then
		state.Derived = d.Derived
		d.Derived = nil
	end

	deepMerge(state.Data, d)
end

----------------------------------------------------------------
-- UI GETTERS
----------------------------------------------------------------
local function getSimUIRoot(): ScreenGui?
	local gui = player:WaitForChild("PlayerGui")
	local sim = gui:WaitForChild("StardewSimulatorUI", 5)
	if sim and sim:IsA("ScreenGui") then
		return sim
	end
	warnOnce("simui_missing", "[Client] StardewSimulatorUI yok.")
	return nil
end

local function getInvUI(): (ScreenGui?, Frame?, Frame?)
	local gui = player:WaitForChild("PlayerGui")
	local inv = gui:WaitForChild("InventoryUI", 5)
	if not (inv and inv:IsA("ScreenGui")) then
		warnOnce("invui_missing", "[Client] InventoryUI yok.")
		return nil, nil, nil
	end
	local hotbar = inv:WaitForChild("HotbarFrame") :: Frame
	local full = inv:WaitForChild("FullInventoryFrame") :: Frame
	return inv, hotbar, full
end

----------------------------------------------------------------
-- TOP BAR
----------------------------------------------------------------
local function bindTopBar()
	local ui = getSimUIRoot()
	if not ui then return end
	local pageContainer = ui:FindFirstChild("PageContainer")
	if not (pageContainer and pageContainer:IsA("Frame")) then return end
	local top = pageContainer:FindFirstChild("TopBar")
	if not (top and top:IsA("Frame")) then return end

	local coinsL = top:FindFirstChild("CoinsLabel")
	local farmL = top:FindFirstChild("FarmingLabel")

	local function render()
		local data = state.Data
		local derived = state.Derived

		if coinsL and coinsL:IsA("TextLabel") then
			local L = (data and data.Coins and data.Coins.L) or {0}
			coinsL.Text = "Gold: " .. fmtLayers(L)
		end

		if farmL and farmL:IsA("TextLabel") then
			local lvl = derived and derived.Farming and derived.Farming.Level or 1
			local xp = derived and derived.Farming and derived.Farming.XP or 0
			local need = derived and derived.Farming and derived.Farming.Need or 0
			farmL.Text = ("Farming Lv %d  (%d/%d)"):format(lvl, xp, need)
		end
	end

	-- render on every delta/snapshot
	RE_DataSnapshot.OnClientEvent:Connect(function()
		render()
	end)
	RE_DataDelta.OnClientEvent:Connect(function()
		render()
	end)

	render()
end

----------------------------------------------------------------
-- ROUTER (tabs)
----------------------------------------------------------------
local function bindRouter()
	local ui = getSimUIRoot()
	if not ui then return end

	local pageContainer = ui:FindFirstChild("PageContainer")
	if not (pageContainer and pageContainer:IsA("Frame")) then return end

	local tabs = pageContainer:FindFirstChild("Tabs")
	if not (tabs and tabs:IsA("Frame")) then
		local farm = pageContainer:FindFirstChild("FarmPage")
		if farm and farm:IsA("Frame") then farm.Visible = true end
		return
	end

	local pages = {
		Farm = pageContainer:FindFirstChild("FarmPage"),
		Maps = pageContainer:FindFirstChild("MapsPage"),
		Pierre = pageContainer:FindFirstChild("ShopPierrePage"),
		Joja = pageContainer:FindFirstChild("ShopJojaPage"),
	}

	local function set(pageKey: string)
		for k, p in pairs(pages) do
			if p and p:IsA("Frame") then
				p.Visible = (k == pageKey)
			end
		end
	end

	local function hook(btnName: string, pageKey: string)
		local b = tabs:FindFirstChild(btnName)
		if b and b:IsA("GuiButton") then
			b.Activated:Connect(function()
				set(pageKey)
			end)
		end
	end

	hook("TabFarm", "Farm")
	hook("TabMaps", "Maps")
	hook("TabPierre", "Pierre")
	hook("TabJoja", "Joja")

	set("Farm")
end

----------------------------------------------------------------
-- SEED SHOP UI (buy only)
----------------------------------------------------------------
local function seedUnlocked(data: any, seedDef: any): boolean
	local u = seedDef.Unlock
	if type(u) ~= "table" then return true end
	local kind = tostring(u.Kind or "Always")
	if kind == "Always" then
		return true
	elseif kind == "Level" then
		local need = clampInt(u.FarmingLevel)
		local lvl = clampInt(data and data.Skills and data.Skills.FarmingLevel)
		return lvl >= need
	elseif kind == "Area" then
		local areaId = tostring(u.AreaId or "")
		return (type(data) == "table")
			and (type(data.Unlocks) == "table")
			and (type(data.Unlocks.Areas) == "table")
			and (data.Unlocks.Areas[areaId] == true)
	end
	return false
end

local function bindSeedShop(shopKey: string)
	local ui = getSimUIRoot()
	if not ui then return end

	local pageContainer = ui:FindFirstChild("PageContainer")
	if not (pageContainer and pageContainer:IsA("Frame")) then return end

	local pageName = (shopKey == "Joja") and "ShopJojaPage" or "ShopPierrePage"
	local shopPage = pageContainer:FindFirstChild(pageName)
	if not (shopPage and shopPage:IsA("Frame")) then
		warnOnce("shop_missing_" .. pageName, "[Client] " .. pageName .. " yok.")
		return
	end

	local shop = ShopConfig.GetShop(shopKey)
	local allowSet: {[string]: boolean} = {}
	if shop then
		for _, id in ipairs(shop.SeedIds) do
			allowSet[id] = true
		end
	end

	local list = shopPage:FindFirstChild("SeedList")
	local template = list and list:FindFirstChild("SeedRowTemplate")
	if not (list and list:IsA("ScrollingFrame") and template and template:IsA("Frame")) then
		warnOnce("seedlist_missing_" .. pageName, "[Client] " .. pageName .. "/SeedList/SeedRowTemplate eksik.")
		return
	end
	(template :: Frame).Visible = false

	local rowById: {[string]: Frame} = {}

	local function ensureRow(seedId: string): Frame
		local row = rowById[seedId]
		if row and row.Parent then return row end
		local r = (template :: Frame):Clone()
		r.Name = "Seed_" .. seedId
		r.Visible = true
		r.Parent = list
		rowById[seedId] = r
		return r
	end

	local function render()
		local data = state.Data
		local idx = state.Index
		if not idx or type(data) ~= "table" then return end

		for order, s in ipairs(idx.SeedsSorted) do
			local seedId = tostring(s.Id or "")
			if seedId ~= "" and allowSet[seedId] then
				local row = ensureRow(seedId)
				row.LayoutOrder = order

				local nameL = row:FindFirstChild("NameLabel") :: TextLabel?
				local costL = row:FindFirstChild("CostLabel") :: TextLabel?
				local growL = row:FindFirstChild("GrowLabel") :: TextLabel?
				local lockL = row:FindFirstChild("LockLabel") :: TextLabel?
				local buyBtn = row:FindFirstChild("BuyButton") :: GuiButton?

				local unlocked = seedUnlocked(data, s)

				if nameL then nameL.Text = tostring(s.Name or seedId) end
				if costL then costL.Text = fmtLayers(s.BuyCostL or {0}) end
				if growL then growL.Text = ("%ds"):format(clampInt(s.GrowSec)) end

				if lockL then
					if unlocked then
						lockL.Text = ""
						lockL.Visible = false
					else
						local u = s.Unlock
						local kind = type(u) == "table" and tostring(u.Kind) or "Locked"
						if kind == "Level" then
							lockL.Text = ("Lv %d"):format(clampInt(u.FarmingLevel))
						elseif kind == "Area" then
							lockL.Text = ("Area: %s"):format(tostring(u.AreaId or "?"))
						else
							lockL.Text = "Locked"
						end
						lockL.Visible = true
					end
				end

				if buyBtn then
					buyBtn.Active = unlocked
					buyBtn.AutoButtonColor = unlocked
					if not buyBtn:GetAttribute("Hooked") then
						buyBtn:SetAttribute("Hooked", true)
						buyBtn.Activated:Connect(function()
							local ok, res = pcall(function()
								return RF_BuySeed:InvokeServer(seedId, 1, shopKey)
							end)
							if not ok then
								warn("[Shop] BuySeed invoke failed")
								return
							end
							if type(res) == "table" and res.ok ~= true then
								warn("[Shop] Buy failed:", res.err)
							end
						end)
					end
				end
			end
		end

		task.defer(function()
			local layout = list:FindFirstChildOfClass("UIListLayout")
			if layout then
				(list :: ScrollingFrame).CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y)
			end
		end)
	end

	RE_DataSnapshot.OnClientEvent:Connect(render)
	RE_DataDelta.OnClientEvent:Connect(render)
	render()
end

----------------------------------------------------------------
-- INVENTORY UI (Hotbar 12 + Full 36)
----------------------------------------------------------------
type SlotData = { Id: string, Q: string, Count: number }
type InventoryClient = {
	HotbarSize: number,
	BagSize: number,
	EquippedHotbar: number,
	Hotbar: { any }, -- SlotData or false
	Bag: { any }, -- SlotData or false
}

type SlotUI = {
	Button: GuiButton,
	Icon: ImageLabel,
	Count: TextLabel,
	EquippedStroke: UIStroke?,
	Index: number,
	IsHotbar: boolean,
}

local invUIReady = false
local hotbarSlots: {SlotUI} = {}
local bagSlots: {SlotUI} = {}
local fullFrameRef: Frame? = nil

local function getSlot(frame: Frame, idx: number, isHotbar: boolean): SlotUI
	local slotName = "Slot_" .. tostring(idx)
	local obj = frame:WaitForChild(slotName)
	assert(obj:IsA("GuiButton") or obj:IsA("ImageButton") or obj:IsA("TextButton"), ("UI %s must be a button"):format(slotName))
	local btn = obj :: GuiButton

	local iconObj = btn:WaitForChild("Icon")
	assert(iconObj:IsA("ImageLabel"), ("%s.Icon must be ImageLabel"):format(slotName))
	local countObj = btn:WaitForChild("Count")
	assert(countObj:IsA("TextLabel"), ("%s.Count must be TextLabel"):format(slotName))

	local stroke: UIStroke? = nil
	if isHotbar then
		local s = btn:WaitForChild("EquippedStroke")
		assert(s:IsA("UIStroke"), ("%s.EquippedStroke must be UIStroke"):format(slotName))
		stroke = s :: UIStroke
	end

	return {
		Button = btn,
		Icon = iconObj :: ImageLabel,
		Count = countObj :: TextLabel,
		EquippedStroke = stroke,
		Index = idx,
		IsHotbar = isHotbar,
	}
end

local function getInv(): InventoryClient?
	local data = state.Data
	if type(data) ~= "table" then return nil end
	local inv = data.Inventory
	if type(inv) ~= "table" then return nil end
	return inv :: any
end

local function slotItem(inv: InventoryClient, isHotbar: boolean, idx: number): SlotData?
	local list = isHotbar and inv.Hotbar or inv.Bag
	if type(list) ~= "table" then return nil end
	local raw = list[idx]
	if raw and raw ~= false and type(raw) == "table" then
		return raw :: any
	end
	return nil
end

local function setSlot(slot: SlotUI, item: SlotData?, equipped: boolean)
	if item == nil then
		slot.Count.Text = ""
	else
		slot.Count.Text = (item.Count > 1) and tostring(item.Count) or ""
	end
	if slot.EquippedStroke then
		slot.EquippedStroke.Enabled = equipped
	end
end

local function renderInventoryUI()
	if not invUIReady then return end
	local inv = getInv()
	if not inv then return end

	local hbSize = math.clamp(tonumber(inv.HotbarSize) or 12, 1, 12)
	local bagSize = math.clamp(tonumber(inv.BagSize) or 36, 1, 36)
	local eq = tonumber(inv.EquippedHotbar) or 0

	for i = 1, 12 do
		local item = (i <= hbSize) and slotItem(inv, true, i) or nil
		setSlot(hotbarSlots[i], item, (eq == i))
	end

	for i = 1, 36 do
		local item = (i <= bagSize) and slotItem(inv, false, i) or nil
		setSlot(bagSlots[i], item, false)
	end
end

local function bindInventoryUI()
	local _, hotbarFrame, fullFrame = getInvUI()
	if not (hotbarFrame and fullFrame) then return end

	fullFrameRef = fullFrame
	fullFrame.Visible = false

	for i = 1, 12 do
		hotbarSlots[i] = getSlot(hotbarFrame, i, true)
	end
	for i = 1, 36 do
		bagSlots[i] = getSlot(fullFrame, i, false)
	end

	-- Hotbar click: equip
	for i = 1, 12 do
		hotbarSlots[i].Button.Activated:Connect(function()
			pcall(function()
				RF_InvEquip:InvokeServer(i)
			end)
		end)
	end

	-- Right click sell (bag + hotbar): Sell x1 if Crop_
	local function bindSell(slot: SlotUI)
		slot.Button.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
			local inv = getInv()
			if not inv then return end
			local it = slotItem(inv, slot.IsHotbar, slot.Index)
			if not it then return end
			if not isCropId(tostring(it.Id)) then return end

			pcall(function()
				RF_SellItem:InvokeServer(it.Id, it.Q, 1)
			end)
		end)
	end

	for i = 1, 12 do bindSell(hotbarSlots[i]) end
	for i = 1, 36 do bindSell(bagSlots[i]) end

	invUIReady = true
	renderInventoryUI()
end

UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end
	if input.KeyCode == Enum.KeyCode.I then
		if fullFrameRef then
			fullFrameRef.Visible = not fullFrameRef.Visible
		end
	end
end)

----------------------------------------------------------------
-- TILE FARM CLICK CONTROLLER (context actions)
----------------------------------------------------------------
local FarmsFolder = Workspace:WaitForChild("Farms") :: Folder
local lastClickAt = 0.0

local function currentFarmSlot(): number
	local a = player:GetAttribute("FarmSlot")
	local slot = clampInt(a)
	if slot > 0 then return slot end
	local d = state.Derived
	slot = clampInt(d and d.FarmSlot)
	return slot
end

local function getFarmBase(slot: number): (Instance?, BasePart?, Attachment?)
	local farmFolder = FarmsFolder:FindFirstChild("Farm" .. tostring(slot))
	if not (farmFolder and farmFolder:IsA("Folder")) then return nil, nil, nil end

	local baseObj = farmFolder:FindFirstChild("Base")
	if not baseObj then return farmFolder, nil, nil end

	local basePart: BasePart? = nil
	if baseObj:IsA("BasePart") then
		basePart = baseObj
	elseif baseObj:IsA("Model") then
		basePart = (baseObj :: Model).PrimaryPart or (baseObj :: Model):FindFirstChildWhichIsA("BasePart", true)
	end

	local originAtt = (baseObj :: Instance):FindFirstChild("GridOrigin", true)
	local att: Attachment? = nil
	if originAtt and originAtt:IsA("Attachment") then
		att = originAtt :: Attachment
	end

	return farmFolder, basePart, att
end

local function gridParams(slot: number, basePart: BasePart): (number, number, number)
	local farmFolder = FarmsFolder:FindFirstChild("Farm" .. tostring(slot))
	local tileSize = tonumber((farmFolder and farmFolder:GetAttribute("TileSize")) or basePart:GetAttribute("TileSize")) or 4
	local w = tonumber((farmFolder and farmFolder:GetAttribute("GridW")) or basePart:GetAttribute("GridW")) or 64
	local h = tonumber((farmFolder and farmFolder:GetAttribute("GridH")) or basePart:GetAttribute("GridH")) or 64
	tileSize = math.max(1, tileSize)
	w = math.max(4, math.floor(w))
	h = math.max(4, math.floor(h))
	return tileSize, w, h
end

local function tileKey(slot: number, tileId: number): string
	return "S" .. tostring(slot) .. ":" .. tostring(tileId)
end

local function getTileState(slot: number, tileId: number): any
	local data = state.Data
	if type(data) ~= "table" then return nil end
	local farm = data.Farm
	if type(farm) ~= "table" then return nil end
	local tiles = farm.Tiles
	if type(tiles) ~= "table" then return nil end
	return tiles[tileKey(slot, tileId)]
end

local function equippedSeedId(): string?
	local inv = getInv()
	if not inv then return nil end
	local eq = clampInt(inv.EquippedHotbar)
	if eq <= 0 then return nil end
	local it = slotItem(inv, true, eq)
	if not it then return nil end
	local id = tostring(it.Id)
	if not isSeedId(id) then return nil end
	return id
end

local function screenRaycastFarm(): (number?, Vector3?, BasePart?)
	local cam = Workspace.CurrentCamera
	if not cam then return nil, nil, nil end

	local slot = currentFarmSlot()
	if slot <= 0 then return nil, nil, nil end

	local farmFolder, basePart, _ = getFarmBase(slot)
	if not (farmFolder and basePart) then return nil, nil, nil end

	local mousePos = UserInputService:GetMouseLocation()
	local ray = cam:ScreenPointToRay(mousePos.X, mousePos.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Whitelist
	params.FilterDescendantsInstances = { farmFolder }
	params.IgnoreWater = true

	local result = Workspace:Raycast(ray.Origin, ray.Direction * 500, params)
	if not result then return nil, nil, nil end

	local hit = result.Instance
	if not (hit and hit:IsDescendantOf(farmFolder)) then return nil, nil, nil end
	return slot, result.Position, basePart
end

local function worldPosToTileId(slot: number, basePart: BasePart, hitPos: Vector3): number?
	local _, _, att = getFarmBase(slot)
	if not att then return nil end

	local tileSize, w, h = gridParams(slot, basePart)

	local baseCF = basePart.CFrame
	local originOS = baseCF:PointToObjectSpace(att.WorldPosition)
	local hitOS = baseCF:PointToObjectSpace(hitPos)

	local dx = hitOS.X - originOS.X
	local dz = hitOS.Z - originOS.Z

	local gx = math.floor(dx / tileSize)
	local gy = math.floor(dz / tileSize)

	if gx < 0 or gy < 0 or gx >= w or gy >= h then
		return nil
	end

	local tileId = (gy * w) + gx + 1
	return tileId
end

local function tileXYFromId(w: number, tileId: number): (number, number)
	local idx0 = tileId - 1
	return (idx0 % w), math.floor(idx0 / w)
end

local function isTileBlockedByObject(slot: number, tileId: number, w: number): boolean
	local data = state.Data
	if type(data) ~= "table" or type(data.Farm) ~= "table" then return false end
	local objs = data.Farm.Objects
	if type(objs) ~= "table" then return false end

	local x, y = tileXYFromId(w, tileId)
	for _, obj in pairs(objs) do
		if obj ~= false and type(obj) == "table" and clampInt(obj.Slot) == slot then
			local ox, oy = clampInt(obj.X), clampInt(obj.Y)
			local ow, oh = clampInt(obj.W), clampInt(obj.H)
			if x >= ox and y >= oy and x < (ox + ow) and y < (oy + oh) then
				return true
			end
		end
	end
	return false
end

local function handleTileClick(slot: number, tileId: number)
	local now = approxServerNow()
	local st = getTileState(slot, tileId)

	local hoe = false
	local seedId = ""
	local readyAt = 0
	local occ = ""

	if type(st) == "table" then
		hoe = (st.Hoe == true)
		seedId = tostring(st.SeedId or "")
		readyAt = clampInt(st.ReadyAt)
		occ = tostring(st.Occ or "")
	end

	-- object footprint block (client-side UX)
	do
		local _, basePart = getFarmBase(slot)
		if basePart then
			local _, w, _ = gridParams(slot, basePart)
			if isTileBlockedByObject(slot, tileId, w) then
				return
			end
		end
	end

	if occ ~= "" then
		return
	end

	local eqSeed = equippedSeedId()

	-- EMPTY TILE
	if seedId == "" then
		if not hoe then
			local ok, res = pcall(function()
				return RF_HoeTile:InvokeServer(tileId)
			end)
			if not ok or (type(res) == "table" and res.ok ~= true) then
				return
			end
			-- after hoe: if equipped seed, try plant
			if eqSeed then
				pcall(function()
					RF_PlantTile:InvokeServer(tileId, eqSeed)
				end)
			end
		else
			-- hoed + empty
			if eqSeed then
				pcall(function()
					RF_PlantTile:InvokeServer(tileId, eqSeed)
				end)
			end
		end
		return
	end

	-- PLANTED TILE
	if readyAt > 0 and readyAt <= now then
		pcall(function()
			RF_HarvestTile:InvokeServer(tileId)
		end)
	else
		pcall(function()
			RF_WaterTile:InvokeServer(tileId)
		end)
	end
end

UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

	-- simple debounce
	local t = os.clock()
	if (t - lastClickAt) < 0.08 then return end
	lastClickAt = t

	local slot, hitPos, basePart = screenRaycastFarm()
	if not slot or not hitPos or not basePart then return end

	local tileId = worldPosToTileId(slot, basePart, hitPos)
	if not tileId then return end

	handleTileClick(slot, tileId)
end)

----------------------------------------------------------------
-- NETWORK HOOK
----------------------------------------------------------------
RE_DataSnapshot.OnClientEvent:Connect(function(payload: any)
	applySnapshot(payload)
	renderInventoryUI()
end)

RE_DataDelta.OnClientEvent:Connect(function(payload: any)
	applyDelta(payload)
	renderInventoryUI()
end)

----------------------------------------------------------------
-- BOOT
----------------------------------------------------------------
bindRouter()
bindTopBar()
bindSeedShop("Pierre")
bindSeedShop("Joja")
bindInventoryUI()

local ok, snap = pcall(function()
	return RF_RequestSnapshot:InvokeServer()
end)
if ok and type(snap) == "table" then
	applySnapshot(snap)
	renderInventoryUI()
end

-- optional dev reset hotkey (L)
UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end
	if input.KeyCode == Enum.KeyCode.L and RunService:IsStudio() then
		local dev = Remotes:FindFirstChild("DevResetData")
		if dev and dev:IsA("RemoteEvent") then
			(dev :: RemoteEvent):FireServer()
		end
	end
end)
