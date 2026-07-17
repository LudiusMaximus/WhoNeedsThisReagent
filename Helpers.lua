local _, addon = ...

-- Cache of global WoW API tables/functions.
local C_Item_IsItemDataCachedByID                = _G.C_Item.IsItemDataCachedByID
local C_TooltipInfo_GetRecipeResultItem          = _G.C_TooltipInfo.GetRecipeResultItem
local C_TradeSkillUI_GetRecipeInfo               = _G.C_TradeSkillUI.GetRecipeInfo
local C_TradeSkillUI_GetRecipeSchematic          = _G.C_TradeSkillUI.GetRecipeSchematic
local GetProfessionInfo                          = _G.GetProfessionInfo
local GetProfessions                             = _G.GetProfessions
local PlaySound                                  = _G.PlaySound
local StopSound                                  = _G.StopSound

local sort                                       = _G.sort
local string_find                                = _G.string.find
local string_gmatch                              = _G.string.gmatch
local tinsert                                    = _G.tinsert
local wipe                                       = _G.wipe



-- Suppress the sound effect that plays when opening/closing the profession UI.
-- Trick by MunkDev: https://www.wowinterface.com/forums/showthread.php?p=325688#post325688
function addon.StopLastSound()
  local _, handle = PlaySound(SOUNDKIT[next(SOUNDKIT)], "SFX", false)
  if handle then
    StopSound(handle-1)
    StopSound(handle)
  end
end

-- True if the character has the given base profession AND it is a profession the
-- addon cares about. This is the single source of truth for the latter policy:
-- the destructure deliberately discards the 3rd and 4th GetProfessions() return
-- values (archaeology and fishing) because those don't have recipes that consume
-- reagents, so syncing them would produce nothing useful. CONSOLE_MESSAGE and
-- NEW_RECIPE_LEARNED use this function as their gating filter.
function addon.CharacterHasBaseProfession(requestedBaseSkillLineId)
  local spellTabIndexProf1, spellTabIndexProf2, _, _, spellTabIndexCooking = GetProfessions()
  for _, spellTabIndex in ipairs({spellTabIndexProf1, spellTabIndexProf2, spellTabIndexCooking}) do
    if spellTabIndex then
      local _, _, _, _, _, _, baseSkillLineId = GetProfessionInfo(spellTabIndex)
      if baseSkillLineId == requestedBaseSkillLineId then
        return true
      end
    end
  end
  return false
end


function addon.AddOrUpdateCharacterToClass(realmName, playerName, classFilename)
  WNTR_characterToClass[realmName] = WNTR_characterToClass[realmName] or {}
  WNTR_characterToClass[realmName][playerName] = classFilename
end


-- Colon-separated integer id lists ("id1:id2:id3", no leading/trailing colon)
-- are the storage format for WNTR_variantToRecipes and the inner values of
-- WNTR_reagentToRecipe. These two helpers centralise the parse/contain idiom.

-- True if `id` (number or numeric string) is present in the colon-separated
-- list `str`. Safe on nil `str`.
function addon.ColonListContains(str, id)
  if not str then return false end
  local needle = ":" .. tostring(id) .. ":"
  return string_find(":" .. str .. ":", needle, 1, true) ~= nil
end

-- Iterator over the numeric ids in a colon-separated list. Safe on nil `str`
-- (yields nothing). Usage: `for id in IterColonListIds(str) do ... end`.
function addon.IterColonListIds(str)
  if not str then return function() end end
  local gm = string_gmatch(str, "[^:]+")
  return function()
    local s = gm()
    if s then return tonumber(s) end
  end
end



