local folderName, addon = ...

-- Cache of global WoW API tables/functions.
local C_Timer_NewTicker                             = _G.C_Timer.NewTicker
local C_Timer_NewTimer                              = _G.C_Timer.NewTimer
local C_TradeSkillUI_CloseTradeSkill                = _G.C_TradeSkillUI.CloseTradeSkill
local C_TradeSkillUI_GetAllRecipeIDs                = _G.C_TradeSkillUI.GetAllRecipeIDs
local C_TradeSkillUI_GetBaseProfessionInfo          = _G.C_TradeSkillUI.GetBaseProfessionInfo
local C_TradeSkillUI_GetChildProfessionInfos        = _G.C_TradeSkillUI.GetChildProfessionInfos
local C_TradeSkillUI_GetProfessionInfoBySkillLineID = _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID
local C_TradeSkillUI_GetRecipeInfo                  = _G.C_TradeSkillUI.GetRecipeInfo
local C_TradeSkillUI_IsRecipeInSkillLine            = _G.C_TradeSkillUI.IsRecipeInSkillLine
local C_TradeSkillUI_OpenTradeSkill                 = _G.C_TradeSkillUI.OpenTradeSkill
local GetProfessionInfo                             = _G.GetProfessionInfo
local GetProfessions                                = _G.GetProfessions
local GetRealmName                                  = _G.GetRealmName
local UnitName                                      = _G.UnitName

local table_remove                                  = _G.table.remove
local tinsert                                       = _G.tinsert

-- Cache addon functions/tables.
local AddOrUpdateCharacterToClass                 = addon.AddOrUpdateCharacterToClass
local AddReagentsForRecipe                        = addon.AddReagentsForRecipe
local AssignRanksByName                           = addon.AssignRanksByName
local CharacterHasBaseProfession                      = addon.CharacterHasBaseProfession
local CorrectShadowlandsRankedRecipeDifficulty    = addon.CorrectShadowlandsRankedRecipeDifficulty
local GetRecipeRank                               = addon.GetRecipeRank
local UpdateRecipeExperience                      = addon.UpdateRecipeExperience
local StopLastSound                               = addon.StopLastSound
local pendingBaseSkillLineIds                     = addon.pendingBaseSkillLineIds

-- State for the silent-open flow: when we need to sync a profession not currently in the backend,
-- we open this profession invisibly, try to sync until successful, then closes it again.
local silentOpenProfessionId  = nil
local silentOpenFrameWasShown = nil
local silentOpenRetryTicker   = nil
local silentOpenRetryCount    = nil

-- True when SyncPendingProfession() was called from the chat /run command (no argument),
-- false when called from the minimap button (notFromChat = true). Controls whether we
-- re-pre-fill the chat box after each successful sync so the user can just press Enter again.
local syncFromChat = false


-- We debounce NEW_RECIPE_LEARNED so that TRADE_SKILL_LIST_UPDATE has time to
-- fire and do a full sync before we check GetBaseProfessionInfo() and potentially add to pending.
local pendingNewRecipes = {}
local newRecipeTimer = nil



-- Clickable chat hyperlinks to let the user trigger restricted functions from secure context.
-- OpenTradeSkill() is a restricted function that cannot be called from addon code.
-- https://warcraft.wiki.gg/wiki/Category:API_functions/restricted
-- By pre-filling the chat edit box with a /run command, the user can execute it with a single Enter.
hooksecurefunc(ItemRefTooltip, "SetHyperlink", function(self, link)
  local _, identifier = strsplit(":", link)
  if identifier == "wntr" then
    -- No need to hide ItemRefTooltip, because it will not even show up with our modified link.
    ChatEdit_ActivateChat(DEFAULT_CHAT_FRAME.editBox)
    DEFAULT_CHAT_FRAME.editBox:SetText("/run SyncPendingProfession()")
  end
end)

