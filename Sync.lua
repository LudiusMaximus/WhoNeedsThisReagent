local folderName, addon = ...

local CONFIG_DEFAULTS = {
  showPendingSyncMessages = true,
  showStatusMessages      = true,
  showUncollectedTransmog = true,
}

-- Cache of global WoW API tables/functions.
local C_Timer_NewTicker                             = _G.C_Timer.NewTicker
local C_Timer_NewTimer                              = _G.C_Timer.NewTimer
local C_TradeSkillUI_CloseTradeSkill                = _G.C_TradeSkillUI.CloseTradeSkill
local C_TradeSkillUI_GetAllRecipeIDs                = _G.C_TradeSkillUI.GetAllRecipeIDs
local C_TradeSkillUI_GetBaseProfessionInfo          = _G.C_TradeSkillUI.GetBaseProfessionInfo
local C_TradeSkillUI_GetChildProfessionInfos        = _G.C_TradeSkillUI.GetChildProfessionInfos
local C_TradeSkillUI_GetProfessionChildSkillLineID  = _G.C_TradeSkillUI.GetProfessionChildSkillLineID
local C_TradeSkillUI_GetProfessionInfoByRecipeID    = _G.C_TradeSkillUI.GetProfessionInfoByRecipeID
local C_TradeSkillUI_GetProfessionInfoBySkillLineID = _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID
local C_TradeSkillUI_GetRecipeInfo                  = _G.C_TradeSkillUI.GetRecipeInfo
local C_TradeSkillUI_IsRecipeInSkillLine            = _G.C_TradeSkillUI.IsRecipeInSkillLine
local C_TradeSkillUI_OpenTradeSkill                 = _G.C_TradeSkillUI.OpenTradeSkill
local GetProfessionInfo                             = _G.GetProfessionInfo
local GetProfessions                                = _G.GetProfessions
local GetRealmName                                  = _G.GetRealmName
local UnitName                                      = _G.UnitName

local string_find                                   = _G.string.find
local string_match                                  = _G.string.match
local table_remove                                  = _G.table.remove
local tinsert                                       = _G.tinsert

-- Cache addon functions/tables.
local AddOrUpdateCharacterToClass                 = addon.AddOrUpdateCharacterToClass
local AddReagentsForRecipe                        = addon.AddReagentsForRecipe
local AssignRanksByName                           = addon.AssignRanksByName
local CharacterHasBaseProfession                  = addon.CharacterHasBaseProfession
local CorrectShadowlandsRankedRecipeDifficulty    = addon.CorrectShadowlandsRankedRecipeDifficulty
local GetRecipeRank                               = addon.GetRecipeRank
local UpdateRecipeExperience                      = addon.UpdateRecipeExperience
local UpdateUncollectedTransmog                   = addon.UpdateUncollectedTransmog
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


-- Shared debounce for CONSOLE_MESSAGE and NEW_RECIPE_LEARNED.
-- A single craft can trigger both a skill-up (CONSOLE_MESSAGE) and a new recipe
-- (NEW_RECIPE_LEARNED) almost simultaneously; learning a new profession can fire
-- many recipe events at once. The 0.5s timer batches all of these into one
-- ProcessPendingChanges() call, resulting in a single SyncOrAddPending per base profession.
local pendingNewRecipes = {}
local pendingChangesTimer = nil



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
    if not WNTR_config.showPendingSyncMessages then return end
    local lines = "|cff00ccffWhoNeedsThisReagent:|r The following professions need synchronization:"
    for _, baseProfessionId in ipairs(pendingBaseSkillLineIds) do
      lines = lines .. "\n  - " .. C_TradeSkillUI_GetProfessionInfoBySkillLineID(baseProfessionId).professionName
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


