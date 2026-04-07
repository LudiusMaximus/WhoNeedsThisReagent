local _, addon = ...

-- Cache of global WoW API tables/functions.
local C_TooltipInfo_GetItemByID                  = _G.C_TooltipInfo.GetItemByID
local C_TradeSkillUI_GetRecipeInfo               = _G.C_TradeSkillUI.GetRecipeInfo
local C_TradeSkillUI_GetRecipeSchematic          = _G.C_TradeSkillUI.GetRecipeSchematic
local GetProfessionInfo                          = _G.GetProfessionInfo
local GetProfessions                             = _G.GetProfessions
local PlaySound                                  = _G.PlaySound
local StopSound                                  = _G.StopSound

local sort                                       = _G.sort
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



function addon.AddReagentsForRecipe(recipeId, variantSkillLineId)
  -- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetRecipeSchematic
  local schematic = C_TradeSkillUI_GetRecipeSchematic(recipeId, false)
  if schematic and schematic.reagentSlotSchematics then
    for _, reagentSlot in pairs(schematic.reagentSlotSchematics) do
      if reagentSlot.reagents then
        for _, reagent in pairs(reagentSlot.reagents) do
          -- Some reagents are currencies (reagent.currencyID) rather than items; skip those.
          if reagent.itemID then
            -- Add reagent to recipe mapping (colon-delimited string of recipeIds).
            WNTR_reagentToRecipe[variantSkillLineId] = WNTR_reagentToRecipe[variantSkillLineId] or {}
            local existing = WNTR_reagentToRecipe[variantSkillLineId][reagent.itemID]
            if existing then
              WNTR_reagentToRecipe[variantSkillLineId][reagent.itemID] = existing .. ":" .. recipeId
            else
              WNTR_reagentToRecipe[variantSkillLineId][reagent.itemID] = tostring(recipeId)
            end
          end
        end
      end
    end
  end
end


function addon.GetRecipesForReagent(variantId, reagentId, result)
  if result then wipe(result) else result = {} end
  if WNTR_reagentToRecipe[variantId] then
    local str = WNTR_reagentToRecipe[variantId][reagentId]
    if str then
      for id in string_gmatch(str, "[^:]+") do
        tinsert(result, tonumber(id))
      end
    end
  end
  return result
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


-- Check whether a recipe produces an item whose transmog appearance has not yet been collected.
-- C_TransmogCollection.PlayerHasTransmog(itemId) appears to be broken (always returns false),
-- so we inspect the recipe result tooltip for TRANSMOGRIFY_TOOLTIP_APPEARANCE_UNKNOWN instead.
-- Uses schematic.outputItemID instead of the broken C_TooltipInfo.GetRecipeResultItem() API,
-- which returns wrong results for Shadowlands recipes.
function addon.UpdateUncollectedTransmog(recipeId)
  local schematic = C_TradeSkillUI_GetRecipeSchematic(recipeId, false)
  if not schematic or not schematic.outputItemID then
    WNTR_recipeWithUncollectedTransmog[recipeId] = nil
    return
  end

  local tooltipInfo = C_TooltipInfo_GetItemByID(schematic.outputItemID)
  if tooltipInfo and tooltipInfo.lines then
    -- Search from bottom to top, because the appearance line is typically near the end.
    for i = #tooltipInfo.lines, 3, -1 do
      if tooltipInfo.lines[i].leftText == TRANSMOGRIFY_TOOLTIP_APPEARANCE_UNKNOWN then
        WNTR_recipeWithUncollectedTransmog[recipeId] = true
        return
      end
    end
  end

  WNTR_recipeWithUncollectedTransmog[recipeId] = nil
end
