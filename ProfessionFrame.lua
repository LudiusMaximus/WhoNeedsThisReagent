local folderName, addon = ...

-- Hook the profession frame's recipe list to show transmog icons next to recipes
-- that produce items with uncollected appearances.
--
-- ProfessionsRecipeListRecipeMixin:Init() is called every time a recipe row is
-- recycled by the scroll box. We post-hook it to create/show/hide a small transmog
-- icon texture on each row button frame.
--
-- The recipe rows have very little space to the left of the Label font string,
-- so we shift SkillUps (and with it the anchored Label) to the right to make room.

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
    -- only resets the position when SkillUps is shown — so an increment would
    -- accumulate on recycled frames.
    -- Original Blizzard position: LEFT, self, LEFT, -9, yOfs (yOfs is 0 or 1).
    local _, _, _, _, yOfs = self.SkillUps:GetPoint(1)
    self.SkillUps:ClearAllPoints()
    self.SkillUps:SetPoint("LEFT", self, "LEFT", -9 + 9, yOfs or 0)

    -- All ranks of a recipe produce the same item appearance, so a direct
    -- lookup by recipeID is sufficient — no chain walk needed.
    local recipeId = node:GetData().recipeInfo.recipeID
    if not recipeId then
      if self.WNTRTransmogIcon then self.WNTRTransmogIcon:Hide() end
      return
    end

    local transmogType
    if WNTR_recipeWithUncollectedTransmog[recipeId] then
      transmogType = "unknown"
    elseif WNTR_recipeWithUncollectedTransmogItem[recipeId] then
      transmogType = "item"
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