-- Backend readiness must be verified by the caller (SyncBaseProfession) before calling this.
local function SyncVariantProfession(variantSkillLineId, recipeIds)
  
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
  -- sync the profession variants they have learned.

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

          -- Store the authoritative variant-to-recipes mapping (colon-delimited string).
          -- IsRecipeInSkillLine() is reliable here because the backend is active.
          -- We append rather than wipe, preserving entries from other characters' professions.
          local existing = WNTR_variantToRecipes[variantSkillLineId]
          local recipeStr = tostring(recipeId)
          if not existing then
            WNTR_variantToRecipes[variantSkillLineId] = recipeStr
          elseif not string_find(":" .. existing .. ":", ":" .. recipeStr .. ":", 1, true) then
            WNTR_variantToRecipes[variantSkillLineId] = existing .. ":" .. recipeStr
          end

          -- Is this a Legion/Shadowlands ranked recipe?
          if recipeInfo.previousRecipeID or recipeInfo.nextRecipeID then
            WNTR_recipeToRank[recipeId] = GetRecipeRank(recipeInfo)
            -- print("WNTR DEBUG:", recipeId, recipeInfo.name, "prev=", tostring(recipeInfo.previousRecipeID), "next=", tostring(recipeInfo.nextRecipeID), "rank=", WNTR_recipeToRank[recipeId])
          end

        end
        
        if recipeInfo.learned then
          WNTR_recipeToDifficulty[realmName][playerName][variantSkillLineId] = WNTR_recipeToDifficulty[realmName][playerName][variantSkillLineId] or {}
          WNTR_recipeToDifficulty[realmName][playerName][variantSkillLineId][recipeId] = recipeInfo.relativeDifficulty
        end

        UpdateUncollectedTransmog(recipeId)

        -- If this recipe was a pending new recipe, ProcessPendingChanges() no longer needs to take care of it.
        if pendingNewRecipes[recipeId] then
          pendingNewRecipes[recipeId] = nil
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
    WNTR_variantToSkillLevel[realmName] = WNTR_variantToSkillLevel[realmName] or {}
    WNTR_variantToSkillLevel[realmName][playerName] = WNTR_variantToSkillLevel[realmName][playerName] or {}
    WNTR_variantToSkillLevel[realmName][playerName][variantSkillLineId] = variantInfo.skillLevel
    WNTR_variantToSkillLevel[realmName][playerName]["maxLevels"] = WNTR_variantToSkillLevel[realmName][playerName]["maxLevels"] or {}
    WNTR_variantToSkillLevel[realmName][playerName]["maxLevels"][variantSkillLineId] = variantInfo.maxSkillLevel
  end

  -- Mark this variant as no longer pending for character specific sync.
  if WNTR_pendingCharacterSync[realmName] and WNTR_pendingCharacterSync[realmName][playerName] then
    WNTR_pendingCharacterSync[realmName][playerName][variantSkillLineId] = nil
  end
  
end


-- Sync all variants of a base profession.
local function SyncBaseProfession(baseSkillLineId)
  -- Backend readiness check: two conditions must both be met.
  -- 1) GetBaseProfessionInfo().professionID must match the desired profession.
  --    Returns 0 when the frame is closed, or a different ID if another profession is active.
  -- 2) GetProfessionChildSkillLineID() must be non-zero, confirming the backend has fully
  --    loaded a profession variant (not just the base shell).
  -- Together these prevent syncing against stale or partially loaded data.
  local activeProfessionInfo = C_TradeSkillUI_GetBaseProfessionInfo()
  if not activeProfessionInfo or activeProfessionInfo.professionID ~= baseSkillLineId then
    return false
  end
  if C_TradeSkillUI_GetProfessionChildSkillLineID() == 0 then
    return false
  end

  -- Fetch recipes of current backend profession.
  -- nil means the API itself failed; an empty table is valid (e.g. Herbalism has no recipes).
  local recipeIds = C_TradeSkillUI_GetAllRecipeIDs()
  if not recipeIds then return false end

  -- Sync all expansion variants for this profession.
  -- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetChildProfessionInfos
  local childInfos = C_TradeSkillUI_GetChildProfessionInfos()
  for _, childInfo in ipairs(childInfos) do
    SyncVariantProfession(childInfo.professionID, recipeIds)
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
  if WNTR_config.showStatusMessages then
    print("|cff00ccffWhoNeedsThisReagent:|r ...", C_TradeSkillUI_GetProfessionInfoBySkillLineID(baseSkillLineId).professionName, "synced successfully!")
  end
  addon.UpdateMinimapGlow()