function addon.AddReagentsForRecipe(recipeId, variantSkillLineId)
  -- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetRecipeSchematic
  local schematic = C_TradeSkillUI_GetRecipeSchematic(recipeId, false)
  if not schematic then return end

  -- Cache the recipe's output item id (used by the transitive reagent walker
  -- to follow reagent -> intermediate -> final-product chains).
  if schematic.outputItemID then
    WNTR_recipeToOutputItem[recipeId] = schematic.outputItemID
  end

  if schematic.reagentSlotSchematics then
    local recipeStr = tostring(recipeId)
    for _, reagentSlot in pairs(schematic.reagentSlotSchematics) do
      -- Enum.CraftingReagentType: Basic=1 (required), Modifying=0, Finishing=2,
      -- Automatic=3. Anything not Basic is "optional" for our purposes.
      local isRequired = reagentSlot.reagentType == 1
      if reagentSlot.reagents then
        for _, reagent in pairs(reagentSlot.reagents) do
          -- Some reagents are currencies (reagent.currencyID) rather than items; skip those.
          if reagent.itemID then
            -- Add reagent to the union mapping (colon-delimited string of recipeIds).
            -- Skip if the recipeId is already present: the same itemID can appear in
            -- multiple reagent slots of one recipe, and global resyncs append onto
            -- the previously-stored entry rather than rebuilding it.
            WNTR_reagentToRecipe[variantSkillLineId] = WNTR_reagentToRecipe[variantSkillLineId] or {}
            local existing = WNTR_reagentToRecipe[variantSkillLineId][reagent.itemID]
            if not existing then
              WNTR_reagentToRecipe[variantSkillLineId][reagent.itemID] = recipeStr
            elseif not addon.ColonListContains(existing, recipeId) then
              WNTR_reagentToRecipe[variantSkillLineId][reagent.itemID] = existing .. ":" .. recipeStr
            end

            -- Mirror into the required-only mapping when the slot is Basic. The
            -- transitive walker uses this so chains don't explode through items
            -- accepted only as optional modifiers.
            if isRequired then
              WNTR_reagentToRecipeRequired[variantSkillLineId] = WNTR_reagentToRecipeRequired[variantSkillLineId] or {}
              local existingReq = WNTR_reagentToRecipeRequired[variantSkillLineId][reagent.itemID]
              if not existingReq then
                WNTR_reagentToRecipeRequired[variantSkillLineId][reagent.itemID] = recipeStr
              elseif not addon.ColonListContains(existingReq, recipeId) then
                WNTR_reagentToRecipeRequired[variantSkillLineId][reagent.itemID] = existingReq .. ":" .. recipeStr
              end
            end
          end
        end
      end
    end
  end
end


-- ============================================================
-- Consumer graph (shared by Tooltip.lua and ProfessionFrame.lua)
-- ============================================================

-- Depth cap for transitive walks. Covers Ore -> Bar -> Steel Bar ->
-- Steel Weapon Chain -> Gauntlets (4 hops) with one hop of slack.
addon.TRANSITIVE_REAGENT_MAX_DEPTH = 5

-- Merged consumer indexes, built lazily from the saved reagent tables:
--   index[itemId] = flat array {recipeId1, varId1, recipeId2, varId2, ...}
-- of every recipe (across all variants) consuming the item. Iterating the saved
-- tables directly would mean, per lookup, one probe into each of the ~60
-- variant subtables plus re-parsing colon strings on every visit; the index
-- parses each colon string exactly once per session and turns a lookup into a
-- single array scan.
local consumerIndexUnion = nil     -- from WNTR_reagentToRecipe (all slot types)
local consumerIndexRequired = nil  -- from WNTR_reagentToRecipeRequired (Basic only)

