local folderName, addon = ...

-- Cache of global WoW API tables/functions.
local C_TradeSkillUI_GetProfessionInfoBySkillLineID = _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID

local table_concat                                  = _G.table.concat
local tinsert                                       = _G.tinsert

-- Cache addon tables/functions.
local pendingBaseSkillLineIds = addon.pendingBaseSkillLineIds


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

    function plugin.OnTooltipShow(tt)
      tt:AddLine("Who Needs This Reagent?")
      if #pendingBaseSkillLineIds > 0 then
        local names = {}
        for _, profId in ipairs(pendingBaseSkillLineIds) do
          local info = C_TradeSkillUI_GetProfessionInfoBySkillLineID(profId)
          tinsert(names, info and info.professionName or tostring(profId))
        end
        tt:AddLine("Pending sync: " .. table_concat(names, ", "), 1, 0.5, 0)
      else
        tt:AddLine("All professions synced.", 0, 1, 0)
      end
      tt:AddLine(" ")
      tt:AddLine("Click to sync pending professions.", 0.2, 1, 0.2)
    end

    function plugin.OnClick(self, button)
      SyncPendingProfession(true)
    end

    -- Pulsating glow overlay to indicate pending professions.
    -- UpdateMinimapGlow() is called after every mutation of pendingBaseSkillLineIds.
    local glowTexture = nil
    local glowAnim = nil

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
        local minimapButton = icon:GetMinimapButton(folderName)
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
