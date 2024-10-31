local folderName = ...

-- Saved variables.
recipeDifficultyData = recipeDifficultyData or {}
reagentToRecipeData = reagentToRecipeData or {}

characterToClass = characterToClass or {}

-- The profession icon can only be obtained with GetProfessionInfo(), which takes spell-tab-index as argument.
-- But spell-tab-index can only be obtained for the current character with GetProfessions()
-- So if we want to display icons for arbitrary professions, we need to map professions to icons.
professionSkillLineToIcon = professionSkillLineToIcon or {}

-- A profession can be identified by two different IDs: the TradeSkillLineID or Enum.Profession.
-- The latter has to be derived from the former using GetProfessionInfoBySkillLineID().
-- So we use the former, which comes directly from GetProfessionInfo()!
-- https://warcraft.wiki.gg/wiki/API_GetProfessions
-- https://warcraft.wiki.gg/wiki/API_GetProfessionInfo
-- https://warcraft.wiki.gg/wiki/TradeSkillLineID
-- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetProfessionInfoBySkillLineID
-- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetBaseProfessionInfo





-- Shortcuts!
local C_BattleNet_GetGameAccountInfoByGUID = _G.C_BattleNet.GetGameAccountInfoByGUID
local string_match = string.match



-- For debugging.
local function NoEscape(toPrint)
  -- Brackets are needed to only print the first outout of gsub.
  return (string.gsub(toPrint, "\124", "\124\124"))
end








local function AddOrUpdateCharacterRecipeDifficulty(realm, character, professionId, recipeId, difficulty)
  recipeDifficultyData[realm] = recipeDifficultyData[realm] or {}
  recipeDifficultyData[realm][character] = recipeDifficultyData[realm][character] or {}
  recipeDifficultyData[realm][character][professionId] = recipeDifficultyData[realm][character][professionId] or {}
  recipeDifficultyData[realm][character][professionId][recipeId] = difficulty
end

local function AddRecipeToReagent(professionId, reagentId, recipeId)
  reagentToRecipeData[professionId] = reagentToRecipeData[professionId] or {}
  reagentToRecipeData[professionId][reagentId] = reagentToRecipeData[professionId][reagentId] or {}
  tinsert(reagentToRecipeData[professionId][reagentId], recipeId)
end

local function AddOrUpdatecharacterToClass(realm, character, classFilename)
  characterToClass[realm] = characterToClass[realm] or {}
  characterToClass[realm][character] = classFilename
end




local tradeSkillUpdateFrame = CreateFrame("Frame")
local function FetchAllRecipes()
  if C_TradeSkillUI.IsTradeSkillReady() and not C_TradeSkillUI.IsTradeSkillLinked() then


    -- Only fetch all recipes when there is a new build.
    -- https://warcraft.wiki.gg/wiki/API_GetBuildInfo
    local _, buildNumber = GetBuildInfo()



    -- Get info of the currently viewed profession.
    -- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetBaseProfessionInfo
    local professionInfo = C_TradeSkillUI.GetBaseProfessionInfo()

    -- print("Profession:", professionInfo.professionName, "Enum.Profession:", professionInfo.profession, "Profession Trade Skill Line ID:", professionInfo.professionID)

    -- Using Trade Skill Line ID because this easier to obtain with GetProfessionInfo() below.
    local professionId = professionInfo.professionID


    -- if reagentToRecipeData["buildNumber"] ~= buildNumber then
      -- Clear the profession entry in reagentToRecipeData table.
      -- (Easiest way to make sure that we don't have any old data in there.)
      reagentToRecipeData[professionId] = {}
    -- end



    -- For reuse in loop.
    local realmName = GetRealmName()
    local playerName = UnitName("player")

    -- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetAllRecipeIDs
    local recipeIDs = C_TradeSkillUI.GetAllRecipeIDs()
    for _, recipeID in pairs(recipeIDs) do

      -- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetRecipeInfo
      local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID)

      -- print("Recipe:", recipeInfo.name, "Recipe ID:", recipeID, "Learned:", recipeInfo.learned, "Relative Difficulty:", recipeInfo.relativeDifficulty)

      if recipeInfo and recipeInfo.learned then
        AddOrUpdateCharacterRecipeDifficulty(realmName, playerName, professionId, recipeInfo.recipeID, recipeInfo.relativeDifficulty)
      end


      -- if reagentToRecipeData["buildNumber"] ~= buildNumber then
        -- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetRecipeSchematic
        local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
        if schematic and schematic.reagentSlotSchematics then
          for _, reagentSlot in pairs(schematic.reagentSlotSchematics) do
            -- Typically each slot only has one reagent, but sometimes there are different quality levels with individual IDs.
            if reagentSlot.reagents then
              for _, reagent in pairs(reagentSlot.reagents) do
                -- print("   ->  ", reagent.itemID, C_Item.GetItemNameByID(reagent.itemID), reagentSlot.required and "(required)" or "(optional)")
                AddRecipeToReagent(professionId, reagent.itemID, recipeID)
              end
            end
          end
        end
      -- end

    end

    reagentToRecipeData["buildNumber"] = buildNumber
  end