local PrintPendingSyncLinkTimer = nil
local function PrintPendingSyncLink()
  if PrintPendingSyncLinkTimer then
    PrintPendingSyncLinkTimer:Cancel()
  end
  PrintPendingSyncLinkTimer = C_Timer_NewTimer(0.5, function()
    PrintPendingSyncLinkTimer = nil
    if #pendingBaseSkillLineIds == 0 then return end
    local lines = "|cff00ccffWhoNeedsThisReagent:|r The following professions need synchronization:"
    for _, profId in ipairs(pendingBaseSkillLineIds) do
      local info = C_TradeSkillUI_GetProfessionInfoBySkillLineID(profId)
      lines = lines .. "\n  - " .. (info and info.professionName or tostring(profId))
    end
    lines = lines .. "\nOpen the profession frame, click the minimap button, or |cffff9900|Hitem:wntr:fetch|h[click here]|h|r and press Enter."
    print(lines)
  end)
end

local function AddPendingBaseProfession(baseSkillLineId)
  for _, id in ipairs(pendingBaseSkillLineIds) do
    if id == baseSkillLineId then return end
  end
  tinsert(pendingBaseSkillLineIds, baseSkillLineId)
  PrintPendingSyncLink()
  addon.UpdateMinimapGlow()
end


-- Look up the base profession for a variant, using the persisted mapping
-- with a fallback to the API (which populates the mapping for next time).
local function GetBaseOfVariant(variantSkillLineId)
  if WNTR_variantToBaseProfession[variantSkillLineId] then
    return WNTR_variantToBaseProfession[variantSkillLineId]
  end
  local variantProfessionInfo = C_TradeSkillUI_GetProfessionInfoBySkillLineID(variantSkillLineId)
  if variantProfessionInfo and variantProfessionInfo.parentProfessionID then
    WNTR_variantToBaseProfession[variantSkillLineId] = variantProfessionInfo.parentProfessionID
    return variantProfessionInfo.parentProfessionID
  end
  return nil
end


