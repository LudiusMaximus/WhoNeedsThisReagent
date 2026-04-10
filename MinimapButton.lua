local folderName, addon = ...

-- Locals for frequently used global frames and functions.
local GameTooltip_AddBlankLineToTooltip  = _G.GameTooltip_AddBlankLineToTooltip
local GameTooltip_AddErrorLine           = _G.GameTooltip_AddErrorLine
local GameTooltip_AddInstructionLine     = _G.GameTooltip_AddInstructionLine
local GameTooltip_AddNormalLine          = _G.GameTooltip_AddNormalLine
local GameTooltip_SetTitle               = _G.GameTooltip_SetTitle


-- Cache of global WoW API tables/functions.
local C_TradeSkillUI_GetProfessionInfoBySkillLineID = _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID

local tinsert                                       = _G.tinsert

-- Cache addon tables/functions.
local pendingBaseSkillLineIds = addon.pendingBaseSkillLineIds


-- Custom tooltip for settings menu entries.
local settingsTooltip = CreateFrame("GameTooltip", folderName .. "_SettingsTooltip", UIParent, "GameTooltipTemplate")
settingsTooltip:SetFrameStrata("TOOLTIP")
settingsTooltip:Hide()

local settingsTooltipHideTimer = nil

local function ShowSettingsTooltip(anchorFrame, title, text)
  if settingsTooltipHideTimer then
    settingsTooltipHideTimer:Cancel()
    settingsTooltipHideTimer = nil
  end
  local anchor = (anchorFrame:GetRight() or 0) > UIParent:GetWidth() / 2 and "ANCHOR_LEFT" or "ANCHOR_RIGHT"
  settingsTooltip:SetOwner(anchorFrame, anchor)
  settingsTooltip:ClearLines()
  GameTooltip_SetTitle(settingsTooltip, title)
  GameTooltip_AddNormalLine(settingsTooltip, text)
  settingsTooltip:Show()
end

local function HideSettingsTooltipDelayed()
  if settingsTooltipHideTimer then
    settingsTooltipHideTimer:Cancel()
  end
  settingsTooltipHideTimer = C_Timer.NewTimer(0.33, function()
    settingsTooltip:Hide()
    settingsTooltipHideTimer = nil
  end)
end

local function HideSettingsTooltipImmediately()
  if settingsTooltipHideTimer then
    settingsTooltipHideTimer:Cancel()
    settingsTooltipHideTimer = nil
  end
  settingsTooltip:Hide()
end