end

tradeSkillUpdateFrame:SetScript("OnEvent", function() FetchAllRecipes() end)
tradeSkillUpdateFrame:RegisterEvent("TRADE_SKILL_SHOW")
tradeSkillUpdateFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")





-- Create a frame for event handling
local skillLinesChangedFrame = CreateFrame("Frame")


-- Removing recipes when unlearning a profession.
local function UpdateProfessions()

  local realmName = GetRealmName()
  local playerName = UnitName("player")


  -- Using this function to also store the player class.
  AddOrUpdatecharacterToClass(realmName, playerName, select(2, UnitClass("player")))




  -- https://warcraft.wiki.gg/wiki/API_GetProfessions
  local spellTabIndexProf1, spellTabIndexProf2, _, _, spellTabIndexCooking = GetProfessions()
  -- print("spellTabIndexProf1:", spellTabIndexProf1, "spellTabIndexProf2:", spellTabIndexProf2, "cooking:", spellTabIndexCooking)

  -- Using Trade Skill Line ID because this easier to obtain with GetProfessionInfo().
  local professionId1, professionId2
  if spellTabIndexProf1 then
    local name, icon, _, _, _, _, tradeSkillLineId = GetProfessionInfo(spellTabIndexProf1)
    -- print("Profession 1 - name:", name, "icon:", icon, "tradeSkillLineId:", tradeSkillLineId)
    professionSkillLineToIcon[tradeSkillLineId] = icon
    professionId1 = tradeSkillLineId
    if not recipeDifficultyData[realmName] or not recipeDifficultyData[realmName][playerName] or not recipeDifficultyData[realmName][playerName][tradeSkillLineId] then
      print("|cffff2020Your addon \"Who needs this reagent\" has no data on " .. name .. ". Please open the profession pane.|r")
    end
  end
  if spellTabIndexProf2 then
    local name, icon, _, _, _, _, tradeSkillLineId = GetProfessionInfo(spellTabIndexProf2)
    -- print("Profession 2 - name:", name, "icon:", icon, "tradeSkillLineId:", tradeSkillLineId)
    professionSkillLineToIcon[tradeSkillLineId] = icon
    professionId2 = tradeSkillLineId
    if not recipeDifficultyData[realmName] or not recipeDifficultyData[realmName][playerName] or not recipeDifficultyData[realmName][playerName][tradeSkillLineId] then
      print("|cffff2020Your addon \"Who needs this reagent\" has no data on " .. name .. ". Please open the profession pane.|r")
    end
  end
  if spellTabIndexCooking then
    local name, icon, _, _, _, _, tradeSkillLineId = GetProfessionInfo(spellTabIndexCooking)
    -- print("Cooking - name:", name, "icon:", icon, "tradeSkillLineId:", tradeSkillLineId)
    professionSkillLineToIcon[tradeSkillLineId] = icon
    if not recipeDifficultyData[realmName] or not recipeDifficultyData[realmName][playerName] or not recipeDifficultyData[realmName][playerName][tradeSkillLineId] then
      print("|cffff2020Your addon \"Who needs this reagent\" has no data on " .. name .. ". Please open the profession pane.|r")
    end
  end

  -- If we have entries, check if they are still correct.
  if recipeDifficultyData[realmName] and recipeDifficultyData[realmName][playerName] then
    -- Update the professions for the character, removing any old professions.
    for professionId in pairs(recipeDifficultyData[realmName][playerName]) do
      -- Always keep cooking.
      if professionId ~= 185 then
        -- print("Checking profession:", professionId, "against", professionId1, professionId2)
        if professionId ~= professionId1 and professionId ~= professionId2 then
          -- print("Removing profession:", professionId)
          recipeDifficultyData[realmName][playerName][professionId] = nil
        end
      end
    end
  end

