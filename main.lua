local folderName = ...

local C_BattleNet_GetGameAccountInfoByGUID = _G.C_BattleNet.GetGameAccountInfoByGUID
local strung_gsub = string.gsub



-- For debugging.
local function NoEscape(toPrint)
  -- Brackets are needed to only print the first outout of gsub.
  return (string.gsub(toPrint, "\124", "\124\124"))
end


-- Use the same colors as Broker_PlayedTime.
local CLASS_COLORS = { UNKNOWN = "|cffcccccc" }
for k, v in pairs(RAID_CLASS_COLORS) do
	CLASS_COLORS[k] = format("|cff%02x%02x%02x", v.r * 255, v.g * 255, v.b * 255)
  -- print(k, NoEscape(CLASS_COLORS[k]) )
end




-- To use the items count from Bagnon if available.
local GetBagnonCounts = nil
if Bagnon then

  -- Copied these from BagBrother\core\features\tooltipCounts.lua.

  local NONE = Bagnon.None

  local function aggregate(counts, bag)
    for slot, data in pairs(bag or NONE) do
      if tonumber(slot) then
        local singleton = tonumber(data)
        local count = not singleton and tonumber(data:match(';(%d+)$')) or 1
        local id = singleton or tonumber(data:match('^(%d+)'))
        counts[id] = (counts[id] or 0) + count
      end
    end
  end

  local function find(bag, item)
    local count = 0
    for slot, data in pairs(bag or NONE) do
      if tonumber(slot) then
        local singleton = tonumber(data)
        local id = singleton or tonumber(data:match('^(%d+)'))
        if id == item then
          count = count + (not singleton and tonumber(data:match(';(%d+)$')) or 1)
        end
      end
    end
    return count
  end

  local function CountItems(owner)
    if owner.isguild then
      owner.counts = {}
      for tab = 1, MAX_GUILDBANK_TABS do
        aggregate(owner.counts, owner[tab])
      end
    else
      owner.counts = {bags={}, bank={}, equip={}, vault={}}
      for _, bag in ipairs(Bagnon.InventoryBags) do
        aggregate(owner.counts.bags, owner[bag])
      end
      for _, bag in ipairs(Bagnon.BankBags) do
        aggregate(owner.counts.bank, owner[bag])
      end
      aggregate(owner.counts.equip, owner.equip)
      aggregate(owner.counts.vault, owner.vault)
    end
  end




  -- Using relevant parts from TipCounts:AddOwners().
  GetBagnonCounts = function(link)

    returnTable = {}


    local id = tonumber(link and GetItemInfoInstant(link) and link:match(':(%d+)')) -- workaround Blizzard craziness
    if id and id ~= HEARTHSTONE_ITEM_ID then

      for i, owner in Bagnon.Owners:Iterate() do

        -- Make sure we are only checking characters from the same realm.
        local gameAccountInfo = C_BattleNet_GetGameAccountInfoByGUID(UnitGUID("player"))
        if not gameAccountInfo then return end

        -- We are not looking at guilds.
        if owner.realm == gameAccountInfo.realmName and not owner.isguild then
          -- print("--------------------", owner.name)

          if owner.offline and not owner.counts then
            CountItems(owner)
          end

          local equip, bags, bank, vault
          if not owner.offline then
            local carrying = GetItemCount(id)

            equip = find(owner.equip, id)
            vault = find(owner.vault, id)
            bank = GetItemCount(id, true) - carrying
            bags = carrying - equip
          else
            equip, bags = owner.counts.equip[id], owner.counts.bags[id]
            bank, vault = owner.counts.bank[id], owner.counts.vault[id]
          end


          if equip and equip > 0 or bags and bags > 0 or bank and bank > 0 or vault and vault > 0 then
            -- print(owner.name, equip, bags, bank, owner.class)
            returnTable[owner.name] = {["equip"] = equip, ["bags"] = bags, ["bank"] = bank, ["vault"] = vault, ["class"] = owner.class}
          end

        end
      end
    end

    return returnTable

	end
end



-- Hooking
local function OnItem(self)

  -- TooltipUtil.GetDisplayedItem(self) is the same as self:GetItem()
  local _, link = TooltipUtil.GetDisplayedItem(self)
  if not link then return end



  if Bagnon then

    local labelTotal = "Total"
    local labelEquip = "Equipped"
    local labelBags = "Bags"
    local labelBank = "Bank"
    local labelVault = "Vault"

    local countColour = "|cffffffff"
    local placeColour = "|cffc7c7cf"

    local characters = 0
    local total = 0

    local bagnonCounts = GetBagnonCounts(link)
    if not bagnonCounts then return end

    -- Sort by character name.
    local function SortPlayers(a, b)
      if a == UnitName("player") then
        return true
      elseif b == UnitName("player") then
        return false
      else
        return a < b
      end
    end

    local tkeys = {}
    for k in pairs(bagnonCounts) do tinsert(tkeys, k) end
    sort(tkeys, SortPlayers)

    -- print("############################")
    for _, k in ipairs(tkeys) do
      v = bagnonCounts[k]

      -- print(k, v["equip"], v["bags"], v["bank"], v["class"], v["vault"])

      if v["equip"] == nil or v["equip"] < 0 then v["equip"] = 0 end
      if v["bags"] == nil or v["bags"] < 0 then v["bags"] = 0 end
      if v["bank"] == nil or v["bank"] < 0 then v["bank"] = 0 end
      if v["vault"] == nil or v["vault"] < 0 then v["vault"] = 0 end

      local sum = v["equip"] + v["bags"] + v["bank"] + v["vault"]

      if sum > 0 then

        local places = 0
        local text = ""

        if v["equip"] > 0 then
          text = text .. placeColour .. labelEquip .. "|r " .. countColour .. v["equip"] .. "|r, "
          places = places + 1
        end
        if v["bags"] > 0 then
          text = text .. placeColour .. labelBags .. "|r " .. countColour .. v["bags"] .. "|r, "
          places = places + 1
        end
        if v["bank"] > 0 then
          text = text .. placeColour .. labelBank .. "|r " .. countColour .. v["bank"] .. "|r, "
          places = places + 1
        end
        if v["vault"] > 0 then
          text = text .. placeColour .. labelVault .. "|r " .. countColour .. v["vault"] .. "|r, "
          places = places + 1
        end

        -- Remove last delimiter.
        text = strsub(text, 1, #text - 2)

        if places > 1 then
          text = placeColour .. "(" .. "|r" .. text .. placeColour .. ") " .. "|r" .. countColour .. sum .. "|r"
        end

        if characters == 0 then
          self:AddLine(" ")
        end
        self:AddDoubleLine(CLASS_COLORS[v["class"]] .. k .. "|r", text)

        characters = characters + 1
        total = total + sum

        -- print("total", total)
      end


    end

    if characters > 1 then
      self:AddLine(" ")
      self:AddDoubleLine(labelTotal, countColour .. total .. "|r")
    end

  end

end
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItem)










