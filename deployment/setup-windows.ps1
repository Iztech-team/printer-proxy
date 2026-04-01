#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Baraka Printer Proxy -- Windows Setup Wizard

.DESCRIPTION
    GUI installer that sets up Python, dependencies, USB printers,
    firewall rules, and auto-start as a hidden background service.

.NOTES
    Run via the included setup.bat, or manually:
      powershell -ExecutionPolicy Bypass -File deployment\setup-windows.ps1
#>

$ErrorActionPreference = "Continue"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ProjectDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# --- Colors -----------------------------------------------------------------
$C_Bg          = [System.Drawing.ColorTranslator]::FromHtml("#0F1923")
$C_BgCard      = [System.Drawing.ColorTranslator]::FromHtml("#1A2733")
$C_BgCardHover = [System.Drawing.ColorTranslator]::FromHtml("#223344")
$C_HeaderTop   = [System.Drawing.ColorTranslator]::FromHtml("#00C896")
$C_HeaderBot   = [System.Drawing.ColorTranslator]::FromHtml("#00897B")
$C_Accent      = [System.Drawing.ColorTranslator]::FromHtml("#00E5A0")
$C_AccentHover = [System.Drawing.ColorTranslator]::FromHtml("#00CC8E")
$C_AccentDim   = [System.Drawing.ColorTranslator]::FromHtml("#00E5A0")
$C_Text        = [System.Drawing.Color]::White
$C_TextSub     = [System.Drawing.ColorTranslator]::FromHtml("#8899AA")
$C_TextDim     = [System.Drawing.ColorTranslator]::FromHtml("#556677")
$C_Green       = [System.Drawing.ColorTranslator]::FromHtml("#00E676")
$C_Amber       = [System.Drawing.ColorTranslator]::FromHtml("#FFAB40")
$C_Red         = [System.Drawing.ColorTranslator]::FromHtml("#FF5252")
$C_BarBg       = [System.Drawing.ColorTranslator]::FromHtml("#0D1520")
$C_BarFill     = [System.Drawing.ColorTranslator]::FromHtml("#00E5A0")
$C_Badge       = [System.Drawing.ColorTranslator]::FromHtml("#00C896")
$C_BadgeDone   = [System.Drawing.ColorTranslator]::FromHtml("#00E676")
$C_BadgeErr    = [System.Drawing.ColorTranslator]::FromHtml("#FF5252")
$C_Separator   = [System.Drawing.ColorTranslator]::FromHtml("#1E3040")

# --- Fonts ------------------------------------------------------------------
$F_Hero     = New-Object System.Drawing.Font("Segoe UI Light", 26)
$F_HeroSub  = New-Object System.Drawing.Font("Segoe UI", 11)
$F_StepNum  = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$F_StepName = New-Object System.Drawing.Font("Segoe UI Semibold", 11)
$F_Detail   = New-Object System.Drawing.Font("Segoe UI", 9)
$F_Btn      = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
$F_BtnSm    = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$F_Mono     = New-Object System.Drawing.Font("Cascadia Mono,Consolas", 9.5)
$F_Body     = New-Object System.Drawing.Font("Segoe UI", 10)
$F_Big      = New-Object System.Drawing.Font("Segoe UI Light", 20)
$F_Status   = New-Object System.Drawing.Font("Segoe UI", 8.5)

# ============================================================================
# FORM
# ============================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text            = "Baraka Printer Proxy"
$form.ClientSize      = New-Object System.Drawing.Size(740, 620)
$form.StartPosition   = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox     = $false
$form.BackColor       = $C_Bg
$form.ForeColor       = $C_Text
$form.Icon            = [System.Drawing.SystemIcons]::Application

# ============================================================================
# HEADER -- gradient painted panel
# ============================================================================
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock   = "Top"
$headerPanel.Height = 100

$headerPanel.Add_Paint({
    param($s, $e)
    $rect = $s.ClientRectangle
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect, $C_HeaderTop, $C_HeaderBot,
        [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal
    )
    $e.Graphics.FillRectangle($brush, $rect)
    $brush.Dispose()

    # Title
    $tf = New-Object System.Drawing.Font("Segoe UI Light", 24)
    $e.Graphics.DrawString("Baraka Printer Proxy", $tf, [System.Drawing.Brushes]::White, 28, 16)
    $tf.Dispose()

    # Subtitle
    $sf = New-Object System.Drawing.Font("Segoe UI", 10)
    $subBrush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml("#C8FFF0"))
    $e.Graphics.DrawString("Windows Installation Wizard", $sf, $subBrush, 32, 56)
    $sf.Dispose()
    $subBrush.Dispose()

    # Decorative line
    $linePen = New-Object System.Drawing.Pen([System.Drawing.ColorTranslator]::FromHtml("#00FFB0"), 2)
    $e.Graphics.DrawLine($linePen, 30, 82, 200, 82)
    $linePen.Dispose()
})

$form.Controls.Add($headerPanel)

# ============================================================================
# FOOTER
# ============================================================================
$footerPanel = New-Object System.Windows.Forms.Panel
$footerPanel.Dock      = "Bottom"
$footerPanel.Height    = 30
$footerPanel.BackColor = $C_BgCard

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text      = "Ready"
$statusLabel.Font      = $F_Status
$statusLabel.ForeColor = $C_TextDim
$statusLabel.AutoSize  = $true
$statusLabel.Location  = New-Object System.Drawing.Point(14, 7)
$statusLabel.BackColor = [System.Drawing.Color]::Transparent

$footerPanel.Controls.Add($statusLabel)
$form.Controls.Add($footerPanel)

# ============================================================================
# CONTENT
# ============================================================================
$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Dock      = "Fill"
$contentPanel.BackColor = $C_Bg
$form.Controls.Add($contentPanel)

