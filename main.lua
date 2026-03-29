local folderName, addon = ...


-- ### Saved variables.

-- WNTR_reagentToRecipe[variantSkillLineId][reagentItemId] = { recipeId, ... }.
-- Also stores WNTR_reagentToRecipe["buildNumber"] to detect game client updates.
WNTR_reagentToRecipe = WNTR_reagentToRecipe or {}


-- WNTR_recipeToDifficulty[realmName][playerName][variantSkillLineId][recipeId] = relativeDifficulty (0-3).
WNTR_recipeToDifficulty = WNTR_recipeToDifficulty or {}

-- WNTR_recipeToRank[recipeId] = rank (1-based). Populated by walking the previousrecipeId/nextrecipeId
-- chain for Legion/BfA recipes (which have those fields populated). For Shadowlands recipes (which
-- lack chain fields), AssignRanksByName() is used as a fallback - but note that this name-based
-- heuristic (same recipe name, sorted by recipeId ascending = rank order) was tested and found to
-- be INCORRECT for Legion/BfA: several recipes have ranked variants whose recipeIds are not
-- monotonically ordered by rank. The chain-based path is therefore essential for those expansions.
WNTR_recipeToRank = WNTR_recipeToRank or {}

-- Recipe rank XP progress per [realmName][playerName][recipeId] = currentXP (number).
-- Only stored for the rank currently being worked on (i.e. the highest learned rank).
-- WNTR_recipeToExperience["nextLevels"][recipeId] = nextLevelXP (shared across characters).
WNTR_recipeToExperience = WNTR_recipeToExperience or {}


-- Skill level per [realmName][playerName][variantSkillLineId] (plain number), and max level per [realmName][playerName]["maxLevels"][variantSkillLineId].
-- We need to store max levels character-specifically because of profession specializations (e.g. Kul Tiran Herbalism vs. regular Herbalism).
WNTR_variantToSkillLevel = WNTR_variantToSkillLevel or {}


-- We store character classes to be able to display character names in class colours.
WNTR_characterToClass = WNTR_characterToClass or {}

-- The profession icon can only be obtained with GetProfessionInfo(), which takes spell-tab-index as argument.
-- But spell-tab-index can only be obtained for the current character with GetProfessions()
-- So if we want to display icons for arbitrary professions, we need to map professions to icons.
WNTR_professionSkillLineToIcon = WNTR_professionSkillLineToIcon or {}

-- WNTR_variantToBaseProfession[variantSkillLineId] = baseId.
-- C_TradeSkillUI.GetChildProfessionInfos() only works for the active profession backend,
-- so we persist this mapping to resolve variant/base relationships at any time.
-- Populated by SyncVariantProfession().
WNTR_variantToBaseProfession = WNTR_variantToBaseProfession or {}

-- WNTR_recipeToVariant[recipeId] = variantSkillLineId.
-- GetProfessionInfoByRecipeID() is unreliable for some recipes and only works while,
-- the profession is currently active in the backend. That's why we build our own
-- authoritative mapping during SyncVariantProfession() while the backend is active
-- and IsRecipeInSkillLine() is trustworthy. Entries are overwritten (not wiped) on
-- global sync, so data from other characters is preserved.
WNTR_recipeToVariant = WNTR_recipeToVariant or {}


-- LibDBIcon minimap button position/state.
WNTR_whoNeedsThisReagentIconDB = WNTR_whoNeedsThisReagentIconDB or {}

-- User-facing configuration options. Defaults are applied in Sync.lua's ADDON_LOADED handler.
WNTR_config = WNTR_config or {}


-- Persistent pending-sync tracking (survives reloads).
-- WNTR_pendingGlobalSync[variantSkillLineId] = true: variant's reagent/rank data needs rebuilding (any character can fulfill).
-- WNTR_pendingCharacterSync[realmName][playerName][variantSkillLineId] = true: character's difficulty data needs refreshing.
WNTR_pendingGlobalSync = WNTR_pendingGlobalSync or {}
WNTR_pendingCharacterSync = WNTR_pendingCharacterSync or {}

-- Build change detection is performed in Sync.lua's ADDON_LOADED handler,
-- after saved variables have been populated by the game engine.


-- ============================================================
-- Architecture overview
-- ============================================================
--
-- Profession IDs:
--   A profession can be identified by two different IDs: the TradeSkillLineID or Enum.Profession.
--   We use TradeSkillLineID throughout, which comes directly from GetProfessionInfo().
--   Each profession has a "base" ID (e.g. Alchemy) and expansion-specific "variant" IDs
--   (e.g. Kul Tiran Alchemy, Shadowlands Alchemy). Both are TradeSkillLineIDs.
--   In this code: "baseId" / "baseProfessionId" = base, "variantId" = expansion variant.
--
-- Data flow:
--   SKILL_LINES_CHANGED fires on login and profession changes.
--     -> UpdateProfessions() detects what needs syncing by checking the persistent pending
--        tables and comparing stored vs. current skill levels.
--     -> For each base profession needing sync: if the profession backend is active,
--        SyncBaseProfession() runs immediately; otherwise the base ID is queued into
--        pendingBaseSkillLineIds (a runtime-only list) so the user can trigger sync manually.
--   TRADE_SKILL_LIST_UPDATE fires when a profession window opens.
--     -> SyncBaseProfession() rebuilds global data (reagents, ranks) if pendingGlobalSync
--        says so, and always rebuilds character-specific data (difficulty, skill levels).
--   NEW_RECIPE_LEARNED fires when the player learns a new recipe.
--     -> ProcessNewRecipes() attempts a quick difficulty update or queues for later sync.
--
-- Pending sync (two tiers, both persisted as saved variables):
--   WNTR_pendingGlobalSync[variantSkillLineId] = true
--     Variant's reagent/rank data needs rebuilding. Any character with that profession *variant*
--     can fulfill this (the data is shared across characters).
--   WNTR_pendingCharacterSync[realmName][playerName][variantSkillLineId] = true
--     Character's difficulty/skill data needs refreshing. Only that character can fulfill.
--
-- File layout:
--   main.lua          – Saved variables, namespace setup, architecture docs.
--   Helpers.lua       – Utility functions (sound, data mutation, recipe rank/reagent helpers).
--   MinimapButton.lua – LibDataBroker/LibDBIcon minimap icon with pulsating glow.
--   Sync.lua          – Profession syncing engine, event handling, pending-sync management.
--   Tooltip.lua       – Custom multi-column "Who needs this reagent?" tooltip.
--
-- References:
--   https://warcraft.wiki.gg/wiki/API_GetProfessions
--   https://warcraft.wiki.gg/wiki/API_GetProfessionInfo
--   https://warcraft.wiki.gg/wiki/TradeSkillLineID
--   https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetProfessionInfoBySkillLineID
--   https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetBaseProfessionInfo


-- Runtime-only list of base profession IDs that need syncing but couldn't be synced
-- immediately (because the profession backend wasn't active). Rebuilt from the persistent
-- pending tables each session by UpdateProfessions(). Drives the chat link UI and
-- SyncPendingProfession() sequential silent-open flow.
addon.pendingBaseSkillLineIds = {}

-- UpdateMinimapGlow is called after every mutation of pendingBaseSkillLineIds.
-- Starts as a no-op; overridden by MinimapButton.lua if LDB is available.
addon.UpdateMinimapGlow = function() end


-- -- For debugging.
-- local function NoEscape(toPrint)
--   -- Brackets are needed to only print the first outout of gsub.
--   return (string.gsub(toPrint, "\124", "\124\124"))
-- end