-- Minimap icon via LibDataBroker + LibDBIcon.
-- UpdateMinimapGlow is called after every mutation of pendingBaseSkillLineIds;
-- addon.UpdateMinimapGlow starts as a no-op (set in main.lua), overridden below if LDB is available.
do
  local ldb = LibStub("LibDataBroker-1.1", true)
  if ldb then
    local atlasInfo = C_Texture.GetAtlasInfo("Reagents")
    local plugin = ldb:NewDataObject(folderName, {
      type = "data source",
      text = "0",
      icon = atlasInfo and atlasInfo.file or "Interface\\Icons\\INV_Misc_QuestionMark",
      iconCoords = atlasInfo and {atlasInfo.leftTexCoord, atlasInfo.rightTexCoord, atlasInfo.topTexCoord, atlasInfo.bottomTexCoord} or nil,
    })

    function plugin.OnTooltipShow(tooltip)
      GameTooltip_SetTitle(tooltip, "Who Needs This Reagent?")
      GameTooltip_AddNormalLine(tooltip, "Shows in a reagent's tooltip which of your characters can use it for crafting. Holding down SHIFT while the tooltip is shown displays further information.", true)
      GameTooltip_AddBlankLineToTooltip(tooltip)
      GameTooltip_AddNormalLine(tooltip, "When this minimap button is glowing, a sync of profession data is required; e.g. after you learn a new recipe or skill up. We cannot sync automatically but you can trigger a sync by clicking this button (if enabled) or using the command of the addon's console message (if enabled).", true)
      if #pendingBaseSkillLineIds > 0 then
        GameTooltip_AddBlankLineToTooltip(tooltip)
        GameTooltip_AddErrorLine(tooltip, "The following professions need a sync:")
        for _, baseSkillLineId in ipairs(pendingBaseSkillLineIds) do
          GameTooltip_AddErrorLine(tooltip, "  - " .. C_TradeSkillUI_GetProfessionInfoBySkillLineID(baseSkillLineId).professionName)
        end
        GameTooltip_AddBlankLineToTooltip(tooltip)
        GameTooltip_AddInstructionLine(tooltip, "Left-click to sync pending professions.")
      else
        GameTooltip_AddBlankLineToTooltip(tooltip)
        GameTooltip_AddNormalLine(tooltip, "Currently all professions are synced!")
      end
      GameTooltip_AddBlankLineToTooltip(tooltip)
      GameTooltip_AddInstructionLine(tooltip, "Right-click for options.")
    end

    function plugin.OnClick(self, button)
      if button == "LeftButton" then
        if #pendingBaseSkillLineIds > 0 then
          SyncPendingProfession(true)
        end
      elseif button == "RightButton" then
        MenuUtil.CreateContextMenu(UIParent, function(_, menu)
          menu:CreateTitle("Who Needs This Reagent?")

          local cb, submenu

          submenu = menu:CreateButton("Sync Settings")
          submenu:SetOnEnter(function(frame, desc)
            HideSettingsTooltipImmediately()
            desc:ForceOpenSubmenu()
            ShowSettingsTooltip(frame, "Sync Settings", "Settings for chat messages related to profession syncing.")
          end)
          submenu:SetOnLeave(function() HideSettingsTooltipDelayed() end)

          submenu:CreateTitle("Sync Settings")

          cb = submenu:CreateCheckbox(
            "Pending sync messages",
            function() return WNTR_config.showPendingSyncMessages end,
            function() WNTR_config.showPendingSyncMessages = not WNTR_config.showPendingSyncMessages end
          )
          cb:SetOnEnter(function(frame)
            ShowSettingsTooltip(frame, "Pending sync messages", "Show a chat message listing professions that need synchronization, with a clickable link to start the sync.")
          end)
          cb:SetOnLeave(function() HideSettingsTooltipDelayed() end)

          cb = submenu:CreateCheckbox(
            "Status messages",
            function() return WNTR_config.showStatusMessages end,
            function() WNTR_config.showStatusMessages = not WNTR_config.showStatusMessages end
          )
          cb:SetOnEnter(function(frame)
            ShowSettingsTooltip(frame, "Status messages", "Show chat messages when a manually triggered background profession sync starts and completes.")
          end)
          cb:SetOnLeave(function() HideSettingsTooltipDelayed() end)

          submenu = menu:CreateButton("Tooltip Settings")
          submenu:SetOnEnter(function(frame, desc)
            HideSettingsTooltipImmediately()
            desc:ForceOpenSubmenu()
            ShowSettingsTooltip(frame, "Tooltip Settings", "Settings that affect the reagent tooltip display.")
          end)
          submenu:SetOnLeave(function() HideSettingsTooltipDelayed() end)

          submenu:CreateTitle("Tooltip Settings")

          cb = submenu:CreateCheckbox(
            "Next unlearned rank only",
            function() return WNTR_config.nextUnlearnedRankOnly end,
            function() WNTR_config.nextUnlearnedRankOnly = not WNTR_config.nextUnlearnedRankOnly end
          )
          cb:SetOnEnter(function(frame)
            ShowSettingsTooltip(frame, "Next unlearned rank only", "If a recipe has several ranks, only show the next rank you have not yet learned. E.g. if a recipe has 4 ranks and you know rank 2, only rank 3 is shown as unlearned while the also unlearned rank 4 is hidden.")
          end)
          cb:SetOnLeave(function() HideSettingsTooltipDelayed() end)

          cb = submenu:CreateCheckbox(
            "Uncollected transmog icon",
            function() return WNTR_config.showUncollectedTransmog end,
            function() WNTR_config.showUncollectedTransmog = not WNTR_config.showUncollectedTransmog end
          )
          cb:SetOnEnter(function(frame)
            ShowSettingsTooltip(frame, "Uncollected transmog icon", "Display a transmogrification icon next to recipes whose crafted item has an appearance you haven't collected yet. Semi-transparent if the appearance is known from a different item.")
          end)
          cb:SetOnLeave(function() HideSettingsTooltipDelayed() end)
        end)
      end
    end

    -- Pulsating glow overlay to indicate pending professions.
    -- UpdateMinimapGlow() is called after every mutation of pendingBaseSkillLineIds.
    local glowTexture = nil
    local glowAnim = nil
    local minimapButton = nil

    function addon.UpdateMinimapGlow()
      if not glowTexture then return end
      if #pendingBaseSkillLineIds > 0 then
        if not glowAnim:IsPlaying() then
          glowTexture:Show()
          glowAnim:Play()
        end
      else
        glowAnim:Stop()
        glowTexture:Hide()
      end
      -- Refresh the tooltip if the cursor is still over our minimap button.
      if minimapButton and minimapButton:IsMouseOver() then
        local onEnter = minimapButton:GetScript("OnEnter")
        if onEnter then onEnter(minimapButton) end
      end
    end

    local iconFrame = CreateFrame("Frame")
    iconFrame:SetScript("OnEvent", function()
      local icon = LibStub("LibDBIcon-1.0", true)
      if icon then
        icon:Register(folderName, plugin, WNTR_whoNeedsThisReagentIconDB)

        -- On first registration (no saved position), avoid overlapping other minimap icons.
        if not WNTR_whoNeedsThisReagentIconDB.minimapPos then
          local MIN_DISTANCE = 15  -- minimum degrees apart
          local occupied = {}
          for _, name in ipairs(icon:GetButtonList()) do
            if name ~= folderName then
              local btn = icon:GetMinimapButton(name)
              if btn then
                tinsert(occupied, (btn.db and btn.db.minimapPos) or btn.minimapPos or 225)
              end
            end
          end
          local function isTooClose(p)
            for _, o in ipairs(occupied) do
              local diff = math.abs(p - o)
              if diff > 180 then diff = 360 - diff end
              if diff < MIN_DISTANCE then return true end
            end
            return false
          end
          if isTooClose(225) then
            for offset = MIN_DISTANCE, 360 - MIN_DISTANCE, MIN_DISTANCE do
              local candidate = (225 + offset) % 360
              if not isTooClose(candidate) then
                WNTR_whoNeedsThisReagentIconDB.minimapPos = candidate
                icon:SetButtonToPosition(folderName, candidate)
                break
              end
              candidate = (225 - offset) % 360
              if not isTooClose(candidate) then
                WNTR_whoNeedsThisReagentIconDB.minimapPos = candidate
                icon:SetButtonToPosition(folderName, candidate)
                break
              end
            end
          end
        end

        -- Create the glow overlay on the minimap button.
        minimapButton = icon:GetMinimapButton(folderName)
        if minimapButton then
          glowTexture = minimapButton:CreateTexture(nil, "OVERLAY", nil, 1)
          -- Atlas "groupfinder-eye-highlight" as the glow texture.
          glowTexture:SetAtlas("groupfinder-eye-highlight")
          -- Size 1.2x so the glow bleeds slightly beyond the button edges.
          glowTexture:SetSize(minimapButton:GetWidth() * 1.1, minimapButton:GetHeight() * 1.1)
          glowTexture:ClearAllPoints()
          glowTexture:SetPoint("CENTER", minimapButton, "CENTER", 0, 1)
          glowTexture:SetVertexColor(1.0, 0.2, 0.2)
          glowTexture:SetBlendMode("ADD")
          glowTexture:Hide()

          -- Pulsating opacity animation (two-step REPEAT, matching Baganator's proven pattern).
          glowAnim = glowTexture:CreateAnimationGroup()
          glowAnim:SetLooping("REPEAT")
          local fadeIn = glowAnim:CreateAnimation("Alpha")
          fadeIn:SetFromAlpha(0)
          fadeIn:SetToAlpha(1)
          fadeIn:SetDuration(0.8)
          fadeIn:SetOrder(1)
          fadeIn:SetSmoothing("IN_OUT")
          local fadeOut = glowAnim:CreateAnimation("Alpha")
          fadeOut:SetFromAlpha(1)
          fadeOut:SetToAlpha(0)
          fadeOut:SetDuration(0.8)
          fadeOut:SetOrder(2)
          fadeOut:SetSmoothing("IN_OUT")
          glowTexture:SetAlpha(0)

          addon.UpdateMinimapGlow()
        end
      end
    end)
    iconFrame:RegisterEvent("PLAYER_LOGIN")
  end
end