# ============================================================================
# WELCOME VIEW
# ============================================================================
$welcomePanel = New-Object System.Windows.Forms.Panel
$welcomePanel.Dock      = "Fill"
$welcomePanel.BackColor = $C_Bg

# Welcome card
$welcomeCard = New-Object System.Windows.Forms.Panel
$welcomeCard.Location  = New-Object System.Drawing.Point(40, 30)
$welcomeCard.Size      = New-Object System.Drawing.Size(660, 300)
$welcomeCard.BackColor = $C_BgCard

$wcText = New-Object System.Windows.Forms.Label
$wcText.Text = "This wizard will configure everything automatically:`r`n`r`n    1    Python 3 runtime`r`n    2    Virtual environment and packages`r`n    3    USB thermal printer detection`r`n    4    Windows Firewall rule (port 3006)`r`n    5    Auto-start background service`r`n`r`nOnce complete, the proxy server starts at login`r`nand runs silently in the background."
$wcText.Font      = $F_Body
$wcText.ForeColor = $C_TextSub
$wcText.Location  = New-Object System.Drawing.Point(32, 24)
$wcText.Size      = New-Object System.Drawing.Size(600, 260)
$wcText.BackColor = [System.Drawing.Color]::Transparent

$welcomeCard.Controls.Add($wcText)
$welcomePanel.Controls.Add($welcomeCard)

# Install button
$installBtn = New-Object System.Windows.Forms.Button
$installBtn.Text      = "BEGIN SETUP"
$installBtn.Font      = $F_Btn
$installBtn.Size      = New-Object System.Drawing.Size(260, 54)
$installBtn.Location  = New-Object System.Drawing.Point(240, 370)
$installBtn.FlatStyle = "Flat"
$installBtn.FlatAppearance.BorderSize = 0
$installBtn.BackColor = $C_Accent
$installBtn.ForeColor = $C_Bg
$installBtn.Cursor    = [System.Windows.Forms.Cursors]::Hand
$installBtn.Add_MouseEnter({ $this.BackColor = $C_AccentHover })
$installBtn.Add_MouseLeave({ $this.BackColor = $C_Accent })

$welcomePanel.Controls.Add($installBtn)
$contentPanel.Controls.Add($welcomePanel)

# ============================================================================
# PROGRESS VIEW
# ============================================================================
$progressPanel = New-Object System.Windows.Forms.Panel
$progressPanel.Dock      = "Fill"
$progressPanel.BackColor = $C_Bg
$progressPanel.Visible   = $false
$contentPanel.Controls.Add($progressPanel)

$script:stepControls = @{}

function New-StepPanel {
    param([int]$Index, [string]$StepTitle, [string]$StepDesc)

    $y = 16 + ($Index - 1) * 86

    # Main card
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location  = New-Object System.Drawing.Point(30, $y)
    $panel.Size      = New-Object System.Drawing.Size(680, 74)
    $panel.BackColor = $C_BgCard

    # Number badge (custom painted circle)
    $badge = New-Object System.Windows.Forms.Panel
    $badge.Location  = New-Object System.Drawing.Point(16, 17)
    $badge.Size      = New-Object System.Drawing.Size(40, 40)
    $badge.BackColor = [System.Drawing.Color]::Transparent

    # Paint handler is added after all panels are created (with .GetNewClosure())

    # Title
    $titleLbl = New-Object System.Windows.Forms.Label
    $titleLbl.Text      = $StepTitle
    $titleLbl.Font      = $F_StepName
    $titleLbl.ForeColor = $C_Text
    $titleLbl.Location  = New-Object System.Drawing.Point(68, 12)
    $titleLbl.Size      = New-Object System.Drawing.Size(300, 22)
    $titleLbl.BackColor = [System.Drawing.Color]::Transparent

    # Detail
    $detail = New-Object System.Windows.Forms.Label
    $detail.Text      = "Waiting..."
    $detail.Font      = $F_Detail
    $detail.ForeColor = $C_TextDim
    $detail.Location  = New-Object System.Drawing.Point(68, 38)
    $detail.Size      = New-Object System.Drawing.Size(380, 24)
    $detail.BackColor = [System.Drawing.Color]::Transparent

    # Custom progress bar (owner-drawn panel)
    $progPanel = New-Object System.Windows.Forms.Panel
    $progPanel.Location  = New-Object System.Drawing.Point(470, 28)
    $progPanel.Size      = New-Object System.Drawing.Size(190, 18)
    $progPanel.BackColor = [System.Drawing.Color]::Transparent
    $progPanel.Tag       = 0  # Store progress value in Tag
    # Paint handler is added after all panels are created (with .GetNewClosure())

    $panel.Controls.Add($badge)
    $panel.Controls.Add($titleLbl)
    $panel.Controls.Add($detail)
    $panel.Controls.Add($progPanel)

    $script:stepControls[$Index] = @{
        Panel    = $panel
        Badge    = $badge
        Title    = $titleLbl
        Detail   = $detail
        ProgBar  = $progPanel
    }

    return $panel
}

$progressPanel.Controls.Add((New-StepPanel -Index 1 -StepTitle "Python Runtime"       -StepDesc "Detect or install Python 3"))
$progressPanel.Controls.Add((New-StepPanel -Index 2 -StepTitle "Dependencies"          -StepDesc "Virtual environment and packages"))
$progressPanel.Controls.Add((New-StepPanel -Index 3 -StepTitle "USB Printers"          -StepDesc "Detect and register devices"))
$progressPanel.Controls.Add((New-StepPanel -Index 4 -StepTitle "Firewall"              -StepDesc "Allow port 3006"))
$progressPanel.Controls.Add((New-StepPanel -Index 5 -StepTitle "Auto-Start Service"    -StepDesc "Background service at login"))

