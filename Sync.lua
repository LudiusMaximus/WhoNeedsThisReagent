local _, addon = ...

-- Cache of global WoW API tables/functions.
local C_Timer_NewTicker                             = _G.C_Timer.NewTicker
local C_Timer_NewTimer                              = _G.C_Timer.NewTimer
local C_TradeSkillUI_CloseTradeSkill                = _G.C_TradeSkillUI.CloseTradeSkill
local C_TradeSkillUI_GetAllRecipeIDs                = _G.C_TradeSkillUI.GetAllRecipeIDs
local C_TradeSkillUI_GetBaseProfessionInfo          = _G.C_TradeSkillUI.GetBaseProfessionInfo
local C_TradeSkillUI_GetChildProfessionInfos        = _G.C_TradeSkillUI.GetChildProfessionInfos
local C_TradeSkillUI_GetProfessionInfoByRecipeID    = _G.C_TradeSkillUI.GetProfessionInfoByRecipeID
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

-- Cache addon tables/functions.
local AddOrUpdateCharacterRecipeDifficulty = addon.AddOrUpdateCharacterRecipeDifficulty
local AddOrUpdateCharacterToClass          = addon.AddOrUpdateCharacterToClass
local AddReagentsForRecipe                 = addon.AddReagentsForRecipe
local AssignRanksByName                    = addon.AssignRanksByName
local CharacterHasProfession               = addon.CharacterHasProfession
local GetRecipeRank                        = addon.GetRecipeRank
local pendingFetchProfessions              = addon.pendingFetchProfessions
local StopLastSound                        = addon.StopLastSound


-- State for the silent-open flow: when we need to sync a profession that isn't currently
-- active, InitProfession() opens it invisibly, runs the callback, then closes it again.
local silentOpenProfessionId  = nil
local silentOpenCallback      = nil
local silentOpenFrameWasShown = nil
local silentOpenRetryTicker   = nil

-- True when SyncPendingProfession() was called from the chat /run command (no argument),
-- false when called from the minimap button (notFromChat = true). Controls whether we
-- re-pre-fill the chat box after each successful sync so the user can just press Enter again.
local syncFromChat = false

local eventFrame = CreateFrame("Frame")


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

local function PrintPendingFetchLink()
  if #pendingFetchProfessions == 0 then return end
  local lines = "|cff00ccffWhoNeedsThisReagent:|r The following professions need synchronization:"
  for _, profId in ipairs(pendingFetchProfessions) do
    local info = C_TradeSkillUI_GetProfessionInfoBySkillLineID(profId)
    lines = lines .. "\n  - " .. (info and info.professionName or tostring(profId))
  end
  lines = lines .. "\nOpen the profession frame, click the minimap button, or |cffff9900|Hitem:wntr:fetch|h[click here]|h|r and press Enter."
  print(lines)
end

local function AddPendingProfession(professionId)
  for _, id in ipairs(pendingFetchProfessions) do
    if id == professionId then return end
  end
  tinsert(pendingFetchProfessions, professionId)
  PrintPendingFetchLink()
  addon.UpdateMinimapGlow()
end