end

skillLinesChangedFrame:SetScript("OnEvent", function() UpdateProfessions() end)
skillLinesChangedFrame:RegisterEvent("SKILL_LINES_CHANGED")














local function GetRecipesForReagent(professionId, reagentId)

  local recipes = {}

  if reagentToRecipeData[professionId] then
    if reagentToRecipeData[professionId][reagentId] then

      for _, recipeId in pairs(reagentToRecipeData[professionId][reagentId]) do
        tinsert(recipes, recipeId)
      end

    end
  end

  return recipes
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

    -- TODO: GetItemInfoInstant depricated!
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
-- https://warcraft.wiki.gg/wiki/API_GetProfessionInfo


local secondTooltip

local function HideSecondTooltip()
  if secondTooltip and secondTooltip:IsShown() then secondTooltip:Hide() end
end

local function ShowSecondTooltip()

  if (IsLeftShiftKeyDown() or IsRightShiftKeyDown()) and GameTooltip:IsShown() then


    local _, link = GameTooltip:GetItem()
    if not link then
      HideSecondTooltip()
      return
    end

    local isCraftingReagent = select(17, C_Item.GetItemInfo(link))
    if not isCraftingReagent then
      HideSecondTooltip()
      return
    end

    local reagentId = tonumber(string_match(link, "^.-:(%d+):"))
    -- print("reagentId", reagentId)




    local charactersToPrint = {}
    local charactersToPrintEmpty = true


    -- Go through all stored characters.
    for realm, characters in pairs(recipeDifficultyData) do
      for character, recipeDifficultyDataSets in pairs(characters) do
        -- print(realm, character)

        -- Go through this character's professions.
        for professionId, recipeToDifficulty in pairs(recipeDifficultyDataSets) do
          -- print("professionId", professionId)

          -- Go through all recipes for the current reagent.
          for _, recipeID in pairs(GetRecipesForReagent(professionId, reagentId)) do

            local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID)

            -- print("Character:", character.."-"..realm, "Profession:", professionId, "Recipe:", recipeInfo.name, "Recipe ID:", recipeID, "difficulty:", recipeToDifficulty[recipeID])

            charactersToPrint[realm] = charactersToPrint[realm] or {}
            charactersToPrint[realm][character] = charactersToPrint[realm][character] or {}
            charactersToPrint[realm][character][professionId] = charactersToPrint[realm][character][professionId] or {}
            tinsert(charactersToPrint[realm][character][professionId], {recipeInfo.name, recipeToDifficulty[recipeID]})

            if charactersToPrintEmpty then charactersToPrintEmpty = false end

          end
        end
      end
    end

    if charactersToPrintEmpty then
      HideSecondTooltip()
      return
    end


    -- Draw the tooltip.

    secondTooltip = CreateFrame("Frame", "CustomTooltipFrame", UIParent, "BackdropTemplate")
    secondTooltip:SetFrameStrata("TOOLTIP")
    secondTooltip:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    secondTooltip:SetBackdropBorderColor(TOOLTIP_DEFAULT_COLOR:GetRGBA())
    secondTooltip:SetBackdropColor(TOOLTIP_DEFAULT_BACKGROUND_COLOR:GetRGBA())

    if GameTooltip:GetPoint(1) == "BOTTOMLEFT" then
      secondTooltip:SetPoint("TOPLEFT", GameTooltip, "TOPRIGHT", 0, -10)
    else
      secondTooltip:SetPoint("TOPRIGHT", GameTooltip, "TOPLEFT", 0, -10)
    end

    local tooltipHeaderFontString = secondTooltip:CreateFontString(nil, "OVERLAY", "GameTooltipText")
    tooltipHeaderFontString:SetPoint("TOPLEFT", secondTooltip, "TOPLEFT", 10, -10)
    tooltipHeaderFontString:SetTextScale(1.2)
    tooltipHeaderFontString:SetTextColor(NORMAL_FONT_COLOR:GetRGB())
    tooltipHeaderFontString:SetText("Who needs this reagent?")


    lastCharacterFrame = tooltipHeaderFontString


    local tooltipHeight = tooltipHeaderFontString:GetHeight()

    -- Go through all characters to print.
    for realm, characters in pairs(charactersToPrint) do


      for character, professionIds in pairs(characters) do


        local characterFrame = CreateFrame("Frame", nil, secondTooltip)



        local characterNameFontString = characterFrame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
        characterNameFontString:SetTextColor(LIGHTGRAY_FONT_COLOR:GetRGB())
        characterNameFontString:SetPoint("TOPLEFT", characterFrame, "TOPLEFT")
        -- https://warcraft.wiki.gg/wiki/API_C_ClassColor.GetClassColor
        characterNameFontString:SetText(C_ClassColor.GetClassColor(characterToClass[realm][character]):WrapTextInColorCode(character) .. " (" .. realm .. ")")

        -- To calculate height of frames.
        local stringHeight = tooltipHeaderFontString:GetHeight()
        local frameHeight = stringHeight

        local lastString = characterNameFontString

        for professionId, recipes in pairs(professionIds) do

          local professionNameFontString = characterFrame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
          professionNameFontString:SetTextColor(WHITE_FONT_COLOR:GetRGB())
          professionNameFontString:SetText("|T" .. professionSkillLineToIcon[professionId] .. ":16:16:0:0|t " .. C_TradeSkillUI.GetProfessionInfoBySkillLineID(professionId).professionName)
          professionNameFontString:SetPoint("TOPLEFT", lastString, "BOTTOMLEFT", 0, 0)
          frameHeight = frameHeight + stringHeight
          lastString = professionNameFontString


          for _, recipe in pairs(recipes) do
            -- print(recipe[1], recipe[2])

            -- https://warcraft.wiki.gg/wiki/ColorMixin
            local textColor = IMPOSSIBLE_DIFFICULTY_COLOR
            if recipe[2] == 0 then
              textColor = DIFFICULT_DIFFICULTY_COLOR
            elseif recipe[2] == 1 then
              textColor = FAIR_DIFFICULTY_COLOR
            elseif recipe[2] == 2 then
              textColor = EASY_DIFFICULTY_COLOR
            elseif recipe[2] == 3 then
              textColor = TRIVIAL_DIFFICULTY_COLOR
            end

            local recipeNameFontString = characterFrame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
            recipeNameFontString:SetTextColor(WHITE_FONT_COLOR:GetRGB())
            recipeNameFontString:SetTextColor(textColor.r, textColor.g, textColor.b)
            recipeNameFontString:SetText(recipe[1])
            recipeNameFontString:SetPoint("TOPLEFT", lastString, "BOTTOMLEFT", 0, 0)
            frameHeight = frameHeight + stringHeight
            lastString = recipeNameFontString

          end


        end


        characterFrame:SetPoint("TOPLEFT", lastCharacterFrame, "BOTTOMLEFT", 0, 0)
        characterFrame:SetSize(300, frameHeight)

        tooltipHeight = tooltipHeight + characterFrame:GetHeight()

        lastCharacterFrame = characterFrame

      end

    end




    -- UIParent:GetWidth() * UIParent:GetEffectiveScale()

    secondTooltip:SetSize(300, tooltipHeight)


    secondTooltip:Show()

  else
    HideSecondTooltip()
  end
end





local function ModifierChanged(self, event, key)
  if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
	ShowSecondTooltip()
end
local f = CreateFrame("Frame")
f:RegisterEvent("MODIFIER_STATE_CHANGED")
f:SetScript("OnEvent", ModifierChanged)
GameTooltip:HookScript("OnShow", ShowSecondTooltip)
GameTooltip:HookScript("OnHide", HideSecondTooltip)




























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