# Overall progress label
$overallLabel = New-Object System.Windows.Forms.Label
$overallLabel.Text      = "Installing..."
$overallLabel.Font      = $F_Body
$overallLabel.ForeColor = $C_TextSub
$overallLabel.Location  = New-Object System.Drawing.Point(30, 454)
$overallLabel.Size      = New-Object System.Drawing.Size(680, 24)
$overallLabel.TextAlign = "MiddleCenter"
$overallLabel.BackColor = [System.Drawing.Color]::Transparent
$progressPanel.Controls.Add($overallLabel)

# ============================================================================
# COMPLETION VIEW
# ============================================================================
$completePanel = New-Object System.Windows.Forms.Panel
$completePanel.Dock      = "Fill"
$completePanel.BackColor = $C_Bg
$completePanel.Visible   = $false
$contentPanel.Controls.Add($completePanel)

# Completion header card
$doneCard = New-Object System.Windows.Forms.Panel
$doneCard.Location  = New-Object System.Drawing.Point(40, 20)
$doneCard.Size      = New-Object System.Drawing.Size(660, 100)
$doneCard.BackColor = $C_BgCard

$doneCard.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = "AntiAlias"
    $bgBrush = New-Object System.Drawing.SolidBrush($C_BgCard)
    $e.Graphics.FillRectangle($bgBrush, $s.ClientRectangle)
    $bgBrush.Dispose()
    # Left accent bar
    $accentBrush = New-Object System.Drawing.SolidBrush($C_Green)
    $e.Graphics.FillRectangle($accentBrush, 0, 0, 4, $s.Height)
    $accentBrush.Dispose()
})

$doneTitle = New-Object System.Windows.Forms.Label
$doneTitle.Font      = $F_Big
$doneTitle.ForeColor = $C_Text
$doneTitle.Location  = New-Object System.Drawing.Point(24, 14)
$doneTitle.Size      = New-Object System.Drawing.Size(620, 36)
$doneTitle.BackColor = [System.Drawing.Color]::Transparent

$doneSub = New-Object System.Windows.Forms.Label
$doneSub.Font      = $F_Body
$doneSub.ForeColor = $C_TextSub
$doneSub.Location  = New-Object System.Drawing.Point(24, 56)
$doneSub.Size      = New-Object System.Drawing.Size(620, 36)
$doneSub.BackColor = [System.Drawing.Color]::Transparent

$doneCard.Controls.Add($doneTitle)
$doneCard.Controls.Add($doneSub)
$completePanel.Controls.Add($doneCard)

# URL card
$urlCard = New-Object System.Windows.Forms.Panel
$urlCard.Location  = New-Object System.Drawing.Point(40, 140)
$urlCard.Size      = New-Object System.Drawing.Size(660, 140)
$urlCard.BackColor = $C_BgCard

$urlTitle = New-Object System.Windows.Forms.Label
$urlTitle.Text      = "SERVER ENDPOINTS"
$urlTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$urlTitle.ForeColor = $C_TextDim
$urlTitle.Location  = New-Object System.Drawing.Point(20, 12)
$urlTitle.AutoSize  = $true
$urlTitle.BackColor = [System.Drawing.Color]::Transparent

$urlBox = New-Object System.Windows.Forms.TextBox
$urlBox.Font        = $F_Mono
$urlBox.BackColor   = $C_Bg
$urlBox.ForeColor   = $C_Accent
$urlBox.Location    = New-Object System.Drawing.Point(20, 38)
$urlBox.Size        = New-Object System.Drawing.Size(620, 90)
$urlBox.Multiline   = $true
$urlBox.ReadOnly    = $true
$urlBox.BorderStyle = "None"
$urlBox.Text        = "  Server    http://localhost:3006`r`n  Health    http://localhost:3006/api/health`r`n  Swagger   http://localhost:3006/docs`r`n  Test      http://localhost:3006/"

$urlCard.Controls.Add($urlTitle)
$urlCard.Controls.Add($urlBox)
$completePanel.Controls.Add($urlCard)

# Detail card (for warnings/errors)
$detailCard = New-Object System.Windows.Forms.Panel
$detailCard.Location  = New-Object System.Drawing.Point(40, 300)
$detailCard.Size      = New-Object System.Drawing.Size(660, 80)
$detailCard.BackColor = $C_BgCard
$detailCard.Visible   = $false

$detailText = New-Object System.Windows.Forms.Label
$detailText.Font      = $F_Detail
$detailText.ForeColor = $C_TextSub
$detailText.Location  = New-Object System.Drawing.Point(20, 10)
$detailText.Size      = New-Object System.Drawing.Size(620, 60)
$detailText.BackColor = [System.Drawing.Color]::Transparent

$detailCard.Controls.Add($detailText)
$completePanel.Controls.Add($detailCard)

# Buttons
$openBtn = New-Object System.Windows.Forms.Button
$openBtn.Text      = "OPEN TEST PAGE"
$openBtn.Font      = $F_BtnSm
$openBtn.Size      = New-Object System.Drawing.Size(200, 46)
$openBtn.Location  = New-Object System.Drawing.Point(190, 410)
$openBtn.FlatStyle = "Flat"
$openBtn.FlatAppearance.BorderSize = 0
$openBtn.BackColor = $C_Accent
$openBtn.ForeColor = $C_Bg
$openBtn.Cursor    = [System.Windows.Forms.Cursors]::Hand
$openBtn.Add_MouseEnter({ $this.BackColor = $C_AccentHover })
$openBtn.Add_MouseLeave({ $this.BackColor = $C_Accent })
$openBtn.Add_Click({ Start-Process "http://localhost:3006/" })

