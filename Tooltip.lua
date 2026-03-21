local folderName, addon = ...

-- Cache of global WoW API tables/functions.
local C_ClassColor_GetClassColor                    = _G.C_ClassColor.GetClassColor
local C_Item_GetItemInfo                            = _G.C_Item.GetItemInfo
local C_TradeSkillUI_GetProfessionInfoBySkillLineID = _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID
local C_TradeSkillUI_GetRecipeInfo                  = _G.C_TradeSkillUI.GetRecipeInfo
local GameTooltip                                   = _G.GameTooltip
local GameTooltipText                               = _G.GameTooltipText
local IsLeftShiftKeyDown                            = _G.IsLeftShiftKeyDown
local IsRightShiftKeyDown                           = _G.IsRightShiftKeyDown
local UIParent                                      = _G.UIParent

local ceil                                          = _G.ceil
local math_floor                                    = _G.math.floor
local min                                           = _G.min
local sort                                          = _G.sort
local string_match                                  = _G.string.match
local tinsert                                       = _G.tinsert

-- Cache addon tables/functions.
local GetRecipesForReagent = addon.GetRecipesForReagent



-- ============================================================
-- Custom multi-column tooltip (pooled font strings)
-- ============================================================

local RECIPE_INDENT = 20  -- roughly the width of the 16x16 profession icon


local tooltipFrame
local measureTooltip
local tooltipLineHeight
local tooltipTopBottomPadding

local fontStringPool = {}
local fontStringPoolSize = 0
local fontStringPoolActive = 0

local function GetTooltipLineHeight()
  if not measureTooltip then
    measureTooltip = CreateFrame("GameTooltip", folderName .. "_MeasureTooltip", UIParent, "SharedTooltipTemplate")
  else
    measureTooltip:ClearLines()
  end
  measureTooltip:SetOwner(UIParent, "ANCHOR_TOPLEFT")
  measureTooltip:AddLine("Title")
  measureTooltip:Show()
  local tooltipHeight1 = measureTooltip:GetHeight()
  measureTooltip:AddLine("Line 1")
  measureTooltip:Show()
  local tooltipHeight2 = measureTooltip:GetHeight()
  local lineHeight = tooltipHeight2 - tooltipHeight1
  measureTooltip:AddLine("Line 2")
  measureTooltip:Show()
  local tooltipHeight3 = measureTooltip:GetHeight()
  measureTooltip:Hide()
  if math_floor((tooltipHeight2 + lineHeight) * 1000) - math_floor(tooltipHeight3 * 1000) == 0 then
    tooltipLineHeight = lineHeight
    tooltipTopBottomPadding = tooltipHeight1 - lineHeight
  else
    tooltipLineHeight = nil
    tooltipTopBottomPadding = nil
  end
end

local function InitTooltipFrame()
  if tooltipFrame then return end
  tooltipFrame = CreateFrame("Frame", folderName .. "_TooltipFrame", UIParent, "TooltipBackdropTemplate")
  tooltipFrame:SetFrameStrata("TOOLTIP")
  tooltipFrame:SetClampedToScreen(true)
  tooltipFrame:Hide()
  if C_AddOns.IsAddOnLoaded("ElvUI") then
    local E = unpack(ElvUI or {})
    if E and E.private and E.private.skins
        and E.private.skins.blizzard
        and E.private.skins.blizzard.enable
        and E.private.skins.blizzard.tooltip
        and tooltipFrame.SetTemplate then
      if tooltipFrame.NineSlice then
        tooltipFrame.NineSlice:SetAlpha(0)
      end
      local TT = E:GetModule("Tooltip", true)
      if TT and TT.db then
        tooltipFrame.customBackdropAlpha = TT.db.colorAlpha
      end
      tooltipFrame:SetTemplate("Transparent")
    end
  end
end

local titleFont = nil
local function GetTitleFont()
  if not titleFont then
    titleFont = CreateFont(folderName .. "_TitleFont")
    titleFont:CopyFontObject(GameTooltipHeaderText)
    local path, size, flags = titleFont:GetFont()
    titleFont:SetFont(path, size + 2, flags)
  end
  return titleFont
