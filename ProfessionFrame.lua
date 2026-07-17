local folderName, addon = ...

-- Hook the profession frame's recipe list to show transmog icons next to recipes
-- that produce items with uncollected appearances - directly, or (desaturated)
-- transitively via crafting chains through the recipe's product.
--
-- ProfessionsRecipeListRecipeMixin:Init() is called every time a recipe row is
-- recycled by the scroll box. We post-hook it to create/show/hide a small transmog
-- icon texture on each row button frame.
--
-- The recipe rows have very little space to the left of the Label font string,
-- so we shift SkillUps (and with it the anchored Label) to the right to make room.

-- When the open profession variant is maxed out, no recipe can show a skill-up
-- indicator, so the SkillUps column is empty on every row. In that case we
-- reclaim it: shift SkillUps (and with it the anchored Label) left so the
-- recipe names sit right next to our transmog icons, and widen the Label by
-- the same amount (its width was computed by Blizzard's Init for the original
-- position). Fine-tune here.
-- Geometry: our icon spans x -12..+2 (14 wide); the Label starts at
-- SkillUps.x + 30 (26 button width + 4 anchor offset). The normal shifted
-- position is SkillUps.x = 0 -> Label at 30. A left shift of 25 puts the
-- Label at 5, leaving a 3 px gap after the icon.
local MAXED_PROFESSION_LEFT_SHIFT = 25

-- True if the currently loaded profession variant is at its skill cap.
local function OpenVariantIsMaxed()
  local variantId = C_TradeSkillUI.GetProfessionChildSkillLineID()
  if not variantId or variantId == 0 then return false end
  local info = C_TradeSkillUI.GetProfessionInfoBySkillLineID(variantId)
  return info and info.maxSkillLevel and info.maxSkillLevel > 0
      and info.skillLevel >= info.maxSkillLevel or false
end

