local _, addon = ...

-- Cache of global WoW API tables/functions.
local C_TradeSkillUI_GetProfessionInfoByRecipeID = _G.C_TradeSkillUI.GetProfessionInfoByRecipeID
local C_TradeSkillUI_GetRecipeInfo               = _G.C_TradeSkillUI.GetRecipeInfo
local C_TradeSkillUI_GetRecipeSchematic          = _G.C_TradeSkillUI.GetRecipeSchematic
local GetProfessionInfo                          = _G.GetProfessionInfo
local GetProfessions                             = _G.GetProfessions
local PlaySound                                  = _G.PlaySound
local StopSound                                  = _G.StopSound

local sort                                       = _G.sort
local tinsert                                    = _G.tinsert



-- Suppress the sound effect that plays when opening/closing the profession UI.
-- Trick by MunkDev: https://www.wowinterface.com/forums/showthread.php?p=325688#post325688
function addon.StopLastSound()
  local _, handle = PlaySound(SOUNDKIT[next(SOUNDKIT)], "SFX", false)
  if handle then
    StopSound(handle-1)
    StopSound(handle)
  end
end

function addon.CharacterHasProfession(professionId)
  local spellTabIndexProf1, spellTabIndexProf2, _, _, spellTabIndexCooking = GetProfessions()
  for _, spellTabIndex in ipairs({spellTabIndexProf1, spellTabIndexProf2, spellTabIndexCooking}) do
    if spellTabIndex then
      local _, _, _, _, _, _, tradeSkillLineId = GetProfessionInfo(spellTabIndex)
      if tradeSkillLineId == professionId then
        return true
      end
    end
  end
  return false
end


function addon.AddOrUpdateCharacterToClass(realm, character, classFilename)
  WNTR_characterToClass[realm] = WNTR_characterToClass[realm] or {}
  WNTR_characterToClass[realm][character] = classFilename
end


function addon.AddOrUpdateCharacterRecipeDifficulty(realm, character, variantId, recipeId, difficulty)
  -- Double-check that the recipe actually belongs to the profession variant.
  local profInfoCheck = C_TradeSkillUI_GetProfessionInfoByRecipeID(recipeId)
  if not profInfoCheck or (profInfoCheck.professionID ~= 0 and profInfoCheck.professionID ~= variantId) then
    print("|cffff0000WhoNeedsThisReagent:|r variantId mismatch in AddOrUpdateCharacterRecipeDifficulty: our variantId=" .. tostring(variantId) .. ", game variantId=" .. tostring(profInfoCheck and profInfoCheck.professionID) .. ", recipeId=" .. tostring(recipeId))
    return false
  end

  WNTR_recipeToDifficulty[realm] = WNTR_recipeToDifficulty[realm] or {}
  WNTR_recipeToDifficulty[realm][character] = WNTR_recipeToDifficulty[realm][character] or {}
  WNTR_recipeToDifficulty[realm][character][variantId] = WNTR_recipeToDifficulty[realm][character][variantId] or {}
  WNTR_recipeToDifficulty[realm][character][variantId][recipeId] = difficulty
  return true
end


function addon.AddReagentsForRecipe(variantId, recipeID)
  -- Double-check that the recipe actually belongs to the profession variant.
  local profInfoCheck = C_TradeSkillUI_GetProfessionInfoByRecipeID(recipeID)
  if not profInfoCheck or (profInfoCheck.professionID ~= 0 and profInfoCheck.professionID ~= variantId) then
    print("|cffff0000WhoNeedsThisReagent:|r variantId mismatch in AddReagentsForRecipe: our variantId=" .. tostring(variantId) .. ", game variantId=" .. tostring(profInfoCheck and profInfoCheck.professionID) .. ", recipeId=" .. tostring(recipeID))
    return false
  end

  -- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetRecipeSchematic
  local schematic = C_TradeSkillUI_GetRecipeSchematic(recipeID, false)
  if schematic and schematic.reagentSlotSchematics then
    for _, reagentSlot in pairs(schematic.reagentSlotSchematics) do
      if reagentSlot.reagents then
        for _, reagent in pairs(reagentSlot.reagents) do
          -- Some reagents are currencies (reagent.currencyID) rather than items; skip those.
          if reagent.itemID then
            -- Add reagent to recipe mapping.
            WNTR_reagentToRecipe[variantId] = WNTR_reagentToRecipe[variantId] or {}
            WNTR_reagentToRecipe[variantId][reagent.itemID] = WNTR_reagentToRecipe[variantId][reagent.itemID] or {}
            tinsert(WNTR_reagentToRecipe[variantId][reagent.itemID], recipeID)
          end
        end
      end
    end
  end
  return true
end


function addon.GetRecipesForReagent(variantId, reagentId)
  local recipes = {}
  if WNTR_reagentToRecipe[variantId] then
    if WNTR_reagentToRecipe[variantId][reagentId] then
      for _, recipeId in pairs(WNTR_reagentToRecipe[variantId][reagentId]) do
        tinsert(recipes, recipeId)
      end
    end
  end
  return recipes
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

-- For recipes without previousRecipeID/nextRecipeID chain data (e.g. Shadowlands),
-- detect rank groups by matching recipe names and assign ranks by sorted recipeID.
-- NOTE: This heuristic (same name + ascending recipeID = ascending rank) only works for
-- Shadowlands. For Legion/BfA it was found to produce incorrect results: the chain fields
-- (previousRecipeID/nextRecipeID) indicate the true rank order, which does NOT always
-- correspond to ascending recipeID. Those recipes are handled by GetRecipeRank() above and
-- are skipped here via the `if not WNTR_recipeToRank[recipeID]` guard.
function addon.AssignRanksByName(recipeNames)
  -- recipeNames: { [recipeID] = recipeName, ... }
  local nameToIds = {}
  for recipeID, name in pairs(recipeNames) do
    if not WNTR_recipeToRank[recipeID] then
      nameToIds[name] = nameToIds[name] or {}
      tinsert(nameToIds[name], recipeID)
    end
  end
  for name, ids in pairs(nameToIds) do
    if #ids > 1 then
      sort(ids)
      for rank, recipeID in ipairs(ids) do
        WNTR_recipeToRank[recipeID] = rank
      end
    end
  end
end