$closeBtn = New-Object System.Windows.Forms.Button
$closeBtn.Text      = "CLOSE"
$closeBtn.Font      = $F_BtnSm
$closeBtn.Size      = New-Object System.Drawing.Size(160, 46)
$closeBtn.Location  = New-Object System.Drawing.Point(410, 410)
$closeBtn.FlatStyle = "Flat"
$closeBtn.FlatAppearance.BorderSize = 1
$closeBtn.FlatAppearance.BorderColor = $C_TextDim
$closeBtn.BackColor = $C_Bg
$closeBtn.ForeColor = $C_Text
$closeBtn.Cursor    = [System.Windows.Forms.Cursors]::Hand
$closeBtn.Add_MouseEnter({ $this.BackColor = $C_BgCard })
$closeBtn.Add_MouseLeave({ $this.BackColor = $C_Bg })
$closeBtn.Add_Click({ $form.Close() })

$completePanel.Controls.Add($openBtn)
$completePanel.Controls.Add($closeBtn)

# ============================================================================
# STEP STATE HELPERS
# ============================================================================
function Set-StepState {
    param([int]$Step, [string]$State, [string]$Detail)

    $c = $script:stepControls[$Step]
    switch ($State) {
        "running" {
            $c.Detail.ForeColor = $C_Accent
            $c.Panel.BackColor  = $C_BgCardHover
            $c.ProgBar.Tag = 0
            $c.ProgBar.Invalidate()
            # Repaint badge as running (accent color)
            $c.Badge.Tag = "running"
            $c.Badge.Invalidate()
        }
        "success" {
            $c.Detail.ForeColor = $C_Green
            $c.Panel.BackColor  = $C_BgCard
            $c.ProgBar.Tag = 100
            $c.ProgBar.Invalidate()
            $c.Badge.Tag = "success"
            $c.Badge.Invalidate()
        }
        "warning" {
            $c.Detail.ForeColor = $C_Amber
            $c.Panel.BackColor  = $C_BgCard
            $c.ProgBar.Tag = 100
            $c.ProgBar.Invalidate()
            $c.Badge.Tag = "warning"
            $c.Badge.Invalidate()
        }
        "error" {
            $c.Detail.ForeColor = $C_Red
            $c.Panel.BackColor  = $C_BgCard
            $c.ProgBar.Tag = 100
            $c.ProgBar.Invalidate()
            $c.Badge.Tag = "error"
            $c.Badge.Invalidate()
        }
        "skipped" {
            $c.Detail.ForeColor = $C_TextDim
            $c.Panel.BackColor  = $C_BgCard
            $c.ProgBar.Tag = 0
            $c.ProgBar.Invalidate()
            $c.Badge.Tag = "skipped"
            $c.Badge.Invalidate()
        }
    }
    if ($Detail) { $c.Detail.Text = $Detail }
}

# Repaint badges to reflect state via Tag
foreach ($idx in 1..5) {
    $ctrl = $script:stepControls[$idx]
    $badgeNum = $idx
    $ctrl.Badge.Add_Paint({
        param($s, $e)
        $e.Graphics.SmoothingMode = "AntiAlias"
        $state = $s.Tag
        $bColor = $C_Badge
        $txt = $badgeNum.ToString()
        if ($state -eq "running")  { $bColor = $C_Accent }
        if ($state -eq "success")  { $bColor = $C_BadgeDone; $txt = "+" }
        if ($state -eq "warning")  { $bColor = $C_Amber;     $txt = "!" }
        if ($state -eq "error")    { $bColor = $C_BadgeErr;   $txt = "X" }
        if ($state -eq "skipped")  { $bColor = $C_TextDim;    $txt = "-" }

        $br = New-Object System.Drawing.SolidBrush($bColor)
        $e.Graphics.FillEllipse($br, 0, 0, 38, 38)
        $br.Dispose()
        $nf = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = "Center"
        $sf.LineAlignment = "Center"
        $rc = New-Object System.Drawing.RectangleF(0, 0, 38, 38)
        $e.Graphics.DrawString($txt, $nf, [System.Drawing.Brushes]::White, $rc, $sf)
        $nf.Dispose()
        $sf.Dispose()
    }.GetNewClosure())
}

# Also make the progress bar color reflect state
foreach ($idx in 1..5) {
    $ctrl = $script:stepControls[$idx]
    # Remove default paint handler and add stateful one
    $ctrl.ProgBar.Add_Paint({
        param($s, $e)
        $e.Graphics.SmoothingMode = "AntiAlias"
        $w = $s.Width
        $h = $s.Height
        $val = [int]$s.Tag

        # Background track
        $bgBrush = New-Object System.Drawing.SolidBrush($C_BarBg)
        $bgPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $r = $h / 2
        $bgPath.AddArc(0, 0, $h, $h, 90, 180)
        $bgPath.AddArc($w - $h, 0, $h, $h, 270, 180)
        $bgPath.CloseFigure()
        $e.Graphics.FillPath($bgBrush, $bgPath)
        $bgBrush.Dispose()
        $bgPath.Dispose()

        if ($val -gt 0) {
            $fillW = [math]::Max($h, [int]($w * $val / 100))
            $fillColor = $C_BarFill
            $parentBadge = $s.Parent.Controls[0]
            if ($parentBadge.Tag -eq "warning") { $fillColor = $C_Amber }
            if ($parentBadge.Tag -eq "error")   { $fillColor = $C_Red }
            $fillBrush = New-Object System.Drawing.SolidBrush($fillColor)
            $fillPath = New-Object System.Drawing.Drawing2D.GraphicsPath
            $fillPath.AddArc(0, 0, $h, $h, 90, 180)
            $fillPath.AddArc($fillW - $h, 0, $h, $h, 270, 180)
            $fillPath.CloseFigure()
            $e.Graphics.FillPath($fillBrush, $fillPath)
            $fillBrush.Dispose()
            $fillPath.Dispose()
        }
    }.GetNewClosure())
}