-- ProfessionsRecipeListRecipeMixin is defined in Blizzard_ProfessionsTemplates,
-- which is loaded on demand. Wait for it before hooking.
local function HookRecipeListInit()
  hooksecurefunc(ProfessionsRecipeListRecipeMixin, "Init", function(self, node)
    if not WNTR_config.uncollectedTransmogInProfessions then
      if self.WNTRTransmogIcon then self.WNTRTransmogIcon:Hide() end
      -- Restore SkillUps to original Blizzard position.
      local _, _, _, _, yOfs = self.SkillUps:GetPoint(1)
      self.SkillUps:ClearAllPoints()
      self.SkillUps:SetPoint("LEFT", self, "LEFT", -9, yOfs or 0)
      return
    end

    -- Shift SkillUps right to make room for our icon.
    -- Label is anchored to SkillUps:RIGHT, so it follows automatically.
    -- Use an absolute position rather than incrementing, because the original Init
    -- only resets the position when SkillUps is shown - so an increment would
    -- accumulate on recycled frames.
    -- Original Blizzard position: LEFT, self, LEFT, -9, yOfs (yOfs is 0 or 1).
    -- Maxed variant: reclaim the always-empty SkillUps column by shifting left
    -- (see MAXED_PROFESSION_LEFT_SHIFT above). The IsShown guard is a safety
    -- net: a visible skill-up indicator must never be shifted under our icon.
    local leftShift = 0
    if OpenVariantIsMaxed() and not self.SkillUps:IsShown() then
      leftShift = MAXED_PROFESSION_LEFT_SHIFT
    end
    local _, _, _, _, yOfs = self.SkillUps:GetPoint(1)
    self.SkillUps:ClearAllPoints()
    self.SkillUps:SetPoint("LEFT", self, "LEFT", -9 + 9 - leftShift, yOfs or 0)
    if leftShift > 0 then
      -- Blizzard's Init computed the Label width for the unshifted position:
      -- min(available space, natural string width). The shift frees the same
      -- amount of space on the right, so extend by it - again capped at the
      -- natural width, which also keeps the RIGHT-anchored Count snug for
      -- labels that already fit.
      self.Label:SetWidth(math.min(self.Label:GetWidth() + leftShift, self.Label:GetUnboundedStringWidth()))
    end

    -- All ranks of a recipe produce the same item appearance, so a direct
    -- lookup by recipeID is sufficient - no chain walk needed.
    local recipeId = node:GetData().recipeInfo.recipeID
    if not recipeId then
      if self.WNTRTransmogIcon then self.WNTRTransmogIcon:Hide() end
      return
    end

    -- Icon states (two independent visual channels, matching the tooltip):
    --   alpha:      full = appearance fully uncollected ("unknown"),
    --               0.5  = collected, but not from this item ("item").
    --   saturation: normal      = this recipe's own product,
    --               desaturated = transitive - the product only leads, through
    --                             crafting chains, to a recipe with an
    --                             uncollected appearance.
    -- Direct flags win over transitive; transitive lookup is gated on the
    -- "Show transitive recipe chains" option and cached in Helpers.lua.
    local transmogType
    local transitive = false
    if WNTR_recipeWithUncollectedTransmog[recipeId] then
      transmogType = "unknown"
    elseif WNTR_recipeWithUncollectedTransmogItem[recipeId] then
      transmogType = "item"
    elseif WNTR_config.showTransitiveRecipeChains then
      transmogType = addon.GetTransitiveTransmogState(recipeId)
      transitive = transmogType ~= nil
    end
    if not transmogType then
      if self.WNTRTransmogIcon then self.WNTRTransmogIcon:Hide() end
      return
    end

    -- Create the icon texture lazily on this row frame.
    if not self.WNTRTransmogIcon then
      local icon = self:CreateTexture(nil, "OVERLAY")
      icon:SetAtlas("Crosshair_Transmogrify_32")
      icon:SetSize(14, 14)
      self.WNTRTransmogIcon = icon
    end

    local icon = self.WNTRTransmogIcon
    icon:SetAlpha(transmogType == "item" and 0.5 or 1)
    -- Always set explicitly: rows are recycled, so a stale desaturation from a
    -- previous occupant must be cleared for direct icons.
    icon:SetDesaturated(transitive)
    icon:ClearAllPoints()

    -- Fixed column position for all icons, regardless of SkillUps visibility.
    icon:SetPoint("LEFT", self, "LEFT", -12, 1)

    icon:Show()
  end)
end

-- Force the profession frame's recipe list to re-initialize all visible recipe rows.
-- Called when the setting is toggled so icons appear/disappear immediately.
function addon.RefreshProfessionRecipeList()
  local pf = ProfessionsFrame
  if not pf or not pf:IsShown() then return end
  local craftingPage = pf.CraftingPage
  if not craftingPage then return end
  local recipeList = craftingPage.RecipeList
  if not recipeList then return end
  local scrollBox = recipeList.ScrollBox
  if not scrollBox then return end

  local hideCraftableCount = recipeList.hideCraftableCount
  scrollBox:ForEachFrame(function(frame)
    local node = frame.GetElementData and frame:GetElementData()
    -- Only re-init recipe rows (those with SkillUps), not categories or dividers.
    if node and frame.SkillUps then
      frame:Init(node, hideCraftableCount)
    end
  end)
end

if ProfessionsRecipeListRecipeMixin then
  HookRecipeListInit()
else
  local frame = CreateFrame("Frame")
  frame:RegisterEvent("ADDON_LOADED")
  frame:RegisterEvent("TRADE_SKILL_SHOW")
  frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "TRADE_SKILL_SHOW" or (event == "ADDON_LOADED" and (arg1 == "Blizzard_ProfessionsTemplates" or arg1 == "Blizzard_Professions" or arg1 == "Blizzard_ProfessionsCrafting")) then
      if ProfessionsRecipeListRecipeMixin then
        self:UnregisterAllEvents()
        HookRecipeListInit()
      end
    end
  end)
end
