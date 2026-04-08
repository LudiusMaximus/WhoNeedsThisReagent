local folderName, addon = ...

-- Cache of global WoW API tables/functions.
local C_ClassColor_GetClassColor                    = _G.C_ClassColor.GetClassColor
local C_TradeSkillUI_GetProfessionInfoBySkillLineID = _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID
local C_TradeSkillUI_GetRecipeInfo                  = _G.C_TradeSkillUI.GetRecipeInfo
local GameTooltip                                   = _G.GameTooltip
local GameTooltipText                               = _G.GameTooltipText
local IsModifiedClick                               = _G.IsModifiedClick
local UIParent                                      = _G.UIParent

local ceil                                          = _G.ceil
local math_floor                                    = _G.math.floor
local min                                           = _G.min
local sort                                          = _G.sort
local string_match                                  = _G.string.match
local tinsert                                       = _G.tinsert
local wipe                                          = _G.wipe

-- Cache addon tables/functions.
local GetRecipesForReagent = addon.GetRecipesForReagent


-- API result caches: avoid re-creating large tables on every tooltip rebuild.
-- These rarely change during a session (recipe names are constant, learned status
-- only changes on NEW_RECIPE_LEARNED which triggers a full sync anyway).
local recipeInfoCache = {}
local profInfoCache = {}

local function GetCachedRecipeInfo(recipeId)
  local cached = recipeInfoCache[recipeId]
  if cached then return cached end
  cached = C_TradeSkillUI_GetRecipeInfo(recipeId)
  if cached then recipeInfoCache[recipeId] = cached end
  return cached
end

local function GetCachedProfInfo(variantId)
  local cached = profInfoCache[variantId]
  if cached then return cached end
  cached = C_TradeSkillUI_GetProfessionInfoBySkillLineID(variantId)
  if cached then profInfoCache[variantId] = cached end
  return cached
end

-- Reusable table for GetRecipesForReagent to avoid per-call allocations.
local reusableRecipes = {}

-- Line record pool: avoids allocating {text, kind, r, g, b} tables every rebuild.
local linePool = {}
local linePoolSize = 0
local linePoolActive = 0

local function AcquireLineRecord()
  linePoolActive = linePoolActive + 1
  if linePoolActive > linePoolSize then
    linePoolSize = linePoolActive
    linePool[linePoolSize] = {}
  end
  local rec = linePool[linePoolActive]
  rec.text = nil
  rec.kind = nil
  rec.r = nil
  rec.g = nil
  rec.b = nil
  rec.profSortKey = nil
  rec.transmog = nil
  return rec
end

local function ResetLinePool()
  linePoolActive = 0
end

-- Module-level sort comparator (no closure allocation).
local function sortByProfAndRecipe(a, b)
  if a.profSortKey ~= b.profSortKey then return a.profSortKey < b.profSortKey end
  if a.kind ~= b.kind then return a.kind == "profession" end
  return a.text < b.text
end

-- Reusable intermediate tables (all wiped before each use to avoid stale data).
local collectedLines = {}
local characterLines = {}
local columnStart = {}
local columnEnd = {}
local charBlockStart = {}
local charBlockEnd = {}
local lineToBlock = {}
local splits = {}
local colMaxWidths = {}


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
    fontStringPool[i]:SetAlpha(1)
  end
  fontStringPoolActive = 0
end

-- Cache: skip rebuilding when nothing changed between frames.
local lastTooltipLink = nil
local lastTooltipModifier = false

local function HideSecondTooltip()
  if tooltipFrame and tooltipFrame:IsShown() then
    ReleaseAllFontStrings()
    tooltipFrame:Hide()
  end
  lastTooltipLink = nil
  lastTooltipModifier = false
  ResetLinePool()
end