end

local characterFont = nil
local function GetCharacterFont()
  if not characterFont then
    characterFont = CreateFont(folderName .. "_CharacterFont")
    characterFont:CopyFontObject(GameTooltipHeaderText)
  end
  return characterFont
end

local function AcquireFontString()
  fontStringPoolActive = fontStringPoolActive + 1
  if fontStringPoolActive > fontStringPoolSize then
    fontStringPoolSize = fontStringPoolActive
    local fs = tooltipFrame:CreateFontString(nil, "ARTWORK", "GameTooltipText")
    fs:SetJustifyH("LEFT")
    fontStringPool[fontStringPoolSize] = fs
  end
  local fs = fontStringPool[fontStringPoolActive]
  fs:Show()
  return fs
end

local function ReleaseAllFontStrings()
  for i = 1, fontStringPoolActive do
    fontStringPool[i]:Hide()
    fontStringPool[i]:ClearAllPoints()
  end
  fontStringPoolActive = 0
end

local function HideSecondTooltip()
  if tooltipFrame and tooltipFrame:IsShown() then
    ReleaseAllFontStrings()
    tooltipFrame:Hide()
  end
end

local function ShowSecondTooltip()

  -- Be fast in the standard case.
  if (not IsLeftShiftKeyDown() and not IsRightShiftKeyDown()) or not GameTooltip:IsShown() then
    -- Inlining HideSecondTooltip() for efficiency.
    if tooltipFrame and tooltipFrame:IsShown() then
      ReleaseAllFontStrings()
      tooltipFrame:Hide()
    end
    return
  end


  local _, link = GameTooltip:GetItem()
  if not link then
    HideSecondTooltip()
    return
  end

  local isCraftingReagent = select(17, C_Item_GetItemInfo(link))
  if not isCraftingReagent then
    HideSecondTooltip()
    return
  end

  local reagentId = tonumber(string_match(link, "^.-:(%d+):"))

  -- Collect lines to display.
  local collectedLines = {}
  local hasLines = false

  tinsert(collectedLines, { text = "Who needs this reagent?", kind = "title" })

  for realm, characters in pairs(WNTR_recipeToDifficulty) do
    for character, difficultiesByVariant in pairs(characters) do

      local characterLines = {}
      local classColor = WNTR_characterToClass[realm] and WNTR_characterToClass[realm][character] and C_ClassColor_GetClassColor(WNTR_characterToClass[realm][character])
      local charText = classColor and classColor:WrapTextInColorCode(character) or character
      -- TODO: print realm in a different color.
      tinsert(characterLines, { text = charText .. " (" .. realm .. ")", kind = "character" })

      for variantId, difficultyByRecipe in pairs(difficultiesByVariant) do
        local recipes = GetRecipesForReagent(variantId, reagentId)
        if #recipes > 0 then
          local profVariantInfo = C_TradeSkillUI_GetProfessionInfoBySkillLineID(variantId)
          local baseIdForIcon = profVariantInfo and profVariantInfo.parentProfessionID or variantId
          local profName = profVariantInfo.professionName
          local skillLevel = WNTR_professionVariantToSkillLevel[realm] and WNTR_professionVariantToSkillLevel[realm][character] and WNTR_professionVariantToSkillLevel[realm][character][variantId]
          local maxLevel = WNTR_professionVariantToSkillLevel["maxLevels"] and WNTR_professionVariantToSkillLevel["maxLevels"][variantId]
          if skillLevel and maxLevel and maxLevel > 0 then
            profName = profName .. " (" .. skillLevel .. "/" .. maxLevel .. ")"
          end
          local profText = "|T" .. WNTR_professionSkillLineToIcon[baseIdForIcon] .. ":14:14:0:0|t " .. profName
          tinsert(characterLines, { text = profText, kind = "profession" })

          local recipeLines = {}
          for _, recipeID in pairs(recipes) do
            local recipeInfo = C_TradeSkillUI_GetRecipeInfo(recipeID)
            local difficulty = difficultyByRecipe[recipeID]
            local textColor = IMPOSSIBLE_DIFFICULTY_COLOR
            if difficulty == 0 then
              textColor = DIFFICULT_DIFFICULTY_COLOR
            elseif difficulty == 1 then
              textColor = FAIR_DIFFICULTY_COLOR
            elseif difficulty == 2 then
              textColor = EASY_DIFFICULTY_COLOR
            elseif difficulty == 3 then
              textColor = TRIVIAL_DIFFICULTY_COLOR
            end
            local recipeName = recipeInfo.name
            local rank = WNTR_recipeToRank[recipeID]
            if rank then
              recipeName = recipeName .. " (Rank " .. rank .. ")"
            end
            -- recipeName = recipeName .. " [" .. recipeID .. "]"  -- DEBUG: recipeID display
            tinsert(recipeLines, { text = recipeName, r = textColor.r, g = textColor.g, b = textColor.b, kind = "recipe" })
          end
          sort(recipeLines, function(a, b) return a.text < b.text end)
          for _, recipeLine in ipairs(recipeLines) do
            tinsert(characterLines, recipeLine)
          end
        end
      end

      -- Only add character block if it has at least one recipe.
      if #characterLines > 1 then
        for _, line in ipairs(characterLines) do
          tinsert(collectedLines, line)
        end
        hasLines = true
      end

    end
  end

  if not hasLines then
    HideSecondTooltip()
    return
  end

  -- Determine number of columns based on screen height.
  if not tooltipLineHeight then GetTooltipLineHeight() end
  if not tooltipLineHeight then
    HideSecondTooltip()
    return
  end

  local numLines = #collectedLines
  local numColumns = 1
  local maxScreenFraction = 0.9

  while numLines / numColumns * tooltipLineHeight > maxScreenFraction * UIParent:GetHeight() do
    numColumns = numColumns + 1
  end

  -- Show the tooltip frame.
  InitTooltipFrame()
  ReleaseAllFontStrings()

  local linesPerColumn = ceil(numLines / numColumns)

  local LINE_SPACING = 1
  local CHARACTER_PRE_SPACING = 8   -- gap before each character block (including after title)
  local CHARACTER_POST_SPACING = 4  -- gap after each character block (including after title)
  local PROFESSION_POST_SPACING = 4  -- extra gap after profession headers (enlarged font)

  -- Compute column ranges, keeping character blocks together.
  local columnRanges = {}
  do
    local charBlocks = {}
    local lineToBlock = {}
    local currentBlock = nil
    for i, line in ipairs(collectedLines) do
      if line.kind == "character" then
        currentBlock = { startIdx = i, endIdx = i }
        tinsert(charBlocks, currentBlock)
        lineToBlock[i] = #charBlocks
      elseif currentBlock and (line.kind == "profession" or line.kind == "recipe") then
        currentBlock.endIdx = i
        lineToBlock[i] = #charBlocks
      end
    end

    local splits = {}
    for col = 1, numColumns - 1 do
      splits[col] = min(col * linesPerColumn, numLines)
    end

    for s = 1, #splits do
      local splitIdx = splits[s]
      local blockIdx = lineToBlock[splitIdx]
      if blockIdx then
        local block = charBlocks[blockIdx]
        if splitIdx > block.startIdx and block.startIdx > 1 then
          splits[s] = block.startIdx - 1
        end
      end
    end

    for s = 1, #splits do
      if splits[s] < 1 then splits[s] = 1 end
      if splits[s] >= numLines then splits[s] = numLines - 1 end
      if s > 1 and splits[s] <= splits[s-1] then splits[s] = splits[s-1] + 1 end
    end

    local prevEnd = 0
    for s = 1, #splits do
      tinsert(columnRanges, { startIdx = prevEnd + 1, endIdx = splits[s] })
      prevEnd = splits[s]
    end
    tinsert(columnRanges, { startIdx = prevEnd + 1, endIdx = numLines })

    -- If the tallest column still exceeds the screen fraction, revert to even distribution.
    local maxLinesInCol = 0
    for _, r in ipairs(columnRanges) do
      local count = r.endIdx - r.startIdx + 1
      if count > maxLinesInCol then maxLinesInCol = count end
    end
    if maxLinesInCol * tooltipLineHeight > maxScreenFraction * UIParent:GetHeight() then
      columnRanges = {}
      for col = 1, numColumns do
        local s = (col - 1) * linesPerColumn + 1
        local e = min(col * linesPerColumn, numLines)
        tinsert(columnRanges, { startIdx = s, endIdx = e })
      end
    end
  end

  -- Phase 1: Create font strings, set text, measure widths.
  local columns = {}
  for col = 1, numColumns do
    columns[col] = { entries = {}, maxWidth = 0 }

    for idx = columnRanges[col].startIdx, columnRanges[col].endIdx do
      local lineData = collectedLines[idx]
      local fs = AcquireFontString()

      if lineData.kind == "title" then
        fs:SetFontObject(GetTitleFont())
        fs:SetTextColor(NORMAL_FONT_COLOR:GetRGB())
      elseif lineData.kind == "character" then
        fs:SetFontObject(GetCharacterFont())
        fs:SetTextColor(NORMAL_FONT_COLOR:GetRGB())
      elseif lineData.kind == "profession" then
        fs:SetFontObject(GetCharacterFont())
        fs:SetTextColor(WHITE_FONT_COLOR:GetRGB())
      else
        fs:SetFontObject(GameTooltipText)
      end

      fs:SetText(lineData.text or "")
      if lineData.r then
        fs:SetTextColor(lineData.r, lineData.g, lineData.b)
      end

      local indent = lineData.kind == "recipe" and RECIPE_INDENT or 0
      local w = fs:GetUnboundedStringWidth() + indent
      if w > columns[col].maxWidth then columns[col].maxWidth = w end

      tinsert(columns[col].entries, { fs = fs, kind = lineData.kind })
    end
  end

  -- Phase 2: Calculate frame dimensions.
  local PADDING_H = 14
  local PADDING_V = tooltipTopBottomPadding or 14
  local COLUMN_GAP = 34

  local globalMaxWidth = 0
  for col = 1, numColumns do
    if columns[col].maxWidth > globalMaxWidth then globalMaxWidth = columns[col].maxWidth end
  end
  local colWidth = globalMaxWidth
  local totalWidth = PADDING_H * 2 + colWidth * numColumns + COLUMN_GAP * (numColumns - 1)

  local maxColHeight = 0
  for col = 1, numColumns do
    local h = 0
    for _, entry in ipairs(columns[col].entries) do
      if entry.kind == "character" then h = h + CHARACTER_PRE_SPACING end
      h = h + tooltipLineHeight + LINE_SPACING
      if entry.kind == "character" then h = h + CHARACTER_POST_SPACING end
      if entry.kind == "profession" then h = h + PROFESSION_POST_SPACING end
    end
    if h > maxColHeight then maxColHeight = h end
  end
  local totalHeight = PADDING_V + maxColHeight

  -- Phase 3: Position all font strings.
  local x = PADDING_H
  for col = 1, numColumns do
    local yOffset = -(PADDING_V / 2)
    for _, entry in ipairs(columns[col].entries) do
      local indent = entry.kind == "recipe" and RECIPE_INDENT or 0
      if entry.kind == "character" then yOffset = yOffset - CHARACTER_PRE_SPACING end
      entry.fs:SetPoint("TOPLEFT", tooltipFrame, "TOPLEFT", x + indent, yOffset)
      yOffset = yOffset - (tooltipLineHeight + LINE_SPACING)
      if entry.kind == "character" then yOffset = yOffset - CHARACTER_POST_SPACING end
      if entry.kind == "profession" then yOffset = yOffset - PROFESSION_POST_SPACING end
    end
    x = x + colWidth + COLUMN_GAP
  end

  -- Phase 4: Size and anchor the frame.
  tooltipFrame:SetSize(totalWidth, totalHeight)
  tooltipFrame:ClearAllPoints()

  if GameTooltip:GetPoint(1) == "BOTTOMLEFT" then
    tooltipFrame:SetPoint("TOPLEFT", GameTooltip, "TOPRIGHT", 0, -10)
  else
    tooltipFrame:SetPoint("TOPRIGHT", GameTooltip, "TOPLEFT", 0, -10)
  end

  tooltipFrame:SetFrameLevel(GameTooltip:GetFrameLevel() + 10)

  if tooltipFrame.template == "Transparent" and ElvUI then
    local E = unpack(ElvUI)
    if E then
      local TT = E:GetModule("Tooltip", true)
      if TT and TT.db then
        local r, g, b = tooltipFrame:GetBackdropColor()
        tooltipFrame:SetBackdropColor(r, g, b, TT.db.colorAlpha)
      end
    end
  end

  tooltipFrame:Show()