end


-- Try to sync a base profession immediately (if its backend is currently active).
-- If the backend is not ready (frame closed or different profession loaded),
-- queue it as pending so the user can trigger sync later.
local function SyncOrAddPending(baseSkillLineId)
  if SyncBaseProfession(baseSkillLineId) then
    CompletePendingSync(baseSkillLineId)
  else
    AddPendingBaseProfession(baseSkillLineId)
  end
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
    if WNTR_config.showPendingSyncMessages then
      local lines = "|cff00ccffWhoNeedsThisReagent:|r The following professions still need synchronization:"
      for _, baseSkillLineId in ipairs(pendingBaseSkillLineIds) do
        lines = lines .. "\n  - " .. C_TradeSkillUI_GetProfessionInfoBySkillLineID(baseSkillLineId).professionName
      end
      if syncFromChat then
        lines = lines .. "\nPress Enter again to proceed with the next."
      else
        lines = lines .. "\nOpen the profession frame, click the minimap button, or |cffff9900|Hitem:wntr:fetch|h[click here]|h|r and press Enter."
      end
      print(lines)
    end
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
    if WNTR_config.showStatusMessages then
      print("|cff00ccffWhoNeedsThisReagent:|r All professions are already synced.")
    end
    return
  end
  local baseSkillLineId = pendingBaseSkillLineIds[1]
  
  -- Check if the character actually has this profession.
  if not CharacterHasBaseProfession(baseSkillLineId) then return end
  
  
  if WNTR_config.showStatusMessages then
    print("|cff00ccffWhoNeedsThisReagent:|r Starting synchronization of", C_TradeSkillUI_GetProfessionInfoBySkillLineID(baseSkillLineId).professionName, "...")
  end
  
  
  -- Always open the profession via OpenTradeSkill() to get a live backend.
  -- GetAllRecipeIDs() only reflects the last-opened frame state and is not reliable here.
  -- print("WNTR DEBUG: Opening profession", baseSkillLineId, "silently...")
  silentOpenProfessionId = baseSkillLineId
  silentOpenFrameWasShown = ProfessionsFrame and ProfessionsFrame:IsShown() or false
  C_TradeSkillUI_OpenTradeSkill(baseSkillLineId)
  StopLastSound()
  
  -- The rest happens in OnEvent when TRADE_SKILL_LIST_UPDATE fires.
end



-- Debounced handler for both CONSOLE_MESSAGE (skill-ups) and NEW_RECIPE_LEARNED.
-- Both events mark their variant in WNTR_pendingCharacterSync before the timer fires;
-- this function collects unique base IDs and does one SyncOrAddPending per base.
local function ProcessPendingChanges()

  local realmName  = GetRealmName()
  local playerName = UnitName("player")

  -- Transfer pending new recipes into the persistent pending table.
  WNTR_pendingCharacterSync[realmName] = WNTR_pendingCharacterSync[realmName] or {}
  WNTR_pendingCharacterSync[realmName][playerName] = WNTR_pendingCharacterSync[realmName][playerName] or {}
  for recipeId, variantSkillLineId in pairs(pendingNewRecipes) do
    WNTR_pendingCharacterSync[realmName][playerName][variantSkillLineId] = true
  end
  wipe(pendingNewRecipes)

  -- Sync immediately if the profession backend is active, otherwise queue as pending.
  -- Collect unique base IDs first to avoid syncing the same base profession multiple times.
  local baseIdsToSync = {}
  for variantSkillLineId in pairs(WNTR_pendingCharacterSync[realmName][playerName]) do
    local baseSkillLineId = GetBaseOfVariant(variantSkillLineId)
    if baseSkillLineId then
      baseIdsToSync[baseSkillLineId] = true
    end
  end
  for baseSkillLineId in pairs(baseIdsToSync) do
    SyncOrAddPending(baseSkillLineId)
  end

end