local function DoFetchAllRecipes(baseProfessionId, variantId)

  local _, buildNumber = GetBuildInfo()

  -- print("Fetching recipes for base profession ID:", baseProfessionId, "variantId:", variantId)

  -- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetAllRecipeIDs
  local recipeIDs = C_TradeSkillUI_GetAllRecipeIDs()
  if not recipeIDs or #recipeIDs == 0 then
    -- print("Backend was not ready yet. Returning false so the caller can trigger a retry after a short delay.")
    return false
  end

  local realmName = GetRealmName()
  local playerName = UnitName("player")

  if variantId then
    -- Single-variant fetch: only clear and rebuild data for this one variant.
    -- Uses IsRecipeInSkillLine() to skip non-matching recipes without the heavier
    -- GetProfessionInfoByRecipeID() calls.

    -- Global sync needed if explicitly pending or data is missing.
    local needsGlobalSync = WNTR_pendingGlobalSync[variantId]
        or not WNTR_reagentToRecipe[variantId]
        or not next(WNTR_reagentToRecipe[variantId])
    if needsGlobalSync then
      WNTR_reagentToRecipe[variantId] = {}
    end
    WNTR_recipeToDifficulty[realmName] = WNTR_recipeToDifficulty[realmName] or {}
    WNTR_recipeToDifficulty[realmName][playerName] = WNTR_recipeToDifficulty[realmName][playerName] or {}
    WNTR_recipeToDifficulty[realmName][playerName][variantId] = nil

    local variantRecipeNames = needsGlobalSync and {} or nil

    for _, recipeID in pairs(recipeIDs) do
      -- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.IsRecipeInSkillLine
      if C_TradeSkillUI_IsRecipeInSkillLine(recipeID, variantId) then
        local recipeInfo = C_TradeSkillUI_GetRecipeInfo(recipeID)
        if needsGlobalSync then
          if recipeInfo and (recipeInfo.previousRecipeID or recipeInfo.nextRecipeID) then
            WNTR_recipeToRank[recipeID] = GetRecipeRank(recipeInfo)
            -- print("WNTR DEBUG rank:", recipeID, recipeInfo.name, "prev=", tostring(recipeInfo.previousRecipeID), "next=", tostring(recipeInfo.nextRecipeID), "rank=", WNTR_recipeToRank[recipeID])
          end
          if recipeInfo then
            variantRecipeNames[recipeID] = recipeInfo.name
          end
          if AddReagentsForRecipe(variantId, recipeID) == false then
            print("|cffff0000WhoNeedsThisReagent:|r Aborting fetch for variant", variantId, "due to mismatch.")
            return false
          end
        end
        if recipeInfo and recipeInfo.learned then
          if AddOrUpdateCharacterRecipeDifficulty(realmName, playerName, variantId, recipeID, recipeInfo.relativeDifficulty) == false then
            print("|cffff0000WhoNeedsThisReagent:|r Aborting fetch for variant", variantId, "due to mismatch.")
            return false
          end
        end
      end
    end

    -- Fallback: assign ranks by name grouping for recipes without chain data (i.e. Shadowlands).
    if needsGlobalSync then
      AssignRanksByName(variantRecipeNames)
      WNTR_pendingGlobalSync[variantId] = nil
    end

    -- Update skill level for this variant only.
    local variantInfo = C_TradeSkillUI_GetProfessionInfoBySkillLineID(variantId)
    if variantInfo then
      WNTR_professionVariantToSkillLevel[realmName] = WNTR_professionVariantToSkillLevel[realmName] or {}
      WNTR_professionVariantToSkillLevel[realmName][playerName] = WNTR_professionVariantToSkillLevel[realmName][playerName] or {}
      WNTR_professionVariantToSkillLevel[realmName][playerName][variantId] = variantInfo.skillLevel
      WNTR_professionVariantToSkillLevel["maxLevels"] = WNTR_professionVariantToSkillLevel["maxLevels"] or {}
      WNTR_professionVariantToSkillLevel["maxLevels"][variantId] = variantInfo.maxSkillLevel
    end

    -- Clear character-specific pending (after difficulty and skill level are both updated).
    if WNTR_pendingCharacterSync[realmName] and WNTR_pendingCharacterSync[realmName][playerName] then
      WNTR_pendingCharacterSync[realmName][playerName][variantId] = nil
    end

  else
    -- Full fetch: all expansion variants for this profession.

    -- Get all expansion variants for this profession.
    -- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetChildProfessionInfos
    local childInfos = C_TradeSkillUI_GetChildProfessionInfos()

    -- Global sync needed if any variant is explicitly pending or has missing data.
    local needsGlobalSync = false
    for _, childInfo in ipairs(childInfos) do
      if WNTR_pendingGlobalSync[childInfo.professionID]
          or not WNTR_reagentToRecipe[childInfo.professionID]
          or not next(WNTR_reagentToRecipe[childInfo.professionID]) then
        needsGlobalSync = true
        break
      end
    end

    -- Clear data that needs rebuilding.
    if needsGlobalSync then
      for _, childInfo in ipairs(childInfos) do
        WNTR_reagentToRecipe[childInfo.professionID] = {}
      end
    end
    WNTR_recipeToDifficulty[realmName] = WNTR_recipeToDifficulty[realmName] or {}
    WNTR_recipeToDifficulty[realmName][playerName] = WNTR_recipeToDifficulty[realmName][playerName] or {}
    WNTR_recipeToDifficulty[realmName][playerName][baseProfessionId] = nil
    for _, childInfo in ipairs(childInfos) do
      WNTR_recipeToDifficulty[realmName][playerName][childInfo.professionID] = nil
    end

    local variantRecipeNames = needsGlobalSync and {} or nil  -- [variantId] = { [recipeID] = name, ... }

    for _, recipeID in pairs(recipeIDs) do
      local recipeProfInfo = C_TradeSkillUI_GetProfessionInfoByRecipeID(recipeID)
      local variantId = recipeProfInfo and recipeProfInfo.professionID or baseProfessionId

      -- https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetRecipeInfo
      local recipeInfo = C_TradeSkillUI_GetRecipeInfo(recipeID)

      -- print("Recipe:", recipeInfo.name, "Recipe ID:", recipeID, "Learned:", recipeInfo.learned, "Relative Difficulty:", recipeInfo.relativeDifficulty)

      if needsGlobalSync then
        if recipeInfo and (recipeInfo.previousRecipeID or recipeInfo.nextRecipeID) then
          WNTR_recipeToRank[recipeID] = GetRecipeRank(recipeInfo)
          -- print("WNTR DEBUG rank:", recipeID, recipeInfo.name, "prev=", tostring(recipeInfo.previousRecipeID), "next=", tostring(recipeInfo.nextRecipeID), "rank=", WNTR_recipeToRank[recipeID])
        end
        if recipeInfo then
          variantRecipeNames[variantId] = variantRecipeNames[variantId] or {}
          variantRecipeNames[variantId][recipeID] = recipeInfo.name
        end
        if AddReagentsForRecipe(variantId, recipeID) == false then
          print("|cffff0000WhoNeedsThisReagent:|r Aborting fetch for profession", baseProfessionId, "due to mismatch.")
          return false
        end
      end

      if recipeInfo and recipeInfo.learned then
        if AddOrUpdateCharacterRecipeDifficulty(realmName, playerName, variantId, recipeID, recipeInfo.relativeDifficulty) == false then
          print("|cffff0000WhoNeedsThisReagent:|r Aborting fetch for profession", baseProfessionId, "due to mismatch.")
          return false
        end
      end

    end

    -- Fallback: assign ranks by name grouping for recipes without chain data (i.e. Shadowlands).
    if needsGlobalSync then
      for _, names in pairs(variantRecipeNames) do
        AssignRanksByName(names)
      end
      for _, childInfo in ipairs(childInfos) do
        WNTR_pendingGlobalSync[childInfo.professionID] = nil
      end
    end

    -- Store variant skill levels for change detection in SKILL_LINES_CHANGED.
    WNTR_professionVariantToSkillLevel[realmName] = WNTR_professionVariantToSkillLevel[realmName] or {}
    WNTR_professionVariantToSkillLevel[realmName][playerName] = WNTR_professionVariantToSkillLevel[realmName][playerName] or {}
    WNTR_professionVariantToSkillLevel["maxLevels"] = WNTR_professionVariantToSkillLevel["maxLevels"] or {}
    for _, childInfo in ipairs(childInfos) do
      WNTR_professionVariantToSkillLevel[realmName][playerName][childInfo.professionID] = childInfo.skillLevel
      WNTR_professionVariantToSkillLevel["maxLevels"][childInfo.professionID] = childInfo.maxSkillLevel
    end

    -- Clear character-specific pending (after difficulty and skill levels are both updated).
    WNTR_pendingCharacterSync[realmName] = WNTR_pendingCharacterSync[realmName] or {}
    WNTR_pendingCharacterSync[realmName][playerName] = WNTR_pendingCharacterSync[realmName][playerName] or {}
    for _, childInfo in ipairs(childInfos) do
      WNTR_pendingCharacterSync[realmName][playerName][childInfo.professionID] = nil
    end
  end

  WNTR_reagentToRecipe["buildNumber"] = buildNumber
  return true