end


















-- -- Use the same colors as Broker_PlayedTime.
-- local CLASS_COLORS = { UNKNOWN = "|cffcccccc" }
-- for k, v in pairs(RAID_CLASS_COLORS) do
-- 	CLASS_COLORS[k] = format("|cff%02x%02x%02x", v.r * 255, v.g * 255, v.b * 255)
--   -- print(k, NoEscape(CLASS_COLORS[k]) )
-- end








-- -- To use the items count from Bagnon if available.
-- local GetBagnonCounts = nil
-- if Bagnon then

--   -- Copied these from BagBrother\core\features\tooltipCounts.lua.

--   local NONE = Bagnon.None

--   local function aggregate(counts, bag)
--     for slot, data in pairs(bag or NONE) do
--       if tonumber(slot) then
--         local singleton = tonumber(data)
--         local count = not singleton and tonumber(data:match(';(%d+)$')) or 1
--         local id = singleton or tonumber(data:match('^(%d+)'))
--         counts[id] = (counts[id] or 0) + count
--       end
--     end
--   end

--   local function find(bag, item)
--     local count = 0
--     for slot, data in pairs(bag or NONE) do
--       if tonumber(slot) then
--         local singleton = tonumber(data)
--         local id = singleton or tonumber(data:match('^(%d+)'))
--         if id == item then
--           count = count + (not singleton and tonumber(data:match(';(%d+)$')) or 1)
--         end
--       end
--     end
--     return count
--   end