local function BuildConsumerIndex(sourceTable)
  local index = {}
  for varId, reagents in pairs(sourceTable) do
    if type(varId) == "number" then
      for itemId, recipeStr in pairs(reagents) do
        local list = index[itemId]
        if not list then
          list = {}
          index[itemId] = list
        end
        for recipeId in addon.IterColonListIds(recipeStr) do
          list[#list + 1] = recipeId
          list[#list + 1] = varId
        end
      end
    end
  end
  return index
end

-- includeOptional: true -> union of all reagent slot types, false -> only
-- required (Basic) slots (the default edge set for transitive walks, so chains
-- don't explode through modifier-y catch-all items like Relics of the Past).
function addon.GetConsumerIndex(includeOptional)
  if includeOptional then
    if not consumerIndexUnion then
      consumerIndexUnion = BuildConsumerIndex(WNTR_reagentToRecipe)
    end
    return consumerIndexUnion
  end
  if not consumerIndexRequired then
    consumerIndexRequired = BuildConsumerIndex(WNTR_reagentToRecipeRequired)
  end
  return consumerIndexRequired
end

-- Called by addon.InvalidateReagentCache (Tooltip.lua) when a sync may have
-- changed the underlying reagent tables.
function addon.InvalidateConsumerIndexes()
  consumerIndexUnion = nil
  consumerIndexRequired = nil
end


-- Transitive transmog state per recipe, for the professions frame:
-- does the recipe's output feed - directly or through deeper crafting chains -
-- into any recipe flagged as having an uncollected transmog appearance?
--   "unknown" - some reachable recipe's appearance is fully uncollected.
--   "item"    - reachable appearances are collected, but not from those items.
--   nil       - nothing uncollected reachable.
-- Strictly downstream: the recipe's OWN flags are the caller's business.
-- Follows the same edges as the tooltip's transitive display (required-only by
-- default, union when transitiveIncludeOptionalReagents is on).
-- transitiveTransmogCache[recipeId] = "unknown" | "item" | false (= computed, nothing found).
local transitiveTransmogCache = {}

-- Wiped when a transmog flag actually changes (see SetTransmogFlags below),
-- when the reagent tables may have changed (InvalidateReagentCache), and when
-- the transitive config toggles change (MinimapButton.lua).
function addon.InvalidateTransitiveTransmogCache()
  wipe(transitiveTransmogCache)
end

function addon.GetTransitiveTransmogState(recipeId)
  local cached = transitiveTransmogCache[recipeId]
  if cached ~= nil then
    if cached then return cached end
    return nil
  end

  local index = addon.GetConsumerIndex(WNTR_config.transitiveIncludeOptionalReagents)
  local best = nil
  -- visitedItems[itemId] = highest hop budget it was expanded with. Re-expand
  -- only when a new path arrives with more remaining hops (a cheaper-reached
  -- item may see deeper); this both dedups and breaks cycles.
  local visitedItems = {}

  local function visit(itemId, hopsLeft)
    if (visitedItems[itemId] or -1) >= hopsLeft then return false end
    visitedItems[itemId] = hopsLeft
    local list = index[itemId]
    if not list then return false end
    for i = 1, #list, 2 do
      local rid = list[i]
      if WNTR_recipeWithUncollectedTransmog[rid] then
        best = "unknown"
        return true  -- Strongest state; no need to search further.
      end
      if WNTR_recipeWithUncollectedTransmogItem[rid] then
        best = "item"
      end
      if hopsLeft > 1 then
        local out = WNTR_recipeToOutputItem[rid]
        if out and visit(out, hopsLeft - 1) then return true end
      end
    end
    return false
  end

  local output = WNTR_recipeToOutputItem[recipeId]
  if output then
    -- The recipe itself is depth 1 in tooltip terms; its consumers are depth 2.
    visit(output, addon.TRANSITIVE_REAGENT_MAX_DEPTH - 1)
  end

  transitiveTransmogCache[recipeId] = best or false
  return best
end




-- Compute a recipe's 1-based rank by walking its previousRecipeID chain.
-- Only works while the profession is active (i.e. during sync).
function addon.GetRecipeRank(recipeInfo)
  local firstInfo = recipeInfo
  while firstInfo.previousRecipeID do
    firstInfo = C_TradeSkillUI_GetRecipeInfo(firstInfo.previousRecipeID)
    if not firstInfo then return 0 end
  end
  local rank = 1
  local currentInfo = firstInfo
  while currentInfo do
    if currentInfo.recipeID == recipeInfo.recipeID then return rank end
    if not currentInfo.nextRecipeID then break end
    currentInfo = C_TradeSkillUI_GetRecipeInfo(currentInfo.nextRecipeID)
    rank = rank + 1
  end
  return 0
end

-- For ranked Shadowlands recipes without the previousRecipeID/nextRecipeID logic,
-- detect rank groups by matching recipe names and assign ranks by sorted recipeId.
-- NOTE: This heuristic (same name + ascending recipeId = ascending rank) only works for
-- Shadowlands. For Legion/BfA it was found to produce incorrect results: the chain fields
-- (previousRecipeID/nextRecipeID) indicate the true rank order, which does NOT always
-- correspond to ascending recipeId. Those recipes are handled by GetRecipeRank() and
-- are skipped here via the `if not WNTR_recipeToRank[recipeId]` guard.
-- Have to make sure that AssignRanksByName is run after WNTR_recipeToRank was filled using GetRecipeRank().
function addon.AssignRanksByName(variantRecipeInfos)
  -- variantRecipeInfos: { [recipeId] = recipeInfo }
  
  -- For each recipe name, create a list of associated IDs.
  local recipeNameToIds = {}
  for recipeId, recipeInfo in pairs(variantRecipeInfos) do
    local recipeName = recipeInfo.name
    -- Ranked Legion/BfA recipes have the same names too, but we need to exclude them here.
    if not WNTR_recipeToRank[recipeId] then
      recipeNameToIds[recipeName] = recipeNameToIds[recipeName] or {}
      tinsert(recipeNameToIds[recipeName], recipeId)
    end
  end
  
  -- For every name with more than one ID, sort the IDs, leading to the rank for each ID.
  for recipeName, recipeIds in pairs(recipeNameToIds) do
    if #recipeIds > 1 then
      sort(recipeIds)
      for rank, recipeId in ipairs(recipeIds) do
        WNTR_recipeToRank[recipeId] = rank
      end
    end
  end
end


-- Correct learned/difficulty data for Shadowlands-style ranked recipes, which have two API "bugs":
--   1. recipeInfo.learned returns true for ALL ranks once rank 1 has any XP.
--   2. recipeInfo.relativeDifficulty is always 0 (optimal) regardless of rank progress.
-- Detection: a Shadowlands ranked recipe has a rank but no chain fields (previousRecipeID/nextRecipeID).
-- Fix: after AssignRanksByName has populated WNTR_recipeToRank, compare the recipe's rank to
-- unlockedRecipeLevel to determine the true learned/difficulty state.
function addon.CorrectShadowlandsRankedRecipeDifficulty(realmName, playerName, recipeId, recipeInfo, variantSkillLineId)
  if not recipeInfo then return end
  -- Only apply to Shadowlands-style ranked recipes (no chain fields).
  if recipeInfo.previousRecipeID or recipeInfo.nextRecipeID then return end
  local rank = WNTR_recipeToRank[recipeId]
  if not rank then return end
  local unlockedLevel = recipeInfo.unlockedRecipeLevel
  if not unlockedLevel or unlockedLevel == 0 then return end
  -- print(recipeInfo.name, recipeId, recipeInfo.recipeID, rank, unlockedLevel)

  local charRecipes = WNTR_recipeToDifficulty[realmName]
      and WNTR_recipeToDifficulty[realmName][playerName]
      and WNTR_recipeToDifficulty[realmName][playerName][variantSkillLineId]
  if not charRecipes then return end

  if rank > unlockedLevel then
    -- API incorrectly reports as learned; remove it.
    charRecipes[recipeId] = nil
  elseif rank < unlockedLevel then
    -- Already fully mastered; mark as trivial and clear any stale XP data.
    charRecipes[recipeId] = 3
    if WNTR_recipeToExperience[realmName] and WNTR_recipeToExperience[realmName][playerName] then
      WNTR_recipeToExperience[realmName][playerName][recipeId] = nil
    end
  end
  -- rank == unlockedLevel: currently being worked on; keep the stored difficulty as-is.
end


-- Store recipe rank XP progress for a learned ranked recipe.
-- Only stores data for the rank currently being worked on (where rank == unlockedRecipeLevel).
function addon.UpdateRecipeExperience(realmName, playerName, recipeId, recipeInfo)
  if not recipeInfo or not WNTR_recipeToRank[recipeId] then return end
  local rank = WNTR_recipeToRank[recipeId]
  local unlockedLevel = recipeInfo.unlockedRecipeLevel
  if not unlockedLevel or unlockedLevel == 0 then return end

  if rank == unlockedLevel then
    local currentXP = recipeInfo.currentRecipeExperience
    local nextXP = recipeInfo.nextLevelRecipeExperience
    if currentXP and nextXP and nextXP > 0 then
      WNTR_recipeToExperience[realmName]              = WNTR_recipeToExperience[realmName] or {}
      WNTR_recipeToExperience[realmName][playerName]  = WNTR_recipeToExperience[realmName][playerName] or {}
      WNTR_recipeToExperience[realmName][playerName][recipeId] = currentXP
      WNTR_recipeToExperience["nextLevels"] = WNTR_recipeToExperience["nextLevels"] or {}
      WNTR_recipeToExperience["nextLevels"][recipeId] = nextXP
    end
  end
end


-- Write both transmog flags of a recipe; when either actually changes, the
-- transitive transmog cache is stale (this recipe may sit downstream of other
-- recipes' chains) and gets wiped.
local function SetTransmogFlags(recipeId, unknownFlag, itemFlag)
  if (WNTR_recipeWithUncollectedTransmog[recipeId] ~= nil) ~= unknownFlag
      or (WNTR_recipeWithUncollectedTransmogItem[recipeId] ~= nil) ~= itemFlag then
    WNTR_recipeWithUncollectedTransmog[recipeId] = unknownFlag or nil
    WNTR_recipeWithUncollectedTransmogItem[recipeId] = itemFlag or nil
    addon.InvalidateTransitiveTransmogCache()
  end
end

-- Check whether a recipe produces an item with an uncollected transmog appearance.
-- C_TransmogCollection.PlayerHasTransmog(itemId) appears to be broken (always returns false),
-- so we inspect the recipe result tooltip instead. Uses C_TooltipInfo.GetRecipeResultItem
-- (the same API Blizzard's ProfessionsFrame.CraftingPage.SchematicForm.OutputIcon uses)
-- rather than C_TooltipInfo.GetItemByID(outputItemID). For recipes that produce items with
-- random affixes (e.g. BfA gear like "Tidespray Linen Mittens of the Feverflare"), the base
-- item ID's own tooltip does not reflect the true transmog collection state - only the
-- recipe-context tooltip does.
--
-- Sets WNTR_recipeWithUncollectedTransmog[recipeId] = true when the appearance is fully unknown.
-- Sets WNTR_recipeWithUncollectedTransmogItem[recipeId] = true when the appearance is known
-- but not from this specific item ("You've collected this appearance, but not from this item").
function addon.UpdateUncollectedTransmog(recipeId)
  -- If the output item's data hasn't been cached by the client yet (common on
  -- fresh login before the profession backend loads), GetRecipeResultItem still
  -- returns a table but the tooltip is truncated - it typically has the item
  -- name / level / bind type but is missing the transmog line at the end. If
  -- we ran the parse against that, we'd see no matching line and wrongly clear
  -- the saved flags. Preserve them until the item data is ready.
  local schematic = C_TradeSkillUI_GetRecipeSchematic(recipeId, false)
  if schematic and schematic.outputItemID
      and not C_Item_IsItemDataCachedByID(schematic.outputItemID) then
    return
  end

  local tooltipInfo = C_TooltipInfo_GetRecipeResultItem(recipeId)
  if not (tooltipInfo and tooltipInfo.lines) then
    -- No tooltip data (e.g. recipe belongs to a profession whose backend is not
    -- currently loaded). Preserve existing flags rather than clearing them.
    return
  end

  -- Search from bottom to top, because the appearance line is typically near the end.
  for i = #tooltipInfo.lines, 3, -1 do
    local lineText = tooltipInfo.lines[i].leftText
    if lineText == TRANSMOGRIFY_TOOLTIP_APPEARANCE_UNKNOWN then
      SetTransmogFlags(recipeId, true, false)
      return
    end
    if lineText == TRANSMOGRIFY_TOOLTIP_ITEM_UNKNOWN_APPEARANCE_KNOWN then
      SetTransmogFlags(recipeId, false, true)
      return
    end
  end

  SetTransmogFlags(recipeId, false, false)
end


-- Debug helper. Call via
--   /run WNTR_DebugTransmog(RECIPEID)
-- to dump the tooltip data we actually inspect (from C_TooltipInfo.GetRecipeResultItem)
-- alongside the current saved flags and the two constants we match against.
-- Routes through Ludius_DebugPrint (from MinimalWorkingExample) if that addon is
-- loaded - its scrollable window makes the output copy-pasteable; otherwise
-- falls back to plain chat print.
function WNTR_DebugTransmog(recipeId)
  local sink = _G.Ludius_DebugPrint
  local function out(...)
    if sink then
      local n = select("#", ...)
      local parts = {}
      for i = 1, n do parts[i] = tostring(select(i, ...)) end
      sink(table.concat(parts, "\t"))
    else
      print(...)
    end
  end

  out("--- WNTR Transmog Debug for recipeId", recipeId, "---")
  local schematic = C_TradeSkillUI_GetRecipeSchematic(recipeId, false)
  out("  outputItemID (context):", schematic and schematic.outputItemID)
  out("  saved WNTR_recipeWithUncollectedTransmog     [", recipeId, "] =", WNTR_recipeWithUncollectedTransmog[recipeId])
  out("  saved WNTR_recipeWithUncollectedTransmogItem [", recipeId, "] =", WNTR_recipeWithUncollectedTransmogItem[recipeId])
  out("  const TRANSMOGRIFY_TOOLTIP_APPEARANCE_UNKNOWN           =", TRANSMOGRIFY_TOOLTIP_APPEARANCE_UNKNOWN)
  out("  const TRANSMOGRIFY_TOOLTIP_ITEM_UNKNOWN_APPEARANCE_KNOWN =", TRANSMOGRIFY_TOOLTIP_ITEM_UNKNOWN_APPEARANCE_KNOWN)
  local tooltipInfo = C_TooltipInfo_GetRecipeResultItem(recipeId)
  if not (tooltipInfo and tooltipInfo.lines) then
    out("  GetRecipeResultItem returned no lines")
    return
  end
  out("  recipe-result tooltip lines (leftText):")
  for i, line in ipairs(tooltipInfo.lines) do
    out("   ", i, tostring(line.leftText))
  end
end