# ============================================================================
# SHARED STATE
# ============================================================================
$script:currentStep = 0
$script:stepResults = @(0, "pending", "pending", "pending", "pending", "pending")
$script:warnings = @()
$script:errors = @()
$script:pythonCmd = $null
$script:venvPython = $null

$script:sync = [hashtable]::Synchronized(@{
    Status   = ""
    Detail   = ""
    Progress = 0
    Done     = $false
    Result   = ""
    Error    = ""
    Data     = @{}
})

$script:pollTimer = New-Object System.Windows.Forms.Timer
$script:pollTimer.Interval = 150

# ============================================================================
# STEP RUNNER
# ============================================================================
function Start-Step {
    param([scriptblock]$Code, [hashtable]$Vars = @{})

    $script:sync.Status   = ""
    $script:sync.Detail   = ""
    $script:sync.Progress = 0
    $script:sync.Done     = $false
    $script:sync.Result   = ""
    $script:sync.Error    = ""
    $script:sync.Data     = @{}

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync", $script:sync)
    $runspace.SessionStateProxy.SetVariable("ProjectDir", $ProjectDir)
    foreach ($k in $Vars.Keys) {
        $runspace.SessionStateProxy.SetVariable($k, $Vars[$k])
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $ps.AddScript($Code) | Out-Null
    $script:currentHandle = $ps.BeginInvoke()
    $script:currentPS = $ps
    $script:currentRunspace = $runspace

    $script:pollTimer.Start()
}

$script:pollTimer.Add_Tick({
    $s = $script:sync
    $step = $script:currentStep
    $c = $script:stepControls[$step]

    if ($s.Detail) { $c.Detail.Text = $s.Detail }
    if ($s.Status) { $statusLabel.Text = $s.Status }
    if ($s.Progress -ge 0 -and $s.Progress -le 100) {
        $c.ProgBar.Tag = [math]::Min(100, [math]::Max(0, $s.Progress))
        $c.ProgBar.Invalidate()
    }

    $overallLabel.Text = "Step $step of 5: $($c.Title.Text)..."

    if ($s.Done) {
        $script:pollTimer.Stop()

        try {
            $script:currentPS.EndInvoke($script:currentHandle)
            $script:currentPS.Dispose()
            $script:currentRunspace.Close()
        } catch { }

        $script:stepResults[$step] = $s.Result

        switch ($s.Result) {
            "success" { Set-StepState -Step $step -State "success" -Detail $s.Detail }
            "warning" {
                Set-StepState -Step $step -State "warning" -Detail $s.Detail
                $script:warnings += $s.Detail
            }
            "error" {
                Set-StepState -Step $step -State "error" -Detail $s.Detail
                $script:errors += $s.Detail
            }
        }

        if ($s.Data.PythonCmd)     { $script:pythonCmd = $s.Data.PythonCmd }
        if ($s.Data.VenvPython)    { $script:venvPython = $s.Data.VenvPython }
        if ($s.Data.RefreshedPath) { $env:Path = $s.Data.RefreshedPath }

        Start-NextStep
    }
})

function Start-NextStep {
    $script:currentStep++

    if ($script:currentStep -gt 5) { Show-Completion; return }

    # Step 2 depends on Step 1
    if ($script:currentStep -eq 2 -and $script:stepResults[1] -eq "error") {
        Set-StepState -Step 2 -State "skipped" -Detail "Skipped: Python not available"
        $script:stepResults[2] = "error"
        $script:errors += "Skipped: no Python runtime"
        $script:currentStep++
    }

    # Step 5 depends on Step 2
    if ($script:currentStep -eq 5 -and $script:stepResults[2] -eq "error") {
        Set-StepState -Step 5 -State "skipped" -Detail "Skipped: No virtual environment"
        $script:stepResults[5] = "error"
        $script:errors += "Skipped: no virtual environment"
        Show-Completion; return
    }

    if ($script:currentStep -gt 5) { Show-Completion; return }

    Set-StepState -Step $script:currentStep -State "running" -Detail "Starting..."

    switch ($script:currentStep) {
        1 { Run-Step1-Python }
        2 { Run-Step2-Venv }
        3 { Run-Step3-Printers }
        4 { Run-Step4-Firewall }
        5 { Run-Step5-Service }
    }
}

function Show-Completion {
    $progressPanel.Visible = $false
    $completePanel.Visible = $true

    $hasErrors   = $script:errors.Count -gt 0
    $hasWarnings = $script:warnings.Count -gt 0

    if ($hasErrors) {
        $doneTitle.Text = "Setup Completed with Errors"
        $doneTitle.ForeColor = $C_Red
        $doneSub.Text = "Some steps could not be completed."
        $doneCard.Add_Paint({
            param($s, $e)
            $br = New-Object System.Drawing.SolidBrush($C_Red)
            $e.Graphics.FillRectangle($br, 0, 0, 4, $s.Height)
            $br.Dispose()
        })
        $detailCard.Visible = $true
        $msgs = ""
        foreach ($e in $script:errors) { $msgs += "  - $e`r`n" }
        if ($hasWarnings) { foreach ($w in $script:warnings) { $msgs += "  - $w`r`n" } }
        $detailText.Text = $msgs
        $detailText.ForeColor = $C_Red
    } elseif ($hasWarnings) {
        $doneTitle.Text = "Setup Complete"
        $doneTitle.ForeColor = $C_Amber
        $doneSub.Text = "Server is running. Some items need attention."
        $doneCard.Add_Paint({
            param($s, $e)
            $br = New-Object System.Drawing.SolidBrush($C_Amber)
            $e.Graphics.FillRectangle($br, 0, 0, 4, $s.Height)
            $br.Dispose()
        })
        $detailCard.Visible = $true
        $msgs = ""
        foreach ($w in $script:warnings) { $msgs += "  - $w`r`n" }
        $detailText.Text = $msgs
        $detailText.ForeColor = $C_Amber
    } else {
        $doneTitle.Text = "Setup Complete"
        $doneTitle.ForeColor = $C_Green
        $doneSub.Text = "Server is running and will auto-start at login."
    }

    $doneCard.Invalidate()
    $statusLabel.Text = "Done"
}

# ============================================================================
# STEP 1: Python Detection / Install
# ============================================================================
function Run-Step1-Python {
    Start-Step -Code {
        $ErrorActionPreference = "Continue"
        $sync.Detail = "Searching for Python..."
        $sync.Status = "Checking Python installation..."
        $sync.Progress = 10

        $foundCmd = $null
        foreach ($cmd in @("python", "python3", "py")) {
            try {
                $output = & $cmd --version 2>&1
                $verString = $output | Out-String
                if ($verString -match "Python (3\.\d+)") {
                    $pythonPath = (Get-Command $cmd -ErrorAction SilentlyContinue).Source
                    if ($pythonPath -and $pythonPath -match "WindowsApps") {
                        $sync.Detail = "Skipping Microsoft Store Python..."
                        continue
                    }
                    $foundCmd = $cmd
                    $sync.Detail = "Found Python $($Matches[1]) ($cmd)"
                    $sync.Progress = 100
                    break
                }
            } catch { }
        }

        if ($foundCmd) {
            $sync.Data.PythonCmd = $foundCmd
            $sync.Result = "success"
            $sync.Done = $true
            return
        }

        $sync.Detail = "Python not found. Installing..."
        $sync.Progress = 20
        $installed = $false

        $wingetAvailable = Get-Command winget -ErrorAction SilentlyContinue
        if ($wingetAvailable) {
            $sync.Detail = "Installing Python via winget..."
            $sync.Status = "Installing Python via winget..."
            $sync.Progress = 30
            try {
                $out = winget install Python.Python.3.12 --accept-package-agreements --accept-source-agreements --silent 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $installed = $true
                    $sync.Detail = "Python installed via winget"
                    $sync.Progress = 70
                }
            } catch { }
        }

        if (-not $installed) {
            $sync.Detail = "Downloading Python from python.org..."
            $sync.Status = "Downloading Python installer..."
            $sync.Progress = 30
            $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "win32" }
            $installerUrl = "https://www.python.org/ftp/python/3.12.8/python-3.12.8-$arch.exe"
            $installerPath = Join-Path $env:TEMP "python-installer.exe"
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
                $sync.Detail = "Running Python installer..."
                $sync.Status = "Installing Python..."
                $sync.Progress = 60
                $proc = Start-Process -FilePath $installerPath -ArgumentList `
                    "/quiet", "InstallAllUsers=1", "PrependPath=1", "Include_pip=1", "Include_launcher=1" `
                    -Wait -NoNewWindow -PassThru
                if ($proc.ExitCode -eq 0) {
                    $installed = $true
                    $sync.Progress = 80
                }
                Remove-Item $installerPath -ErrorAction SilentlyContinue
            } catch {
                $sync.Detail = "Download failed: $($_.Exception.Message)"
            }
        }

        if ($installed) {
            $newPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            $commonPaths = @(
                "$env:ProgramFiles\Python312",
                "$env:ProgramFiles\Python312\Scripts",
                "$env:LocalAppData\Programs\Python\Python312",
                "$env:LocalAppData\Programs\Python\Python312\Scripts"
            )
            foreach ($p in $commonPaths) {
                if ((Test-Path $p) -and ($newPath -notlike "*$p*")) {
                    $newPath = "$p;$newPath"
                }
            }
            $env:Path = $newPath
            $sync.Data.RefreshedPath = $newPath

            $sync.Detail = "Verifying Python..."
            $sync.Progress = 90

            foreach ($cmd in @("python", "python3", "py")) {
                try {
                    $output = & $cmd --version 2>&1
                    $verString = $output | Out-String
                    if ($verString -match "Python 3\.\d+") {
                        $foundCmd = $cmd
                        $sync.Detail = "Installed: $($verString.Trim())"
                        break
                    }
                } catch { }
            }
        }

        if ($foundCmd) {
            $sync.Data.PythonCmd = $foundCmd
            $sync.Progress = 100
            $sync.Result = "success"
        } else {
            $sync.Detail = "Failed. Install from python.org manually."
            $sync.Result = "error"
        }
        $sync.Done = $true
    }
}