--   local function CountItems(owner)
--     if owner.isguild then
--       owner.counts = {}
--       for tab = 1, MAX_GUILDBANK_TABS do
--         aggregate(owner.counts, owner[tab])
--       end
--     else
--       owner.counts = {bags={}, bank={}, equip={}, vault={}}
--       for _, bag in ipairs(Bagnon.InventoryBags) do
--         aggregate(owner.counts.bags, owner[bag])
--       end
--       for _, bag in ipairs(Bagnon.BankBags) do
--         aggregate(owner.counts.bank, owner[bag])
--       end
--       aggregate(owner.counts.equip, owner.equip)
--       aggregate(owner.counts.vault, owner.vault)
--     end
--   end




--   -- Using relevant parts from TipCounts:AddOwners().
--   GetBagnonCounts = function(link)

--     returnTable = {}

--     -- TODO: GetItemInfoInstant depricated!
--     local id = tonumber(link and GetItemInfoInstant(link) and link:match(':(%d+)')) -- workaround Blizzard craziness
--     if id and id ~= HEARTHSTONE_ITEM_ID then

--       for i, owner in Bagnon.Owners:Iterate() do

--         -- Make sure we are only checking characters from the same realm.
--         local gameAccountInfo = C_BattleNet.GetGameAccountInfoByGUID(UnitGUID("player"))
--         if not gameAccountInfo then return end