local function ShowSecondTooltip()

  -- Be fast in the standard case.
  local modifierHeld = IsModifiedClick("COMPAREITEMS")
  if not modifierHeld or not GameTooltip:IsShown() then
    if tooltipFrame and tooltipFrame:IsShown() then
      HideSecondTooltip()
    end
    return
  end


  local _, link = GameTooltip:GetItem()
  if not link then
    HideSecondTooltip()
    return
  end

  -- Skip rebuilding if item and modifier state haven't changed.
  if link == lastTooltipLink and lastTooltipModifier then return end
  lastTooltipLink = link
  lastTooltipModifier = true

  -- Read GameTooltip's anchor point before any addon code can taint it.
  -- GetPoint() returns a tainted string if called after we've touched GameTooltip,
  -- causing "attempt to compare a secret string value" errors.
  local gameTooltipAnchor = GameTooltip:GetPoint(1)

  local reagentId = tonumber(string_match(link, "^.-:(%d+):"))

  -- Quick check: does any synced profession variant use this item as a reagent?
  -- This avoids all the pool allocations, API calls, and nested iteration below
  -- for the vast majority of items that aren't crafting ingredients.
  local isKnownReagent = false
  for variantId, reagents in pairs(WNTR_reagentToRecipe) do
    if reagents[reagentId] then
      isKnownReagent = true
      break
    end
  end
  if not isKnownReagent then
    HideSecondTooltip()
    return
  end

  -- Collect lines to display (zero table allocations — all records from pool).
  wipe(collectedLines)
  ResetLinePool()
  local hasLines = false

  local titleLine = AcquireLineRecord()
  titleLine.text = "Who needs this reagent?"
  titleLine.kind = "title"
  tinsert(collectedLines, titleLine)

  for realm, characters in pairs(WNTR_recipeToDifficulty) do
    for character, difficultiesByVariant in pairs(characters) do

      wipe(characterLines)

      for variantId, difficultyByRecipe in pairs(difficultiesByVariant) do
        local recipes = GetRecipesForReagent(variantId, reagentId, reusableRecipes)
        if #recipes > 0 then
          local profVariantInfo = GetCachedProfInfo(variantId)
          local baseIdForIcon = profVariantInfo and profVariantInfo.parentProfessionID or variantId
          local profName = profVariantInfo.professionName
          local charLevels = WNTR_variantToSkillLevel[realm] and WNTR_variantToSkillLevel[realm][character]
          local skillLevel = charLevels and charLevels[variantId]
          local maxLevel = charLevels and charLevels["maxLevels"] and charLevels["maxLevels"][variantId]
          if skillLevel and maxLevel and maxLevel > 0 then
            profName = profName .. " (" .. skillLevel .. "/" .. maxLevel .. ")"
          end
          local profText = "|T" .. WNTR_professionSkillLineToIcon[baseIdForIcon] .. ":14:14:0:0|t " .. profName

          local profLine = AcquireLineRecord()
          profLine.text = profText
          profLine.kind = "profession"
          profLine.profSortKey = profName
          tinsert(characterLines, profLine)

          for _, recipeId in ipairs(recipes) do
            local recipeInfo = GetCachedRecipeInfo(recipeId)
            local difficulty = difficultyByRecipe[recipeId]

            -- To hide recipes if conditions apply.
            local skipRecipe = false

            -- For Legion/BfA ranked recipes (which have previousRecipeID/nextRecipeID),
            -- we skip ranks below the character's highest learned rank.
            -- Because unlike Shadowlands, in Legion/BfA you always craft the highest rank only.
            if recipeInfo and WNTR_recipeToRank[recipeId]
                and (recipeInfo.previousRecipeID or recipeInfo.nextRecipeID) then
              local nextId = recipeInfo.nextRecipeID
              while nextId do
                if difficultyByRecipe[nextId] ~= nil then
                  skipRecipe = true
                  break
                end
                local nextInfo = GetCachedRecipeInfo(nextId)
                nextId = nextInfo and nextInfo.nextRecipeID
              end
            end

            -- "Next unlearned rank only": for ranked recipes the character hasn't learned,
            -- only show the immediate next rank after the highest learned rank.
            if not skipRecipe and WNTR_config.nextUnlearnedRankOnly
                and recipeInfo and WNTR_recipeToRank[recipeId] and difficulty == nil then
              if recipeInfo.previousRecipeID or recipeInfo.nextRecipeID then
                -- Legion/BfA style: walk the previousRecipeID chain to find
                -- whether the immediately preceding rank is learned.
                local prevId = recipeInfo.previousRecipeID
                if prevId then
                  -- Skip unless the previous rank is learned by this character.
                  if difficultyByRecipe[prevId] == nil then
                    skipRecipe = true
                  end
                end
                -- If there is no previousRecipeID, this is rank 1 — always show it.
              else
                -- Shadowlands style: ranks assigned by name via WNTR_recipeToRank.
                -- Find the highest learned rank for recipes with the same name.
                local myRank = WNTR_recipeToRank[recipeId]
                local nextExpectedRank = 1
                for otherRecipeId, otherDifficulty in pairs(difficultyByRecipe) do
                  if otherDifficulty ~= nil then
                    local otherRank = WNTR_recipeToRank[otherRecipeId]
                    if otherRank then
                      local otherInfo = GetCachedRecipeInfo(otherRecipeId)
                      if otherInfo and otherInfo.name == recipeInfo.name and otherRank >= nextExpectedRank then
                        nextExpectedRank = otherRank + 1
                      end
                    end
                  end
                end
                if myRank ~= nextExpectedRank then
                  skipRecipe = true
                end
              end
            end

            if not skipRecipe then

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
              local rank = WNTR_recipeToRank[recipeId]
              if rank then
                local currentXP = WNTR_recipeToExperience[realm] and WNTR_recipeToExperience[realm][character] and WNTR_recipeToExperience[realm][character][recipeId]
                local nextXP = WNTR_recipeToExperience["nextLevels"] and WNTR_recipeToExperience["nextLevels"][recipeId]
                if currentXP and nextXP then
                  recipeName = recipeName .. " (Rank " .. rank .. ", " .. currentXP .. "/" .. nextXP .. ")"
                else
                  recipeName = recipeName .. " (Rank " .. rank .. ")"
                end
              end
              -- recipeName = recipeName .. " [" .. recipeId .. "]"  -- DEBUG: recipeId display

              -- When a profession is maxed out, the API may still report learned recipes with
              -- non-trivial difficulty colors (e.g. Shadowlands recipes show DIFFICULT even at cap).
              -- Force all such recipes to TRIVIAL, unless it's a rank recipe whose rank isn't maxed yet,
              -- or the corrected difficulty (nil) indicates it is not learned yet.
              if recipeInfo.learned and skillLevel and maxLevel and maxLevel > 0 and skillLevel >= maxLevel and difficulty ~= nil then
                local rankNotMaxed = rank and WNTR_recipeToExperience["nextLevels"] and WNTR_recipeToExperience["nextLevels"][recipeId]
                if not rankNotMaxed then
                  textColor = TRIVIAL_DIFFICULTY_COLOR
                end
              end

              local recipeLine = AcquireLineRecord()
              recipeLine.text = recipeName
              recipeLine.kind = "recipe"
              recipeLine.r = textColor.r
              recipeLine.g = textColor.g
              recipeLine.b = textColor.b
              recipeLine.profSortKey = profName
              if WNTR_config.showUncollectedTransmog then
                if WNTR_recipeWithUncollectedTransmog[recipeId] then
                  recipeLine.transmog = "unknown"
                elseif WNTR_recipeWithUncollectedTransmogItem[recipeId] then
                  recipeLine.transmog = "item"
                end
              end
              tinsert(characterLines, recipeLine)

            end -- if not skipRecipe
          end
        end
      end

      -- Only add character block if it has at least one recipe.
      if #characterLines > 0 then
        sort(characterLines, sortByProfAndRecipe)

        local classColor = WNTR_characterToClass[realm] and WNTR_characterToClass[realm][character] and C_ClassColor_GetClassColor(WNTR_characterToClass[realm][character])
        local charText = classColor and classColor:WrapTextInColorCode(character) or character
        -- TODO: print realm in a different color.
        local charLine = AcquireLineRecord()
        charLine.text = charText .. " (" .. realm .. ")"
        charLine.kind = "character"
        tinsert(collectedLines, charLine)

        for i = 1, #characterLines do
          tinsert(collectedLines, characterLines[i])
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
  local maxScreenFraction = 0.7
  local fallbackScreenFraction = 0.9

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
  do
    wipe(columnStart)
    wipe(columnEnd)
    wipe(charBlockStart)
    wipe(charBlockEnd)
    wipe(lineToBlock)
    wipe(splits)
    wipe(colMaxWidths)
    local numCharBlocks = 0
    local currentBlockIdx = 0
    for i = 1, numLines do
      local kind = collectedLines[i].kind
      if kind == "character" then
        numCharBlocks = numCharBlocks + 1
        currentBlockIdx = numCharBlocks
        charBlockStart[numCharBlocks] = i
        charBlockEnd[numCharBlocks] = i
        lineToBlock[i] = numCharBlocks
      elseif currentBlockIdx > 0 and (kind == "profession" or kind == "recipe") then
        charBlockEnd[currentBlockIdx] = i
        lineToBlock[i] = currentBlockIdx
      end
    end

    local numSplits = numColumns - 1
    for col = 1, numSplits do
      splits[col] = min(col * linesPerColumn, numLines)
    end

    for s = 1, numSplits do
      local splitIdx = splits[s]
      local blockIdx = lineToBlock[splitIdx]
      if blockIdx then
        local blockSize = charBlockEnd[blockIdx] - charBlockStart[blockIdx] + 1
        if blockSize > 6 then
          -- Large block: allow splitting within, but avoid tiny orphan groups.
          local beforeCount = splitIdx - charBlockStart[blockIdx] + 1
          local afterCount = charBlockEnd[blockIdx] - splitIdx
          if beforeCount < 3 and charBlockStart[blockIdx] > 1 then
            splits[s] = charBlockStart[blockIdx] - 1
          elseif afterCount > 0 and afterCount < 3 then
            splits[s] = charBlockEnd[blockIdx]
          end
        else
          -- Small block: keep together by moving split before this block.
          if splitIdx > charBlockStart[blockIdx] and charBlockStart[blockIdx] > 1 then
            splits[s] = charBlockStart[blockIdx] - 1
          end
        end
      end
    end

    for s = 1, numSplits do
      if splits[s] < 1 then splits[s] = 1 end
      if splits[s] >= numLines then splits[s] = numLines - 1 end
      if s > 1 and splits[s] <= splits[s-1] then splits[s] = splits[s-1] + 1 end
    end

    local prevEnd = 0
    for s = 1, numSplits do
      columnStart[s] = prevEnd + 1
      columnEnd[s] = splits[s]
      prevEnd = splits[s]
    end
    columnStart[numColumns] = prevEnd + 1
    columnEnd[numColumns] = numLines

    -- If the tallest column still exceeds the screen fraction, revert to even distribution.
    local maxLinesInCol = 0
    for col = 1, numColumns do
      local count = columnEnd[col] - columnStart[col] + 1
      if count > maxLinesInCol then maxLinesInCol = count end
    end
    if maxLinesInCol * tooltipLineHeight > fallbackScreenFraction * UIParent:GetHeight() then
      for col = 1, numColumns do
        columnStart[col] = (col - 1) * linesPerColumn + 1
        columnEnd[col] = min(col * linesPerColumn, numLines)
      end
    end
  end

  -- Phase 1: Create font strings, set text, measure widths.
  -- Font strings are acquired sequentially (1..numLines), matching collectedLines indices.
  for col = 1, numColumns do
    colMaxWidths[col] = 0
    for idx = columnStart[col], columnEnd[col] do
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
      if w > colMaxWidths[col] then colMaxWidths[col] = w end
    end
  end

  -- Phase 2: Calculate frame dimensions.
  local PADDING_H = 14
  local PADDING_V = tooltipTopBottomPadding or 14
  local COLUMN_GAP = 34

  local globalMaxWidth = 0
  for col = 1, numColumns do
    if colMaxWidths[col] > globalMaxWidth then globalMaxWidth = colMaxWidths[col] end
  end
  local colWidth = globalMaxWidth
  local totalWidth = PADDING_H * 2 + colWidth * numColumns + COLUMN_GAP * (numColumns - 1)

  local maxColHeight = 0
  for col = 1, numColumns do
    local h = 0
    for idx = columnStart[col], columnEnd[col] do
      local kind = collectedLines[idx].kind
      if kind == "character" then h = h + CHARACTER_PRE_SPACING end
      h = h + tooltipLineHeight + LINE_SPACING
      if kind == "character" then h = h + CHARACTER_POST_SPACING end
      if kind == "profession" then h = h + PROFESSION_POST_SPACING end
    end
    if h > maxColHeight then maxColHeight = h end
  end
  local totalHeight = PADDING_V + maxColHeight

  -- Phase 3: Position all font strings (fontStringPool[idx] maps to collectedLines[idx]).
  local x = PADDING_H
  for col = 1, numColumns do
    local yOffset = -(PADDING_V / 2)
    for idx = columnStart[col], columnEnd[col] do
      local kind = collectedLines[idx].kind
      local indent = kind == "recipe" and RECIPE_INDENT or 0
      if kind == "character" then yOffset = yOffset - CHARACTER_PRE_SPACING end
      fontStringPool[idx]:SetPoint("TOPLEFT", tooltipFrame, "TOPLEFT", x + indent, yOffset)
      -- Uncollected transmog indicator: place icon in the indent space to the left of the recipe name.
      -- "unknown" = appearance not collected (full opacity).
      -- "item" = appearance collected but not from this item (semi-transparent).
      local transmog = collectedLines[idx].transmog
      if transmog then
        local iconFs = AcquireFontString()
        iconFs:SetFontObject(GameTooltipText)
        iconFs:SetText("|A:Crosshair_Transmogrify_32:15:15|a")
        iconFs:SetAlpha(transmog == "item" and 0.35 or 1)
        iconFs:SetPoint("TOPLEFT", tooltipFrame, "TOPLEFT", x+2, yOffset+2)
      end
      yOffset = yOffset - (tooltipLineHeight + LINE_SPACING)
      if kind == "character" then yOffset = yOffset - CHARACTER_POST_SPACING end
      if kind == "profession" then yOffset = yOffset - PROFESSION_POST_SPACING end
    end
    x = x + colWidth + COLUMN_GAP
  end

  -- Phase 4: Size and anchor the frame.
  tooltipFrame:SetSize(totalWidth, totalHeight)
  tooltipFrame:ClearAllPoints()

  if gameTooltipAnchor == "BOTTOMLEFT" then
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



-- Poll for modifier state changes using OnUpdate (only while GameTooltip is shown).
-- MODIFIER_STATE_CHANGED is not fired when an edit box has keyboard focus (e.g. chat input),
-- but IsModifiedClick() checks raw input state and works regardless -- same as Blizzard's
-- item comparison tooltip (TooltipUtil.ShouldDoItemComparison uses IsModifiedClick("COMPAREITEMS")).
local tooltipModifierListener = CreateFrame("Frame")
GameTooltip:HookScript("OnShow", function()
  tooltipModifierListener:SetScript("OnUpdate", ShowSecondTooltip)
end)
GameTooltip:HookScript("OnHide", function()
  tooltipModifierListener:SetScript("OnUpdate", nil)
  HideSecondTooltip()
end)














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