# ============================================================================
# STEP 2: Virtual Environment & Dependencies
# ============================================================================
function Run-Step2-Venv {
    $pyCmd = $script:pythonCmd
    Start-Step -Code {
        $ErrorActionPreference = "Continue"
        $VenvDir = Join-Path $ProjectDir "venv"
        $VenvPython = Join-Path $VenvDir "Scripts\python.exe"
        $cmd = $pyCmd

        $sync.Detail = "Checking virtual environment..."
        $sync.Status = "Setting up virtual environment..."
        $sync.Progress = 5

        if (Test-Path $VenvDir) {
            if (Test-Path $VenvPython) {
                try {
                    $venvVer = & $VenvPython --version 2>&1 | Out-String
                    $sysVer = & $cmd --version 2>&1 | Out-String
                    if ($venvVer.Trim() -ne $sysVer.Trim()) {
                        $sync.Detail = "Recreating venv (version mismatch)..."
                        Remove-Item -Recurse -Force $VenvDir
                    }
                } catch {
                    $sync.Detail = "Recreating venv (broken)..."
                    Remove-Item -Recurse -Force $VenvDir
                }
            } else {
                $sync.Detail = "Recreating venv (missing python.exe)..."
                Remove-Item -Recurse -Force $VenvDir
            }
        }

        if (-not (Test-Path $VenvDir)) {
            $sync.Detail = "Creating virtual environment..."
            $sync.Progress = 15
            try { & $cmd -m venv $VenvDir 2>&1 | Out-Null } catch { }
            if (-not (Test-Path $VenvPython)) {
                $sync.Detail = "Venv creation failed"
                $sync.Result = "error"
                $sync.Done = $true
                return
            }
        }

        $sync.Detail = "Upgrading pip..."
        $sync.Progress = 25
        try { & $VenvPython -m pip install -q --upgrade pip 2>&1 | Out-Null } catch { }

        $sync.Detail = "Installing dependencies..."
        $sync.Status = "Installing Python packages..."
        $sync.Progress = 40
        try {
            $pipOutput = & $VenvPython -m pip install -q -r (Join-Path $ProjectDir "requirements.txt") 2>&1
            $sync.Progress = 75
        } catch {
            $sync.Detail = "pip install failed: $($_.Exception.Message)"
            $sync.Result = "error"
            $sync.Done = $true
            return
        }

        $sync.Detail = "Checking pywin32..."
        $sync.Progress = 80
        $pywin32Check = & $VenvPython -c "import win32print; print('OK')" 2>&1 | Out-String
        $pywin32Warn = $false
        if ($pywin32Check.Trim() -ne "OK") {
            $sync.Detail = "Running pywin32 post-install..."
            $sync.Progress = 90
            try { & $VenvPython -m pywin32_postinstall -install 2>&1 | Out-Null } catch { $pywin32Warn = $true }
            $pywin32Check2 = & $VenvPython -c "import win32print; print('OK')" 2>&1 | Out-String
            if ($pywin32Check2.Trim() -ne "OK") { $pywin32Warn = $true }
        }

        $sync.Data.VenvPython = $VenvPython
        $sync.Progress = 100

        if ($pywin32Warn) {
            $sync.Detail = "Done (pywin32 may need manual setup)"
            $sync.Result = "warning"
        } else {
            $sync.Detail = "All dependencies installed"
            $sync.Result = "success"
        }
        $sync.Done = $true
    } -Vars @{ pyCmd = $pyCmd }
}