-- Show the profession icons with a border of the colour (grey, green, yellow, orange, red).
-- https://wow.gamepedia.com/API_GetProfessionInfo








-- TODO:   Missing the function of Bagsync to sync currencies!


-- local function CurrencyTooltip(objTooltip, currencyName, currencyIcon, currencyID)
	-- if not currencyID then return end

	-- --loop through our characters
	-- local usrData = {}

	-- for unitObj in Data:IterateUnits() do
		-- if not unitObj.isGuild and unitObj.data.currency and unitObj.data.currency[currencyID] then
			-- table.insert(usrData, { unitObj=unitObj, colorized=self:ColorizeUnit(unitObj), sortIndex=self:GetSortIndex(unitObj), count=unitObj.data.currency[currencyID].count} )
		-- end
	-- end

	-- --sort the list by our sortIndex then by realm and finally by name
	-- table.sort(usrData, function(a, b)
		-- if a.sortIndex  == b.sortIndex then
			-- if a.unitObj.realm == b.unitObj.realm then
				-- return a.unitObj.name < b.unitObj.name;
			-- end
			-- return a.unitObj.realm < b.unitObj.realm;
		-- end
		-- return a.sortIndex < b.sortIndex;
	-- end)

	-- if currencyName then
		-- objTooltip:AddLine(currencyName, 64/255, 224/255, 208/255)
		-- objTooltip:AddLine(" ")
	-- end

	-- for i=1, table.getn(usrData) do
		-- objTooltip:AddDoubleLine(usrData[i].colorized, comma_value(usrData[i].count), 1, 1, 1, 1, 1, 1)
	-- end

	-- objTooltip.__tooltipUpdated = true
	-- objTooltip:Show()
-- end



-- hooksecurefunc(GameTooltip, "SetCurrencyToken", function(self, index)

  -- if self.__tooltipUpdated then return end

  -- local name, isHeader, isExpanded, isUnused, isWatched, count, icon = GetCurrencyListInfo(index)


  -- local link = GetCurrencyListLink(index)
  -- if name and icon and link then
    -- local currencyID = BSYC:GetCurrencyID(link)
    -- Tooltip:CurrencyTooltip(self, name, icon, currencyID)
  -- end
-- end)

-- hooksecurefunc(GameTooltip, "SetCurrencyTokenByID", function(self, currencyID)

  -- if self.__tooltipUpdated then return end
  -- local name, currentAmount, icon, earnedThisWeek, weeklyMax, totalMax, isDiscovered, rarity = GetCurrencyInfo(currencyID)
  -- if name and icon then
    -- Tooltip:CurrencyTooltip(self, name, icon, currencyID)
  -- end
-- end)
-- hooksecurefunc(GameTooltip, "SetCurrencyByID", function(self, currencyID)
  -- if self.__tooltipUpdated then return end
  -- local name, currentAmount, icon, earnedThisWeek, weeklyMax, totalMax, isDiscovered, rarity = GetCurrencyInfo(currencyID)
  -- if name and icon then
    -- Tooltip:CurrencyTooltip(self, name, icon, currencyID)
  -- end
-- end)
-- hooksecurefunc(GameTooltip, "SetBackpackToken", function(self, index)
  -- if self.__tooltipUpdated then return end
  -- local name, count, icon, currencyID = GetBackpackCurrencyInfo(index)
  -- if name and icon and currencyID then
    -- Tooltip:CurrencyTooltip(self, name, icon, currencyID)
  -- end
-- end)
-- hooksecurefunc(GameTooltip, "SetMerchantCostItem", function(self, index, currencyIndex)
  -- --see MerchantFrame_UpdateAltCurrency
  -- if self.__tooltipUpdated then return end

  -- local currencyID = select(currencyIndex, GetMerchantCurrencies())
  -- if currencyID then
    -- local name, currentAmount, icon, earnedThisWeek, weeklyMax, totalMax, isDiscovered, rarity = GetCurrencyInfo(currencyID)
    -- if name and icon then
      -- Tooltip:CurrencyTooltip(self, name, icon, currencyID)
    -- end
  -- end
-- end)





-- hooksecurefunc("SetView", function(viewNumber) print("SetView", viewNumber) end)

