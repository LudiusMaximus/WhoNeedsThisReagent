local folderName, addon = ...

-- Cache of global WoW API tables/functions.
local C_ClassColor_GetClassColor                    = _G.C_ClassColor.GetClassColor
local C_TradeSkillUI_GetProfessionInfoBySkillLineID = _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID
local C_TradeSkillUI_GetRecipeInfo                  = _G.C_TradeSkillUI.GetRecipeInfo
local GameTooltip                                   = _G.GameTooltip
local GameTooltipText                               = _G.GameTooltipText
local GetItemInfo                                   = _G.GetItemInfo
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
local GetConsumerIndex = addon.GetConsumerIndex

-- Depth cap for the recursive transitive walk (defined in Helpers.lua, shared
-- with ProfessionFrame.lua's transitive transmog lookup).
local TRANSITIVE_REAGENT_MAX_DEPTH = addon.TRANSITIVE_REAGENT_MAX_DEPTH

-- Reagent lookup cache: maps itemId -> true/false (is/isn't a known reagent).
-- Avoids iterating all profession variants on every tooltip. Invalidated on sync.
local reagentCache = {}

-- Monotonic counter for `insertionOrder` on line records. Reset at the top of
-- each ShowSecondTooltip() so sortLines() can use it as a stable within-profession
-- tiebreaker while still respecting the tree order in which lines were emitted.
local nextInsertionOrder = 0

-- API result caches: avoid re-creating large tables on every tooltip rebuild.
-- These rarely change during a session (recipe names are constant, learned status
-- only changes on NEW_RECIPE_LEARNED which triggers a full sync that invalidates
-- these caches via InvalidateReagentCache).
local recipeInfoCache = {}
local profInfoCache = {}

-- Consumer tree cache: treeCache[reagentId] = array of root nodes. The tree of
-- recipes reachable from a reagent is character/variant-independent, so it is
-- built once per hovered reagent and reused by every (character, variant)
-- section of the tooltip - the per-section work is then just a pruned traversal.
-- Each node: {recipeId, varId, output, children = {...}, subVariants = {set}}
-- where subVariants is the union of varIds appearing strictly BELOW the node
-- (children and deeper). A section for variant V can skip a branch entirely
-- when node.varId ~= V and not node.subVariants[V].
-- The cache is keyed by the config it was built under; a config change wipes it.
local treeCache = {}
local treeCacheIncludeOptional = nil
local treeCacheMaxDepth = nil

function addon.InvalidateReagentCache()
  wipe(reagentCache)
  wipe(treeCache)
  wipe(recipeInfoCache)
  addon.InvalidateConsumerIndexes()
  addon.InvalidateTransitiveTransmogCache()
end

-- Recursively expand the consumers of itemId into `children`.
-- Depth 1 uses the union index so the direct display keeps showing every use
-- of the hovered reagent; deeper hops use transitiveIndex (required-only by
-- default, union in expert mode). pathItems is the ancestor set of the current
-- DFS path - recursion into an item already on the path is a cycle and cut.
-- Parallel paths are NOT deduplicated: an item reachable via two different
-- intermediates appears in both subtrees (each path is real lineage).
local function BuildConsumerTreeChildren(itemId, depth, maxDepth, pathItems, children, unionIndex, transitiveIndex)
  local index = (depth == 1) and unionIndex or transitiveIndex
  local list = index[itemId]
  if not list then return end
  for i = 1, #list, 2 do
    local recipeId = list[i]
    local varId = list[i + 1]
    local output = WNTR_recipeToOutputItem[recipeId]
    local node = {
      recipeId = recipeId,
      varId = varId,
      output = output,
      children = {},
      subVariants = {},
    }
    children[#children + 1] = node
    if output and depth < maxDepth and not pathItems[output] then
      pathItems[output] = true
      BuildConsumerTreeChildren(output, depth + 1, maxDepth, pathItems, node.children, unionIndex, transitiveIndex)
      pathItems[output] = nil
      for _, child in ipairs(node.children) do
        node.subVariants[child.varId] = true
        for v in pairs(child.subVariants) do
          node.subVariants[v] = true
        end
      end
    end
  end
end

local function GetConsumerTree(reagentId, includeOptional, maxDepth)
  if treeCacheIncludeOptional ~= includeOptional or treeCacheMaxDepth ~= maxDepth then
    wipe(treeCache)
    treeCacheIncludeOptional = includeOptional
    treeCacheMaxDepth = maxDepth
  end
  local cached = treeCache[reagentId]
  if cached then return cached end

  -- Depth 1 always uses the union index (direct display shows every use of
  -- the hovered reagent); deeper hops use the config-selected edge set.
  local unionIndex = GetConsumerIndex(true)
  local transitiveIndex = GetConsumerIndex(includeOptional)

  local rootNodes = {}
  BuildConsumerTreeChildren(reagentId, 1, maxDepth, { [reagentId] = true }, rootNodes, unionIndex, transitiveIndex)
  treeCache[reagentId] = rootNodes
  return rootNodes
end

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

-- Item-name cache for the intermediate reagent headers in the transitive
-- display. GetItemInfo may return nil if item data isn't cached yet; we skip
-- caching in that case so a later lookup can succeed once the data arrives.
local itemNameCache = {}
local function GetCachedItemName(itemId)
  local cached = itemNameCache[itemId]
  if cached then return cached end
  local name = GetItemInfo(itemId)
  if name then itemNameCache[itemId] = name end
  return name
end

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
  -- Position within its profession block. Layout uses `depth` for indent (0 for
  -- profession header, N >= 1 for tree lines). sortLines uses `insertionOrder`
  -- as a stable tiebreaker so recursive tree order is preserved after sort.
  rec.depth = nil
  rec.insertionOrder = nil
  return rec
end

local function ResetLinePool()
  linePoolActive = 0
end

-- Module-level sort comparator (no closure allocation). Groups by profession,
-- puts the profession header first within its block, then preserves the order
-- in which the recursive tree walk emitted its lines (via insertionOrder).
local function sortLines(a, b)
  if a.profSortKey ~= b.profSortKey then return a.profSortKey < b.profSortKey end
  if a.kind == "profession" then return b.kind ~= "profession" end
  if b.kind == "profession" then return false end
  return (a.insertionOrder or 0) < (b.insertionOrder or 0)
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
-- Per-depth extra indent for recipes / intermediates deeper in the transitive tree.
-- Depth 1 gets RECIPE_INDENT; depth N gets RECIPE_INDENT + (N-1) * SUB_RECIPE_INDENT
-- so each level visually nests under its parent. Transmog icons stay at the
-- normal column-left position; only the text shifts right.
local SUB_RECIPE_INDENT = 14


-- Map a stored relativeDifficulty (0-3 or nil for unlearned) to a colour object.
local function DifficultyToColor(difficulty)
  if difficulty == 0 then return DIFFICULT_DIFFICULTY_COLOR
  elseif difficulty == 1 then return FAIR_DIFFICULTY_COLOR
  elseif difficulty == 2 then return EASY_DIFFICULTY_COLOR
  elseif difficulty == 3 then return TRIVIAL_DIFFICULTY_COLOR
  end
  return IMPOSSIBLE_DIFFICULTY_COLOR
end


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

-- Build one recipe line for a character-craftable recipe. Returns the pooled
-- line record, or nil if the recipe should be hidden (ranks below highest
-- learned, or unlearned ranks beyond the "next" one when the nextUnlearnedRankOnly
-- config is on). Called at every depth in the recursive tree walk; layout uses
-- `depth` to compute the indent.
local function BuildRecipeLine(recipeId, difficultyByRecipe, profName, realm, character, skillLevel, maxLevel, depth)
  local recipeInfo = GetCachedRecipeInfo(recipeId)
  -- No recipe info (e.g. a stale recipeId in saved data after a game update):
  -- emit nothing rather than erroring on recipeInfo.name below.
  if not recipeInfo then return nil end
  local difficulty = difficultyByRecipe[recipeId]

  -- For Legion/BfA ranked recipes (which have previousRecipeID/nextRecipeID),
  -- skip ranks below the character's highest learned rank: in those expansions
  -- crafting always uses the highest known rank, so lower ones are noise.
  if WNTR_recipeToRank[recipeId]
      and (recipeInfo.previousRecipeID or recipeInfo.nextRecipeID) then
    local nextId = recipeInfo.nextRecipeID
    while nextId do
      if difficultyByRecipe[nextId] ~= nil then return nil end
      local nextInfo = GetCachedRecipeInfo(nextId)
      nextId = nextInfo and nextInfo.nextRecipeID
    end
  end

  -- "Next unlearned rank only": for ranked recipes the character hasn't learned,
  -- only show the immediate next rank after the highest learned rank.
  if WNTR_config.nextUnlearnedRankOnly
      and WNTR_recipeToRank[recipeId] and difficulty == nil then
    if recipeInfo.previousRecipeID or recipeInfo.nextRecipeID then
      -- Legion/BfA style: walk the previousRecipeID chain to find whether
      -- the immediately preceding rank is learned. If not, hide.
      local prevId = recipeInfo.previousRecipeID
      if prevId and difficultyByRecipe[prevId] == nil then return nil end
      -- If there is no previousRecipeID, this is rank 1 - always show it.
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
      if myRank ~= nextExpectedRank then return nil end
    end
  end

  local textColor = DifficultyToColor(difficulty)
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
  recipeLine.depth = depth or 1
  nextInsertionOrder = nextInsertionOrder + 1
  recipeLine.insertionOrder = nextInsertionOrder
  if WNTR_config.showUncollectedTransmog then
    if WNTR_recipeWithUncollectedTransmog[recipeId] then
      recipeLine.transmog = "unknown"
    elseif WNTR_recipeWithUncollectedTransmogItem[recipeId] then
      recipeLine.transmog = "item"
    end
  end
  return recipeLine
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
  -- Results are cached for the session; invalidated on sync via addon.InvalidateReagentCache().
  local isKnownReagent = reagentCache[reagentId]
  if isKnownReagent == nil then
    isKnownReagent = false
    for variantId, reagents in pairs(WNTR_reagentToRecipe) do
      if reagents[reagentId] then
        isKnownReagent = true
        break
      end
    end
    reagentCache[reagentId] = isKnownReagent
  end
  if not isKnownReagent then
    HideSecondTooltip()
    return
  end

  -- Collect lines to display (zero table allocations - all records from pool).
  wipe(collectedLines)
  ResetLinePool()
  nextInsertionOrder = 0
  local hasLines = false

  local titleLine = AcquireLineRecord()
  titleLine.text = "Who needs this reagent?"
  titleLine.kind = "title"
  tinsert(collectedLines, titleLine)

  -- Transitive-walk configuration (read once per tooltip build).
  local walkTransitive = WNTR_config.showTransitiveRecipeChains
  local includeOptional = WNTR_config.transitiveIncludeOptionalReagents
  local walkMaxDepth = walkTransitive and TRANSITIVE_REAGENT_MAX_DEPTH or 1

  -- Build (or fetch) the shared consumer tree once; every (character, variant)
  -- section below traverses this same tree with per-variant pruning.
  local consumerTree = GetConsumerTree(reagentId, includeOptional, walkMaxDepth)

  for realm, characters in pairs(WNTR_recipeToDifficulty) do
    for character, difficultiesByVariant in pairs(characters) do

      wipe(characterLines)

      for variantId, difficultyByRecipe in pairs(difficultiesByVariant) do
        local profVariantInfo = GetCachedProfInfo(variantId)
        local baseIdForIcon = profVariantInfo and profVariantInfo.parentProfessionID or variantId
        local profName = profVariantInfo and profVariantInfo.professionName
        if profName then
          local charLevels = WNTR_variantToSkillLevel[realm] and WNTR_variantToSkillLevel[realm][character]
          local skillLevel = charLevels and charLevels[variantId]
          local maxLevel = charLevels and charLevels["maxLevels"] and charLevels["maxLevels"][variantId]
          if skillLevel and maxLevel and maxLevel > 0 then
            profName = profName .. " (" .. skillLevel .. "/" .. maxLevel .. ")"
          end

          local sectionStart = #characterLines + 1  -- index for the profession header, prepended after content lands.

          -- Traverse the shared consumer tree, emitting one line per node on
          -- the current path.
          --   * Nodes in THIS variant become "recipe" lines (name, difficulty
          --     colour, transmog icon per BuildRecipeLine).
          --   * Nodes in another variant become "intermediate" lines, labelled
          --     with the produced item's name and the producing profession's
          --     icon - kept only if their subtree actually emits an own-recipe
          --     line (a breadcrumb is only useful if it leads somewhere).
          -- Branches whose subtree cannot contain this variant are skipped
          -- outright via the precomputed node.subVariants set. Returns true if
          -- this call emitted at least one own-recipe line, so a foreign
          -- caller can decide whether to keep its intermediate header.
          local emitTreeNodes
          emitTreeNodes = function(nodes, depth)
            local anyOwn = false
            for i = 1, #nodes do
              local node = nodes[i]

              if node.varId == variantId then
                -- Own recipe: emit unless the rank filters hide it. Recurse
                -- only when the line is actually shown AND deeper own recipes
                -- can exist - a rank-hidden line must not recurse, or its
                -- children would dangle under the previous visible line.
                -- No subtree is lost: all ranks of a chain share the same
                -- output item, so the visible rank's node carries the same
                -- children.
                local line = BuildRecipeLine(node.recipeId, difficultyByRecipe, profName, realm, character, skillLevel, maxLevel, depth)
                if line then
                  tinsert(characterLines, line)
                  anyOwn = true
                  if node.subVariants[variantId] then
                    if emitTreeNodes(node.children, depth + 1) then
                      anyOwn = true
                    end
                  end
                end

              elseif node.subVariants[variantId] then
                -- Foreign variant leading (possibly) to own recipes. Acquire
                -- the header first so its insertionOrder locks in BEFORE any
                -- lines the recursion adds (sort places header first). Only
                -- tinsert if the recursion actually produces an own-recipe
                -- line, otherwise the pooled record just goes unused this build.
                local itemName = GetCachedItemName(node.output)
                if itemName then
                  local varId = node.varId
                  local producerBaseId = WNTR_variantToBaseProfession[varId]
                  local charHasProducerBase = false
                  if producerBaseId then
                    for cvId in pairs(difficultiesByVariant) do
                      if WNTR_variantToBaseProfession[cvId] == producerBaseId then
                        charHasProducerBase = true
                        break
                      end
                    end
                  end
                  local color
                  if charHasProducerBase then
                    local producerDifficulty = difficultiesByVariant[varId] and difficultiesByVariant[varId][node.recipeId]
                    color = DifficultyToColor(producerDifficulty)
                  else
                    color = CORRUPTION_COLOR
                  end
                  local text = itemName
                  local producerIcon = producerBaseId and WNTR_professionSkillLineToIcon[producerBaseId]
                  if producerIcon then
                    text = text .. " |T" .. producerIcon .. ":14:14:0:0|t"
                  end
                  local headerLine = AcquireLineRecord()
                  headerLine.text = text
                  headerLine.kind = "intermediate"
                  headerLine.r = color.r
                  headerLine.g = color.g
                  headerLine.b = color.b
                  headerLine.profSortKey = profName
                  headerLine.depth = depth
                  nextInsertionOrder = nextInsertionOrder + 1
                  headerLine.insertionOrder = nextInsertionOrder

                  if emitTreeNodes(node.children, depth + 1) then
                    tinsert(characterLines, headerLine)
                    anyOwn = true
                  end
                end
              end
            end
            return anyOwn
          end
          emitTreeNodes(consumerTree, 1)

          -- If any lines landed for this variant, prepend the profession header.
          if #characterLines >= sectionStart then
            local profText = "|T" .. WNTR_professionSkillLineToIcon[baseIdForIcon] .. ":14:14:0:0|t " .. profName
            local profLine = AcquireLineRecord()
            profLine.text = profText
            profLine.kind = "profession"
            profLine.profSortKey = profName
            tinsert(characterLines, sectionStart, profLine)
          end
        end
      end

      -- Only add character block if it has at least one recipe.
      if #characterLines > 0 then
        sort(characterLines, sortLines)

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
      elseif currentBlockIdx > 0 and (kind == "profession" or kind == "recipe" or kind == "intermediate") then
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

      local kind = lineData.kind
      local indent = 0
      if kind == "recipe" or kind == "intermediate" then
        indent = RECIPE_INDENT + ((lineData.depth or 1) - 1) * SUB_RECIPE_INDENT
      end
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
      local lineData = collectedLines[idx]
      local kind = lineData.kind
      local indent = 0
      if kind == "recipe" or kind == "intermediate" then
        indent = RECIPE_INDENT + ((lineData.depth or 1) - 1) * SUB_RECIPE_INDENT
      end
      if kind == "character" then yOffset = yOffset - CHARACTER_PRE_SPACING end
      fontStringPool[idx]:SetPoint("TOPLEFT", tooltipFrame, "TOPLEFT", x + indent, yOffset)
      -- Uncollected transmog indicator: place icon in the indent space to the left of the recipe name.
      -- "unknown" = appearance not collected (full opacity).
      -- "item" = appearance collected but not from this item (semi-transparent).
      local transmog = lineData.transmog
      if transmog then
        local iconFs = AcquireFontString()
        iconFs:SetFontObject(GameTooltipText)
        iconFs:SetText("|A:Crosshair_Transmogrify_32:15:15|a")
        iconFs:SetAlpha(transmog == "item" and 0.5 or 1)
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