# ============================================================================
# STEP 3: USB Printer Registration
# ============================================================================
function Run-Step3-Printers {
    Start-Step -Code {
        $ErrorActionPreference = "Continue"
        $sync.Detail = "Scanning for USB printers..."
        $sync.Status = "Detecting USB printers..."
        $sync.Progress = 10

        $hasPrintMgmt = $false
        try {
            Import-Module PrintManagement -ErrorAction Stop
            $hasPrintMgmt = $true
        } catch { }

        if ($hasPrintMgmt) {
            $sync.Detail = "Checking printer drivers..."
            $sync.Progress = 20

            $installedDrivers = Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
            $driverName = $null

            foreach ($candidate in @("Generic / Text Only", "Generic/Text Only", "MS Publisher Imagesetter")) {
                if ($installedDrivers -contains $candidate) {
                    $driverName = $candidate
                    break
                }
            }

            if (-not $driverName) {
                $sync.Detail = "Installing Generic / Text Only driver..."
                $sync.Progress = 30
                $infPath = Join-Path $env:SystemRoot "inf\ntprint.inf"
                if (Test-Path $infPath) {
                    try { pnputil /add-driver $infPath /install 2>&1 | Out-Null } catch { }
                }
                try {
                    Add-PrinterDriver -Name "Generic / Text Only" -ErrorAction Stop
                    $driverName = "Generic / Text Only"
                } catch {
                    try {
                        Add-PrinterDriver -Name "Generic / Text Only" -InfPath $infPath -ErrorAction Stop
                        $driverName = "Generic / Text Only"
                    } catch { }
                }
            }

            $sync.Detail = "Scanning USB ports..."
            $sync.Progress = 50

            $usbPorts = Get-PrinterPort -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "USB*" }
            $existingPrinters = Get-Printer -ErrorAction SilentlyContinue
            $registeredCount = 0
            $existingCount = 0

            if ($usbPorts) {
                $sync.Progress = 60
                foreach ($port in $usbPorts) {
                    $portName = $port.Name
                    $alreadyUsed = $existingPrinters | Where-Object { $_.PortName -eq $portName }
                    if ($alreadyUsed) {
                        $existingCount++
                    } elseif ($driverName) {
                        $printerName = "POS-Printer-$portName"
                        try {
                            Add-Printer -Name $printerName -DriverName $driverName -PortName $portName -ErrorAction Stop
                            $registeredCount++
                        } catch { }
                    }
                }
            }

            $sync.Progress = 100
            if (-not $usbPorts -or $usbPorts.Count -eq 0) {
                $sync.Detail = "No USB printer ports found (plug in and re-run)"
                $sync.Result = "warning"
            } elseif ($registeredCount -gt 0) {
                $sync.Detail = "Registered $registeredCount new printer(s)"
                $sync.Result = "success"
            } else {
                $sync.Detail = "All USB ports already have printers ($existingCount found)"
                $sync.Result = "success"
            }
        } else {
            $sync.Detail = "Using printui.dll (Windows Home)..."
            $sync.Progress = 20
            $infPath = Join-Path $env:SystemRoot "inf\ntprint.inf"
            if (Test-Path $infPath) {
                try {
                    $proc = Start-Process -FilePath "rundll32.exe" `
                        -ArgumentList "printui.dll,PrintUIEntry /ia /m `"Generic / Text Only`" /f `"$infPath`"" `
                        -Wait -NoNewWindow -PassThru
                } catch { }
            }

            $sync.Progress = 50
            $regPorts = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\USB Monitor\Ports" -ErrorAction SilentlyContinue
            $portCount = 0
            if ($regPorts) {
                foreach ($port in $regPorts) {
                    $portName = $port.PSChildName
                    try {
                        $proc = Start-Process -FilePath "rundll32.exe" `
                            -ArgumentList "printui.dll,PrintUIEntry /if /b `"POS-Printer-$portName`" /r `"$portName`" /m `"Generic / Text Only`"" `
                            -Wait -NoNewWindow -PassThru
                        if ($proc.ExitCode -eq 0) { $portCount++ }
                    } catch { }
                }
            }

            $sync.Progress = 100
            if ($portCount -gt 0) {
                $sync.Detail = "Registered $portCount printer(s) via printui"
                $sync.Result = "success"
            } else {
                $sync.Detail = "No USB printers detected (plug in and re-run)"
                $sync.Result = "warning"
            }
        }
        $sync.Done = $true
    }
}

# ============================================================================
# STEP 4: Firewall Rule
# ============================================================================
function Run-Step4-Firewall {
    Start-Step -Code {
        $ErrorActionPreference = "Continue"
        $sync.Detail = "Checking firewall rules..."
        $sync.Status = "Configuring firewall..."
        $sync.Progress = 30

        $RuleName = "Baraka Printer Proxy"
        $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue

        if ($existing) {
            $sync.Detail = "Firewall rule already exists"
            $sync.Progress = 100
            $sync.Result = "success"
        } else {
            $sync.Detail = "Adding firewall rule for port 3006..."
            $sync.Progress = 60
            try {
                New-NetFirewallRule `
                    -DisplayName $RuleName `
                    -Direction Inbound `
                    -Protocol TCP `
                    -LocalPort 3006 `
                    -Action Allow `
                    -Profile Private,Domain | Out-Null
                $sync.Detail = "Firewall rule added (port 3006)"
                $sync.Progress = 100
                $sync.Result = "success"
            } catch {
                $sync.Detail = "Failed: $($_.Exception.Message)"
                $sync.Result = "error"
            }
        }
        $sync.Done = $true
    }
}

# ============================================================================
# STEP 5: Auto-Start Service
# ============================================================================
function Run-Step5-Service {
    $venvPy = $script:venvPython
    Start-Step -Code {
        $ErrorActionPreference = "Continue"
        $sync.Detail = "Configuring auto-start..."
        $sync.Status = "Setting up background service..."
        $sync.Progress = 10

        $TaskName = "Baraka Printer Proxy"

        $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            $sync.Detail = "Removing old scheduled task..."
            $sync.Progress = 15
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }

        $sync.Detail = "Creating launcher script..."
        $sync.Progress = 30
        $LauncherVbs = Join-Path $ProjectDir "deployment\start-hidden.vbs"
        $AppPath = Join-Path $ProjectDir "app.py"
        $VenvPython = $venvPy

        $vbsContent = "Set WshShell = CreateObject(""WScript.Shell"")" + "`r`n"
        $vbsContent += "WshShell.CurrentDirectory = """ + ($ProjectDir -replace '\\', '\\') + """" + "`r`n"
        $vbsContent += "WshShell.Run Chr(34) & """ + ($VenvPython -replace '\\', '\\') + """ & Chr(34) & "" "" & Chr(34) & """ + ($AppPath -replace '\\', '\\') + """ & Chr(34), 0, False" + "`r`n"
        $vbsContent | Out-File -Encoding ASCII $LauncherVbs

        $sync.Detail = "Registering scheduled task..."
        $sync.Progress = 50
        try {
            $Action = New-ScheduledTaskAction `
                -Execute "wscript.exe" `
                -Argument ('"' + $LauncherVbs + '"') `
                -WorkingDirectory $ProjectDir

            $Trigger = New-ScheduledTaskTrigger -AtLogOn

            $Settings = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -StartWhenAvailable `
                -ExecutionTimeLimit (New-TimeSpan -Days 365) `
                -RestartCount 3 `
                -RestartInterval (New-TimeSpan -Minutes 1)

            Register-ScheduledTask `
                -TaskName $TaskName `
                -Action $Action `
                -Trigger $Trigger `
                -Settings $Settings `
                -Description "Baraka POS Printer Proxy Server (hidden)" `
                -RunLevel Highest | Out-Null

            $sync.Detail = "Starting server..."
            $sync.Progress = 80
            Start-ScheduledTask -TaskName $TaskName

            $sync.Detail = "Server started (auto-start enabled)"
            $sync.Progress = 100
            $sync.Result = "success"
        } catch {
            $sync.Detail = "Failed: $($_.Exception.Message)"
            $sync.Result = "error"
        }
        $sync.Done = $true
    } -Vars @{ venvPy = $venvPy }
}

# ============================================================================
# INSTALL BUTTON
# ============================================================================
$installBtn.Add_Click({
    $installBtn.Enabled = $false
    $welcomePanel.Visible = $false
    $progressPanel.Visible = $true
    $script:currentStep = 0
    Start-NextStep
})

# ============================================================================
# LAUNCH
# ============================================================================
[void]$form.ShowDialog()

$script:pollTimer.Stop()
$script:pollTimer.Dispose()
$form.Dispose()