local function ScheduleProcessPendingChanges()
  if pendingChangesTimer then
    pendingChangesTimer:Cancel()
  end
  pendingChangesTimer = C_Timer_NewTimer(0.5, function()
    pendingChangesTimer = nil
    ProcessPendingChanges()
  end)
end



-- Check which professions need syncing, queue them as pending,
-- and remove stored data for professions the character no longer has.
-- Skill level change detection is NOT done here — that is handled by the
-- CONSOLE_MESSAGE event ("Skill <id> increased from X to Y"), which marks
-- the affected variant as pending and schedules ProcessPendingChanges().
local function UpdateProfessions()

  local realmName  = GetRealmName()
  local playerName = UnitName("player")

  -- Initialize character specific saved variables if not present.
  WNTR_variantToSkillLevel[realmName] = WNTR_variantToSkillLevel[realmName] or {}
  WNTR_variantToSkillLevel[realmName][playerName] = WNTR_variantToSkillLevel[realmName][playerName] or {}

  WNTR_pendingCharacterSync[realmName] = WNTR_pendingCharacterSync[realmName] or {}
  WNTR_pendingCharacterSync[realmName][playerName] = WNTR_pendingCharacterSync[realmName][playerName] or {}


  -- Track which base professions the character currently has (for possible cleanup of removed professions below).
  local currentBaseIds = {}

  -- Do NOT wipe pendingBaseSkillLineIds here. Other events (CONSOLE_MESSAGE, ProcessPendingChanges)
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
      -- If not, we schedule a sync. Also check for variants with a pending sync (from
      -- CONSOLE_MESSAGE or a previous session's WNTR_pendingCharacterSync).
      local hasAnyVariantData = false
      local hasPendingVariants = false

      for variantSkillLineId in pairs(WNTR_variantToSkillLevel[realmName][playerName]) do
        -- Skipping the "maxLevels" entry, which is not a real variant and does not have a parentProfessionID.
        if type(variantSkillLineId) == "number" then
          local variantProfessionInfo = C_TradeSkillUI_GetProfessionInfoBySkillLineID(variantSkillLineId)
          if variantProfessionInfo and variantProfessionInfo.parentProfessionID == baseSkillLineId then
            hasAnyVariantData = true
            if WNTR_pendingCharacterSync[realmName][playerName][variantSkillLineId] then
              hasPendingVariants = true
            end
          end
        end
      end

      if not hasAnyVariantData or hasPendingVariants then
        SyncOrAddPending(baseSkillLineId)
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
  if WNTR_variantToSkillLevel[realmName] and WNTR_variantToSkillLevel[realmName][playerName] then
    for variantSkillLineId in pairs(WNTR_variantToSkillLevel[realmName][playerName]) do
      -- Skipping the "maxLevels" entry.
      if type(variantSkillLineId) == "number" then
        local baseSkillLineId = GetBaseOfVariant(variantSkillLineId)
        if baseSkillLineId and not currentBaseIds[baseSkillLineId] then
          WNTR_variantToSkillLevel[realmName][playerName][variantSkillLineId] = nil
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
    
    
    -- Apply config defaults: remove obsolete keys, fill in missing ones.
    for k in pairs(WNTR_config) do
      if CONFIG_DEFAULTS[k] == nil then WNTR_config[k] = nil end
    end
    for k, v in pairs(CONFIG_DEFAULTS) do
      if WNTR_config[k] == nil then WNTR_config[k] = v end
    end

    -- Update character class, because sometimes you delete a character
    -- and create another one with the same name but different class.
    AddOrUpdateCharacterToClass(GetRealmName(), UnitName("player"), select(2, UnitClass("player")))



  -- #########################################################################
  -- This event fires when the tradeskill frame is opened. Either directly by the player
  -- or by our "silent" opening.
  elseif event == "TRADE_SKILL_SHOW" and silentOpenProfessionId then

    -- A safeguard in case something went wrong and the frame is invisible when it should be visible.
    if ProfessionsFrame and ProfessionsFrame.hiddenByWhoNeedsThisReagent and ProfessionsFrame:GetAlpha() == 0 then
      ProfessionsFrame:SetAlpha(ProfessionsFrame.hiddenByWhoNeedsThisReagent)
      ProfessionsFrame.hiddenByWhoNeedsThisReagent = nil
    end

    -- The silentOpenFrameWasShown checks if the frame was already open, when our "silent" opening tried to open it.
    -- In this case, we let the profession switch happen visibly instead of hiding/closing the frame.
    if ProfessionsFrame and not silentOpenFrameWasShown and ProfessionsFrame:GetAlpha() > 0 then
      -- TODO: Very unlikely but potential problem if the users makes a silent sync while the ProfessionsFrame is faded in/out
      --       by another addon, because then our safeguard above may restore a wrong alpha value.
      ProfessionsFrame.hiddenByWhoNeedsThisReagent = ProfessionsFrame:GetAlpha()
      ProfessionsFrame:SetAlpha(0)
    end


  -- #########################################################################
  -- This event fires both for normal opens and for our silent opens of the profession frame.
  elseif event == "TRADE_SKILL_LIST_UPDATE" then

    -- Silent open flow: profession UI was opened by us.
    if silentOpenProfessionId then

      -- Check that the desired profession is now active.
      local activeProfessionInfo = C_TradeSkillUI_GetBaseProfessionInfo()
      if activeProfessionInfo and activeProfessionInfo.professionID == silentOpenProfessionId then
        -- print("WNTR DEBUG: ...silent open succeeded for profession", silentOpenProfessionId)
        
        -- When OpenTradeSkill() is run for the first time after client restart,
        -- GetBaseProfessionInfo() may already return our requested professionID while
        -- GetProfessionChildSkillLineID() still returns 0 (backend not fully loaded).
        -- SyncBaseProfession checks both conditions; if not ready, we retry below.
        if SyncBaseProfession(silentOpenProfessionId) then
          CompletePendingSync(silentOpenProfessionId)
          FinishSilentOpen()

        -- Backend was not fully ready yet. If the ticker does not exist yet, we start it.
        -- Keep the invisible frame open and retry every 0.2s for up to 2 seconds,
        -- giving the backend time to finish loading the profession variant data.
        elseif not silentOpenRetryTicker then
        
          silentOpenRetryCount = 0
          silentOpenRetryTicker = C_Timer_NewTicker(0.2, function()
            silentOpenRetryCount = silentOpenRetryCount + 1
            
            local retrySuccess = SyncBaseProfession(silentOpenProfessionId)

            if retrySuccess or silentOpenRetryCount >= 10 then
              if retrySuccess then
                CompletePendingSync(silentOpenProfessionId)
              else
                if WNTR_config.showStatusMessages then
                  print("|cff00ccffWhoNeedsThisReagent:|r Synchronization timed out. Professions backend did not respond within 2 seconds.")
                end
              end
              FinishSilentOpen()
            end
            
          end)
        end
        
        
      else
        -- Profession mismatch. Should never happen.
        -- print("WNTR DEBUG: ...silent open failed because of profession mismatch. Expected:", silentOpenProfessionId, "Got:", activeProfessionInfo and activeProfessionInfo.professionID or "nil")
        FinishSilentOpen()
      end


    -- Normal (non-silent) flow: profession UI was opened by the user.
    -- When changing the active profession (by opening the profession frame),
    -- we always sync the character-specific data of all variants (pending or not),
    -- because the cost of syncing already up-to-date variants is negligible
    -- compared to opening the profession backend.
    else

      -- Check that the desired profession is now active.
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
          elseif WNTR_config.showStatusMessages then
            print("|cff00ccffWhoNeedsThisReagent:|r All professions are now synced.")
          end
        end
      end

    end



  -- #########################################################################
  -- The game emits locale-independent console messages like "Skill 2568 increased from 0 to 1"
  -- whenever a profession variant's skill level changes. This covers two cases:
  --   1) A skill level-up (e.g. "from 50 to 51") — marks the variant for character sync.
  --   2) A newly learned variant (e.g. "from 0 to 1") — also caught here, even when
  --      LEARNED_SPELL_IN_SKILL_LINE does not fire (e.g. Pandaria Mining).
  elseif event == "CONSOLE_MESSAGE" then
    local messageText = ...
    local variantSkillLineId = string_match(messageText, "^Skill (%d+) increased from")
    if variantSkillLineId then
      variantSkillLineId = tonumber(variantSkillLineId)
      local realmName  = GetRealmName()
      local playerName = UnitName("player")

      -- Mark variant as pending character sync (persisted across sessions).
      WNTR_pendingCharacterSync[realmName] = WNTR_pendingCharacterSync[realmName] or {}
      WNTR_pendingCharacterSync[realmName][playerName] = WNTR_pendingCharacterSync[realmName][playerName] or {}
      WNTR_pendingCharacterSync[realmName][playerName][variantSkillLineId] = true

      -- Debounce: a craft can trigger both a skill-up and a NEW_RECIPE_LEARNED
      -- almost simultaneously; the shared timer batches them into one sync.
      ScheduleProcessPendingChanges()
    end


  -- #########################################################################
  -- Called once on login to pick up any pending syncs from a previous session
  -- and to clean up data for professions the character no longer has.
  elseif event == "PLAYER_LOGIN" then
    UpdateProfessions()


  -- #########################################################################
  -- Triggered when a new recipe is learned.
  elseif event == "NEW_RECIPE_LEARNED" then

    local recipeId = ...

    if not recipeId then return end


    -- Determine which variant this recipe belongs to.
    -- GetProfessionInfoByRecipeID() is unreliable for some recipes:
    --   - For some recipes (like https://www.wowhead.com/spell=399034/curried-coconut-crab),
    --     GetProfessionInfoByRecipeID() does not return a variant skillLineId,
    --     but instead their base skillLineId. Even though IsRecipeInSkillLine() returns true when
    --     you are testing the recipeId with the variantSkillLineId.
    --   - Similarly, "Techniques" like https://www.wowhead.com/spell=194171/unbroken-claw also return their base skillLineId.
    --   - And then there are some MoP recipes for which professionID and parentProfessionID seem to be swapped
    --     (e.g. for https://www.wowhead.com/spell=124052/ginseng-tea professionID is 980 and parentProfessionID is 2544).
    -- Strategy: try the API first, fall back to scanning WNTR_variantToRecipes only when needed.
    local variantSkillLineId = nil
    local profInfo = C_TradeSkillUI_GetProfessionInfoByRecipeID(recipeId)
    if profInfo then
      if WNTR_variantToBaseProfession[profInfo.professionID] then
        -- professionID is a known variant.
        variantSkillLineId = profInfo.professionID
      elseif profInfo.parentProfessionID and WNTR_variantToBaseProfession[profInfo.parentProfessionID] then
        -- parentProfessionID is a known variant (swapped IDs case).
        variantSkillLineId = profInfo.parentProfessionID
      else
        -- API returned a base ID or something unexpected. Scan WNTR_variantToRecipes
        -- for variants of this base profession only.
        local baseId = profInfo.professionID
        local recipeStr = tostring(recipeId)
        for candidateVariant, recipesStr in pairs(WNTR_variantToRecipes) do
          if WNTR_variantToBaseProfession[candidateVariant] == baseId
              and string_find(":" .. recipesStr .. ":", ":" .. recipeStr .. ":", 1, true) then
            variantSkillLineId = candidateVariant
            break
          end
        end
      end
    end
    -- print("NEW_RECIPE_LEARNED", recipeId, variantSkillLineId)
  
    -- If variantSkillLineId is nil (recipe not yet in the mapping because no global sync has run yet),
    -- the entry below is a Lua no-op, but the profession is already pending a full sync which will cover this recipe.
    pendingNewRecipes[recipeId] = variantSkillLineId

    -- Debounce: learning a new profession fires many recipe events at once;
    -- the shared timer batches them (and any concurrent skill-ups) into one sync.
    ScheduleProcessPendingChanges()

  end
end

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", EventFrameFunction)
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
eventFrame:RegisterEvent("CONSOLE_MESSAGE")
eventFrame:RegisterEvent("NEW_RECIPE_LEARNED")