--         -- We are not looking at guilds.
--         if owner.realm == gameAccountInfo.realmName and not owner.isguild then
--           -- print("--------------------", owner.name)

--           if owner.offline and not owner.counts then
--             CountItems(owner)
--           end

--           local equip, bags, bank, vault
--           if not owner.offline then
--             local carrying = GetItemCount(id)

--             equip = find(owner.equip, id)
--             vault = find(owner.vault, id)
--             bank = GetItemCount(id, true) - carrying
--             bags = carrying - equip
--           else
--             equip, bags = owner.counts.equip[id], owner.counts.bags[id]
--             bank, vault = owner.counts.bank[id], owner.counts.vault[id]
--           end


--           if equip and equip > 0 or bags and bags > 0 or bank and bank > 0 or vault and vault > 0 then
--             -- print(owner.name, equip, bags, bank, owner.class)
--             returnTable[owner.name] = {["equip"] = equip, ["bags"] = bags, ["bank"] = bank, ["vault"] = vault, ["class"] = owner.class}
--           end

--         end
--       end
--     end

--     return returnTable

-- 	end
-- end




-- -- Hooking
-- local function OnItem(self)

--   -- TooltipUtil.GetDisplayedItem(self) is the same as self:GetItem()
--   local _, link = TooltipUtil.GetDisplayedItem(self)
--   if not link then return end