end


-- If the profession is not active, we need to open it to fetch the recipes. But we don't want to
-- interrupt the user if they are doing something else in the profession UI, so we do it silently
-- and close it immediately after fetching the data.
local function InitProfession(professionId, callback)

  -- Check if the character actually has this profession.
  if not CharacterHasProfession(professionId) then
    -- print("InitProfession: Character does not have profession", professionId, "- skipping.")
    return
  end

  -- Check if desired profession is already the active one.
  local professionInfo = C_TradeSkillUI_GetBaseProfessionInfo()
  if professionInfo and professionInfo.professionID == professionId then
    callback()
    return
  end

  -- The desired profession is not active. Open it silently.
  -- print("InitProfession: Opening profession", professionId, "silently...")
  silentOpenProfessionId = professionId
  silentOpenCallback = callback
  silentOpenFrameWasShown = ProfessionsFrame and ProfessionsFrame:IsShown() or false
  C_TradeSkillUI_OpenTradeSkill(professionId)
  StopLastSound()
  -- The rest happens in OnEvent when TRADE_SKILL_LIST_UPDATE fires.
end


local function FetchAllRecipes(professionId)
  -- Normal case: profession UI was opened by the user; use whichever profession is currently active.
  if not professionId then
    local professionInfo = C_TradeSkillUI_GetBaseProfessionInfo()
    if not professionInfo or professionInfo.professionID == 0 then
      print("FetchAllRecipes: No profession active, nothing to fetch.")
      return
    end
    return DoFetchAllRecipes(professionInfo.professionID)
  end

  -- Silent open case: fetch recipes for the given profession, opening it silently if needed.
  InitProfession(professionId, function() return DoFetchAllRecipes(professionId) end)
