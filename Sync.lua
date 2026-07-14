local folderName, addon = ...

local CONFIG_DEFAULTS = {
  showPendingSyncMessages          = true,
  showStatusMessages               = true,
  showUncollectedTransmog          = true,
  nextUnlearnedRankOnly            = true,
  uncollectedTransmogInProfessions = true,
}


-- Base profession skill-line IDs for the three gathering professions. By
-- default the addon ignores their skill-ups and recipe-learns (like fishing
-- and archaeology) because their recipes don't consume reagents. The single
-- exception is the smelting recipes available on Classic/TBC/Wrath/Cata/MoP
-- Mining - handled by the per-variant thresholds in gatheringSkillThresholds
-- below.
--
-- IDs see: https://warcraft.wiki.gg/wiki/TradeSkillLineID
local gatheringBaseProfessionIds = {
  [393] = true,  -- Skinning
  [186] = true,  -- Mining
  [182] = true,  -- Herbalism
}

-- Per-variant skill-level thresholds for the few gathering variants that DO
-- have recipes worth syncing (Mining's smelting recipes, pre-Warlords). A
-- CONSOLE_MESSAGE skill-up for one of these variants only marks it pending
-- when the new skill level crosses one of the listed thresholds (i.e. some
-- recipe's relativeDifficulty just flipped: orange -> yellow / yellow -> green
-- / green -> grey). All other gathering variants - and crossings outside
-- these lists - are ignored entirely.
--
-- IDs see: https://warcraft.wiki.gg/wiki/TradeSkillLineID
local gatheringSkillThresholds = {
  [2572] = {1, 20, 40, 50, 57, 60, 65, 75, 100, 105, 110, 115, 125, 130, 135, 150, 155, 160, 165, 175, 200, 205, 210, 245, 250, 255, 260, 270, 290, 300, 305, 310},  -- Classic Mining
  [2571] = {1, 5, 10, 13, 25, 32, 40, 50, 57, 65, 75},  -- TBC Mining
  [2570] = {1, 13, 25, 50, 62, 75},  -- Wrath Mining
  [2569] = {1, 13, 25, 50, 62, 75},  -- Cata Mining
  [2568] = {1, 25, 50, 75},  -- MoP Mining
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
local debugprofilestop                              = _G.debugprofilestop
local GetProfessionInfo                             = _G.GetProfessionInfo
local GetProfessions                                = _G.GetProfessions
local GetRealmName                                  = _G.GetRealmName
local UnitName                                      = _G.UnitName

local string_match                                  = _G.string.match
local table_remove                                  = _G.table.remove
local tinsert                                       = _G.tinsert

-- Cache addon functions/tables.
local AddOrUpdateCharacterToClass                 = addon.AddOrUpdateCharacterToClass
local AddReagentsForRecipe                        = addon.AddReagentsForRecipe
local AssignRanksByName                           = addon.AssignRanksByName
local CharacterHasBaseProfession                  = addon.CharacterHasBaseProfession
local ColonListContains                           = addon.ColonListContains
local CorrectShadowlandsRankedRecipeDifficulty    = addon.CorrectShadowlandsRankedRecipeDifficulty
local GetRecipeRank                               = addon.GetRecipeRank
local IterColonListIds                            = addon.IterColonListIds
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
-- ProcessPendingChanges() call, resulting in a single sync per base profession.
local pendingChangesTimer = nil

-- Debounce for TRADE_SKILL_LIST_UPDATE in the normal (non-silent) flow.
-- Completing a craft while the profession UI is open fires the event several
-- times in quick succession; the 0.5s timer batches them into one sync.
-- pendingFullSyncBase tracks the base profession that timer will fully sync, so
-- ScheduleProcessPendingChanges() can skip arming when its variant is covered.
local tradeSkillListUpdateTimer = nil
local pendingFullSyncBase = nil

-- Gate against repeated TRADE_SKILL_LIST_UPDATE events while the profession UI
-- is open. Set once the first sync of an open-UI session runs successfully.
-- Skill-ups are caught by CONSOLE_MESSAGE and new recipes by NEW_RECIPE_LEARNED,
-- so the per-craft TRADE_SKILL_LIST_UPDATE fires are mostly redundant. Cleared
-- on TRADE_SKILL_CLOSE and on TRADE_SKILL_DATA_SOURCE_CHANGED so a profession
-- switch inside the open UI still re-syncs. The accepted trade-off is stale
-- Shadowlands ranked-recipe XP between rank-ups (corrected on next reopen).
local syncedSinceShow = false



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


-- Time budget (in milliseconds) for spread work per frame.
-- debugprofilestop measures wall-clock time in ms.
-- 2ms is ~12% of a 16.7ms frame at 60fps - imperceptible.
local SPREAD_BUDGET_MS = 2

-- Spread UpdateUncollectedTransmog calls across frames to avoid FPS drops.
-- Used by both SyncBaseProfession (deferred transmog for all processed recipes)
-- and TRANSMOG_COLLECTION_SOURCE_ADDED (re-check previously-flagged recipes).
--
-- State is stored in module-level variables because the processing logic is always
-- the same (UpdateUncollectedTransmog per recipe, RefreshProfessionRecipeList when done).
-- Multiple callers may safely append to the queue mid-spread because processing is
-- idempotent - re-checking the same recipe just re-reads its tooltip.
-- No cancel function needed: new work is additive, never conflicting.
local transmogRefreshList = {}
local transmogRefreshIndex = 0
local transmogRefreshFrame = CreateFrame("Frame")

-- Priority-chunk boundary for the transmog spread. When the queue contains a
-- "priority" prefix (e.g. recipes belonging to the currently-viewed profession
-- variant on a TRANSMOG_COLLECTION_SOURCE_* event), transmogPriorityCount holds
-- its length so the spread can call RefreshProfessionRecipeList as soon as the
-- prefix finishes, without waiting for the rest of the queue.
local transmogPriorityCount = 0
local transmogPriorityRefreshed = false


local function TransmogRefreshFunction()
  local start = debugprofilestop()
  while debugprofilestop() - start < SPREAD_BUDGET_MS do
    transmogRefreshIndex = transmogRefreshIndex + 1
    if transmogRefreshIndex > #transmogRefreshList then
      transmogRefreshFrame:SetScript("OnUpdate", nil)
      addon.RefreshProfessionRecipeList()
      return
    end
    UpdateUncollectedTransmog(transmogRefreshList[transmogRefreshIndex])
    -- End of priority chunk: refresh so the user sees the icons in front of
    -- them update without waiting for the background portion of the queue.
    if not transmogPriorityRefreshed
        and transmogPriorityCount > 0
        and transmogRefreshIndex >= transmogPriorityCount then
      transmogPriorityRefreshed = true
      addon.RefreshProfessionRecipeList()
    end
  end
end

-- Append recipe IDs to the transmog refresh queue and start/continue the spread.
-- priorityCount (optional) marks the length of a priority prefix at the front
-- of recipeIds; the spread refreshes the recipe list after that prefix finishes
-- and again when the whole queue is done. Only honored on a fresh spread.
local function QueueTransmogRefresh(recipeIds, priorityCount)
  if not transmogRefreshFrame:GetScript("OnUpdate") then
    -- No refresh in progress - reset for a clean run.
    wipe(transmogRefreshList)
    transmogRefreshIndex = 0
    transmogPriorityCount = priorityCount or 0
    transmogPriorityRefreshed = false
  end
  for _, recipeId in ipairs(recipeIds) do
    tinsert(transmogRefreshList, recipeId)
  end
  if #transmogRefreshList > 0 then
    transmogRefreshFrame:SetScript("OnUpdate", TransmogRefreshFunction)
  end
end


-- Spread SyncBaseProfession's recipe iteration across frames to prevent FPS drops.
-- When a sync runs with onComplete callback, the full-path recipe loop uses a
-- time budget per frame. The narrow path (variant-specific, character-only) stays
-- synchronous because it touches only ~50 recipes.
--
-- Unlike the transmog spread, sync state must be per-invocation: each SyncBaseProfession
-- call creates unique closures (ProcessRecipe, FinishSync) that capture their own
-- variantRecipeInfos, tempDifficulty, etc. syncSpreadState bridges the OnUpdate handler
-- to these per-invocation closures.
--
-- A new sync must cancel any in-progress spread (via CancelSyncSpread) because the old
-- closures hold stale data - their FinishSync would commit outdated difficulty values.
-- Difficulty data is accumulated in a temporary table and committed atomically on
-- completion, so cancellation never leaves saved variables in a partial state.
local syncSpreadState = nil
local syncSpreadFrame = CreateFrame("Frame")

local function CancelSyncSpread()
  syncSpreadFrame:SetScript("OnUpdate", nil)
  syncSpreadState = nil
end

local function SyncSpreadOnUpdate()
  local s = syncSpreadState
  local start = debugprofilestop()
  while debugprofilestop() - start < SPREAD_BUDGET_MS do
    s.recipeIndex = s.recipeIndex + 1
    if s.recipeIndex > #s.recipeIds then
      CancelSyncSpread()
      s.finishSync()
      return
    end
    s.processRecipe(s.recipeIds[s.recipeIndex])
  end
end


-- Sync profession data for a base profession. Iterates the recipe list once
-- (O(recipes)) rather than once per variant, using GetProfessionInfoByRecipeID
-- for O(1) variant lookup with IsRecipeInSkillLine fallback for the few recipes
-- where the API returns a base ID instead of a variant (some MoP/Technique recipes).
--
-- variantFilter: optional table {[variantSkillLineId] = true}.
--   nil  -> sync all variants of the base profession.
--   set  -> sync only the listed variants (e.g. after a single skill-up).
-- onComplete: optional callback, called when sync finishes.
--   When provided, the full-path recipe loop is spread across frames.
--   When nil, the entire sync runs synchronously.
local function SyncBaseProfession(baseSkillLineId, variantFilter, onComplete)
  -- print("SyncBaseProfession", baseSkillLineId)

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

  -- Cancel any in-progress spread (a new sync supersedes an old one).
  -- Done AFTER the readiness check so a sync attempt that bails out doesn't
  -- needlessly kill a valid in-progress spread for a different base.
  CancelSyncSpread()

  local realmName  = GetRealmName()
  local playerName = UnitName("player")

  -- Determine which variants to sync.
  local childInfos = C_TradeSkillUI_GetChildProfessionInfos()
  local variantsToSync = {}
  for _, childInfo in ipairs(childInfos) do
    local variantSkillLineId = childInfo.professionID
    if not variantFilter or variantFilter[variantSkillLineId] then
      variantsToSync[variantSkillLineId] = true
    end
  end

  -- Per-variant setup: determine global sync needs.
  local needsGlobalSync = {}    -- [variantSkillLineId] = bool
  local anyGlobalSync = false
  local variantRecipeInfos = {} -- [variantSkillLineId] = { [recipeId] = recipeInfo }
  -- Accumulate difficulty data in a temp table; commit atomically on completion
  -- so cancellation of a spread never leaves saved variables in a partial state.
  local tempDifficulty = {}     -- [variantSkillLineId] = { [recipeId] = relativeDifficulty }

  for variantSkillLineId in pairs(variantsToSync) do
    needsGlobalSync[variantSkillLineId] = WNTR_pendingGlobalSync[variantSkillLineId]
        or not WNTR_reagentToRecipe[variantSkillLineId]
        or not next(WNTR_reagentToRecipe[variantSkillLineId])
    if needsGlobalSync[variantSkillLineId] then anyGlobalSync = true end

    variantRecipeInfos[variantSkillLineId] = {}
    tempDifficulty[variantSkillLineId] = {}
  end


  -- When syncing specific variants for character-only updates (no global sync needed),
  -- iterate only the recipes belonging to those variants via WNTR_variantToRecipes
  -- instead of all recipes returned by GetAllRecipeIDs().
  -- This cuts the loop from ~500 recipes to ~50 for a single-variant sync.
  local useNarrowRecipeList = variantFilter and not anyGlobalSync
  local transmogRecipeIds = {}

  local function ProcessRecipe(recipeId, variantSkillLineId)
    local recipeInfo = C_TradeSkillUI_GetRecipeInfo(recipeId)
    if not recipeInfo then return end

    variantRecipeInfos[variantSkillLineId][recipeId] = recipeInfo

    if needsGlobalSync[variantSkillLineId] then

      AddReagentsForRecipe(recipeId, variantSkillLineId)

      -- Store the authoritative variant-to-recipes mapping (colon-delimited string).
      -- We append rather than wipe, preserving entries from other characters' professions.
      local existing = WNTR_variantToRecipes[variantSkillLineId]
      if not existing then
        WNTR_variantToRecipes[variantSkillLineId] = tostring(recipeId)
      elseif not ColonListContains(existing, recipeId) then
        WNTR_variantToRecipes[variantSkillLineId] = existing .. ":" .. recipeId
      end

      -- Is this a Legion/BfA ranked recipe?
      if recipeInfo.previousRecipeID or recipeInfo.nextRecipeID then
        WNTR_recipeToRank[recipeId] = GetRecipeRank(recipeInfo)
      end

    end

    if recipeInfo.learned then
      tempDifficulty[variantSkillLineId][recipeId] = recipeInfo.relativeDifficulty
    end

    -- Transmog re-check queue:
    --   * During global sync: every recipe (initial "unknown" / "item" detection).
    --   * During any other sync: only recipes that already have a flag set, so
    --     narrow syncs stay cheap while still giving previously-flagged recipes
    --     a chance to correct themselves against the current game state.
    -- Processed as a frame-spread in FinishSync via QueueTransmogRefresh.
    if anyGlobalSync
        or WNTR_recipeWithUncollectedTransmog[recipeId]
        or WNTR_recipeWithUncollectedTransmogItem[recipeId] then
      tinsert(transmogRecipeIds, recipeId)
    end

  end


  -- Resolve which synced variant a recipe belongs to (full-path only).
  local function ResolveVariantAndProcess(recipeId)
    local variantSkillLineId
    local profInfo = C_TradeSkillUI_GetProfessionInfoByRecipeID(recipeId)
    if profInfo then
      if variantsToSync[profInfo.professionID] then
        variantSkillLineId = profInfo.professionID
      elseif profInfo.parentProfessionID and variantsToSync[profInfo.parentProfessionID] then
        variantSkillLineId = profInfo.parentProfessionID
      end
    end
    if not variantSkillLineId then
      for vid in pairs(variantsToSync) do
        if C_TradeSkillUI_IsRecipeInSkillLine(recipeId, vid) then
          variantSkillLineId = vid
          break
        end
      end
    end
    if variantSkillLineId then
      ProcessRecipe(recipeId, variantSkillLineId)
    end
  end


  -- Post-processing and commit. Runs after all recipes have been processed.
  local function FinishSync()
    -- Commit difficulty data atomically.
    WNTR_recipeToDifficulty[realmName] = WNTR_recipeToDifficulty[realmName] or {}
    WNTR_recipeToDifficulty[realmName][playerName] = WNTR_recipeToDifficulty[realmName][playerName] or {}
    for vid in pairs(variantsToSync) do
      WNTR_recipeToDifficulty[realmName][playerName][vid] = tempDifficulty[vid]
    end

    -- Per-variant post-processing.
    for vid in pairs(variantsToSync) do

      if needsGlobalSync[vid] then
        -- Assign ranks by name grouping for Shadowlands ranked recipes.
        AssignRanksByName(variantRecipeInfos[vid])
        WNTR_pendingGlobalSync[vid] = nil
      end

      -- Correct Shadowlands ranked recipe learned/difficulty, then store XP.
      -- Both must happen after AssignRanksByName so WNTR_recipeToRank is fully populated.
      for recipeId, recipeInfo in pairs(variantRecipeInfos[vid]) do
        if recipeInfo.learned then
          CorrectShadowlandsRankedRecipeDifficulty(realmName, playerName, recipeId, recipeInfo, vid)
          UpdateRecipeExperience(realmName, playerName, recipeId, recipeInfo)
        end
      end

      -- Update skill level and variant-to-base mapping.
      local variantInfo = C_TradeSkillUI_GetProfessionInfoBySkillLineID(vid)
      if variantInfo then
        if variantInfo.parentProfessionID then
          WNTR_variantToBaseProfession[vid] = variantInfo.parentProfessionID
        end
        WNTR_variantToSkillLevel[realmName] = WNTR_variantToSkillLevel[realmName] or {}
        WNTR_variantToSkillLevel[realmName][playerName] = WNTR_variantToSkillLevel[realmName][playerName] or {}
        WNTR_variantToSkillLevel[realmName][playerName][vid] = variantInfo.skillLevel
        WNTR_variantToSkillLevel[realmName][playerName]["maxLevels"] = WNTR_variantToSkillLevel[realmName][playerName]["maxLevels"] or {}
        WNTR_variantToSkillLevel[realmName][playerName]["maxLevels"][vid] = variantInfo.maxSkillLevel
      end

      -- Mark this variant as no longer pending for character specific sync.
      if WNTR_pendingCharacterSync[realmName] and WNTR_pendingCharacterSync[realmName][playerName] then
        WNTR_pendingCharacterSync[realmName][playerName][vid] = nil
      end
    end

    -- Kick off the transmog frame-spread. Content of transmogRecipeIds is
    -- decided in ProcessRecipe above: everything on global sync, only
    -- already-flagged recipes otherwise.
    if #transmogRecipeIds > 0 then
      QueueTransmogRefresh(transmogRecipeIds)
    end

    if onComplete then onComplete() end
  end


  -- Execute the recipe iteration.
  if useNarrowRecipeList then
    -- Character-only sync: iterate only the known recipes for each filtered variant.
    -- Small recipe set (~50), always synchronous.
    for vid in pairs(variantsToSync) do
      for recipeId in IterColonListIds(WNTR_variantToRecipes[vid]) do
        ProcessRecipe(recipeId, vid)
      end
    end
    FinishSync()

  else
    -- Full sync: fetch all recipes and process them.
    local recipeIds = C_TradeSkillUI_GetAllRecipeIDs()
    if not recipeIds then return false end

    if onComplete then
      -- Spread across frames to avoid FPS drops.
      syncSpreadState = {
        recipeIds = recipeIds,
        recipeIndex = 0,
        processRecipe = ResolveVariantAndProcess,
        finishSync = FinishSync,
      }
      syncSpreadFrame:SetScript("OnUpdate", SyncSpreadOnUpdate)
    else
      -- Synchronous (used by silent open and other paths that need immediate results).
      for _, recipeId in pairs(recipeIds) do
        ResolveVariantAndProcess(recipeId)
      end
      FinishSync()
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
  if WNTR_config.showStatusMessages then
    print("|cff00ccffWhoNeedsThisReagent:|r ...", C_TradeSkillUI_GetProfessionInfoBySkillLineID(baseSkillLineId).professionName, "synced successfully!")
  end
  addon.InvalidateReagentCache()
  addon.UpdateMinimapGlow()
end


-- Try to sync a base profession immediately (if its backend is currently active).
-- If the backend is not ready (frame closed or different profession loaded),
-- queue it as pending so the user can trigger sync later.
local function SyncOrAddPending(baseSkillLineId)
  -- print("SyncOrAddPending", baseSkillLineId)
  -- SyncBaseProfession returns true if it started (may complete async via the callback);
  -- false if the backend isn't active, in which case we queue for later.
  if not SyncBaseProfession(baseSkillLineId, nil, function()
    CompletePendingSync(baseSkillLineId)
  end) then
    AddPendingBaseProfession(baseSkillLineId)
  end
end



-- Closes the invisible profession frame (if we opened it), resets the silent-open state,
-- and notifies the user about any remaining pending professions.
--
-- NOTE: it is tempting to also restore the base profession the user had open before
-- SyncPendingProfession switched away from it (e.g. return to Tailoring after silently
-- syncing Cooking). Do not try - C_TradeSkillUI.OpenTradeSkill is a protected function
-- that only works inside a hardware-event call stack (mouse click, key press, /run in
-- chat). By the time this callback fires we are inside the sync spread's OnUpdate, out
-- of any hardware-event context, and OpenTradeSkill raises ADDON_ACTION_BLOCKED. There
-- is no Lua-only workaround (SecureActionButton, /click, SetOverrideBindingMacro all
-- still need a real user input to activate). The only viable alternative would be a
-- chat hyperlink that prefills the chat with /run OpenTradeSkill(id) for the user to
-- press Enter on, which is not really "automatic" and gives worse UX than just clicking
-- the profession in the sidebar.
local function FinishSilentOpen()
  -- Cancel any in-progress async sync spread so its callback doesn't fire
  -- after silentOpenProfessionId has been cleared.
  CancelSyncSpread()

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
-- Both events mark their variant directly in WNTR_pendingCharacterSync; this
-- function collects the pending variants per base profession and syncs only those
-- (not every variant of the base), falling back to AddPendingBaseProfession if the
-- backend is not active.
local function ProcessPendingChanges()

  -- print("ProcessPendingChanges")

  local realmName  = GetRealmName()
  local playerName = UnitName("player")

  WNTR_pendingCharacterSync[realmName] = WNTR_pendingCharacterSync[realmName] or {}
  WNTR_pendingCharacterSync[realmName][playerName] = WNTR_pendingCharacterSync[realmName][playerName] or {}

  -- Collect pending variants per base profession.
  -- Skip variants whose base has an armed TRADE_SKILL_LIST_UPDATE full sync
  -- (pendingFullSyncBase): that full sync will cover them, so syncing them
  -- here would just duplicate work. The variants stay in WNTR_pendingCharacterSync
  -- and SyncBaseProfession's FinishSync clears them when the full sync completes.
  local baseToVariants = {}
  for variantSkillLineId in pairs(WNTR_pendingCharacterSync[realmName][playerName]) do
    local baseSkillLineId = GetBaseOfVariant(variantSkillLineId)
    if baseSkillLineId and baseSkillLineId ~= pendingFullSyncBase then
      baseToVariants[baseSkillLineId] = baseToVariants[baseSkillLineId] or {}
      baseToVariants[baseSkillLineId][variantSkillLineId] = true
    end
  end

  -- Sync only the pending variants (not all variants of each base profession).
  -- Don't call CompletePendingSync here - a variant-specific sync may not cover
  -- all pending work for the base (e.g. global sync of other variants after a
  -- build change). The full TRADE_SKILL_LIST_UPDATE path handles that.
  local anySynced = false
  for baseSkillLineId, variantFilter in pairs(baseToVariants) do
    if silentOpenProfessionId == baseSkillLineId then
      -- A silent open of this base is already in progress and will fully sync
      -- all variants (clearing them from WNTR_pendingCharacterSync in FinishSync).
      -- Calling SyncBaseProfession here would pass the readiness check and then
      -- CancelSyncSpread the silent's in-progress spread, leaving the silent's
      -- callback chain (CompletePendingSync + FinishSilentOpen) un-fired.
    elseif SyncBaseProfession(baseSkillLineId, variantFilter) then
      anySynced = true
    else
      AddPendingBaseProfession(baseSkillLineId)
    end
  end
  if anySynced then
    addon.InvalidateReagentCache()
  end

end

local function ScheduleProcessPendingChanges(variantSkillLineId)
  -- If a TRADE_SKILL_LIST_UPDATE-triggered full sync is already armed for this
  -- variant's base profession, skip - that full sync will cover this variant too,
  -- so scheduling a variant-specific sync on top of it would just duplicate work.
  if variantSkillLineId and pendingFullSyncBase
      and GetBaseOfVariant(variantSkillLineId) == pendingFullSyncBase then
    return
  end
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
-- Skill level change detection is NOT done here - that is handled by the
-- CONSOLE_MESSAGE event ("Skill <id> increased from X to Y"), which marks
-- the affected variant as pending and calls ScheduleProcessPendingChanges().
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
  -- UpdateProfessions can only reconstruct entries from WNTR_pendingCharacterSync - which does not capture
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
    -- print("TRADE_SKILL_LIST_UPDATE")

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
        local silentSyncCallback = function()
          CompletePendingSync(silentOpenProfessionId)
          FinishSilentOpen()
        end

        -- Backend was not fully ready yet. If the ticker does not exist yet, we start it.
        -- Keep the invisible frame open and retry every 0.2s for up to 2 seconds,
        -- giving the backend time to finish loading the profession variant data.
        if not SyncBaseProfession(silentOpenProfessionId, nil, silentSyncCallback) and not silentOpenRetryTicker then
          -- print("WNTR DEBUG: Backend was not ready. Starting ticker.")

          silentOpenRetryCount = 0
          silentOpenRetryTicker = C_Timer_NewTicker(0.2, function()
            silentOpenRetryCount = silentOpenRetryCount + 1

            -- print("WNTR DEBUG: Retrying sync of", silentOpenProfessionId)

            if SyncBaseProfession(silentOpenProfessionId, nil, silentSyncCallback) then
              -- Sync started; callback handles CompletePendingSync + FinishSilentOpen.
              -- Cancel ticker; FinishSilentOpen in the callback is a safe double-cancel.
              silentOpenRetryTicker:Cancel()
              silentOpenRetryTicker = nil
            elseif silentOpenRetryCount >= 10 then
              if WNTR_config.showStatusMessages then
                print("|cff00ccffWhoNeedsThisReagent:|r Synchronization timed out. Professions backend did not respond within 2 seconds.")
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
    -- Sync is spread across frames to avoid FPS drops (e.g. selling items
    -- or completing a crafting item triggers TRADE_SKILL_LIST_UPDATE with
    -- the profession frame open). Completing a craft also fires the event
    -- several times back-to-back, so debounce before kicking off the sync.
    else

      -- Gate: skip if this open-UI session already produced a successful sync.
      -- TRADE_SKILL_CLOSE / TRADE_SKILL_DATA_SOURCE_CHANGED clear the flag.
      if syncedSinceShow then return end

      -- Capture the active base at arm-time so ScheduleProcessPendingChanges
      -- can recognise that a pending variant of this base will be covered, and
      -- so ProcessPendingChanges can skip its variants at fire time when an
      -- earlier-armed pendingChangesTimer would otherwise double-sync them.
      -- WNTR_pendingCharacterSync is not pre-cleared here: SyncBaseProfession's
      -- FinishSync clears it on success, and leaving entries in place keeps them
      -- recoverable if the profession UI closes during the debounce.
      local armingProfessionInfo = C_TradeSkillUI_GetBaseProfessionInfo()
      pendingFullSyncBase = armingProfessionInfo and armingProfessionInfo.professionID or nil

      if tradeSkillListUpdateTimer then
        tradeSkillListUpdateTimer:Cancel()
      end
      tradeSkillListUpdateTimer = C_Timer_NewTimer(0.5, function()
        -- print("tradeSkillListUpdateTimer firing")

        tradeSkillListUpdateTimer = nil
        pendingFullSyncBase = nil

        -- Re-check at fire time; the active profession may have changed during the debounce.
        local activeProfessionInfo = C_TradeSkillUI_GetBaseProfessionInfo()
        local activeBaseSkillLineId = activeProfessionInfo and activeProfessionInfo.professionID

        if activeBaseSkillLineId then
          if SyncBaseProfession(activeBaseSkillLineId, nil, function()
            -- Transmog updates are deferred to a frame-spread inside SyncBaseProfession;
            -- RefreshProfessionRecipeList is called automatically when the spread completes.

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
          end) then
            -- Sync actually started (backend ready); gate further TRADE_SKILL_LIST_UPDATE
            -- events in this open-UI session.
            syncedSinceShow = true
          end
        end
      end)

    end



  -- #########################################################################
  -- The game emits locale-independent console messages like "Skill 2568 increased from 0 to 1"
  -- whenever a profession variant's skill level changes. This covers two cases:
  --   1) A skill level-up (e.g. "from 50 to 51") - marks the variant for character sync.
  --   2) A newly learned variant (e.g. "from 0 to 1") - also caught here, even when
  --      LEARNED_SPELL_IN_SKILL_LINE does not fire (e.g. Pandaria Mining).
  elseif event == "CONSOLE_MESSAGE" then
    local messageText = ...
    local variantSkillLineId, oldSkillLevel, newSkillLevel =
        string_match(messageText, "^Skill (%d+) increased from (%d+) to (%d+)")
    if variantSkillLineId then
      -- print("CONSOLE_MESSAGE", messageText)

      variantSkillLineId = tonumber(variantSkillLineId)
      oldSkillLevel     = tonumber(oldSkillLevel)
      newSkillLevel     = tonumber(newSkillLevel)

      -- Reject variants whose base profession is not one we care about (fishing,
      -- archaeology): they have no recipes with reagents, so syncing them would
      -- produce nothing useful and clutter the pending-sync notification. The
      -- "what we care about" policy lives in CharacterHasBaseProfession (prof1,
      -- prof2, cooking).
      local variantBaseId = GetBaseOfVariant(variantSkillLineId)
      if not variantBaseId or not CharacterHasBaseProfession(variantBaseId) then
        return
      end

      -- Gathering professions are ignored by default (no reagent-consuming recipes).
      -- The only exception is the smelting recipes on pre-WoD Mining variants - for
      -- those, mark pending only when the new skill level crossed a configured
      -- threshold (a recipe's relativeDifficulty actually changed). Crafting
      -- professions are not in gatheringBaseProfessionIds, so they fall through
      -- and always mark pending as before.
      if gatheringBaseProfessionIds[variantBaseId] then
        local thresholds = gatheringSkillThresholds[variantSkillLineId]
        if not thresholds then return end
        local crossed = false
        for _, threshold in ipairs(thresholds) do
          if oldSkillLevel < threshold and threshold <= newSkillLevel then
            crossed = true
            break
          end
        end
        if not crossed then return end
      end

      local realmName  = GetRealmName()
      local playerName = UnitName("player")

      -- Mark variant as pending character sync (persisted across sessions).
      WNTR_pendingCharacterSync[realmName] = WNTR_pendingCharacterSync[realmName] or {}
      WNTR_pendingCharacterSync[realmName][playerName] = WNTR_pendingCharacterSync[realmName][playerName] or {}
      WNTR_pendingCharacterSync[realmName][playerName][variantSkillLineId] = true

      -- Debounce: a craft can trigger both a skill-up and a NEW_RECIPE_LEARNED
      -- almost simultaneously; the shared timer batches them into one sync.
      -- Pass the variant so the scheduler can skip if a TRADE_SKILL_LIST_UPDATE
      -- full-sync for this base is already armed.
      ScheduleProcessPendingChanges(variantSkillLineId)
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
        for candidateVariant, recipesStr in pairs(WNTR_variantToRecipes) do
          if WNTR_variantToBaseProfession[candidateVariant] == baseId
              and ColonListContains(recipesStr, recipeId) then
            variantSkillLineId = candidateVariant
            break
          end
        end
      end
    end
    -- print("NEW_RECIPE_LEARNED", recipeId, variantSkillLineId)

    -- Mark variant as pending character sync, just like CONSOLE_MESSAGE does.
    -- If variantSkillLineId is nil (recipe not yet in the mapping because no global sync has run yet),
    -- the profession is already pending a full sync which will cover this recipe.
    if variantSkillLineId then
      -- Reject variants whose base profession is not one we care about (fishing,
      -- archaeology); see the matching guard in the CONSOLE_MESSAGE handler.
      local variantBaseId = GetBaseOfVariant(variantSkillLineId)
      if not variantBaseId or not CharacterHasBaseProfession(variantBaseId) then
        return
      end

      -- Gathering professions are ignored by default; the only exception is
      -- variants listed in gatheringSkillThresholds (Mining smelting). For
      -- NEW_RECIPE_LEARNED there's no skill level to threshold-check against,
      -- so listed-variant means "always mark pending."
      if gatheringBaseProfessionIds[variantBaseId]
          and not gatheringSkillThresholds[variantSkillLineId] then
        return
      end

      -- If this recipeId isn't yet in our variant mapping (e.g. a newly-unlocked
      -- higher rank of a Legion/BfA ranked recipe that wasn't returned by the
      -- earlier global sync's GetAllRecipeIDs), force a global rebuild for this
      -- variant. Without this, ProcessPendingChanges takes the narrow path,
      -- which iterates WNTR_variantToRecipes[variantId] and misses the new
      -- recipe entirely - so its learned/difficulty state never enters
      -- WNTR_recipeToDifficulty, and the tooltip's "hide lower learned ranks"
      -- walk finds no higher-rank difficulty to hide the previous rank against.
      if not ColonListContains(WNTR_variantToRecipes[variantSkillLineId], recipeId) then
        WNTR_pendingGlobalSync[variantSkillLineId] = true
      end

      local realmName  = GetRealmName()
      local playerName = UnitName("player")
      WNTR_pendingCharacterSync[realmName] = WNTR_pendingCharacterSync[realmName] or {}
      WNTR_pendingCharacterSync[realmName][playerName] = WNTR_pendingCharacterSync[realmName][playerName] or {}
      WNTR_pendingCharacterSync[realmName][playerName][variantSkillLineId] = true
    end

    -- Debounce: learning a new profession fires many recipe events at once;
    -- the shared timer batches them (and any concurrent skill-ups) into one sync.
    -- Pass the variant so the scheduler can skip if a TRADE_SKILL_LIST_UPDATE
    -- full-sync for this base is already armed.
    ScheduleProcessPendingChanges(variantSkillLineId)


  -- #########################################################################
  -- A transmog appearance source was collected (SOURCE_ADDED) or a previously
  -- collected source was removed (SOURCE_REMOVED - rare; e.g. vendor refund).
  -- Re-check every currently-flagged recipe via the frame-spread. Recipes for
  -- the currently-viewed profession variant go at the front of the queue as a
  -- "priority prefix" so their icons update as soon as that prefix finishes
  -- (see QueueTransmogRefresh's priorityCount).
  --
  -- Deliberately not filtering by the payload sourceID's visualID: that would
  -- need a schematic + item-info lookup per flagged recipe, which can stutter
  -- when the flagged set is large. The spread bounds the cost either way.
  --
  -- Not caught: SOURCE_REMOVED can newly-flag a previously-unflagged recipe
  -- whose exact output item was the removed source. Such a recipe self-
  -- corrects on the next global sync of its variant.
  elseif event == "TRANSMOG_COLLECTION_SOURCE_ADDED"
      or event == "TRANSMOG_COLLECTION_SOURCE_REMOVED" then
    -- Build the set of recipeIds belonging to the currently-viewed variant.
    local activeVariantId = C_TradeSkillUI_GetProfessionChildSkillLineID()
    if activeVariantId == 0 then activeVariantId = nil end
    local activeVariantRecipes = {}
    if activeVariantId then
      for id in IterColonListIds(WNTR_variantToRecipes[activeVariantId]) do
        activeVariantRecipes[id] = true
      end
    end

    local front = {}
    local back = {}
    local seen = {}
    local function enqueue(recipeId)
      if seen[recipeId] then return end
      seen[recipeId] = true
      if activeVariantRecipes[recipeId] then
        tinsert(front, recipeId)
      else
        tinsert(back, recipeId)
      end
    end
    for recipeId in pairs(WNTR_recipeWithUncollectedTransmog)     do enqueue(recipeId) end
    for recipeId in pairs(WNTR_recipeWithUncollectedTransmogItem) do enqueue(recipeId) end

    local priorityCount = #front
    for _, id in ipairs(back) do
      tinsert(front, id)
    end
    if #front > 0 then
      QueueTransmogRefresh(front, priorityCount)
    end


  -- #########################################################################
  -- The profession UI closed; allow the next TRADE_SKILL_LIST_UPDATE in a future
  -- open-UI session to run a sync again.
  elseif event == "TRADE_SKILL_CLOSE" then
    syncedSinceShow = false


  -- #########################################################################
  -- The user switched between profession data sources inside the open UI (e.g.
  -- selecting their second profession). The active base has changed, so allow
  -- the next TRADE_SKILL_LIST_UPDATE to sync the newly-shown profession.
  elseif event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
    syncedSinceShow = false
  end
end

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", EventFrameFunction)
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("TRADE_SKILL_CLOSE")
eventFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
eventFrame:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED")
eventFrame:RegisterEvent("CONSOLE_MESSAGE")
eventFrame:RegisterEvent("NEW_RECIPE_LEARNED")
eventFrame:RegisterEvent("TRANSMOG_COLLECTION_SOURCE_ADDED")
eventFrame:RegisterEvent("TRANSMOG_COLLECTION_SOURCE_REMOVED")