--   if Bagnon then

--     local labelTotal = "Total"
--     local labelEquip = "Equipped"
--     local labelBags = "Bags"
--     local labelBank = "Bank"
--     local labelVault = "Vault"

--     local countColour = "|cffffffff"
--     local placeColour = "|cffc7c7cf"

--     local characters = 0
--     local total = 0

--     local bagnonCounts = GetBagnonCounts(link)
--     if not bagnonCounts then return end

--     -- Sort by character name.
--     local function SortPlayers(a, b)
--       if a == UnitName("player") then
--         return true
--       elseif b == UnitName("player") then
--         return false
--       else
--         return a < b
--       end
--     end

--     local tkeys = {}
--     for k in pairs(bagnonCounts) do tinsert(tkeys, k) end
--     sort(tkeys, SortPlayers)

--     -- print("############################")
--     for _, k in ipairs(tkeys) do
--       v = bagnonCounts[k]

--       -- print(k, v["equip"], v["bags"], v["bank"], v["class"], v["vault"])

--       if v["equip"] == nil or v["equip"] < 0 then v["equip"] = 0 end
--       if v["bags"] == nil or v["bags"] < 0 then v["bags"] = 0 end
--       if v["bank"] == nil or v["bank"] < 0 then v["bank"] = 0 end
--       if v["vault"] == nil or v["vault"] < 0 then v["vault"] = 0 end

--       local sum = v["equip"] + v["bags"] + v["bank"] + v["vault"]

--       if sum > 0 then

--         local places = 0
--         local text = ""

--         if v["equip"] > 0 then
--           text = text .. placeColour .. labelEquip .. "|r " .. countColour .. v["equip"] .. "|r, "
--           places = places + 1
--         end
--         if v["bags"] > 0 then
--           text = text .. placeColour .. labelBags .. "|r " .. countColour .. v["bags"] .. "|r, "
--           places = places + 1
--         end
--         if v["bank"] > 0 then
--           text = text .. placeColour .. labelBank .. "|r " .. countColour .. v["bank"] .. "|r, "
--           places = places + 1
--         end
--         if v["vault"] > 0 then
--           text = text .. placeColour .. labelVault .. "|r " .. countColour .. v["vault"] .. "|r, "
--           places = places + 1
--         end

--         -- Remove last delimiter.
--         text = strsub(text, 1, #text - 2)

--         if places > 1 then
--           text = placeColour .. "(" .. "|r" .. text .. placeColour .. ") " .. "|r" .. countColour .. sum .. "|r"
--         end

--         if characters == 0 then
--           self:AddLine(" ")
--         end
--         self:AddDoubleLine(CLASS_COLORS[v["class"]] .. k .. "|r", text)

--         characters = characters + 1
--         total = total + sum

--         -- print("total", total)
--       end


--     end

--     if characters > 1 then
--       self:AddLine(" ")
--       self:AddDoubleLine(labelTotal, countColour .. total .. "|r")
--     end

--   end

-- end
-- TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItem)



local function ModifierChanged(self, event, key)
  if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
	ShowSecondTooltip()
end
local f = CreateFrame("Frame")
f:RegisterEvent("MODIFIER_STATE_CHANGED")
f:SetScript("OnEvent", ModifierChanged)
GameTooltip:HookScript("OnShow", ShowSecondTooltip)
GameTooltip:HookScript("OnHide", HideSecondTooltip)