-- If caller already did GetAllRecipeIDs(), you can pass recipeIds for efficiency.
local function SyncVariantProfession(variantSkillLineId, recipeIds)
  -- If not passed as an argument, fetch recipes of current backend profession.
  if not recipeIds then
    recipeIds = C_TradeSkillUI_GetAllRecipeIDs()
    if not recipeIds or #recipeIds == 0 then return false end
  end
  
  local realmName  = GetRealmName()
  local playerName = UnitName("player")
  

  -- Global sync needed if explicitly pending or data is missing.
  local needsGlobalSync = WNTR_pendingGlobalSync[variantSkillLineId]
      or not WNTR_reagentToRecipe[variantSkillLineId]
      or not next(WNTR_reagentToRecipe[variantSkillLineId])
  
  -- Clear old data to be refilled.
  -- Character specific data is always updated.
  WNTR_recipeToDifficulty[realmName] = WNTR_recipeToDifficulty[realmName] or {}
  WNTR_recipeToDifficulty[realmName][playerName] = WNTR_recipeToDifficulty[realmName][playerName] or {}
  WNTR_recipeToDifficulty[realmName][playerName][variantSkillLineId] = nil

  -- Don't wipe, just override global data because a character can only
  -- sync the profession variants they have learned..
  

  -- Collecting { [recipeId] = recipeInfo } for post-processing (AssignRanksByName, CorrectShadowlandsRankedRecipeDifficulty, UpdateRecipeExperience).
  local variantRecipeInfos = {}

  for _, recipeId in pairs(recipeIds) do
  
    -- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.IsRecipeInSkillLine
    if C_TradeSkillUI_IsRecipeInSkillLine(recipeId, variantSkillLineId) then
    
      local recipeInfo = C_TradeSkillUI_GetRecipeInfo(recipeId)
      
      if recipeInfo then
      
        -- Collect for post-processing.
        variantRecipeInfos[recipeId] = recipeInfo
        
        
        if needsGlobalSync then

          AddReagentsForRecipe(recipeId, variantSkillLineId)

          -- Store the authoritative recipe-to-variant mapping.
          -- IsRecipeInSkillLine() is reliable here because the backend is active.
          -- We overwrite rather than wipe, preserving entries from other characters' professions.
          WNTR_recipeIdToVariantSkillLineId[recipeId] = variantSkillLineId

          -- Is this a Legion/Shadowlands ranked recipe?
          if recipeInfo.previousRecipeID or recipeInfo.nextRecipeID then
            WNTR_recipeToRank[recipeId] = GetRecipeRank(recipeInfo)
            -- print("WNTR DEBUG:", recipeId, recipeInfo.name, "prev=", tostring(recipeInfo.previousRecipeID), "next=", tostring(recipeInfo.nextRecipeID), "rank=", WNTR_recipeToRank[recipeId])
          end

        end
        
        if recipeInfo.learned then

          WNTR_recipeToDifficulty[realmName]                                 = WNTR_recipeToDifficulty[realmName] or {}
          WNTR_recipeToDifficulty[realmName][playerName]                     = WNTR_recipeToDifficulty[realmName][playerName] or {}
          WNTR_recipeToDifficulty[realmName][playerName][variantSkillLineId] = WNTR_recipeToDifficulty[realmName][playerName][variantSkillLineId] or {}
          WNTR_recipeToDifficulty[realmName][playerName][variantSkillLineId][recipeId] = recipeInfo.relativeDifficulty

        end

        -- If this recipe was a pending new recipe, ProcessNewRecipes() no longer needs to take care of it.
        if pendingNewRecipes[recipeId] then
          pendingNewRecipes[recipeId] = nil
          print("SyncVariantProfession already took care of pending new recipe", recipeId)
        end

      
      end -- if recipeInfo
    end -- if C_TradeSkillUI_IsRecipeInSkillLine(recipeId, variantSkillLineId
  end -- for _, recipeId in pairs(recipeIds)


  
  if needsGlobalSync then
    -- Assign ranks by name grouping for Shadowlands ranked recipes that lack the previousRecipeID/nextRecipeID logic.
    AssignRanksByName(variantRecipeInfos)
    -- Mark this variant as no longer pending for global sync.
    WNTR_pendingGlobalSync[variantSkillLineId] = nil
  end

  -- Correct Shadowlands ranked recipe learned/difficulty, then store XP.
  -- Both must happen after AssignRanksByName so WNTR_recipeToRank is fully populated.
  for recipeId, recipeInfo in pairs(variantRecipeInfos) do
    if recipeInfo.learned then
      CorrectShadowlandsRankedRecipeDifficulty(realmName, playerName, recipeId, recipeInfo, variantSkillLineId)
      UpdateRecipeExperience(realmName, playerName, recipeId, recipeInfo)
    end
  end

  -- Update skill level and variant-to-base mapping for this variant.
  local variantInfo = C_TradeSkillUI_GetProfessionInfoBySkillLineID(variantSkillLineId)
  if variantInfo then
    if variantInfo.parentProfessionID then
      WNTR_variantToBaseProfession[variantSkillLineId] = variantInfo.parentProfessionID
    end
    WNTR_professionVariantToSkillLevel[realmName] = WNTR_professionVariantToSkillLevel[realmName] or {}
    WNTR_professionVariantToSkillLevel[realmName][playerName] = WNTR_professionVariantToSkillLevel[realmName][playerName] or {}
    WNTR_professionVariantToSkillLevel[realmName][playerName][variantSkillLineId] = variantInfo.skillLevel
    WNTR_professionVariantToSkillLevel[realmName][playerName]["maxLevels"] = WNTR_professionVariantToSkillLevel[realmName][playerName]["maxLevels"] or {}
    WNTR_professionVariantToSkillLevel[realmName][playerName]["maxLevels"][variantSkillLineId] = variantInfo.maxSkillLevel
  end

  -- Mark this variant as no longer pending for character specific sync.
  if WNTR_pendingCharacterSync[realmName] and WNTR_pendingCharacterSync[realmName][playerName] then
    WNTR_pendingCharacterSync[realmName][playerName][variantSkillLineId] = nil
  end
  
  
  return true

end


-- Sync all variants of a base profession.
-- If caller already did GetAllRecipeIDs(), you can pass recipeIds for efficiency.
local function SyncBaseProfession(baseSkillLineId, recipeIds)
  -- If not passed as an argument, fetch recipes of current backend profession.
  if not recipeIds then
    recipeIds = C_TradeSkillUI_GetAllRecipeIDs()
    if not recipeIds or #recipeIds == 0 then return false end
  end

  -- Get all expansion variants for this profession.
  -- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetChildProfessionInfos
  local childInfos = C_TradeSkillUI_GetChildProfessionInfos()
  for _, childInfo in ipairs(childInfos) do
    if not SyncVariantProfession(childInfo.professionID, recipeIds) then
      return false
    end
  end
 
  return true
end



-- Remove a base profession from the pending list after a successful sync,
-- print a success message, and update the minimap glow.
local function CompletePendingSync(baseSkillLineId)
  for i, id in ipairs(pendingBaseSkillLineIds) do
    if id == baseSkillLineId then
      table_remove(pendingBaseSkillLineIds, i)
      break
    end
  end
  local baseProfessionName = C_TradeSkillUI_GetProfessionInfoBySkillLineID(baseSkillLineId).professionName
  print("|cff00ccffWhoNeedsThisReagent:|r ...", baseProfessionName, "synced successfully!")
  addon.UpdateMinimapGlow()
end




-- Closes the invisible profession frame (if we opened it), resets the silent-open state,
-- and notifies the user about any remaining pending professions.
local function FinishSilentOpen()
  if silentOpenRetryTicker then
    silentOpenRetryTicker:Cancel()
    silentOpenRetryTicker = nil
  end

  if not silentOpenFrameWasShown then
    C_TradeSkillUI_CloseTradeSkill()
    StopLastSound()
    if ProfessionsFrame and ProfessionsFrame.hiddenByWhoNeedsThisReagent and ProfessionsFrame:GetAlpha() == 0 then
      ProfessionsFrame:SetAlpha(ProfessionsFrame.hiddenByWhoNeedsThisReagent)
      ProfessionsFrame.hiddenByWhoNeedsThisReagent = nil
    end
  end

  silentOpenProfessionId = nil
  silentOpenFrameWasShown = nil

  if #pendingBaseSkillLineIds > 0 then
    local lines = "|cff00ccffWhoNeedsThisReagent:|r The following professions still need synchronization:"
    for _, profId in ipairs(pendingBaseSkillLineIds) do
      local info = C_TradeSkillUI_GetProfessionInfoBySkillLineID(profId)
      lines = lines .. "\n  - " .. (info and info.professionName or tostring(profId))
    end
    if syncFromChat then
      lines = lines .. "\nPress Enter again to proceed with the next."
    else
      lines = lines .. "\nOpen the profession frame, click the minimap button, or |cffff9900|Hitem:wntr:fetch|h[click here]|h|r and press Enter."
    end
    print(lines)
    if syncFromChat then
      ChatEdit_ActivateChat(DEFAULT_CHAT_FRAME.editBox)
      DEFAULT_CHAT_FRAME.editBox:SetText("/run SyncPendingProfession()")
    end
  end
end



-- Global function to sync the next pending profession, if any.
-- Must be called from a hardware event (minimap button click)
-- or from /run in the chat, since OpenTradeSkill() requires a secure execution context.
-- Better name would be "SyncNextPendingBaseProfession", but we want to keep the name
-- short for the chat input.
function SyncPendingProfession(notFromChat)
  
  -- Set global flag to indicate that we have to refill the chat input text.
  -- "Not not" from chat, may seem cumbersome but is intentional to keep
  -- the chat input command simple without any arguments.
  syncFromChat = not notFromChat
  
  if #pendingBaseSkillLineIds == 0 then
    print("|cff00ccffWhoNeedsThisReagent:|r All professions are already synced.")
    return
  end
  local baseSkillLineId = pendingBaseSkillLineIds[1]
  
  -- Check if the character actually has this profession.
  if not CharacterHasBaseProfession(baseSkillLineId) then return end
  
  
  local baseProfessionName = C_TradeSkillUI_GetProfessionInfoBySkillLineID(baseSkillLineId).professionName
  print("|cff00ccffWhoNeedsThisReagent:|r Starting synchronization of", baseProfessionName, "...")
  
  
  -- Always open the profession via OpenTradeSkill() to get a live backend.
  -- GetAllRecipeIDs() only reflects the last-opened frame state and is not reliable here.
  -- print("WNTR DEBUG: Opening profession", baseSkillLineId, "silently...")
  silentOpenProfessionId = baseSkillLineId
  silentOpenFrameWasShown = ProfessionsFrame and ProfessionsFrame:IsShown() or false
  C_TradeSkillUI_OpenTradeSkill(baseSkillLineId)
  StopLastSound()
  
  -- The rest happens in OnEvent when TRADE_SKILL_LIST_UPDATE fires.
end



local function ProcessNewRecipes()

  local realmName  = GetRealmName()
  local playerName = UnitName("player")

  -- Go through all pending recipes and collect the variantSkillLineIds that need syncing.
  WNTR_pendingCharacterSync[realmName] = WNTR_pendingCharacterSync[realmName] or {}
  WNTR_pendingCharacterSync[realmName][playerName] = WNTR_pendingCharacterSync[realmName][playerName] or {}
  for recipeId, variantSkillLineId in pairs(pendingNewRecipes) do
    print("ProcessNewRecipes processing:", recipeId, variantSkillLineId)
    WNTR_pendingCharacterSync[realmName][playerName][variantSkillLineId] = true
  end
  wipe(pendingNewRecipes)

  -- Queue all pending variants for sync. GetAllRecipeIDs() only reflects the last-opened profession
  -- frame, not a truly live backend, so we never attempt silent syncs outside of TRADE_SKILL_LIST_UPDATE.
  for variantSkillLineId in pairs(WNTR_pendingCharacterSync[realmName][playerName]) do
    AddPendingBaseProfession(GetBaseOfVariant(variantSkillLineId))
  end

end



-- Detect profession changes: track variant skill levels, queue pending syncs,
-- and remove stored data for professions the character no longer has.
local function UpdateProfessions()

  print("UpdateProfessions")

  local realmName  = GetRealmName()
  local playerName = UnitName("player")


  -- Initialize character specific saved variables if not present.
  WNTR_professionVariantToSkillLevel[realmName] = WNTR_professionVariantToSkillLevel[realmName] or {}
  WNTR_professionVariantToSkillLevel[realmName][playerName] = WNTR_professionVariantToSkillLevel[realmName][playerName] or {}
  
  WNTR_pendingCharacterSync[realmName] = WNTR_pendingCharacterSync[realmName] or {}
  WNTR_pendingCharacterSync[realmName][playerName] = WNTR_pendingCharacterSync[realmName][playerName] or {}



  -- Track which base professions the character currently has (for possible cleanup of removed professions below).
  local currentBaseIds = {}

  -- Do NOT wipe pendingBaseSkillLineIds here. Other events (LEARNED_SPELL_IN_SKILL_LINE, ProcessNewRecipes)
  -- may have correctly added entries before UpdateProfessions runs. Wiping would undo that work, because
  -- UpdateProfessions can only reconstruct entries from WNTR_pendingCharacterSync — which does not capture
  -- newly learned variants whose IDs are not yet stored there.
  -- Stale entries for dropped professions are removed explicitly in the cleanup section below.

  -- Going through the character's current professions to detect changes since last check.
  local spellTabIndexProf1, spellTabIndexProf2, _, _, spellTabIndexCooking = GetProfessions()
  for _, spellTabIndex in ipairs({spellTabIndexProf1, spellTabIndexProf2, spellTabIndexCooking}) do
    if spellTabIndex then
      local _, icon, _, _, _, _, baseSkillLineId = GetProfessionInfo(spellTabIndex)

      -- Cache profession icon while we are at it.
      WNTR_professionSkillLineToIcon[baseSkillLineId] = icon

      -- Remember that this is a currently known professions (for possible cleanup of removed professions below).
      currentBaseIds[baseSkillLineId] = true

      -- Check if this base profession has any variant data already stored for this character.
      -- If not, we will schedule a sync for this profession regardless of whether the skill level appears to have changed.
      local hasAnyVariantData = false
      local hasPendingVariants = false

      -- Compare previous profession level with current one to detect changes.
      for variantSkillLineId, prevLevel in pairs(WNTR_professionVariantToSkillLevel[realmName][playerName]) do

        -- Skipping the "maxLevels" entry, which is not a real variant and does not have a parentProfessionID.
        if type(variantSkillLineId) == "number" then

          -- Only check variants of the currently examined base profession.
          local variantProfessionInfo = C_TradeSkillUI_GetProfessionInfoBySkillLineID(variantSkillLineId)
          if variantProfessionInfo and variantProfessionInfo.parentProfessionID == baseSkillLineId then

            -- We found at least one variant with stored data, so we only need to sync if the skill level changed.
            hasAnyVariantData = true

            -- Has the skill level changed since the last sync?
            -- GetProfessionInfoBySkillLineID works without an open trade skill session,
            -- but skillLevel may return 0 when the profession backend is not active yet.
            if variantProfessionInfo.skillLevel > 0 and variantProfessionInfo.skillLevel ~= prevLevel then

              -- Mark as character-pending (persisted).
              WNTR_pendingCharacterSync[realmName][playerName][variantSkillLineId] = true

              -- Store the new skill level for future change detection.
              WNTR_professionVariantToSkillLevel[realmName][playerName][variantSkillLineId] = variantProfessionInfo.skillLevel
            end

            -- Check if this variant has a pending sync (fresh or from previous session).
            if WNTR_pendingCharacterSync[realmName][playerName][variantSkillLineId] then
              hasPendingVariants = true
            end

          end
        end
      end

      if not hasAnyVariantData or hasPendingVariants then
        AddPendingBaseProfession(baseSkillLineId)
      end
    end
  end


  if #pendingBaseSkillLineIds > 0 then
    PrintPendingSyncLink()
  end


  -- Clean up data for professions the character no longer has.
  if WNTR_recipeToDifficulty[realmName] and WNTR_recipeToDifficulty[realmName][playerName] then
    for variantSkillLineId in pairs(WNTR_recipeToDifficulty[realmName][playerName]) do
      local baseSkillLineId = GetBaseOfVariant(variantSkillLineId)
      if baseSkillLineId and not currentBaseIds[baseSkillLineId] then
        WNTR_recipeToDifficulty[realmName][playerName][variantSkillLineId] = nil
      end
    end
  end
  if WNTR_professionVariantToSkillLevel[realmName] and WNTR_professionVariantToSkillLevel[realmName][playerName] then
    for variantSkillLineId in pairs(WNTR_professionVariantToSkillLevel[realmName][playerName]) do
      -- Skipping the "maxLevels" entry.
      if type(variantSkillLineId) == "number" then
        local baseSkillLineId = GetBaseOfVariant(variantSkillLineId)
        if baseSkillLineId and not currentBaseIds[baseSkillLineId] then
          WNTR_professionVariantToSkillLevel[realmName][playerName][variantSkillLineId] = nil
        end
      end
    end
  end
  if WNTR_pendingCharacterSync[realmName] and WNTR_pendingCharacterSync[realmName][playerName] then
    for variantSkillLineId in pairs(WNTR_pendingCharacterSync[realmName][playerName]) do
      local baseSkillLineId = GetBaseOfVariant(variantSkillLineId)
      if baseSkillLineId and not currentBaseIds[baseSkillLineId] then
        WNTR_pendingCharacterSync[realmName][playerName][variantSkillLineId] = nil
      end
    end
  end
  for i = #pendingBaseSkillLineIds, 1, -1 do
    if not currentBaseIds[pendingBaseSkillLineIds[i]] then
      table_remove(pendingBaseSkillLineIds, i)
    end
  end

  addon.UpdateMinimapGlow()

end



-- To prevent spamming UpdateProfessions() we wait for 0.5 seconds for potentially
-- multiple SKILL_LINES_CHANGED events to arrive before actually calling UpdateProfessions().
local updateProfessionsTimer = nil


local function EventFrameFunction(self, event, ...)

  -- #########################################################################
  if event == "ADDON_LOADED" then

    local addonName = ...
    if addonName ~= folderName then return end

    -- Saved variables are now populated. Check for a game client build change and if so,
    -- mark all known profession variants for global resync.
    local _, currentBuildNumber = GetBuildInfo()
    if WNTR_reagentToRecipe["buildNumber"] ~= currentBuildNumber then
      for variantId in pairs(WNTR_reagentToRecipe) do
        if variantId ~= "buildNumber" then
          WNTR_pendingGlobalSync[variantId] = true
        end
      end
      WNTR_reagentToRecipe["buildNumber"] = currentBuildNumber
    end
    
    
    -- Update character class, because sometimes you delete a character
    -- and create another one with the same name but different class.
    AddOrUpdateCharacterToClass(GetRealmName(), UnitName("player"), select(2, UnitClass("player")))



  -- #########################################################################
  -- If we did a silent open, we want to prevent the profession UI from showing while it syncs.
  -- (HideUIPanel would close the session and prevent TRADE_SKILL_LIST_UPDATE.)
  elseif event == "TRADE_SKILL_SHOW" and silentOpenProfessionId then

    -- A safeguard in case something goes wrong with the alpha trick and the frame remains invisible.
    if ProfessionsFrame and ProfessionsFrame.hiddenByWhoNeedsThisReagent and ProfessionsFrame:GetAlpha() == 0 then
      ProfessionsFrame:SetAlpha(ProfessionsFrame.hiddenByWhoNeedsThisReagent)
      ProfessionsFrame.hiddenByWhoNeedsThisReagent = nil
    end

    -- If the frame was already open, let the profession switch happen visibly.
    if ProfessionsFrame and not silentOpenFrameWasShown and ProfessionsFrame:GetAlpha() > 0 then
      ProfessionsFrame.hiddenByWhoNeedsThisReagent = ProfessionsFrame:GetAlpha()
      ProfessionsFrame:SetAlpha(0)
    end


  -- #########################################################################
  -- This event fires both for normal opens and for our silent opens of the profession frame.
  elseif event == "TRADE_SKILL_LIST_UPDATE" then

    -- Silent open flow: profession UI was opened programmatically.
    if silentOpenProfessionId then

      -- Check that the desired profession is now active.
      -- Here we are expecting an open profession frame, so we can use the cheaper GetBaseProfessionInfo() check,
      -- instead of our more expensive backend checks.
      local activeProfessionInfo = C_TradeSkillUI_GetBaseProfessionInfo()
      if activeProfessionInfo and activeProfessionInfo.professionID == silentOpenProfessionId then
      
        -- print("WNTR DEBUG: ...silent open succeeded for profession", silentOpenProfessionId)
        
        
        -- When OpenTradeSkill() is run for the first time after client restart,
        -- in spite of GetBaseProfessionInfo() returning our requested professionID,
        -- GetAllRecipeIDs() in SyncVariantProfession() can return an empty recipe list.
        -- If this is the case, we start the ticker below.
        if SyncBaseProfession(silentOpenProfessionId) then
          CompletePendingSync(silentOpenProfessionId)
          FinishSilentOpen()
          
        -- Backend was not ready yet. If the ticker does not exists yet, we start it.
        -- Keep the invisible frame open and retry every 0.2s for up to 2 seconds,
        -- giving the backend time to populate recipe data.
        elseif not silentOpenRetryTicker then
        
          silentOpenRetryCount = 0
          silentOpenRetryTicker = C_Timer_NewTicker(0.2, function()
            silentOpenRetryCount = silentOpenRetryCount + 1
            
            local retrySuccess = SyncBaseProfession(silentOpenProfessionId)

            if retrySuccess or silentOpenRetryCount >= 10 then
              if retrySuccess then
                CompletePendingSync(silentOpenProfessionId)
              else
                print("|cff00ccffWhoNeedsThisReagent:|r Synchronization timed out. Professions backend did not respond within 2 seconds.")
              end
              FinishSilentOpen()
            end
            
          end)
        end
        
        
      else
        -- Profession mismatch. Should never happen.
        print("WNTR DEBUG: ...silent open failed because of profession mismatch. Expected:", silentOpenProfessionId, "Got:", activeProfessionInfo and activeProfessionInfo.professionID or "nil")
        FinishSilentOpen()
      end


    -- Normal (non-silent) flow: profession UI was opened by the user.
    -- When changing the active profession (by opening the profession frame),
    -- we always sync the character-specific data of all variants (pending or not),
    -- because the cost of syncing already up-to-date variants is negligible
    -- compared to opening the profession backend.
    else

      -- Here we are expecting an open profession frame, so we can use the cheaper GetBaseProfessionInfo() check,
      -- instead of our more expensive backend checks.
      local activeProfessionInfo = C_TradeSkillUI_GetBaseProfessionInfo()
      local activeBaseSkillLineId = activeProfessionInfo and activeProfessionInfo.professionID

      if activeBaseSkillLineId and SyncBaseProfession(activeBaseSkillLineId) then
        -- Check if this profession was pending; if so, complete it with messaging.
        local wasPending = false
        for _, pendingBaseSkillLineId in ipairs(pendingBaseSkillLineIds) do
          if pendingBaseSkillLineId == activeBaseSkillLineId then
            wasPending = true
            break
          end
        end
        if wasPending then
          CompletePendingSync(activeBaseSkillLineId)
          if #pendingBaseSkillLineIds > 0 then
            PrintPendingSyncLink()
          else
            print("|cff00ccffWhoNeedsThisReagent:|r All professions are now synced.")
          end
        end
      end

    end



  -- #########################################################################
  -- Triggered when a new crafting variant is learned.
  elseif event == "LEARNED_SPELL_IN_SKILL_LINE" then
    local _, skillLineIndex = ...

    local spellTabIndexProf1, spellTabIndexProf2, _, _, spellTabIndexCooking = GetProfessions()
    for _, spellTabIndex in ipairs({spellTabIndexProf1, spellTabIndexProf2, spellTabIndexCooking}) do
      if spellTabIndex and spellTabIndex == skillLineIndex then
        local _, _, _, _, _, _, baseSkillLineId = GetProfessionInfo(spellTabIndex)
        AddPendingBaseProfession(baseSkillLineId)
      end
    end



  -- #########################################################################
  -- Triggered when a new recipe is learned.
  elseif event == "NEW_RECIPE_LEARNED" then

    local recipeId = ...

    if not recipeId then return end


    -- GetProfessionInfoByRecipeID() is unreliable for some recipes:
    --   - For some recipes (like https://www.wowhead.com/spell=399034/curried-coconut-crab),
    --     GetProfessionInfoByRecipeID() does not return a variant skillLineId,
    --     but instead their base skillLineId. Even though IsRecipeInSkillLine() returns true when
    --     you are testing the recipeId  with the variantSkillLineId.
    --   - Similarly, "Techniques" like https://www.wowhead.com/spell=194171/unbroken-claw also return their base skillLineId.
    --   - And then there are some MoP recipes for which professionID and parentProfessionID seem to be swapped
    --     (e.g. for https://www.wowhead.com/spell=124052/ginseng-tea professionID is 980 and parentProfessionID is 2544).
    -- That's why we use our own recorded mapping.
    -- If variantSkillLineId is nil (recipe not yet in the mapping because no global sync has run yet),
    -- the entry below is a Lua no-op, but the profession is already pending a full sync which will cover this recipe.
    local variantSkillLineId = WNTR_recipeIdToVariantSkillLineId[recipeId]
    print("NEW_RECIPE_LEARNED", recipeId, variantSkillLineId, WNTR_variantToBaseProfession[variantSkillLineId])
  
    -- Sometimes (e.g. when learning a new profession) we learn several recipes at once.
    -- So we wait until there were no NEW_RECIPE_LEARNED for 0.5 seconds before processing.
    pendingNewRecipes[recipeId] = variantSkillLineId

    if newRecipeTimer then
      newRecipeTimer:Cancel()
    end
    newRecipeTimer = C_Timer_NewTimer(0.5, function()
      newRecipeTimer = nil
      ProcessNewRecipes()
    end)


  -- #########################################################################
  -- Triggered when a skill gets leveled up.
  elseif event == "SKILL_LINES_CHANGED" then

    -- Call UpdateProfessions() after there were no new SKILL_LINES_CHANGED events for 0.5 seconds.
    if updateProfessionsTimer then
      updateProfessionsTimer:Cancel()
    end
    updateProfessionsTimer = C_Timer_NewTimer(0.5, function()
      updateProfessionsTimer = nil
      UpdateProfessions()
    end)

  end
end

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", EventFrameFunction)
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
eventFrame:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE")
eventFrame:RegisterEvent("NEW_RECIPE_LEARNED")
eventFrame:RegisterEvent("SKILL_LINES_CHANGED")