end


-- To prevent spamming UpdateProfessions() we wait for 0.5 seconds for potentially
-- multiple SKILL_LINES_CHANGED events to arrive before actually calling UpdateProfessions().
local updateProfessionsTimer = nil
local UpdateProfessions  -- forward declaration; defined after OnEvent

-- Similarly, we debounce NEW_RECIPE_LEARNED so that TRADE_SKILL_LIST_UPDATE has time to
-- fire and do a full sync before we check GetBaseProfessionInfo() and potentially add to pending.
local pendingNewRecipes = {}
local newRecipeTimer = nil
local ProcessNewRecipes  -- forward declaration; defined after OnEvent

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
  silentOpenCallback = nil
  silentOpenFrameWasShown = nil

  if #pendingFetchProfessions > 0 then
    local lines = "|cff00ccffWhoNeedsThisReagent:|r The following professions still need synchronization:"
    for _, profId in ipairs(pendingFetchProfessions) do
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

local function OnEvent(self, event, ...)

  if event == "NEW_RECIPE_LEARNED" then

    local recipeID = ...
    local recipeProfessionInfo = C_TradeSkillUI_GetProfessionInfoByRecipeID(recipeID)
    if recipeProfessionInfo and recipeProfessionInfo.parentProfessionID then
      print("NEW_RECIPE_LEARNED: recipeID", recipeID, "variantId", recipeProfessionInfo.professionID, "baseId", recipeProfessionInfo.parentProfessionID)
      tinsert(pendingNewRecipes, { recipeID = recipeID, variantId = recipeProfessionInfo.professionID, baseId = recipeProfessionInfo.parentProfessionID })
    else
      tinsert(pendingNewRecipes, { recipeID = recipeID })
    end

    if newRecipeTimer then
      newRecipeTimer:Cancel()
    end
    newRecipeTimer = C_Timer_NewTimer(0.5, function()
      newRecipeTimer = nil
      ProcessNewRecipes()
    end)
    
  

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
  
 

  -- This event fires both for normal opens and for our silent open.
  elseif event == "TRADE_SKILL_LIST_UPDATE" then

     -- Silent open flow: profession UI was opened programmatically.
    if silentOpenProfessionId then

      -- Check that the desired profession is now active.
      local professionInfo = C_TradeSkillUI_GetBaseProfessionInfo()
      if professionInfo and professionInfo.professionID == silentOpenProfessionId then
        -- print("InitProfession: ...silent open succeeded for profession", silentOpenProfessionId)
        local success = silentOpenCallback()
        if success then
          FinishSilentOpen()
        elseif not silentOpenRetryTicker then
          -- Backend not ready (first open after client restart returns empty recipe list).
          -- Keep the invisible frame open and retry every 0.2s for up to 2 seconds,
          -- giving the backend time to populate recipe data.
          local retryCount = 0
          silentOpenRetryTicker = C_Timer_NewTicker(0.2, function()
            retryCount = retryCount + 1
            -- Pre-check so DoFetchAllRecipes doesn't spam the "Initializing" message.
            local recipeIDs = C_TradeSkillUI_GetAllRecipeIDs()
            local retrySuccess = (recipeIDs and #recipeIDs > 0) and silentOpenCallback() or false
            if retrySuccess or retryCount >= 10 then
              if not retrySuccess then
                print("|cff00ccffWhoNeedsThisReagent:|r Synchronization timed out \226\128\148 professions backend did not respond within 2 seconds.")
              end
              FinishSilentOpen()
            end
          end)
        end
        -- If retry ticker is already running, let it handle subsequent attempts.
      else
        -- Profession mismatch.
        print("InitProfession: ...silent open failed because of profession mismatch. Expected:", silentOpenProfessionId, "Got:", professionInfo and professionInfo.professionID or "nil")
        FinishSilentOpen()
      end


    -- Normal (non-silent) flow: profession UI was opened by the user.
    else 

      -- Only remove from pending if the fetch succeeds.
      local professionInfo = C_TradeSkillUI_GetBaseProfessionInfo()
      local success = FetchAllRecipes()
      local removed = false
      if success and professionInfo then
        for i, pendingId in ipairs(pendingFetchProfessions) do
          if pendingId == professionInfo.professionID then
            table_remove(pendingFetchProfessions, i)
            removed = true
            break
          end
        end
      end
      -- Only print when something actually changed (a profession was just synced);
      -- suppress spurious TRADE_SKILL_LIST_UPDATE events that fire without any change.
      if removed then
        if #pendingFetchProfessions > 0 then
          PrintPendingFetchLink()
        else
          print("|cff00ccffWhoNeedsThisReagent:|r All professions are now synced.")
        end
      end
      addon.UpdateMinimapGlow()

    end


  elseif event == "SKILL_LINES_CHANGED" then

    if updateProfessionsTimer then
      updateProfessionsTimer:Cancel()
    end
    updateProfessionsTimer = C_Timer_NewTimer(0.5, function()
      updateProfessionsTimer = nil
      UpdateProfessions()
    end)

  end
end

eventFrame:SetScript("OnEvent", OnEvent)
eventFrame:RegisterEvent("NEW_RECIPE_LEARNED")
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
eventFrame:RegisterEvent("SKILL_LINES_CHANGED")



-- -- For debugging:
-- -- Global test function: call /run TestInitProfession(tradeSkillLineId) to test the silent
-- -- open/restore flow. Open a profession UI first, then call this with a different profession's ID.
-- function TestInitProfession(professionId)
--   InitProfession(professionId, function()
--     local professionInfo = C_TradeSkillUI.GetBaseProfessionInfo()
--     print("TestInitProfession: Callback executed. Active profession:", professionInfo and professionInfo.professionID or "nil", professionInfo and professionInfo.professionName or "nil")
--   end)
-- end


-- Global function to sync pending professions. Can be called from a hardware event (button click)
-- or from /run in the chat, since OpenTradeSkill() requires a secure execution context.
function SyncPendingProfession(notFromChat)
  syncFromChat = not notFromChat
  if #pendingFetchProfessions == 0 then
    print("|cff00ccffWhoNeedsThisReagent:|r All professions are already synced.")
    return
  end
  local professionId = pendingFetchProfessions[1]
  local info = C_TradeSkillUI_GetProfessionInfoBySkillLineID(professionId)
  print("|cff00ccffWhoNeedsThisReagent:|r Starting synchronization (" .. (info and info.professionName or tostring(professionId)) .. ")...")
  InitProfession(professionId, function()
    if DoFetchAllRecipes(professionId) then
      for i, id in ipairs(pendingFetchProfessions) do
        if id == professionId then
          table_remove(pendingFetchProfessions, i)
          break
        end
      end
      print("|cff00ccffWhoNeedsThisReagent:|r ..." .. (info and info.professionName or tostring(professionId)) .. " synced successfully!")
      addon.UpdateMinimapGlow()
      return true
    end
  end)
end


ProcessNewRecipes = function()
  local realmName = GetRealmName()
  local playerName = UnitName("player")

  WNTR_pendingCharacterSync[realmName] = WNTR_pendingCharacterSync[realmName] or {}
  WNTR_pendingCharacterSync[realmName][playerName] = WNTR_pendingCharacterSync[realmName][playerName] or {}

  local byBase = {}
  local hasUnknowns = false

  for _, entry in ipairs(pendingNewRecipes) do
    -- Re-attempt to identify the profession (may succeed now after the delay).
    if not entry.baseId then
      local recipeProfessionInfo = C_TradeSkillUI_GetProfessionInfoByRecipeID(entry.recipeID)
      if recipeProfessionInfo and recipeProfessionInfo.parentProfessionID then
        entry.baseId = recipeProfessionInfo.parentProfessionID
        entry.variantId = recipeProfessionInfo.professionID
      end
    end

    if entry.baseId then
      byBase[entry.baseId] = byBase[entry.baseId] or {}
      tinsert(byBase[entry.baseId], entry)
      -- Persist character-pending so it survives reloads.
      if entry.variantId then
        WNTR_pendingCharacterSync[realmName][playerName][entry.variantId] = true
      end
    else
      hasUnknowns = true
    end
  end
  wipe(pendingNewRecipes)

  -- Unknown recipes: queue all character professions as a fallback.
  if hasUnknowns then
    local spellTabIndexProf1, spellTabIndexProf2, _, _, spellTabIndexCooking = GetProfessions()
    for _, spellTabIndex in ipairs({spellTabIndexProf1, spellTabIndexProf2, spellTabIndexCooking}) do
      if spellTabIndex then
        local _, _, _, _, _, _, tradeSkillLineId = GetProfessionInfo(spellTabIndex)
        AddPendingProfession(tradeSkillLineId)
      end
    end
  end

  -- Check GetBaseProfessionInfo now (after the delay, giving TRADE_SKILL_LIST_UPDATE time to fire).
  local backendProfessionInfo = C_TradeSkillUI_GetBaseProfessionInfo()

  for baseId, recipes in pairs(byBase) do
    -- Check if all recipes are already stored (e.g. by TRADE_SKILL_LIST_UPDATE firing during the delay).
    local allStored = true
    for _, entry in ipairs(recipes) do
      if not (WNTR_recipeToDifficulty[realmName] and WNTR_recipeToDifficulty[realmName][playerName]
              and WNTR_recipeToDifficulty[realmName][playerName][entry.variantId]
              and WNTR_recipeToDifficulty[realmName][playerName][entry.variantId][entry.recipeID] ~= nil) then
        allStored = false
        break
      end
    end

    if not allStored then
      if backendProfessionInfo and backendProfessionInfo.professionID == baseId then
        for _, entry in ipairs(recipes) do
          local recipeInfo = C_TradeSkillUI_GetRecipeInfo(entry.recipeID)
          if recipeInfo and recipeInfo.learned then
            AddOrUpdateCharacterRecipeDifficulty(realmName, playerName, entry.variantId, entry.recipeID, recipeInfo.relativeDifficulty)
          end
        end
        -- Clear character-pending for synced variants.
        for _, entry in ipairs(recipes) do
          if entry.variantId then
            WNTR_pendingCharacterSync[realmName][playerName][entry.variantId] = nil
          end
        end
      else
        AddPendingProfession(baseId)
      end
    else
      -- All stored already (e.g. TRADE_SKILL_LIST_UPDATE fired during the delay); clear pending.
      for _, entry in ipairs(recipes) do
        if entry.variantId then
          WNTR_pendingCharacterSync[realmName][playerName][entry.variantId] = nil
        end
      end
    end
  end
end


-- Detect profession changes: cache icons, track variant skill levels, queue pending syncs,
-- and remove stored data for professions the character no longer has.
UpdateProfessions = function()

  local realmName = GetRealmName()
  local playerName = UnitName("player")

  wipe(pendingFetchProfessions)

  -- Using this function to also store the player class.
  AddOrUpdateCharacterToClass(realmName, playerName, select(2, UnitClass("player")))

  -- https://warcraft.wiki.gg/wiki/API_GetProfessions
  local spellTabIndexProf1, spellTabIndexProf2, _, _, spellTabIndexCooking = GetProfessions()

  -- Track which base professions the character currently has (for cleanup of removed professions).
  local currentBaseIds = {}

  WNTR_professionVariantToSkillLevel[realmName] = WNTR_professionVariantToSkillLevel[realmName] or {}
  WNTR_professionVariantToSkillLevel[realmName][playerName] = WNTR_professionVariantToSkillLevel[realmName][playerName] or {}
  WNTR_pendingCharacterSync[realmName] = WNTR_pendingCharacterSync[realmName] or {}
  WNTR_pendingCharacterSync[realmName][playerName] = WNTR_pendingCharacterSync[realmName][playerName] or {}

  -- Pre-compute which base professions have any pending sync (global or character).
  local baseProfessionsNeedingSync = {}
  for variantId in pairs(WNTR_pendingGlobalSync) do
    local variantInfo = C_TradeSkillUI_GetProfessionInfoBySkillLineID(variantId)
    if variantInfo then
      baseProfessionsNeedingSync[variantInfo.parentProfessionID] = true
    end
  end
  for variantId in pairs(WNTR_pendingCharacterSync[realmName][playerName]) do
    local variantInfo = C_TradeSkillUI_GetProfessionInfoBySkillLineID(variantId)
    if variantInfo then
      baseProfessionsNeedingSync[variantInfo.parentProfessionID] = true
    end
  end

  local activeProfInfo = C_TradeSkillUI_GetBaseProfessionInfo()

  for _, spellTabIndex in ipairs({spellTabIndexProf1, spellTabIndexProf2, spellTabIndexCooking}) do
    if spellTabIndex then
      local _, icon, _, _, _, _, baseSkillLineId = GetProfessionInfo(spellTabIndex)
      WNTR_professionSkillLineToIcon[baseSkillLineId] = icon
      currentBaseIds[baseSkillLineId] = true

      -- Check stored variant levels for this base profession.
      -- GetProfessionInfoBySkillLineID works without an open trade skill session,
      -- but skillLevel may return 0 when the profession backend isn't active yet
      -- (e.g. at login before any profession frame is opened). We guard against
      -- that to avoid false-positive "skill changed" triggers on every login.
      local hasAnyVariantData = false
      for variantId, prevLevel in pairs(WNTR_professionVariantToSkillLevel[realmName][playerName]) do
        local variantInfo = C_TradeSkillUI_GetProfessionInfoBySkillLineID(variantId)
        if variantInfo and variantInfo.parentProfessionID == baseSkillLineId then
          hasAnyVariantData = true
          if variantInfo.skillLevel > 0 and variantInfo.skillLevel ~= prevLevel then
            -- Mark as character-pending (persisted) and update stored level.
            WNTR_pendingCharacterSync[realmName][playerName][variantId] = true
            baseProfessionsNeedingSync[baseSkillLineId] = true
            WNTR_professionVariantToSkillLevel[realmName][playerName][variantId] = variantInfo.skillLevel
          end
        end
      end

      if not hasAnyVariantData or baseProfessionsNeedingSync[baseSkillLineId] then
        if activeProfInfo and activeProfInfo.professionID == baseSkillLineId then
          DoFetchAllRecipes(baseSkillLineId)
        else
          tinsert(pendingFetchProfessions, baseSkillLineId)
        end
      end
    end
  end

  if #pendingFetchProfessions > 0 then
    PrintPendingFetchLink()
  end

  -- Clean up data for professions the character no longer has.
  if WNTR_recipeToDifficulty[realmName] and WNTR_recipeToDifficulty[realmName][playerName] then
    for variantId in pairs(WNTR_recipeToDifficulty[realmName][playerName]) do
      local info = C_TradeSkillUI_GetProfessionInfoBySkillLineID(variantId)
      local baseId = info and info.parentProfessionID or variantId
      if not currentBaseIds[baseId] then
        WNTR_recipeToDifficulty[realmName][playerName][variantId] = nil
      end
    end
  end
  if WNTR_professionVariantToSkillLevel[realmName] and WNTR_professionVariantToSkillLevel[realmName][playerName] then
    for variantId in pairs(WNTR_professionVariantToSkillLevel[realmName][playerName]) do
      local info = C_TradeSkillUI_GetProfessionInfoBySkillLineID(variantId)
      local baseId = info and info.parentProfessionID or variantId
      if not currentBaseIds[baseId] then
        WNTR_professionVariantToSkillLevel[realmName][playerName][variantId] = nil
      end
    end
  end
  if WNTR_pendingCharacterSync[realmName] and WNTR_pendingCharacterSync[realmName][playerName] then
    for variantId in pairs(WNTR_pendingCharacterSync[realmName][playerName]) do
      local info = C_TradeSkillUI_GetProfessionInfoBySkillLineID(variantId)
      local baseId = info and info.parentProfessionID or variantId
      if not currentBaseIds[baseId] then
        WNTR_pendingCharacterSync[realmName][playerName][variantId] = nil
      end
    end
  end

  addon.UpdateMinimapGlow()

end
